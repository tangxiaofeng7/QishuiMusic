//! SodaM 移动端 FFI 桥。
//!
//! 把 libresoda（汽水音乐核心：搜索 / 取流 / 解密 / 扫码登录）包装成
//! C ABI 的 JSON 接口，供 Flutter（Dart FFI）在 iOS / Android 上调用：
//!
//! ```c
//! char* sodam_init(const char* config_json);          // 配置/重建全局会话
//! char* sodam_request(const char* method, const char* params_json);
//! void  sodam_free(char* s);                          // 释放返回的字符串
//! char* sodam_signer_poll(void);                      // 取一条待签名请求（无则 id 为空）
//! char* sodam_signer_respond(const char* json);       // 回填签名结果
//! ```
//!
//! 所有返回值都是 `{"ok":true,"data":...}` 或 `{"ok":false,"error":"..."}`。
//! 调用是同步阻塞的（网络在 Rust 侧完成），Dart 侧应放到后台 isolate 执行。
//!
//! 签名设计（2026-10 改造）：
//! * 不再有任何「远程签名服务 / 远程签名页」配置；
//! * passport 请求（扫码登录）所需的 `a_bogus` 网页签名由 **App 内置的
//!   隐藏 WebView 签名页** 提供：Rust 通过 `sodam_signer_poll/respond`
//!   把请求交给 Dart，Dart 在签名页里执行 `__qishuiRequest`（bdms.js
//!   对 XHR 的补丁自动补签名）后回填结果；
//! * 曲库/歌单/历史播放走汽水移动端开放接口（`aid=8478`，Cookie 即可，
//!   实测免应用签名），PC 接口仅作回退。

use std::collections::{HashMap, VecDeque};
use std::ffi::{c_char, CStr, CString};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

mod ext_source;

// 汽水引擎整体内联（原 vendor/libresoda crate，AGPL-3.0-or-later，
// 出处与上游见 NOTICE.md 与 rust/sodam-ffi/NOTICE-libresoda.md）。
// 引擎内部以 `crate::http` / `crate::soda` 等路径互引，与原 crate 内
// 引用形态一致，故挂在本 crate 根下零改动编译。
pub mod error;
pub mod http;
pub mod model;
pub mod soda;
pub mod util;


use crate::model::QRLoginStatus;
use crate::soda::browser::{BrowserRequest, BrowserRequester, BrowserResponse};
use crate::soda::quality::is_lossless;
use crate::soda::track::build_song_from_track;
use crate::soda::types::{
    build_image_url, join_track_artists, Album, Artist, Track, UserPlaylistItem,
};
use crate::soda::user_playlist::fetch_pc_me;
use crate::soda::Soda;
use serde_json::{json, Value};

pub const FFI_VERSION: &str = concat!(env!("CARGO_PKG_VERSION"), "/libresoda-mobile");

const MOBILE_AID: &str = "8478";
const MOBILE_UA: &str = "SodaMusic/21.0.0 (iPhone; iOS 17.1.1)";
const API_BASE: &str = "https://api.qishui.com";

// ---------------------------------------------------------------------------
// 配置与全局会话
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default)]
struct Config {
    cookie: String,
    /// 音质偏好：best/lossless/highest/medium/low，空 = 自动。
    quality: String,
    /// 缓存目录（由 Dart 传入应用沙盒内的路径，移动端不依赖 dirs）。
    cache_dir: String,
    /// 外部音源回落（lx-music 式内置源）：汽水侧只有试听时按标题+歌手
    /// 匹配酷我免费整曲。默认开（要关在 App 设置里关）。
    ext_enabled: bool,
    /// 播放音源：default = 汽水账号（默认）；lx = 洛雪链优先（Dart 侧
    /// 先解析外部源）。历史值 sodam 已并入 default——签名服务不再是独立
    /// 音源，配置即挂载。
    source_mode: String,
    /// 音质限免链路：签名服务地址（libmssdk / qishui-signer-host）。
    /// 配置即生效：免费曲经 App 端点可取全景声/录音室/无损全档
    /// （服务端对签名请求不按账号限档）；VIP 专属曲整曲仍按账号判。
    signer_url: String,
    /// 签名服务鉴权令牌（Authorization: Bearer）。
    signer_token: String,
    /// 与签名服务一致的设备指纹（device_id，必填才能走 App 端点）。
    device_id: String,
    /// install id（可选；fp 缺省回落 device_id）。
    iid: String,
}

impl Config {
    fn from_json(value: &Value) -> Self {
        let text = |key: &str| {
            value
                .get(key)
                .and_then(Value::as_str)
                .unwrap_or_default()
                .trim()
                .to_string()
        };
        Self {
            cookie: text("cookie"),
            quality: text("quality"),
            cache_dir: text("cacheDir"),
            ext_enabled: value.get("extEnabled").and_then(Value::as_bool).unwrap_or(true),
            source_mode: text("sourceMode"),
            signer_url: text("signerUrl"),
            signer_token: text("signerToken"),
            device_id: text("deviceId"),
            iid: text("iid"),
        }
    }

    /// 签名服务可用：地址配置即挂载（不再要求选择特定音源）。
    fn signer_ready(&self) -> bool {
        !self.signer_url.is_empty()
    }
}

struct Mobile {
    soda: Arc<Soda>,
    config: Config,
}

fn build_soda(config: &Config) -> Soda {
    let soda = Soda::new(config.cookie.clone());
    // passport（扫码登录）请求一律走 App 内置 WebView 签名页。
    soda.set_browser_requester(Arc::new(DartSignerBridge::default()));
    if !config.quality.is_empty() {
        soda.set_quality_preference(config.quality.trim());
    }
    // 音质限免链路：远程签名服务（libmssdk 形态，POST /sign + Bearer
    // token）逐请求出 x-helios/x-medusa，配合设备指纹走 App 端点
    // （/luna/pc/track_v2）取全档音质；签名失败时请求按未签名发出，
    // 服务端回空 body，probe 自然回落网页端点（音质限免静默失效）。
    if config.signer_ready() {
        let mut signer = crate::soda::signature::HttpSignature::new(config.signer_url.clone())
            .with_token(config.signer_token.clone());
        signer = signer.timeout_ms(10_000);
        soda.set_signature_provider(Arc::new(signer));
        if !config.device_id.is_empty() {
            soda.set_app_credentials(crate::soda::signature::AppCredentials {
                device_id: config.device_id.clone(),
                iid: config.iid.clone(),
                fp: config.device_id.clone(),
                ..Default::default()
            });
        }
    }
    soda
}

fn mobile() -> &'static Mutex<Mobile> {
    static CELL: OnceLock<Mutex<Mobile>> = OnceLock::new();
    CELL.get_or_init(|| {
        Mutex::new(Mobile {
            soda: Arc::new(build_soda(&Config::default())),
            config: Config::default(),
        })
    })
}

/// 会话快照：锁内 clone（Soda 内部全部字段自带 Mutex，`Arc` 共享等价同一
/// 会话），网络在锁外执行——`prepareTrack` 这类长 IO（整曲下载可达数十秒）
/// 不再堵住其它请求，页面接口得以并发（对齐官方客户端的请求并发行为）。
struct Snap {
    soda: Arc<Soda>,
    config: Config,
}

/// 拿全局锁只做快照，放锁后执行闭包。
fn with_mobile<T>(f: impl FnOnce(&Snap) -> Result<T, String>) -> Result<T, String> {
    let snap = {
        let guard = mobile().lock().map_err(|_| "全局会话锁中毒".to_string())?;
        Snap {
            soda: guard.soda.clone(),
            config: guard.config.clone(),
        }
    };
    f(&snap)
}

// ---------------------------------------------------------------------------
// 内置 WebView 签名桥：Rust ⇄ Dart 的请求队列
// ---------------------------------------------------------------------------

/// 一条挂起的签名请求（等 Dart 回填）。`id` 已内嵌在 `request_json` 里。
struct PendingSign {
    request_json: String,
}

/// 二次验证登记项（check_qrconnect 返回 2046 时由 qr_login 登记）。
#[derive(Default, Clone)]
struct SecondVerifyEntry {
    decision: Value,
    general_params: Value,
    done: bool,
    /// 是否已通知过 Dart 弹出验证窗口（决策可刷新，窗口只弹一次）。
    notified: bool,
}

static SECOND_VERIFY: OnceLock<Mutex<HashMap<String, SecondVerifyEntry>>> = OnceLock::new();

/// 登记次数计数（诊断：区分「没登记过」与「登记了但查不到」）。
static SECOND_VERIFY_REGISTERS: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(0);

fn token_tail(token: &str) -> String {
    token.chars().rev().take(8).collect::<Vec<_>>()
        .into_iter().rev().collect()
}

fn second_verify_map(
) -> &'static Mutex<HashMap<String, SecondVerifyEntry>> {
    SECOND_VERIFY.get_or_init(|| Mutex::new(HashMap::new()))
}

fn second_verify_notify(token: &str) {
    // 复用签名请求队列：Dart 轮询到 type=secondVerify 的消息时弹验证窗口。
    let bridge = DartSignerBridge::global();
    if let Ok(mut inner) = bridge.inner.lock() {
        let id = format!("verify-{token}");
        inner.queue.push_back(PendingSign {
            request_json: serde_json::to_string(&json!({
                "id": id,
                "request": { "type": "secondVerify", "token": token },
            }))
            .unwrap_or_default(),
        });
        bridge.events.notify_all();
    }
}

#[derive(Default)]
struct SignerBridge {
    inner: Mutex<SignerBridgeInner>,
    /// 有新事件（入队 / 回填）时唤醒等待中的 request()。
    events: Condvar,
}

#[derive(Default)]
struct SignerBridgeInner {
    queue: VecDeque<PendingSign>,
    /// `id → 回填结果`。request() 在这等结果（跨线程，必须是全局的）。
    responds: HashMap<String, Result<Value, String>>,
    next_seq: u64,
}

impl SignerBridgeInner {
    fn new_id(&mut self) -> String {
        self.next_seq += 1;
        let millis = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|v| v.as_millis())
            .unwrap_or_default();
        format!("s{millis:x}-{}", self.next_seq)
    }
}

/// [`BrowserRequester`] 的 App 内置实现：请求塞进队列，等 Dart 侧
/// （隐藏 WebView 里的签名页）通过 `sodam_signer_poll/respond` 处理。
struct DartSignerBridge {
    shared: &'static SignerBridge,
}

impl Default for DartSignerBridge {
    fn default() -> Self {
        Self {
            shared: Self::global(),
        }
    }
}

impl DartSignerBridge {
    fn global() -> &'static SignerBridge {
        static BRIDGE: OnceLock<SignerBridge> = OnceLock::new();
        BRIDGE.get_or_init(SignerBridge::default)
    }
}

impl BrowserRequester for DartSignerBridge {
    fn request(&self, request: &BrowserRequest) -> crate::error::Result<BrowserResponse> {
        let spec = serde_json::to_value(request)
            .map_err(|err| crate::error::SodaError::json(format!("signer request encode: {err}")))?;
        let id = {
            let mut inner = self
                .shared
                .inner
                .lock()
                .map_err(|_| crate::error::SodaError::http("签名桥锁中毒"))?;
            let id = inner.new_id();
            inner.queue.push_back(PendingSign {
                request_json: serde_json::to_string(&json!({ "id": id, "request": spec }))
                    .unwrap_or_default(),
            });
            self.shared.events.notify_all();
            id
        };
        // 签名页冷启动（首次加载 bdms.js）可能要几秒；超时不能太长：
        // 本调用持有全局会话锁，挂太久会阻塞其它页面的所有请求。
        let deadline = Instant::now() + Duration::from_secs(20);
        let reply = loop {
            let now = Instant::now();
            if now >= deadline {
                // 超时清理自己的应答槽，防止 respond 晚到后泄漏。
                if let Ok(mut inner) = self.shared.inner.lock() {
                    inner.responds.remove(&id);
                }
                return Err(crate::error::SodaError::http(
                    "签名页超时：内置签名 WebView 未响应（请重试，首次加载安全组件较慢）",
                ));
            }
            let mut guard = self
                .shared
                .inner
                .lock()
                .map_err(|_| crate::error::SodaError::http("签名桥锁中毒"))?;
            if let Some(reply) = guard.responds.remove(&id) {
                break reply;
            }
            let (guard, _) = self
                .shared
                .events
                .wait_timeout(guard, Duration::from_millis(200))
                .map_err(|_| crate::error::SodaError::http("签名桥等待失败"))?;
            drop(guard);
        };
        match reply {
            Ok(value) => {
                let response: BrowserResponse = serde_json::from_value(value).map_err(|err| {
                    crate::error::SodaError::http(format!("签名页响应解析失败: {err}"))
                })?;
                if !response.ok || (response.error.is_empty() && response.status == 0) {
                    return Err(crate::error::SodaError::http(if response.error.is_empty() {
                        "签名页未返回结果".to_string()
                    } else {
                        response.error.clone()
                    }));
                }
                // 中继 5xx（DNS 失败/网络断开等）时 body 是纯文本错误说明，
                // 不能当 JSON 往下传（否则用户看到「返回无效数据」却不知是
                // 网络问题）——直接把原因浮出来。
                if response.status >= 400 {
                    let reason: String = response
                        .body
                        .chars()
                        .take(160)
                        .collect::<String>()
                        .trim()
                        .to_string();
                    return Err(crate::error::SodaError::http(format!(
                        "网络请求失败（HTTP {}）：{}",
                        response.status, reason
                    )));
                }
                Ok(response)
            }
            Err(message) => Err(crate::error::SodaError::http(format!("签名页请求失败: {message}"))),
        }
    }

    fn close_session(&self, _session_key: &str) -> crate::error::Result<()> {
        // 签名页是 App 内共享的单一 WebView 上下文，无远程会话可关。
        Ok(())
    }

    /// 登记 2046 二次验证决策：存登记表并通知 Dart 弹出验证窗口。
    fn register_second_verify(
        &self,
        token: &str,
        _session_key: &str,
        decision: &Value,
        general_params: &Value,
    ) -> crate::error::Result<()> {
        let mut map = second_verify_map()
            .lock()
            .map_err(|_| crate::error::SodaError::http("二次验证登记表锁中毒"))?;
        let entry = map.entry(token.trim().to_string()).or_default();
        // 决策每次轮询都会刷新（std_verify_token 会换新），窗口只通知一次。
        entry.decision = decision.clone();
        entry.general_params = general_params.clone();
        SECOND_VERIFY_REGISTERS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        if !entry.notified {
            entry.notified = true;
            drop(map);
            second_verify_notify(token);
        }
        Ok(())
    }

    fn second_verify_done(&self, token: &str) -> bool {
        second_verify_map()
            .lock()
            .ok()
            .and_then(|map| map.get(token.trim()).map(|entry| entry.done))
            .unwrap_or(false)
    }

    fn ack_second_verify(&self, token: &str) -> crate::error::Result<()> {
        if let Ok(mut map) = second_verify_map().lock() {
            if let Some(entry) = map.get_mut(token.trim()) {
                entry.done = false;
            }
        }
        Ok(())
    }

    fn clear_second_verify(&self, token: &str) -> crate::error::Result<()> {
        if let Ok(mut map) = second_verify_map().lock() {
            map.remove(token.trim());
        }
        Ok(())
    }

    fn name(&self) -> &'static str {
        "in-app-webview"
    }
}

/// Dart 轮询：取一条待签名请求；返回 `{"id":"", ...}` 表示当前没有。
fn signer_poll() -> Result<Value, String> {
    let bridge = DartSignerBridge::global();
    let mut inner = bridge
        .inner
        .lock()
        .map_err(|_| "签名桥锁中毒".to_string())?;
    match inner.queue.pop_front() {
        Some(pending) => serde_json::from_str(&pending.request_json)
            .map_err(|err| format!("签名请求损坏: {err}")),
        None => Ok(json!({ "id": "" })),
    }
}

/// Dart 回填：`{"id":"...","ok":true,"response":{...}}` 或
/// `{"id":"...","ok":false,"error":"..."}`。
fn signer_respond(value: &Value) -> Result<Value, String> {
    let id = value.get("id").and_then(Value::as_str).unwrap_or_default();
    if id.is_empty() {
        return Err("缺少签名请求 id".to_string());
    }
    let ok = value.get("ok").and_then(Value::as_bool).unwrap_or(false);
    let bridge = DartSignerBridge::global();
    let mut inner = bridge
        .inner
        .lock()
        .map_err(|_| "签名桥锁中毒".to_string())?;
    let reply = if ok {
        Ok(value.get("response").cloned().unwrap_or(Value::Null))
    } else {
        Err(value
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("未知错误")
            .to_string())
    };
    inner.responds.insert(id.to_string(), reply);
    // 应答表兜底清理：只保留最近的应答，防止没人认领的槽堆积。
    if inner.responds.len() > 32 {
        inner.responds.clear();
    }
    bridge.events.notify_all();
    Ok(json!({ "ok": true }))
}

// ---------------------------------------------------------------------------
// JSON 形状：Track
// ---------------------------------------------------------------------------

fn track_json(song: &crate::model::Song) -> Value {
    json!({
        "id": song.id,
        "title": song.name,
        "artist": song.artist,
        "album": song.album,
        "artistId": song.extra_get("artist_id").unwrap_or_default(),
        "albumId": song.album_id,
        "cover": song.cover,
        "durationSeconds": song.duration,
        "vip": song.is_vip,
    })
}

fn tracks_json(songs: &[crate::model::Song]) -> Value {
    Value::Array(songs.iter().map(track_json).collect())
}

/// 从 Dart 传回的 track JSON 还原 `Song`（prepareTrack 用）。
fn song_from_json(value: &Value) -> Result<crate::model::Song, String> {
    let text = |key: &str| {
        value
            .get(key)
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim()
            .to_string()
    };
    let id = text("id");
    if id.is_empty() {
        return Err("缺少歌曲 id".to_string());
    }
    let artist_id = text("artistId");
    let extra = std::collections::BTreeMap::from([
        ("track_id".to_string(), id.clone()),
        ("artist_id".to_string(), artist_id),
    ]);
    Ok(crate::model::Song {
        id: id.clone(),
        name: text("title"),
        artist: text("artist"),
        album: text("album"),
        album_id: text("albumId"),
        duration: value
            .get("durationSeconds")
            .and_then(Value::as_i64)
            .unwrap_or_default(),
        cover: text("cover"),
        is_vip: value.get("vip").and_then(Value::as_bool).unwrap_or(false),
        source: "soda".to_string(),
        link: format!("https://www.qishui.com/track/{id}"),
        extra,
        ..Default::default()
    })
}

// ---------------------------------------------------------------------------
// 移动端开放接口（aid=8478，Cookie 即可）
// ---------------------------------------------------------------------------

fn mobile_options(m: &Snap) -> Vec<crate::http::RequestOption> {
    vec![
        crate::http::RequestOption::new()
            .header("User-Agent", MOBILE_UA)
            .cookie(&m.config.cookie)
            .timeout(Duration::from_secs(15)),
    ]
}

/// 移动端 GET：`/luna/...` 系列接口公共参数 + Cookie。
fn mobile_get(m: &Snap, path: &str, extra: &[(&str, &str)]) -> Result<Value, String> {
    let mut query = format!("aid={MOBILE_AID}&device_platform=iphone");
    for (key, value) in extra {
        query.push_str(&format!("&{key}={}", urlencode(value)));
    }
    let url = format!("{API_BASE}{path}?{query}");
    let raw = crate::http::get(&url, &mobile_options(m)).map_err(|err| {
        format!(
            "汽水接口请求失败（{path}）: {err}；若持续失败请检查登录是否过期"
        )
    })?;
    if raw.is_empty() {
        return Err(format!("汽水接口返回空响应（{path}）：登录可能已过期，请重新登录"));
    }
    serde_json::from_slice(&raw).map_err(|err| format!("响应解析失败（{path}）: {err}"))
}

fn urlencode(value: &str) -> String {
    let mut out = String::new();
    for byte in value.as_bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(*byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// 移动端 POST JSON：官方 App 同款端点（如 `/luna/feed/song-tab`），Cookie 即可。
fn mobile_post_json(m: &Snap, path: &str, body: &Value) -> Result<Value, String> {
    let url = format!("{API_BASE}{path}?aid={MOBILE_AID}&device_platform=iphone");
    let mut options = mobile_options(m);
    options.push(
        crate::http::RequestOption::new()
            .header("Content-Type", "application/json; charset=utf-8"),
    );
    let body_bytes = serde_json::to_vec(body)
        .map_err(|err| format!("请求编码失败（{path}）: {err}"))?;
    let raw = crate::http::post_json(&url, &body_bytes, &options)
        .map_err(|err| format!("汽水接口请求失败（{path}）: {err}"))?;
    if raw.is_empty() {
        return Err(format!("汽水接口返回空响应（{path}）"));
    }
    serde_json::from_slice(&raw).map_err(|err| format!("响应解析失败（{path}）: {err}"))
}

/// 统计条目里「只有视频实体（抖音视频，暂不支持播放）」的数量，供上层提示。
fn count_video_items(items: Option<&Value>) -> usize {
    items
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter(|item| {
                    let has_track = item
                        .pointer("/entity/track_wrapper/track")
                        .or_else(|| item.pointer("/entity/track"))
                        .is_some();
                    let has_video = item.pointer("/entity/video").is_some();
                    has_video && !has_track
                })
                .count()
        })
        .unwrap_or(0)
}

/// 从移动端 `media_resources` / `media` 列表里抽曲目。
fn tracks_from_media_resources(value: Option<&Value>) -> Vec<crate::model::Song> {
    let mut songs = Vec::new();
    let Some(items) = value.and_then(Value::as_array) else {
        return songs;
    };
    for item in items {
        let track = item
            .pointer("/entity/track_wrapper/track")
            .or_else(|| item.pointer("/entity/track"));
        let Some(track) = track else { continue };
        let parsed: Option<Track> = serde_json::from_value(track.clone()).ok();
        // 过滤无 id/无名的杂项条目（电台流里偶发视频卡/推荐位带空壳 track）
        if let Some(track) = parsed
            .filter(|track| !track.id.is_empty() && !track.name.trim().is_empty())
        {
            songs.push(build_song_from_track(&track));
        }
    }
    songs
}

fn require_cookie(m: &Snap) -> Result<(), String> {
    if m.config.cookie.trim().is_empty() {
        return Err("未登录：请先在「我的」里登录".to_string());
    }
    Ok(())
}

/// 账号信息：移动端 `/luna/me`，失败回退 PC。
fn method_account(m: &Snap) -> Result<Value, String> {
    if let Ok(value) = mobile_get(m, "/luna/me", &[]) {
        let info = value.pointer("/my_info").cloned().unwrap_or(Value::Null);
        if info.is_object() {
            let nickname = info
                .get("nickname")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .trim()
                .to_string();
            if !nickname.is_empty() {
                let vip_stage = info
                    .get("vip_stage")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .trim()
                    .to_ascii_lowercase();
                let vip = info.get("is_vip").and_then(Value::as_bool).unwrap_or(false)
                    || matches!(vip_stage.as_str(), "vip" | "svip");
                let image = info
                    .pointer("/larger_avatar_url")
                    .or_else(|| info.pointer("/avatar_url"));
                let mut avatar_url = String::new();
                if let Some(image) = image {
                    if let Some(uri) = image.get("uri").and_then(Value::as_str) {
                        let _ = uri;
                    }
                    if let Some(first) = image
                        .get("urls")
                        .and_then(Value::as_array)
                        .and_then(|urls| urls.first())
                        .and_then(Value::as_str)
                    {
                        avatar_url = first.to_string();
                        if let Some(uri) = image.get("uri").and_then(Value::as_str) {
                            if !uri.is_empty() && !avatar_url.contains(uri) {
                                avatar_url.push_str(uri);
                            }
                        }
                    }
                }
                return Ok(json!({
                    "nickname": nickname,
                    "userId": info.get("id").and_then(Value::as_str).unwrap_or_default(),
                    "vip": vip,
                    "avatarUrl": avatar_url,
                }));
            }
        }
    }
    // PC 回退（网页登录 Cookie 形态走这条也能通）。
    let me = fetch_pc_me(&m.soda).map_err(|err| format!("读取账号信息失败: {err}"))?;
    let vip = me.my_info.is_vip
        || matches!(
            me.my_info.vip_stage.trim().to_ascii_lowercase().as_str(),
            "vip" | "svip"
        );
    let image = &me.my_info.larger_avatar_url;
    let mut avatar_url = image.urls.first().cloned().unwrap_or_default();
    if !avatar_url.is_empty() && !image.uri.is_empty() && !avatar_url.contains(&image.uri) {
        avatar_url.push_str(&image.uri);
    }
    Ok(json!({
        "nickname": me.my_info.nickname.trim(),
        "userId": me.my_info.id.trim(),
        "vip": vip,
        "avatarUrl": avatar_url,
    }))
}

/// 移动端歌单列表：`type=1` 我喜欢的音乐、`type=4` 抖音收藏的音乐。
/// 注意：全新/冷账号的回包里没有 `playlists` 字段——那是「还没有歌单」，
/// 不是错误（按空列表处理，别把裸错误甩到「我的」页吓用户）。
fn mobile_playlists_json(value: &Value) -> Result<Vec<Value>, String> {
    let status = value
        .get("status_code")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let Some(items) = value.get("playlists").and_then(Value::as_array) else {
        if status == 0 {
            return Ok(Vec::new());
        }
        return Err(format!("歌单接口返回错误（{status}）"));
    };
    let mut out = Vec::new();
    for item in items {
        let id = item.get("id").and_then(Value::as_str).unwrap_or_default();
        if id.is_empty() {
            continue;
        }
        let title = if item.get("public_title").and_then(Value::as_str).map_or(false, |t| {
            !t.trim().is_empty()
        }) {
            item.get("public_title").and_then(Value::as_str).unwrap_or_default().to_string()
        } else {
            item.get("title")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string()
        };
        let cover = item
            .get("url_cover")
            .and_then(|image| serde_json::from_value::<crate::soda::types::Image>(image.clone()).ok())
            .map(|image| build_image_url(&image, "~c5_300x300.jpg"))
            .unwrap_or_default();
        let count = item
            .pointer("/resource_cnt/total")
            .and_then(Value::as_i64)
            .or_else(|| item.get("count_tracks").and_then(Value::as_i64))
            .unwrap_or(0);
        let creator = item
            .pointer("/owner/nickname")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        out.push(json!({
            "id": id,
            "title": title,
            "cover": cover,
            "trackCount": count,
            "creator": creator,
            "kind": item.get("type").and_then(Value::as_i64).unwrap_or(0),
        }));
    }
    Ok(out)
}

fn method_my_playlists(m: &Snap, params: &Value) -> Result<Value, String> {
    require_cookie(m)?;
    let cursor = params
        .get("cursor")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    let count = params.get("count").and_then(Value::as_i64).unwrap_or(50);
    if let Ok(value) = mobile_get(m, "/luna/me/playlist", &[("cursor", cursor), ("count", &count.to_string())]) {
        // 移动端业务失败（如网页会话被 1000006 拒）→ 回落 PC 形态，
        // 而不是把错误甩给 UI（网页 Cookie 本来就该走 PC 接口）。
        if let Ok(playlists) = mobile_playlists_json(&value) {
            return Ok(json!({
                "playlists": playlists,
                "hasMore": value.get("has_more").and_then(Value::as_bool).unwrap_or(false),
                "nextCursor": value.get("next_cursor").and_then(Value::as_str).unwrap_or_default(),
            }));
        }
    }
    // PC 回退。
    let page = m
        .soda
        .get_my_playlists(cursor, count)
        .map_err(|err| format!("读取我的歌单失败: {err}"))?;
    let playlists: Vec<Value> = page
        .playlists
        .iter()
        .map(|p| {
            json!({
                "id": p.id, "title": p.name, "cover": p.cover,
                "trackCount": p.track_count, "creator": p.creator, "kind": 0,
            })
        })
        .collect();
    Ok(json!({
        "playlists": playlists,
        "hasMore": page.has_more,
        "nextCursor": page.next_cursor,
    }))
}

/// 歌单元数据：`/luna/playlist/detail` 首屏回包里的 `playlist` 对象
/// （标题/描述/创建者/统计）。字段缺失时返回 Null，UI 用传入的歌单
/// 条目兜底——同一个请求顺手带出，零新增端点。
fn playlist_meta_json(value: &Value) -> Value {
    let item = value.get("playlist").cloned().unwrap_or(Value::Null);
    if !item.is_object() {
        return Value::Null;
    }
    let typed: UserPlaylistItem =
        serde_json::from_value(item.clone()).unwrap_or_default();
    let raw_count = item
        .pointer("/resource_cnt/total")
        .or_else(|| item.pointer("/resource_cnt/track_cnt"))
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let track_count = if raw_count > 0 {
        raw_count
    } else {
        typed.count_tracks
    };
    let play_count = item
        .get("play_count")
        .and_then(Value::as_i64)
        .unwrap_or(0)
        .max(typed.stats.count_played);
    let collected = item
        .pointer("/stats/count_collected")
        .and_then(Value::as_i64)
        .unwrap_or(0)
        .max(typed.stats.count_collected);
    json!({
        "id": typed.id,
        "title": if typed.public_title.is_empty() {
            typed.title.clone()
        } else {
            typed.public_title.clone()
        },
        "desc": typed.desc,
        "cover": build_image_url(&typed.url_cover, "~c5_300x300.jpg"),
        "trackCount": track_count,
        "playCount": play_count,
        "collectedCount": collected,
        "creator": if typed.owner.public_name.is_empty() {
            typed.owner.nickname.clone()
        } else {
            typed.owner.public_name.clone()
        },
        "isPrivate": typed.is_private,
    })
}

/// 歌单曲目：移动端 `/luna/playlist/detail`（`media_resources`），
/// 附带首屏回包里的歌单元数据。
fn method_playlist_tracks(m: &Snap, params: &Value) -> Result<Value, String> {
    require_cookie(m)?;
    let playlist_id = params
        .get("playlistId")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    if playlist_id.is_empty() {
        return Err("缺少歌单 id".to_string());
    }
    let mut songs: Vec<crate::model::Song> = Vec::new();
    let mut videos: usize = 0;
    let mut meta = Value::Null;
    let mut cursor = String::new();
    for _page in 0..20 {
        let value = match mobile_get(
            m,
            "/luna/playlist/detail",
            &[
                ("playlist_id", playlist_id),
                ("cursor", &cursor.clone()),
                ("count", "100"),
            ],
        ) {
            Ok(value) => value,
            Err(err) => {
                if songs.is_empty() && videos == 0 {
                    return Err(err);
                }
                break;
            }
        };
        if meta.is_null() {
            meta = playlist_meta_json(&value);
        }
        videos += count_video_items(value.get("media_resources"));
        let page_songs = tracks_from_media_resources(value.get("media_resources"));
        let before = songs.len();
        let mut seen = songs
            .iter()
            .map(|song| song.id.clone())
            .collect::<std::collections::HashSet<_>>();
        for song in page_songs {
            if seen.insert(song.id.clone()) {
                songs.push(song);
            }
        }
        let next = value
            .get("next_cursor")
            .and_then(|v| {
                v.as_str()
                    .map(str::to_string)
                    .or_else(|| v.as_i64().map(|n| n.to_string()))
            })
            .unwrap_or_default();
        let grew = songs.len() > before;
        if !grew || next.is_empty() || next == "0" {
            break;
        }
        cursor = next;
    }
    if songs.is_empty() && videos == 0 {
        // PC 回退（网页 Cookie 形态）。
        let fallback = m
            .soda
            .get_playlist_songs(playlist_id)
            .map_err(|err| format!("读取歌单歌曲失败: {err}"))?;
        songs = fallback;
    }
    Ok(json!({ "tracks": tracks_json(&songs), "videos": videos, "playlist": meta }))
}

/// 「我喜欢的音乐」：type=1 的系统歌单；找不到时按名字兜底。
fn method_liked_songs(m: &Snap) -> Result<Value, String> {
    require_cookie(m)?;
    let target = find_special_playlist(m, 1, &["喜欢", "收藏"])?;
    method_playlist_tracks(
        m,
        &json!({ "playlistId": target }),
    )
}

/// 「抖音收藏的音乐」：type=4 的系统歌单。
fn method_douyin_favorites(m: &Snap) -> Result<Value, String> {
    require_cookie(m)?;
    let target = find_special_playlist(m, 4, &["抖音收藏"])?;
    method_playlist_tracks(
        m,
        &json!({ "playlistId": target }),
    )
}

fn find_special_playlist(m: &Snap, kind: i64, name_hints: &[&str]) -> Result<String, String> {
    // 系统歌单 id 对账号是稳定的:按 (cookie 尾巴, kind) 缓存,命中即省掉
    // 每次「我喜欢的/抖音收藏」打开时的整轮歌单列表探测(串行 1~2 个请求)。
    // 登录(换 cookie)自动失效。
    static CACHE: OnceLock<Mutex<HashMap<(String, i64), String>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    let cache_key = (token_tail(m.config.cookie.as_str()), kind);
    if let Ok(map) = cache.lock() {
        if let Some(hit) = map.get(&cache_key) {
            if !hit.is_empty() {
                return Ok(hit.clone());
            }
        }
    }
    let found = find_special_playlist_remote(m, kind, name_hints)?;
    if let Ok(mut map) = cache.lock() {
        map.insert(cache_key, found.clone());
    }
    Ok(found)
}

fn find_special_playlist_remote(m: &Snap, kind: i64, name_hints: &[&str]) -> Result<String, String> {
    // 移动端优先；业务失败（网页会话被 1000006 拒等）→ 回落 PC 歌单列表。
    if let Ok(value) = mobile_get(m, "/luna/me/playlist", &[("cursor", ""), ("count", "50")]) {
        if let Ok(playlists) = mobile_playlists_json(&value) {
            if let Some(hit) = playlists
                .iter()
                .find(|p| p.get("kind").and_then(Value::as_i64) == Some(kind))
            {
                return Ok(hit["id"].as_str().unwrap_or_default().to_string());
            }
            if let Some(hit) = playlists.iter().find(|p| {
                name_hints.iter().any(|hint| {
                    p["title"]
                        .as_str()
                        .map_or(false, |title| title.contains(hint))
                })
            }) {
                return Ok(hit["id"].as_str().unwrap_or_default().to_string());
            }
        }
    }
    // PC 回退：按系统歌单标题特征匹配（我喜欢的音乐 / 在抖音收藏的音乐）。
    let page = m
        .soda
        .get_my_playlists("", 50)
        .map_err(|err| format!("读取我的歌单失败: {err}"))?;
    if let Some(hit) = page.playlists.iter().find(|p| {
        name_hints.iter().any(|hint| p.name.contains(hint))
    }) {
        return Ok(hit.id.clone());
    }
    Err(format!(
        "没找到对应歌单（kind={kind}）；账号里可能还没有这份歌单"
    ))
}

// ---------------------------------------------------------------------------
// 扫码登录
// ---------------------------------------------------------------------------

fn method_qr_create(m: &Snap) -> Result<Value, String> {
    let result = m
        .soda
        .create_qr()
        .map_err(|err| format!("创建二维码失败: {err}"))?;
    Ok(json!({
        "token": result.token,
        "scanUrl": result.scan_url,
        "qrImage": result.qr_image,
        "expireTime": result.expire_time,
    }))
}

fn method_qr_check(m: &Snap, params: &Value) -> Result<Value, String> {
    let token = params
        .get("token")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    if token.is_empty() {
        return Err("缺少二维码 token".to_string());
    }
    let result = m
        .soda
        .check_qr(token)
        .map_err(|err| format!("轮询失败: {err}"))?;
    let status = match result.status {
        QRLoginStatus::Waiting => "waiting",
        QRLoginStatus::Scanned => "scanned",
        QRLoginStatus::Success => "success",
        QRLoginStatus::Expired => "expired",
        QRLoginStatus::Failed => "failed",
    };
    let need_second_verify = result
        .extra
        .get("need_second_verify")
        .map(|flag| flag == "true")
        .unwrap_or(false);
    let rate_limited = result
        .extra
        .get("rate_limited")
        .map(|flag| flag == "true")
        .unwrap_or(false);
    // 登录成功：把 cookie 写回全局配置（Dart 侧随后应保存并重新 configure）。
    // `set_cookie` 走 Arc 原地更新对所有快照可见；全局 config 里的备份
    // 也要同步，否则中途 ping/报错文案会拿旧登录态。
    if result.status == QRLoginStatus::Success && !result.cookie.trim().is_empty() {
        let cookie = result.cookie.trim().to_string();
        m.soda.set_cookie(cookie.clone());
        if let Ok(mut guard) = mobile().lock() {
            guard.config.cookie = cookie;
        }
    }
    Ok(json!({
        "status": status,
        "message": result.message,
        "cookie": result.cookie,
        "needSecondVerify": need_second_verify,
        "rateLimited": rate_limited,
        "extra": result.extra,
    }))
}

// ---------------------------------------------------------------------------
// 搜索 / 推荐（沿用 libresoda，网页/PC 形态）
// ---------------------------------------------------------------------------

#[derive(Debug, Default, serde::Deserialize)]
struct RawSearchEntity {
    #[serde(default)]
    track: Option<Track>,
    #[serde(default)]
    artist: Option<Artist>,
    #[serde(default)]
    album: Option<Album>,
    #[serde(default)]
    playlist: Option<UserPlaylistItem>,
}

#[derive(Debug, Default, serde::Deserialize)]
struct RawSearchItem {
    #[serde(default)]
    entity: RawSearchEntity,
}

#[derive(Debug, Default, serde::Deserialize)]
struct RawSearchGroup {
    #[serde(default)]
    data: Vec<RawSearchItem>,
}

#[derive(Debug, Default, serde::Deserialize)]
struct RawSearchResponse {
    #[serde(default)]
    result_groups: Vec<RawSearchGroup>,
}

fn method_search_all(m: &Snap, params: &Value) -> Result<Value, String> {
    let keyword = params
        .get("keyword")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    if keyword.is_empty() {
        return Err("搜索词为空".to_string());
    }
    let body = m
        .soda
        .fetch_search_all_body(keyword, 1, 30)
        .map_err(|err| format!("搜索失败: {err}"))?;
    let response: RawSearchResponse =
        serde_json::from_slice(&body).map_err(|err| format!("解析搜索结果失败: {err}"))?;
    let mut tracks: Vec<Value> = Vec::new();
    let mut artists: Vec<Value> = Vec::new();
    let mut albums: Vec<Value> = Vec::new();
    let mut playlists: Vec<Value> = Vec::new();
    let mut seen_tracks: Vec<String> = Vec::new();
    for group in &response.result_groups {
        for item in &group.data {
            let entity = &item.entity;
            if let Some(track) = entity.track.as_ref().filter(|track| !track.id.is_empty()) {
                let song = build_song_from_track(track);
                if !seen_tracks.contains(&song.id) {
                    seen_tracks.push(song.id.clone());
                    tracks.push(track_json(&song));
                }
            }
            if let Some(artist) = entity.artist.as_ref().filter(|artist| !artist.id.is_empty()) {
                artists.push(json!({
                    "id": artist.id, "name": artist.name,
                    "avatar": build_image_url(&artist.url_avatar, "~c5_300x300.jpg"),
                    "trackCount": artist.count_tracks, "followerCount": artist.stats.count_collected,
                }));
            }
            if let Some(album) = entity.album.as_ref().filter(|album| !album.id.is_empty()) {
                albums.push(json!({
                    "id": album.id, "title": album.name,
                    "cover": build_image_url(&album.url_cover, "~c5_300x300.jpg"),
                    "artist": join_track_artists(&album.artists), "trackCount": album.count_tracks,
                }));
            }
            if let Some(playlist) = entity
                .playlist
                .as_ref()
                .filter(|playlist| !playlist.id.is_empty())
            {
                let title = if playlist.public_title.is_empty() {
                    playlist.title.clone()
                } else {
                    playlist.public_title.clone()
                };
                let creator = if playlist.owner.public_name.is_empty() {
                    playlist.owner.nickname.clone()
                } else {
                    playlist.owner.public_name.clone()
                };
                playlists.push(json!({
                    "id": playlist.id, "title": title,
                    "cover": build_image_url(&playlist.url_cover, "~c5_300x300.jpg"),
                    "trackCount": playlist.count_tracks, "creator": creator,
                }));
            }
        }
    }
    Ok(json!({
        "keyword": keyword,
        "tracks": tracks,
        "artists": artists,
        "albums": albums,
        "playlists": playlists,
    }))
}

fn method_suggest(m: &Snap, params: &Value) -> Result<Value, String> {
    let keyword = params
        .get("keyword")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    if keyword.is_empty() {
        return Ok(json!([]));
    }
    // 移动端官方联想（/luna/suggest-words/recommendation，Cookie 即可）；
    // App-Cookie 形态下 PC 联想无数据。
    if let Ok(value) = mobile_get(
        m,
        "/luna/suggest-words/recommendation",
        &[("keyword", keyword)],
    ) {
        let words: Vec<String> = value
            .get("suggest_words")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(|item| item.get("keyword").and_then(Value::as_str))
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default();
        if !words.is_empty() {
            return Ok(json!(words));
        }
    }
    let value = m
        .soda
        .suggest(keyword)
        .map_err(|err| format!("联想词失败: {err}"))?;
    let data = value.get("data").cloned().unwrap_or(Value::Null);
    let list: Vec<Value> = if let Some(words) = data.get("words").or_else(|| data.get("sug_words"))
    {
        words.as_array().cloned().unwrap_or_default()
    } else {
        data.as_array().cloned().unwrap_or_default()
    };
    let words: Vec<String> = list
        .iter()
        .filter_map(|item| match item {
            Value::String(text) => Some(text.clone()),
            Value::Object(_) => item
                .get("content")
                .or_else(|| item.get("word"))
                .and_then(Value::as_str)
                .map(str::to_string),
            _ => None,
        })
        .collect();
    Ok(json!(words))
}

fn method_lyrics(m: &Snap, params: &Value) -> Result<Value, String> {
    let track_id = params
        .get("trackId")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    if track_id.is_empty() {
        return Err("缺少歌曲 id".to_string());
    }
    let response = crate::soda::track::fetch_web_track_v2(&m.soda, track_id)
        .map_err(|err| format!("获取歌词失败: {err}"))?;
    // 评论只存在于 SEO 分享页回包；web track_v2 命中（歌词稳定但无评论）
    // 时补拉一次 SEO 拿热门评论，尽力而为、失败不影响歌词。
    let mut comments = response.comments.clone();
    if comments.is_none() {
        if let Ok(seo) = crate::soda::track::fetch_seo_track_data(&m.soda, track_id) {
            comments = seo.comments.clone();
        }
    }
    let (comments, comment_count) = comments_json(comments.as_ref());
    // 翻译歌词（SEO 回包带 translations：语言码 → LRC）。中文优先，
    // 其余语言按码稳定排序；空翻译不透出。
    let mut translations = serde_json::Map::new();
    if let Some(map) = response.lyric.translations.as_ref() {
        let mut ordered: Vec<(&String, &String)> = map.iter().collect();
        ordered.sort_by_key(|(lang, _)| if lang.as_str() == "cn" { 0 } else { 1 });
        for (lang, text) in ordered {
            if !text.trim().is_empty() {
                translations.insert(lang.clone(), Value::String(text.clone()));
            }
        }
    }
    Ok(json!({
        "lrc": response.lyric.content,
        "translations": Value::Object(translations),
        "comments": comments,
        "commentCount": comment_count,
    }))
}

/// 把 SEO 回包内嵌的热门评论（`{comments: [...], count}`）拍平成轻量条目。
/// 回包无该字段时返回空列表（PC track_v2 命中时属正常）。
fn comments_json(raw: Option<&Value>) -> (Value, i64) {
    let Some(obj) = raw else {
        return (Value::Array(Vec::new()), 0);
    };
    let count = obj.get("count").and_then(Value::as_i64).unwrap_or(0);
    let list = obj
        .get("comments")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut out = Vec::new();
    for comment in &list {
        let id = comment.get("id").and_then(Value::as_str).unwrap_or_default();
        let content = comment.get("content").and_then(Value::as_str).unwrap_or_default();
        if id.is_empty() || content.trim().is_empty() {
            continue;
        }
        let avatar = comment
            .pointer("/user/medium_avatar_url/urls/0")
            .and_then(Value::as_str)
            .unwrap_or_default();
        out.push(json!({
            "id": id,
            "content": content,
            "likes": comment.get("count_digged").and_then(Value::as_i64).unwrap_or(0),
            "replies": comment.get("count_reply").and_then(Value::as_i64).unwrap_or(0),
            "time": comment.get("time_created").and_then(Value::as_i64).unwrap_or(0),
            "nickname": comment.pointer("/user/nickname").and_then(Value::as_str).unwrap_or("汽水用户"),
            "avatar": avatar,
            "ipLabel": comment.get("ip_label").and_then(Value::as_str).unwrap_or_default(),
            "featured": comment.get("featured").and_then(Value::as_bool).unwrap_or(false),
        }));
    }
    (Value::Array(out), count)
}

// ---------------------------------------------------------------------------
// 首页推荐 / 专辑 / 收藏（沿用 libresoda 的网页/PC 形态）
// ---------------------------------------------------------------------------

/// 听歌模式列表：本地「熟悉/新鲜」+ feed_mode 全量。
fn method_scenes(m: &Snap) -> Result<Value, String> {
    require_cookie(m)?;
    let mode = m
        .soda
        .feed_mode()
        .map_err(|err| format!("读取听歌模式失败: {err}"))?;
    let mut items = vec![
        json!({
            "text": "熟悉模式", "entryType": "scene_mode",
            "sceneModeId": -1, "subQueueType": "familiar", "cover": "",
        }),
        json!({
            "text": "新鲜模式", "entryType": "scene_mode",
            "sceneModeId": -1, "subQueueType": "fresh", "cover": "",
        }),
    ];
    for scene in mode.scenes() {
        items.push(json!({
            "text": scene.text,
            "entryType": scene.entry_type,
            "sceneModeId": scene.scene_mode_id,
            "subQueueType": scene.sub_queue_type,
            "cover": scene.cover_url,
        }));
    }
    Ok(Value::Array(items))
}

/// 解析官方推荐响应里的曲目。
fn recommended_tracks(value: &Value) -> Result<Vec<Value>, String> {
    let items = value
        .get("items")
        .and_then(Value::as_array)
        .ok_or_else(|| "推荐响应缺少 items".to_string())?;
    let mut tracks = Vec::new();
    for item in items {
        if item.get("type").and_then(Value::as_str) != Some("track") {
            continue;
        }
        let Some(track) = item.pointer("/entity/track_wrapper/track") else {
            continue;
        };
        let id = track
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim()
            .to_string();
        if id.is_empty() {
            continue;
        }
        let title = track
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or("未知曲目");
        let artist = track
            .get("artists")
            .and_then(Value::as_array)
            .map(|artists| {
                artists
                    .iter()
                    .filter_map(|artist| artist.get("name").and_then(Value::as_str))
                    .collect::<Vec<_>>()
                    .join(" / ")
            })
            .unwrap_or_default();
        let artist_id = track
            .pointer("/artists/0/id")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let album = track
            .pointer("/album/name")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let album_id = track
            .pointer("/album/id")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let duration_seconds = (track
            .get("duration")
            .and_then(Value::as_f64)
            .unwrap_or_default()
            / 1000.0)
            .round() as i64;
        let vip = track
            .pointer("/label_info/only_vip_playable")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let cover = track
            .pointer("/album/url_cover")
            .and_then(|image| {
                let urls = image.get("urls").and_then(Value::as_array)?;
                let _prefix = urls.first()?.as_str()?;
                let uri = image.get("uri").and_then(Value::as_str)?;
                let template = image
                    .get("template_prefix")
                    .and_then(Value::as_str)?;
                Some(format!(
                    "https://p3-luna.douyinpic.com/img/{uri}~{template}-resize:512:512.png"
                ))
            })
            .unwrap_or_default();
        tracks.push(json!({
            "id": id, "title": title, "artist": artist, "album": album,
            "artistId": artist_id, "albumId": album_id, "cover": cover,
            "durationSeconds": duration_seconds, "vip": vip,
        }));
    }
    Ok(tracks)
}

/// 推荐队列一页。
fn method_feed(m: &Snap, params: &Value) -> Result<Value, String> {
    require_cookie(m)?;
    let fetch_counter = params
        .get("fetchCounter")
        .and_then(Value::as_u64)
        .unwrap_or(0)
        .saturating_add(1);
    let did_first_use_time = params
        .get("didFirstUseTime")
        .and_then(Value::as_u64)
        .filter(|value| *value > 0)
        .unwrap_or_else(|| {
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|value| value.as_secs())
                .unwrap_or_default()
        });
    let scene_mode_id = params.get("sceneModeId").and_then(Value::as_i64);
    let sub_queue_type = params
        .get("subQueueType")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_string();

    let mut body = json!({
        "played_media": [],
        "did_first_use_time": did_first_use_time,
        "is_first_request": fetch_counter == 1,
        "is_did_first_request": fetch_counter == 1,
        "feed_counts": { "mix_session_count": fetch_counter },
    });
    if let Some(scene_mode_id) = scene_mode_id {
        if scene_mode_id >= 0 {
            body["feed_preference"] = json!({ "scene_mode_id": scene_mode_id });
        } else if !sub_queue_type.is_empty() {
            body["feed_preference"] = json!({ "preference_mode": sub_queue_type });
        }
    }

    // 移动端官方推荐端点（/luna/feed/song-tab，aid=8478，Cookie 即可）：
    // App-Cookie（注入官方会话）形态下 PC 端点无数据，移动端点两种形态都通。
    if let Ok(value) = mobile_post_json(m, "/luna/feed/song-tab", &body) {
        if let Ok(tracks) = recommended_tracks(&value) {
            if !tracks.is_empty() {
                let videos = value
                    .get("items")
                    .and_then(Value::as_array)
                    .map(|items| {
                        items
                            .iter()
                            .filter(|item| {
                                item.get("type").and_then(Value::as_str) == Some("video_track_mix")
                            })
                            .count()
                    })
                    .unwrap_or(0);
                return Ok(json!({
                    "tracks": tracks,
                    "hasMore": value.get("has_more").and_then(Value::as_bool).unwrap_or(true),
                    "fetchCounter": fetch_counter,
                    "didFirstUseTime": did_first_use_time,
                    "videos": videos,
                }));
            }
        }
    }

    // PC 形态（网页 Cookie）回退。
    let value = m
        .soda
        .fetch_feed_song_tab(&body)
        .map_err(|err| format!("读取推荐队列失败: {err}"))?;
    let tracks = recommended_tracks(&value)?;
    let has_more = value
        .get("has_more")
        .and_then(Value::as_bool)
        .unwrap_or(true);
    Ok(json!({
        "tracks": tracks,
        "hasMore": has_more,
        "fetchCounter": fetch_counter,
        "didFirstUseTime": did_first_use_time,
    }))
}

/// 专辑曲目 + 元信息（公开分享页解析，无需登录）。
///
/// 优先走 `fetch_album_detail`（一份回包同时含发行时间/简介/厂牌与全曲目），
/// 解析失败再回落纯曲目的 `get_album_songs`。
fn method_album_tracks(m: &Snap, params: &Value) -> Result<Value, String> {
    let album_id = params
        .get("albumId")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    if album_id.is_empty() {
        return Err("缺少专辑 id".to_string());
    }
    if let Ok((album, songs)) =
        crate::soda::album::fetch_album_detail(&m.soda, album_id)
    {
        if !songs.is_empty() {
            let out: Vec<Value> = songs.iter().map(track_json).collect();
            return Ok(json!({
                "tracks": out,
                "album": {
                    "title": album.name,
                    "cover": album.cover,
                    "artist": album.creator,
                    "trackCount": album.track_count,
                    "releaseDate": album.extra.get("release_date").cloned().unwrap_or_default(),
                    "description": album.description,
                },
            }));
        }
    }
    let songs = m
        .soda
        .get_album_songs(album_id)
        .map_err(|err| format!("读取专辑歌曲失败: {err}"))?;
    let out: Vec<Value> = songs.iter().map(track_json).collect();
    Ok(json!({ "tracks": out }))
}

// ---------------------------------------------------------------------------
// 业务状态码校验：官方回包成功时常缺 `status_code`（只有出错才有），
// 因此「字段缺席 = 成功，出现且非 0 = 失败」。
// ---------------------------------------------------------------------------

fn check_status(value: &Value, what: &str) -> Result<(), String> {
    if let Some(status) = value.get("status_code").and_then(Value::as_i64) {
        if status != 0 {
            let msg = value
                .pointer("/status_info/status_msg")
                .and_then(Value::as_str)
                .unwrap_or_default();
            return Err(format!("{what}被拒: {status} {msg}"));
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// 艺人（PC 形态 /luna/pc/artists/*，回包为 IDL 原始 JSON，防御式解析）
// ---------------------------------------------------------------------------

/// 兼容裸 Track / entity 包装两种条目形态的歌曲解析。
fn song_from_track_value(item: &Value) -> Option<crate::model::Song> {
    for source in [
        Some(item),
        item.pointer("/entity/track_wrapper/track"),
        item.pointer("/entity/track"),
        item.pointer("/track"),
    ]
    .into_iter()
    .flatten()
    {
        if let Ok(track) = serde_json::from_value::<Track>(source.clone()) {
            if !track.id.is_empty() {
                return Some(build_song_from_track(&track));
            }
        }
    }
    None
}

fn songs_from_array(value: Option<&Value>) -> Vec<crate::model::Song> {
    value
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(song_from_track_value).collect())
        .unwrap_or_default()
}

/// 分页字段：`/has_more`、`/next_cursor`（部分回包套在 `/data` 下）。
fn page_fields(value: &Value) -> (bool, String) {
    let has_more = value
        .get("has_more")
        .or_else(|| value.pointer("/data/has_more"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let next = value
        .get("next_cursor")
        .or_else(|| value.pointer("/data/next_cursor"))
        .and_then(|v| {
            v.as_str()
                .map(str::to_string)
                .or_else(|| v.as_i64().map(|n| n.to_string()))
        })
        .unwrap_or_default();
    (has_more, next)
}

fn method_artist_detail(m: &Snap, params: &Value) -> Result<Value, String> {
    require_cookie(m)?;
    let artist_id = params
        .get("artistId")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    if artist_id.is_empty() {
        return Err("缺少艺人 id".to_string());
    }
    let raw = m
        .soda
        .fetch_artist_detail(artist_id)
        .map_err(|err| format!("读取艺人详情失败: {err}"))?;
    let info = raw
        .get("artist_info")
        .or_else(|| raw.get("artist"))
        .cloned()
        .unwrap_or_default();
    let artist: Artist = serde_json::from_value(info).unwrap_or_default();
    let hot_tracks = songs_from_array(raw.get("hot_tracks").or_else(|| raw.get("hot_songs")));
    Ok(json!({
        "id": artist_id,
        "name": artist.name,
        "avatar": build_image_url(&artist.url_avatar, "~c5_300x300.jpg"),
        "trackCount": artist.count_tracks,
        "followerCount": artist.stats.count_collected,
        "hotTracks": tracks_json(&hot_tracks),
    }))
}

fn method_artist_tracks(m: &Snap, params: &Value) -> Result<Value, String> {
    require_cookie(m)?;
    let artist_id = params
        .get("artistId")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    if artist_id.is_empty() {
        return Err("缺少艺人 id".to_string());
    }
    let cursor = params
        .get("cursor")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    let count = params.get("count").and_then(Value::as_i64).unwrap_or(50);
    let raw = m
        .soda
        .list_artist_tracks(artist_id, cursor, count)
        .map_err(|err| format!("读取艺人单曲失败: {err}"))?;
    let mut songs = tracks_from_media_resources(raw.get("media_resources"));
    if songs.is_empty() {
        songs = songs_from_array(
            raw.get("tracks")
                .or_else(|| raw.get("data").filter(|v: &&Value| v.is_array())),
        );
    }
    let (has_more, next_cursor) = page_fields(&raw);
    Ok(json!({
        "tracks": tracks_json(&songs),
        "hasMore": has_more,
        "nextCursor": next_cursor,
    }))
}

fn method_artist_albums(m: &Snap, params: &Value) -> Result<Value, String> {
    require_cookie(m)?;
    let artist_id = params
        .get("artistId")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    if artist_id.is_empty() {
        return Err("缺少艺人 id".to_string());
    }
    let cursor = params
        .get("cursor")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    let count = params.get("count").and_then(Value::as_i64).unwrap_or(50);
    let raw = m
        .soda
        .list_artist_albums(artist_id, cursor, count)
        .map_err(|err| format!("读取艺人专辑失败: {err}"))?;
    let albums_value = raw
        .get("albums")
        .or_else(|| raw.get("data").filter(|v: &&Value| v.is_array()))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let albums: Vec<Value> = albums_value
        .iter()
        .filter_map(|item| {
            let album: Album = serde_json::from_value(item.clone()).ok()?;
            if album.id.is_empty() {
                return None;
            }
            Some(json!({
                "id": album.id, "title": album.name,
                "cover": build_image_url(&album.url_cover, "~c5_300x300.jpg"),
                "artist": join_track_artists(&album.artists),
                "trackCount": album.count_tracks,
            }))
        })
        .collect();
    let (has_more, next_cursor) = page_fields(&raw);
    Ok(json!({
        "albums": albums,
        "hasMore": has_more,
        "nextCursor": next_cursor,
    }))
}

// ---------------------------------------------------------------------------
// 歌单读取

/// 我收藏的歌单（/luna/me/collection/mixed，非 PC 路径，桌面实测通过）。
fn method_collected_playlists(m: &Snap, params: &Value) -> Result<Value, String> {
    require_cookie(m)?;
    let cursor = params
        .get("cursor")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    let count = params.get("count").and_then(Value::as_i64).unwrap_or(50);
    let items = m
        .soda
        .collected_items(cursor, count, &["playlist"])
        .map_err(|err| format!("读取收藏的歌单失败: {err}"))?;
    let mut out = Vec::new();
    for item in items {
        let Some(playlist) = item.playlist.clone() else {
            continue;
        };
        let Ok(typed) = serde_json::from_value::<UserPlaylistItem>(playlist) else {
            continue;
        };
        if typed.id.is_empty() {
            continue;
        }
        out.push(json!({
            "id": typed.id,
            "title": if typed.public_title.is_empty() { typed.title.clone() } else { typed.public_title.clone() },
            "cover": build_image_url(&typed.url_cover, "~c5_300x300.jpg"),
            "trackCount": typed.count_tracks,
            "creator": if typed.owner.public_name.is_empty() { typed.owner.nickname.clone() } else { typed.owner.public_name.clone() },
            "kind": 0,
        }));
    }
    Ok(json!({ "playlists": out }))
}

// ---------------------------------------------------------------------------
// 发现页（歌单广场/排行榜）+ 推荐歌单 + 歌单改名删除 + 导入进度 + 关注艺人
// （Phase 3：libresoda 已实现能力透出，移动端优先 + PC 回落）
// ---------------------------------------------------------------------------

/// 发现页内容流（`POST /luna/pc/discover/mix`）。
///
/// `blockType` 用官方场景名：`discovery_playlist`=歌单广场、
/// `discovery_chart`/`discover_track_top_list`=排行榜、`discovery_radio`=电台。
/// 回包字段随版本变动大，所以同时透出「类型化拍平的歌单列表」与原始 JSON，
/// Dart 端歌单形态直接用，榜单等其它形态从 raw 里按需挖。
fn method_discover_mix(m: &Snap, params: &Value) -> Result<Value, String> {
    require_cookie(m)?;
    let block_type = params
        .get("blockType")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    if block_type.is_empty() {
        return Err("缺少 blockType".to_string());
    }
    let sub_channel_id = params
        .get("subChannelId")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let cursor = params
        .get("cursor")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    let count = params
        .get("count")
        .and_then(Value::as_i64)
        .unwrap_or(20)
        .clamp(1, 50);
    let body = crate::soda::feed::discover_mix_body(
        block_type,
        sub_channel_id,
        cursor,
        count,
        "",
    );
    let value = m
        .soda
        .fetch_discover_mix_body(&body)
        .map_err(|err| format!("读取发现页内容失败: {err}"))?;
    let parsed = crate::soda::feed::parse_discover_mix(&value)
        .map_err(|err| format!("解析发现页内容失败: {err}"))?;
    let mut playlists = Vec::new();
    for block in &parsed.inner_block {
        for resource in &block.resources {
            let playlist = &resource.entity.playlist;
            if playlist.id.is_empty() {
                continue;
            }
            playlists.push(json!({
                "id": playlist.id,
                "title": playlist.display_title(),
                "cover": playlist.cover_url(),
                "trackCount": playlist.count_tracks,
                "desc": playlist.desc,
                "blockId": block.inner_block_id,
            }));
        }
    }
    Ok(json!({ "playlists": playlists, "hasMore": parsed.has_more, "raw": value }))
}

/// 推荐歌单（`GET /luna/me/playlist/recommend`）。
fn method_recommend_playlists(m: &Snap) -> Result<Value, String> {
    require_cookie(m)?;
    let playlists = m
        .soda
        .get_recommend_playlists()
        .map_err(|err| format!("读取推荐歌单失败: {err}"))?;
    let out: Vec<Value> = playlists
        .iter()
        .filter(|playlist| !playlist.id.is_empty())
        .map(|playlist| {
            json!({
                "id": playlist.id,
                "title": playlist.name,
                "cover": playlist.cover,
                "trackCount": playlist.track_count,
                "creator": playlist.creator,
                "desc": playlist.description,
            })
        })
        .collect();
    Ok(json!({ "playlists": out }))
}

/// 电台列表：官方发现页首屏（`POST /luna/discover`）里的 `discover_radio`
/// 电台块。移动端优先（实测回 12 个电台：标题/描述/封面/主色），
/// PC `/luna/pc/discover` 回落（同形回包）。
fn method_radio_list(m: &Snap) -> Result<Value, String> {
    require_cookie(m)?;
    // 回落链：移动端 /luna/discover → PC discover/mix(discovery_radio) →
    // PC /luna/pc/discover。移动端信封 1000006 时（App 指纹风控）走 PC；
    // PC discover 首屏回的是歌单广场+榜单（无电台），所以 mix 场景优先。
    let value = match mobile_post_json(m, "/luna/discover", &json!({})) {
        Ok(value) if mobile_envelope_error(&value).is_none() => value,
        Ok(_) | Err(_) => {
            let mix_body = crate::soda::feed::discover_mix_body(
                "discovery_radio", 0, "", 30, "",
            );
            match m.soda.fetch_discover_mix_body(&mix_body) {
                Ok(value) if mobile_envelope_error(&value).is_none() => value,
                Ok(_) | Err(_) => m.soda.fetch_discover().map_err(|pc_err| {
                    format!("读取电台列表失败：移动端与 PC mix 均被拒，PC discover {pc_err}")
                })?,
            }
        }
    };
    let mut stations = Vec::new();
    // 调试信息（空电台时自检打印，定位服务端形态变化）
    let mut block_types: Vec<String> = Vec::new();
    let mut inner_types: Vec<String> = Vec::new();
    // 候选块拍平：移动端 discover 形态（blocks[].inner_block[]，块带
    // type=discover_radio）与 PC mix 形态（顶层 inner_block[]，电台实体
    // 在 resources[].entity.radio）都过一遍。
    let mut candidate_blocks: Vec<&Value> = Vec::new();
    if let Some(blocks) = value.get("blocks").and_then(Value::as_array) {
        for block in blocks {
            block_types.push(
                block
                    .get("type")
                    .and_then(Value::as_str)
                    .unwrap_or("?")
                    .to_string(),
            );
            if let Some(inner) = block.get("inner_block").and_then(Value::as_array) {
                candidate_blocks.extend(inner.iter());
            }
        }
    }
    if let Some(inner) = value.get("inner_block").and_then(Value::as_array) {
        candidate_blocks.extend(inner.iter());
    }
    for item in candidate_blocks {
        let item_type = item
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        if inner_types.len() < 8 {
            inner_types.push(if item_type.is_empty() {
                "<no-type>".to_string()
            } else {
                item_type.clone()
            });
        }
        if item_type == "discover_radio" {
            if let Some(station) = radio_station_from_block(item) {
                stations.push(station);
                continue;
            }
        }
        // PC mix：resources[].entity.radio{id,name,desc,url_cover}
        if let Some(resources) = item.get("resources").and_then(Value::as_array) {
            for resource in resources {
                let Some(radio) = resource.pointer("/entity/radio") else {
                    continue;
                };
                let id = radio
                    .get("id")
                    .and_then(Value::as_str)
                    .or_else(|| {
                        resource.get("resource_id").and_then(Value::as_str)
                    })
                    .unwrap_or_default()
                    .trim()
                    .to_string();
                if id.is_empty() {
                    continue;
                }
                let title = radio
                    .get("name")
                    .or_else(|| radio.get("title"))
                    .and_then(Value::as_str)
                    .or_else(|| item.get("title").and_then(Value::as_str))
                    .unwrap_or_default()
                    .trim()
                    .to_string();
                if title.is_empty() {
                    continue;
                }
                let cover = resource
                    .pointer("/style/cover_url_list/0")
                    .or_else(|| radio.get("url_cover"))
                    .and_then(|image| image_url_from(image))
                    .unwrap_or_default();
                let desc = resource
                    .pointer("/style/desc")
                    .and_then(Value::as_str)
                    .or_else(|| radio.get("desc").and_then(Value::as_str))
                    .unwrap_or_default()
                    .trim()
                    .to_string();
                stations.push(json!({
                    "id": id, "title": title, "desc": desc, "cover": cover, "color": "",
                }));
            }
        }
    }
    // 按电台 id 去重（移动端/PC 两种形态不会同回，但 mix 分页可能重）
    let mut seen = std::collections::HashSet::new();
    stations.retain(|station| {
        seen.insert(station["id"].as_str().unwrap_or_default().to_string())
    });
    // 线上三链路（移动端 discover / PC mix / PC discover）都可能被风控或
    // 场景降级拿不到电台——回落内置种子目录（2026-10-09 官方发现页实测
    // 抓取的 12 个风格电台；id 是稳定内容 id，取流端点按 id 出曲不受影响）。
    let source = if stations.is_empty() {
        if let Ok(seeded) = serde_json::from_str::<Vec<Value>>(SEED_RADIO_STATIONS) {
            stations = seeded;
        }
        "seed"
    } else {
        "online"
    };
    let head: String = serde_json::to_string(&value)
        .unwrap_or_default()
        .chars()
        .take(160)
        .collect();
    Ok(json!({
        "stations": stations,
        "source": source,
        "debug": {
            "blocks": block_types,
            "innerTypes": inner_types,
            "head": head,
        }
    }))
}

/// 内置电台种子目录：官方发现页 2026-10-09 实测快照（12 个风格电台）。
/// 线上链路被风控/降级时的兜底展示；`/luna/feed/radio/tracks` 按 id 出曲。
const SEED_RADIO_STATIONS: &str = r##"[
    {
        "id": "7408841206354165811",
        "title": "儿歌精选",
        "desc": "超可爱的歌，人听人爱",
        "cover": "https://p3-luna.douyinpic.com/img/tos-cn-v-2774c002/ef7b6cc2ba3b4c99a8ce47403fb282c6~tplv-b829550vbb-resize:512:512.png",
        "color": "328693"
    },
    {
        "id": "7408841206895263771",
        "title": "冥想",
        "desc": "在方寸之间，在无尽之野，疗愈身心",
        "cover": "https://p3-luna.douyinpic.com/img/tos-cn-i-b829550vbb/f125c637ffee32f14393ef676630a9d2.jpg~tplv-b829550vbb-resize:512:512.png",
        "color": "163669"
    },
    {
        "id": "7408841206895083547",
        "title": "回忆之声",
        "desc": "我们的回忆，都藏在歌里",
        "cover": "https://p3-luna.douyinpic.com/img/tos-cn-v-2774c002/61ba48258e0646f4a96f89abdfa44e01~tplv-b829550vbb-resize:512:512.png",
        "color": "8B6464"
    },
    {
        "id": "7408841207247306803",
        "title": "70年粤语流行",
        "desc": "记忆深处的港乐",
        "cover": "https://p3-luna.douyinpic.com/img/tos-cn-v-2774c002/1abc28b8db4a43a786c09360f2f4c646~tplv-b829550vbb-resize:512:512.png",
        "color": "865A2A"
    },
    {
        "id": "7408841206878257161",
        "title": "国风电音",
        "desc": "中国传统音乐与现代电子乐相结合",
        "cover": "https://p3-luna.douyinpic.com/img/tos-cn-v-2774c002/o4deZmA2PB6Dt6nqACIAXMnbVmUgdeInAFDBGu~tplv-b829550vbb-resize:512:512.png",
        "color": "D69433"
    },
    {
        "id": "7408841206865772570",
        "title": "民谣流行",
        "desc": "最受欢迎的民谣歌曲",
        "cover": "https://p3-luna.douyinpic.com/img/tos-cn-v-2774c002/5bc602299c6f4ebb9ed50efc95bca46c~tplv-b829550vbb-resize:512:512.png",
        "color": "C69660"
    },
    {
        "id": "7408841206895181851",
        "title": "运动必备",
        "desc": "跟着超强节奏一起燃脂",
        "cover": "https://p3-luna.douyinpic.com/img/tos-cn-i-b829550vbb/40a048d21175dbd0c7780906d4d544cb.jpg~tplv-b829550vbb-resize:512:512.png",
        "color": "5F9FC9"
    },
    {
        "id": "7408841207197171722",
        "title": "松弛感纯音乐",
        "desc": "阳光下的惬意午后",
        "cover": "https://p3-luna.douyinpic.com/img/tos-cn-v-2774c002/oI9twFFu2IDQyrACXsAgf2EimxIJZbsADAfNqB~tplv-b829550vbb-resize:512:512.png",
        "color": "5692C3"
    },
    {
        "id": "7408841206865690650",
        "title": "老派说唱",
        "desc": "说唱经典之作",
        "cover": "https://p3-luna.douyinpic.com/img/tos-cn-v-2774c002/osyAos32UAOE7BisxAVEAalAAmWswufAVrdBi9~tplv-b829550vbb-resize:512:512.png",
        "color": "030303"
    },
    {
        "id": "7408841206895099931",
        "title": "浪漫情歌",
        "desc": "爱在你身旁，你在我眼里",
        "cover": "https://p3-luna.douyinpic.com/img/tos-cn-i-b829550vbb/4ee7bfb49ea03c955aeac574d8a70f12.JPG~tplv-b829550vbb-resize:512:512.png",
        "color": "C19EB7"
    },
    {
        "id": "7408841206970728486",
        "title": "动感R&B",
        "desc": "动感节奏 松弛摇摆",
        "cover": "https://p3-luna.douyinpic.com/img/tos-cn-v-2774c002/oAeFkCDk9enAzfAFLSAJ8LpBb9aAPJQaCTQ0Ss~tplv-b829550vbb-resize:512:512.png",
        "color": "4040BA"
    },
    {
        "id": "7408841207004184603",
        "title": "热情布鲁斯",
        "desc": "热情奔放的布鲁斯节奏",
        "cover": "https://p3-luna.douyinpic.com/img/tos-cn-v-2774c002/043725bc70cc4e05bc9c36d3cf9919a7~tplv-b829550vbb-resize:512:512.png",
        "color": "374A15"
    }
]"##;

/// 图片对象（`uri` + `template_prefix`）→ 完整 CDN 地址。
fn image_url_from(image: &Value) -> Option<String> {
    let uri = image.get("uri").and_then(Value::as_str)?;
    if uri.is_empty() {
        return None;
    }
    let template = image
        .get("template_prefix")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if template.is_empty() {
        return Some(format!("https://p3-luna.douyinpic.com/img/{uri}"));
    }
    Some(format!(
        "https://p3-luna.douyinpic.com/img/{uri}~{template}-resize:512:512.png"
    ))
}

/// 移动端信封校验：HTTP 200 但 `status_code != 0` 视为失败（如 1000006
/// 风控信封），把服务端原因带回错误链供回落与 UI 提示。
fn mobile_envelope_error(value: &Value) -> Option<String> {
    let code = value
        .get("status_code")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    if code == 0 {
        return None;
    }
    let msg = value
        .pointer("/status_info/status_msg")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    Some(format!("移动端接口错误 {code}（{msg}）"))
}

/// 电台块 → 展示条目（id/标题/描述/封面/服务端主色）。
fn radio_station_from_block(block: &Value) -> Option<Value> {
    let id = block
        .get("inner_block_id")
        .and_then(Value::as_str)
        .filter(|value| !value.trim().is_empty())
        .or_else(|| {
            block
                .pointer("/resources/0/resource_id")
                .and_then(Value::as_str)
        })?
        .to_string();
    let style = block.pointer("/resources/0/style");
    let text = |key: &str| -> String {
        style
            .and_then(|style| style.get(key))
            .and_then(Value::as_str)
            .unwrap_or_default()
            .trim()
            .to_string()
    };
    let title = {
        let title = text("title");
        if title.is_empty() {
            block
                .get("title")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .trim()
                .to_string()
        } else {
            title
        }
    };
    if id.is_empty() || title.is_empty() {
        return None;
    }
    let cover = style
        .and_then(|style| style.get("cover_url_list"))
        .and_then(Value::as_array)
        .and_then(|list| list.first())
        .and_then(|image| {
            let uri = image.get("uri").and_then(Value::as_str)?;
            let template = image.get("template_prefix").and_then(Value::as_str)?;
            if uri.is_empty() || template.is_empty() {
                return None;
            }
            Some(format!(
                "https://p3-luna.douyinpic.com/img/{uri}~{template}-resize:512:512.png"
            ))
        })
        .unwrap_or_default();
    let color = block
        .pointer("/resources/0/style/cover_color/dominant_color/rgb")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    Some(json!({
        "id": id, "title": title, "desc": text("desc"),
        "cover": cover, "color": color,
    }))
}

/// 电台曲目队列（官方「无限电台」播放源）。
///
/// 移动端 `POST /luna/feed/radio/tracks`（实测体 `{radio_id, played_media,
/// count}`，Cookie 即可）；PC `/luna/pc/feed/radio/tracks` 回落。
/// 回包同参重拉内容会轮换（与歌单广场同语义），去重交给 Dart 侧按 id 做。
fn method_radio_tracks(m: &Snap, params: &Value) -> Result<Value, String> {
    require_cookie(m)?;
    let radio_id = params
        .get("radioId")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    if radio_id.is_empty() {
        return Err("缺少 radioId".to_string());
    }
    let count = params
        .get("count")
        .and_then(Value::as_i64)
        .unwrap_or(20)
        .clamp(1, 50);
    let played: Vec<Value> = params
        .get("playedIds")
        .and_then(Value::as_array)
        .map(|ids| {
            ids.iter()
                .filter_map(|id| id.as_str())
                .map(|id| json!({ "media_id": id, "media_type": "track" }))
                .collect()
        })
        .unwrap_or_default();
    let body = json!({
        "radio_id": radio_id,
        "played_media": played,
        "count": count,
    });
    let value = match mobile_post_json(m, "/luna/feed/radio/tracks", &body) {
        Ok(value) if mobile_envelope_error(&value).is_none() => value,
        Ok(value) => {
            let mobile_err = mobile_envelope_error(&value).unwrap_or_default();
            m.soda
                .fetch_feed_radio_tracks_body(&body)
                .map_err(|pc_err| format!("读取电台队列失败：{mobile_err}；PC 回落: {pc_err}"))?
        }
        Err(mobile_err) => m
            .soda
                .fetch_feed_radio_tracks_body(&body)
                .map_err(|pc_err| format!("读取电台队列失败：{mobile_err}；PC 回落: {pc_err}"))?,
    };
    if let Some(err) = mobile_envelope_error(&value) {
        return Err(format!("读取电台队列失败：PC 回落返回 {err}"));
    }
    let items = value.get("items").cloned().unwrap_or(Value::Null);
    let tracks = tracks_from_media_resources(Some(&items));
    let has_more = value
        .get("has_more")
        .and_then(Value::as_bool)
        .unwrap_or(true);
    // tracks_json 做 Song→Dart Track 的字段映射（title/artistId/durationSeconds）；
    // 直接序列化 Song 会产出 name/artist_id 等蛇形键，Dart 侧解析为空
    Ok(json!({ "tracks": tracks_json(&tracks), "hasMore": has_more }))
}

/// 我关注的艺人（`GET /luna/me/collection/artist`，原始回包透出）。
fn method_collected_artists(m: &Snap, params: &Value) -> Result<Value, String> {
    require_cookie(m)?;
    let cursor = params
        .get("cursor")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_string();
    let count = params.get("count").and_then(Value::as_i64).unwrap_or(20);
    let value = m
        .soda
        .collected_artists(&cursor, count)
        .map_err(|err| format!("读取关注的艺人失败: {err}"))?;
    // 回包形态：`artists[]`（条目可能是艺人本体，也可能包一层 `artist`）。
    // 防御式取字段，头像沿用封面拼接规则（urls[0] + uri + template）。
    let mut artists = Vec::new();
    if let Some(items) = value.get("artists").and_then(Value::as_array) {
        for item in items {
            let entry = item.get("artist").unwrap_or(item);
            let id = entry
                .get("id")
                .or_else(|| entry.get("artist_id"))
                .and_then(Value::as_str)
                .unwrap_or_default()
                .trim();
            if id.is_empty() {
                continue;
            }
            let name = entry
                .get("name")
                .or_else(|| entry.get("title"))
                .and_then(Value::as_str)
                .unwrap_or_default()
                .trim();
            let avatar = entry
                .get("url_avatar")
                .or_else(|| entry.get("url_cover"))
                .or_else(|| entry.get("avatar"))
                .and_then(|image| {
                    let uri = image.get("uri").and_then(Value::as_str)?;
                    let template = image.get("template_prefix").and_then(Value::as_str)?;
                    if uri.is_empty() {
                        return None;
                    }
                    Some(if template.is_empty() {
                        format!("https://p3-luna.douyinpic.com/img/{uri}")
                    } else {
                        format!(
                            "https://p3-luna.douyinpic.com/img/{uri}~{template}-resize:200:200.png"
                        )
                    })
                })
                .unwrap_or_default();
            artists.push(json!({
                "id": id, "name": name, "avatar": avatar,
            }));
        }
    }
    Ok(json!({
        "artists": artists,
        "hasMore": value.get("has_more").and_then(Value::as_bool).unwrap_or(false),
        "nextCursor": value.get("next_cursor").and_then(Value::as_str).unwrap_or_default(),
    }))
}

/// 我收藏的专辑（`collected_mixed` 过滤 album 类型，拍平成轻量条目）。
fn method_collected_albums(m: &Snap, params: &Value) -> Result<Value, String> {
    require_cookie(m)?;
    let cursor = params
        .get("cursor")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_string();
    let count = params.get("count").and_then(Value::as_i64).unwrap_or(20);
    let value = m
        .soda
        .collected_mixed(&cursor, count, &["album"])
        .map_err(|err| format!("读取收藏的专辑失败: {err}"))?;
    let (has_more, next_cursor) = page_fields(&value);
    let items = crate::soda::collection::parse_mixed_collections(&value);
    let mut albums = Vec::new();
    for item in items {
        if item.kind() != "album" {
            continue;
        }
        let Some(album) = item.album.as_ref() else {
            continue;
        };
        let id = item.id();
        if id.is_empty() {
            continue;
        }
        // 专辑条目上的艺人名（拍平 artists[]，缺省留空）
        let artists = album
            .get("artists")
            .and_then(Value::as_array)
            .map(|list| {
                list.iter()
                    .filter_map(|a| a.get("name").and_then(Value::as_str))
                    .collect::<Vec<_>>()
                    .join(" / ")
            })
            .unwrap_or_default();
        let track_count = album
            .get("resource_count")
            .and_then(|c| c.get("track_count"))
            .or_else(|| album.get("track_count"))
            .and_then(Value::as_i64)
            .unwrap_or(0);
        albums.push(json!({
            "id": id,
            "name": item.title(),
            "cover": item.cover_url(),
            "artists": artists,
            "trackCount": track_count,
        }));
    }
    Ok(json!({
        "albums": albums,
        "hasMore": has_more,
        "nextCursor": next_cursor,
    }))
}

/// 相似歌曲（官方播放页「相似歌曲」，`GET /luna/media/related` 移动端形态）。
/// 回包形态未文档化，做防御式抽取：常见候选数组里挖 track 实体。
fn method_related_tracks(m: &Snap, params: &Value) -> Result<Value, String> {
    require_cookie(m)?;
    let track_id = params
        .get("trackId")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_string();
    if track_id.is_empty() {
        return Err("缺少歌曲 id".to_string());
    }
    let count = params.get("count").and_then(Value::as_i64).unwrap_or(30);
    let value = mobile_get(
        m,
        "/luna/media/related",
        &[
            ("resource_id", track_id.as_str()),
            ("resource_type", "track"),
            ("count", &count.to_string()),
        ],
    )
    .map_err(|err| format!("相似歌曲不可用: {err}"))?;
    check_status(&value, "相似歌曲")?;
    let mut songs: Vec<crate::model::Song> = Vec::new();
    for key in ["related_tracks", "resources", "media_resources", "tracks", "items"] {
        songs = tracks_from_media_resources(value.get(key));
        if songs.is_empty() {
            songs = songs_from_array(value.get(key));
        }
        if !songs.is_empty() {
            break;
        }
    }
    if songs.is_empty() {
        return Err("相似歌曲回包为空（形态可能已变化）".to_string());
    }
    Ok(json!({ "tracks": tracks_json(&songs) }))
}

/// 我的音乐墙（PC 形态）：最爱曲目墙 + 口味标签（官方个人主页对位）。
/// 注意信封校验——PC 端点偶发「HTTP 200 + 错误信封」（radioList 同款教训）。
fn method_music_wall(m: &Snap) -> Result<Value, String> {
    require_cookie(m)?;
    let value = m
        .soda
        .fetch_music_wall()
        .map_err(|err| format!("读取音乐墙失败: {err}"))?;
    check_status(&value, "音乐墙")?;
    let mut songs: Vec<crate::model::Song> = Vec::new();
    if let Some(items) = value.get("tracks").and_then(Value::as_array) {
        for item in items {
            let parsed: Option<Track> = serde_json::from_value(item.clone()).ok();
            if let Some(track) = parsed.filter(|t| !t.id.is_empty() && !t.name.trim().is_empty())
            {
                songs.push(build_song_from_track(&track));
            }
        }
    }
    let tags = value
        .get("tags")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .filter_map(|tag| {
                    let name = tag.get("tag").and_then(Value::as_str)?.trim().to_string();
                    if name.is_empty() {
                        return None;
                    }
                    Some(json!({
                        "tag": name,
                        "rgb": tag.pointer("/tag_color/rgb").and_then(Value::as_str).unwrap_or_default(),
                        "alpha": tag.pointer("/tag_color/alpha").and_then(Value::as_str).unwrap_or_default(),
                    }))
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    Ok(json!({ "tracks": tracks_json(&songs), "tags": tags }))
}

// ---------------------------------------------------------------------------
// 热搜词 / 歌单导入 / 删除最近播放
// ---------------------------------------------------------------------------

fn method_hot_words(m: &Snap) -> Result<Value, String> {
    // 移动端官方热搜（/luna/suggest-words/default，Cookie 即可）；
    // 回落 PC suggest_words 形态（words/sug_words 数组，字符串或对象混排）。
    if let Ok(value) = mobile_get(m, "/luna/suggest-words/default", &[]) {
        let words: Vec<String> = value
            .get("suggest_words")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(|item| item.get("keyword").and_then(Value::as_str))
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default();
        if !words.is_empty() {
            return Ok(json!(words));
        }
    }
    let value = m
        .soda
        .suggest_words("default")
        .map_err(|err| format!("读取热搜词失败: {err}"))?;
    let list: Vec<Value> = value
        .get("words")
        .or_else(|| value.get("sug_words"))
        .or_else(|| value.get("data"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_else(|| {
            value
                .as_array()
                .map(|items| items.to_vec())
                .unwrap_or_default()
        });
    let words: Vec<String> = list
        .iter()
        .filter_map(|item| match item {
            Value::String(text) => Some(text.clone()),
            Value::Object(_) => item
                .get("content")
                .or_else(|| item.get("word"))
                .or_else(|| item.get("keyword"))
                .and_then(Value::as_str)
                .map(str::to_string),
            _ => None,
        })
        .collect();
    Ok(json!(words))
}

// ---------------------------------------------------------------------------
// 下载缓存（保留：免费曲/试听兜底播放）
// ---------------------------------------------------------------------------

fn quality_tag(config: &Config) -> String {
    let value = config.quality.trim().to_ascii_lowercase();
    if value.is_empty() {
        "auto".to_string()
    } else {
        value
    }
}

fn is_truncated_download(declared: i64, written: u64) -> bool {
    declared > 0 && written < declared as u64
}

fn describe_quality(info: &crate::soda::types::DownloadInfo) -> String {
    let bitrate = info.bitrate.max(0) / 1000;
    let quality = info.quality.to_ascii_lowercase();
    // 对标官方 App 五档：全景声（spatial/atmos）/ 录音室（hi_res）是独立档位，
    // 必须在无损/码率归档之前判，否则 spatial 324k 会被归成「极高」。
    let tier = if quality.contains("spatial")
        || quality.contains("atmos")
        || quality.contains("dolby")
    {
        "全景声"
    } else if quality.contains("hi_res") || quality.contains("hires") || quality.contains("master")
    {
        "录音室"
    } else {
        let lossless = is_lossless(info)
            || info.format.eq_ignore_ascii_case("flac")
            || quality.contains("lossless");
        if lossless {
            "无损"
        } else if bitrate >= 300 {
            "极高"
        } else if bitrate >= 192 {
            "较高"
        } else if bitrate > 0 {
            "标准"
        } else {
            "未知"
        }
    };
    let mut label = if bitrate > 0 {
        format!("{tier} {bitrate}k")
    } else {
        tier.to_string()
    };
    if info.is_preview {
        label.push_str(" · 试听");
    }
    label
}

// ---------------------------------------------------------------------------
// resolve 结果 TTL 缓存：免签层明文直链免重复梯子探测
// ---------------------------------------------------------------------------

/// CDN 直链 token 时效有限，5 分钟内可放心复用；过期重走梯子。
const RESOLVE_CACHE_TTL: Duration = Duration::from_secs(5 * 60);
/// 容量上限：超出即先清过期、再整体清空（曲目有限，不做 LRU）。
const RESOLVE_CACHE_CAP: usize = 32;

struct ResolveCacheEntry {
    info: crate::soda::types::DownloadInfo,
    saved_at: Instant,
}

static RESOLVE_CACHE: OnceLock<Mutex<HashMap<(String, String), ResolveCacheEntry>>> =
    OnceLock::new();

fn resolve_cache() -> &'static Mutex<HashMap<(String, String), ResolveCacheEntry>> {
    RESOLVE_CACHE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn resolve_cache_get(
    track_id: &str,
    preference: &str,
) -> Option<crate::soda::types::DownloadInfo> {
    let key = (track_id.to_string(), preference.to_string());
    let mut map = resolve_cache().lock().ok()?;
    let expired = map
        .get(&key)
        .map(|entry| entry.saved_at.elapsed() > RESOLVE_CACHE_TTL)
        .unwrap_or(false);
    if expired {
        map.remove(&key);
        return None;
    }
    map.get(&key).map(|entry| entry.info.clone())
}

/// 只缓存整曲（非试听）：试听结果入缓存会让后续 forceTrial 回落
/// （外部链失败后回拿试听）拿不到最新判定。
fn resolve_cache_put(
    track_id: &str,
    preference: &str,
    info: &crate::soda::types::DownloadInfo,
) {
    if let Ok(mut map) = resolve_cache().lock() {
        if map.len() >= RESOLVE_CACHE_CAP {
            map.retain(|_, entry| entry.saved_at.elapsed() <= RESOLVE_CACHE_TTL);
            if map.len() >= RESOLVE_CACHE_CAP {
                map.clear();
            }
        }
        map.insert(
            (track_id.to_string(), preference.to_string()),
            ResolveCacheEntry {
                info: info.clone(),
                saved_at: Instant::now(),
            },
        );
    }
}

/// 取流梯子诊断：对同一曲目逐档偏好 resolve（不下载），报告每档实际
/// 命中的层（web/h5/mobile/pc）与档位。用于真机钉死「免签名直取」链路
/// 在当前设备会话下到底能拿到几档。
fn method_stream_ladder(m: &Snap, params: &Value) -> Result<Value, String> {
    let track = params
        .get("track")
        .cloned()
        .ok_or_else(|| "缺少 track 参数".to_string())?;
    let song = song_from_json(&track)?;
    let track_id = crate::soda::download::song_track_id(&song);
    let saved = m.soda.quality_preference();
    let mut rungs = Vec::new();
    for preference in ["", "lossless", "spatial", "hires", "highest"] {
        m.soda.set_quality_preference(preference);
        let outcome = match crate::soda::download::resolve_download_info(&m.soda, &track_id, None) {
            Ok(info) => json!({
                "quality": describe_quality(&info),
                "origin": info.origin,
                "isPreview": info.is_preview,
            }),
            Err(err) => json!({"error": err.to_string()}),
        };
        rungs.push(json!({
            "preference": if preference.is_empty() { "auto".to_string() } else { preference.to_string() },
            "result": outcome,
        }));
    }
    m.soda.set_quality_preference(saved);
    Ok(json!({ "trackId": track_id, "rungs": rungs }))
}

fn method_prepare_track(m: &Snap, params: &Value) -> Result<Value, String> {
    let track = params
        .get("track")
        .cloned()
        .ok_or_else(|| "缺少 track 参数".to_string())?;
    let song = song_from_json(&track)?;
    let dir = std::path::PathBuf::from(&m.config.cache_dir).join("tracks");
    std::fs::create_dir_all(&dir).map_err(|err| format!("创建缓存目录失败: {err}"))?;
    let tag = quality_tag(&m.config);
    let path = dir.join(format!("{}-{tag}.m4a", song.id));
    let quality_path = dir.join(format!("{}-{tag}.quality", song.id));

    if let (Ok(meta), Ok(text)) = (std::fs::metadata(&path), std::fs::read_to_string(&quality_path))
    {
        let actual = meta.len();
        let mut fields = text.split('\t');
        let quality = fields.next().unwrap_or_default().trim().to_string();
        let size = fields.next().unwrap_or_default().trim().parse::<u64>().ok();
        if actual > 0 && !quality.is_empty() && size == Some(actual) {
            return Ok(json!({
                "path": path.to_string_lossy(),
                "quality": quality,
                "size": actual,
                "cached": true,
            }));
        }
    }

    // 一次 resolve 同时回答两件事：是否试听（决定要不要走外部音源），
    // 以及下载直链。旧实现 probe 后再 download_with_info 会把整套
    // web/pc/player_info 探测重跑一遍（首播请求数翻倍）。
    let force_trial = params
        .get("forceTrial")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    // 播放器直链失败（如 CDN 校验 UA）后的回退调用：跳过流式返回，
    // 强制整曲下载落盘。
    let force_download = params
        .get("forceDownload")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let track_id = crate::soda::download::song_track_id(&song);
    // resolve TTL 缓存命中：免掉 web→h5→mobile→pc 梯子探测（预取暖过的
    // 直链直接复用）。缓存里只有整曲，试听/needsExt 判定不受影响。
    let preference = m.soda.quality_preference();
    let info = match resolve_cache_get(&track_id, &preference) {
        Some(info) => info,
        None => match crate::soda::download::resolve_download_info(&m.soda, &track_id, None) {
            Ok(info) => {
                if !info.is_preview {
                    resolve_cache_put(&track_id, &preference, &info);
                }
                info
            }
            // 汽水侧完全探测失败：外部源还有机会按标题匹配救回，维持旧回落语义
            Err(err) if m.config.ext_enabled && !force_trial => {
                return Ok(json!({ "needsExt": true, "probeError": err.to_string() }));
            }
            Err(err) => return Err(format!("探测音源失败: {err}")),
        },
    };

    // 外部音源回落（lx-music 式）：汽水侧为试听档（VIP/会话限制）且外部
    // 源开启时，不急着下载试听——交 Dart 侧解析外部整曲（原生酷我 +
    // lx 脚本链），全部失败后再以 forceTrial 重调拿试听。
    if m.config.ext_enabled && !force_trial && info.is_preview {
        return Ok(json!({ "needsExt": true }));
    }

    // 明文流（免签层免费曲，无 play_auth 加密）：直接返回 CDN 直链交
    // 播放器流式播放——起播从「整曲下载+解密落盘」降到「缓冲头部几秒」，
    // 切档等待从 10~30s 级降到秒级。加密流仍走下方整曲下载解密路径。
    if !force_download && info.play_auth.trim().is_empty() {
        return Ok(json!({
            "url": info.url,
            "ua": crate::soda::types::USER_AGENT,
            "quality": describe_quality(&info),
            "origin": info.origin,
            "size": info.size,
            "cached": false,
        }));
    }

    // 临时文件名带调用序号：会话锁放开后同一曲目可能被并发 prepare
    // （如预取与点播同曲），仅用 pid 会互写同一个 part 文件。
    static PART_SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let part = dir.join(format!(
        "{}-{tag}-{}-{}-part.m4a",
        song.id,
        std::process::id(),
        PART_SEQ.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
    ));
    crate::soda::download::download_resolved(&info, &part).map_err(|err| {
        let _ = std::fs::remove_file(&part);
        format!("下载失败: {err}")
    })?;
    let written = std::fs::metadata(&part).map(|meta| meta.len()).unwrap_or(0);
    if is_truncated_download(info.size, written) {
        let _ = std::fs::remove_file(&part);
        return Err(format!(
            "下载不完整（至少需要 {} 字节，实际 {written} 字节）",
            info.size
        ));
    }
    let quality = describe_quality(&info);
    std::fs::rename(&part, &path).map_err(|err| format!("缓存落盘失败: {err}"))?;
    let _ = std::fs::write(&quality_path, format!("{quality}\t{written}"));
    Ok(json!({
        "path": path.to_string_lossy(),
        "quality": quality,
        "origin": info.origin,
        "size": written,
        "cached": false
    }))
}

fn method_cache_stats(m: &Snap) -> Result<Value, String> {
    let dir = std::path::PathBuf::from(&m.config.cache_dir).join("tracks");
    let mut bytes: u64 = 0;
    let mut files: u64 = 0;
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for entry in entries.flatten() {
            if let Ok(meta) = entry.metadata() {
                if meta.is_file() {
                    bytes += meta.len();
                    files += 1;
                }
            }
        }
    }
    Ok(json!({
        "dir": dir.to_string_lossy(),
        "bytes": bytes,
        "files": files,
    }))
}

fn method_clear_cache(m: &Snap) -> Result<Value, String> {
    let dir = std::path::PathBuf::from(&m.config.cache_dir).join("tracks");
    let mut removed: u64 = 0;
    if let Ok(entries) = std::fs::read_dir(&dir) {
        for entry in entries.flatten() {
            if std::fs::remove_file(entry.path()).is_ok() {
                removed += 1;
            }
        }
    }
    Ok(json!({ "removed": removed }))
}

// ---------------------------------------------------------------------------
// 分发
// ---------------------------------------------------------------------------

fn dispatch(method: &str, params: &Value) -> Result<Value, String> {
    match method {
        "ping" => with_mobile(|m| {
            Ok(json!({
                "version": FFI_VERSION,
                "hasCookie": !m.config.cookie.trim().is_empty(),
                "sourceMode": m.config.source_mode,
                "signerConfigured": m.config.signer_ready(),
            }))
        }),
        "configure" => {
            let config = Config::from_json(params);
            let mut guard =
                mobile().lock().map_err(|_| "全局会话锁中毒".to_string())?;
            guard.soda = Arc::new(build_soda(&config));
            guard.config = config;
            Ok(json!({ "ok": true }))
        }
        "account" => with_mobile(|m| method_account(m)),
        "qrCreate" => with_mobile(|m| method_qr_create(m)),
        "qrCheck" => with_mobile(|m| method_qr_check(m, params)),
        "searchAll" => with_mobile(|m| method_search_all(m, params)),
        "suggest" => with_mobile(|m| method_suggest(m, params)),
        "scenes" => with_mobile(|m| method_scenes(m)),
        "feed" => with_mobile(|m| method_feed(m, params)),
        "albumTracks" => with_mobile(|m| method_album_tracks(m, params)),
        "lyrics" => with_mobile(|m| method_lyrics(m, params)),
        "myPlaylists" => with_mobile(|m| method_my_playlists(m, params)),
        "playlistTracks" => with_mobile(|m| method_playlist_tracks(m, params)),
        "collectedPlaylists" => with_mobile(|m| method_collected_playlists(m, params)),
        "discoverMix" => with_mobile(|m| method_discover_mix(m, params)),
        "recommendPlaylists" => with_mobile(|m| method_recommend_playlists(m)),
        "radioList" => with_mobile(|m| method_radio_list(m)),
        "radioTracks" => with_mobile(|m| method_radio_tracks(m, params)),
        "collectedArtists" => with_mobile(|m| method_collected_artists(m, params)),
        "collectedAlbums" => with_mobile(|m| method_collected_albums(m, params)),
        "relatedTracks" => with_mobile(|m| method_related_tracks(m, params)),
        "musicWall" => with_mobile(|m| method_music_wall(m)),
        "hotWords" => with_mobile(|m| method_hot_words(m)),
        "artistDetail" => with_mobile(|m| method_artist_detail(m, params)),
        "artistTracks" => with_mobile(|m| method_artist_tracks(m, params)),
        "artistAlbums" => with_mobile(|m| method_artist_albums(m, params)),
        "likedSongs" => with_mobile(|m| method_liked_songs(m)),
        "douyinFavorites" => with_mobile(|m| method_douyin_favorites(m)),
        "prepareTrack" => with_mobile(|m| method_prepare_track(m, params)),
        "streamLadder" => with_mobile(|m| method_stream_ladder(m, params)),
        "cacheStats" => with_mobile(|m| method_cache_stats(m)),
        "clearCache" => with_mobile(|m| method_clear_cache(m)),
        // ext_* 是免签外部源，与会话无关，直接执行（不占会话快照）。
        // 原生酷我直连（extPing/extLookup）已移除：外部整曲统一走
        // lx 脚本链，这里只保留其依赖的平台搜索。
        "searchPlatform" => {
            let platform = params.get("platform").and_then(Value::as_str).unwrap_or_default();
            let keyword = params.get("keyword").and_then(Value::as_str).unwrap_or_default();
            let page = params.get("page").and_then(Value::as_i64).unwrap_or(1);
            ext_source::platform_search(platform, keyword, page)
        }
        "chartTracks" => {
            let platform = params.get("platform").and_then(Value::as_str).unwrap_or_default();
            let chart_id = params.get("chartId").and_then(Value::as_str).unwrap_or_default();
            let page = params.get("page").and_then(Value::as_i64).unwrap_or(1);
            ext_source::platform_chart_tracks(platform, chart_id, page)
        }
        "platformLyric" => {
            let platform = params.get("platform").and_then(Value::as_str).unwrap_or_default();
            let songmid = params.get("songmid").and_then(Value::as_str).unwrap_or_default();
            ext_source::platform_lyric(platform, songmid)
        }
        _ => Err(format!("未知方法: {method}")),
    }
}

// ---------------------------------------------------------------------------
// C ABI
// ---------------------------------------------------------------------------

fn take_c_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    Some(unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned())
}

fn return_json(result: Result<Value, String>) -> *mut c_char {
    let payload = match result {
        Ok(data) => json!({ "ok": true, "data": data }),
        Err(error) => json!({ "ok": false, "error": error }),
    };
    let text = payload.to_string();
    match CString::new(text) {
        Ok(cstring) => CString::into_raw(cstring),
        Err(_) => std::ptr::null_mut(),
    }
}

/// 初始化/重新配置全局会话。`config_json` 见 [`Config::from_json`] 的键名。
#[no_mangle]
pub extern "C" fn sodam_init(config_json: *const c_char) -> *mut c_char {
    let config = take_c_string(config_json).unwrap_or_default();
    let result = catch_unwind(AssertUnwindSafe(|| {
        let value: Value = serde_json::from_str(&config)
            .map_err(|err| format!("config json 解析失败: {err}"))?;
        dispatch("configure", &value)
    }))
    .unwrap_or_else(|panic| {
        Err(format!("sodam_init panic: {panic:?}"))
    });
    return_json(result)
}

/// 业务调用统一入口。所有方法同步阻塞，Dart 侧应在后台 isolate 执行。
#[no_mangle]
pub extern "C" fn sodam_request(method: *const c_char, params_json: *const c_char) -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(|| {
        let method = take_c_string(method).unwrap_or_default();
        let params_text = take_c_string(params_json).unwrap_or_default();
        let params: Value = if params_text.trim().is_empty() {
            Value::Object(Default::default())
        } else {
            serde_json::from_str(&params_text)
                .map_err(|err| format!("params json 解析失败: {err}"))?
        };
        dispatch(method.trim(), &params)
    }))
    .unwrap_or_else(|panic| Err(format!("sodam_request panic: {panic:?}")));
    return_json(result)
}

/// Dart 轮询签名请求：返回 `{"id":"...","request":{...}}`；`{"id":""}` 表示空闲。
/// 注意：不得经由 `sodam_request` 调用（会与业务请求抢同一把全局锁）。
#[no_mangle]
pub extern "C" fn sodam_signer_poll() -> *mut c_char {
    let result = catch_unwind(AssertUnwindSafe(signer_poll))
        .unwrap_or_else(|panic| Err(format!("signer_poll panic: {panic:?}")));
    return_json(result)
}

/// 二次验证窗口启动数据：`{"token":"..."}` → `{decision, generalParams}`。
fn second_verify_data(params: &Value) -> Result<Value, String> {
    let token = params
        .get("token")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    if token.is_empty() {
        return Err("缺少二维码 token".to_string());
    }
    let map = second_verify_map()
        .lock()
        .map_err(|_| "二次验证登记表锁中毒".to_string())?;
    let entry = map.get(token).ok_or_else(|| {
        format!(
            "汽水二维码会话已过期，请重新生成二维码（登记表 {} 项/共登记 {} 次，查无 token 尾 {}）",
            map.len(),
            SECOND_VERIFY_REGISTERS.load(std::sync::atomic::Ordering::Relaxed),
            token_tail(token),
        )
    })?;
    Ok(json!({
        "decision": entry.decision,
        "generalParams": entry.general_params,
    }))
}

/// 验证窗口回执完成（验证页 /verify/complete 调用）。
fn second_verify_complete(params: &Value) -> Result<Value, String> {
    let token = params
        .get("token")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim();
    if token.is_empty() {
        return Err("缺少二维码 token".to_string());
    }
    let mut map = second_verify_map()
        .lock()
        .map_err(|_| "二次验证登记表锁中毒".to_string())?;
    match map.get_mut(token) {
        Some(entry) => {
            entry.done = true;
            Ok(json!({ "success": true }))
        }
        None => Err("汽水二维码会话已过期，请重新生成二维码".to_string()),
    }
}

/// Dart 回填签名结果。
#[no_mangle]
pub extern "C" fn sodam_signer_respond(json: *const c_char) -> *mut c_char {
    let text = take_c_string(json).unwrap_or_default();
    let result = catch_unwind(AssertUnwindSafe(|| {
        let value: Value = serde_json::from_str(&text)
            .map_err(|err| format!("respond json 解析失败: {err}"))?;
        signer_respond(&value)
    }))
    .unwrap_or_else(|panic| Err(format!("signer_respond panic: {panic:?}")));
    return_json(result)
}

/// 二次验证窗口启动数据（decision + generalParams）。`params_json`: {"token":...}
#[no_mangle]
pub extern "C" fn sodam_second_verify_data(params_json: *const c_char) -> *mut c_char {
    let text = take_c_string(params_json).unwrap_or_default();
    let result = catch_unwind(AssertUnwindSafe(|| {
        let value: Value = if text.trim().is_empty() {
            Value::Object(Default::default())
        } else {
            serde_json::from_str(&text).map_err(|err| format!("params 解析失败: {err}"))?
        };
        second_verify_data(&value)
    }))
    .unwrap_or_else(|panic| Err(format!("second_verify_data panic: {panic:?}")));
    return_json(result)
}

/// 二次验证完成回执（验证页 /verify/complete → 这里置位，轮询侧随即重发确认）。
#[no_mangle]
pub extern "C" fn sodam_second_verify_complete(params_json: *const c_char) -> *mut c_char {
    let text = take_c_string(params_json).unwrap_or_default();
    let result = catch_unwind(AssertUnwindSafe(|| {
        let value: Value = if text.trim().is_empty() {
            Value::Object(Default::default())
        } else {
            serde_json::from_str(&text).map_err(|err| format!("params 解析失败: {err}"))?
        };
        second_verify_complete(&value)
    }))
    .unwrap_or_else(|panic| Err(format!("second_verify_complete panic: {panic:?}")));
    return_json(result)
}

/// 释放其余接口返回的字符串。
#[no_mangle]
pub extern "C" fn sodam_free(text: *mut c_char) {
    if !text.is_null() {
        drop(unsafe { CString::from_raw(text) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn track_json_round_trip() {
        let song = song_from_json(&json!({
            "id": "123", "title": "测试", "artist": "歌手", "album": "专辑",
            "artistId": "a1", "albumId": "al1", "cover": "https://x/c.jpg",
            "durationSeconds": 234, "vip": true,
        }))
        .expect("song");
        assert_eq!(song.id, "123");
        assert_eq!(song.duration, 234);
        let value = track_json(&song);
        assert_eq!(value["artistId"], "a1");
        assert_eq!(value["vip"], true);
    }

    #[test]
    fn dispatch_unknown_method() {
        assert!(dispatch("nope", &Value::Null).is_err());
    }

    /// C ABI 离线往返：init(config) → request("ping") → free。
    #[test]
    fn c_abi_round_trip() {
        use std::ffi::CString;
        let config = CString::new(
            json!({ "cacheDir": std::env::temp_dir().to_string_lossy() }).to_string(),
        )
        .expect("config cstring");
        let init = sodam_init(config.as_ptr());
        let init_text = unsafe { CStr::from_ptr(init) }.to_string_lossy().into_owned();
        sodam_free(init);
        assert!(init_text.contains(r#""ok":true"#), "init 返回: {init_text}");

        let method = CString::new("ping").expect("method cstring");
        let params = CString::new("{}").expect("params cstring");
        let result = sodam_request(method.as_ptr(), params.as_ptr());
        let text = unsafe { CStr::from_ptr(result) }.to_string_lossy().into_owned();
        sodam_free(result);
        assert!(text.contains(r#""ok":true"#), "ping 返回: {text}");
        assert!(text.contains("hasCookie"), "ping 应包含会话状态: {text}");
    }

    /// 签名桥空闲轮询应返回空 id。
    #[test]
    fn signer_poll_idle() {
        let ptr = sodam_signer_poll();
        let text = unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned();
        sodam_free(ptr);
        assert!(text.contains(r#""id":""#), "空闲轮询返回: {text}");
    }

    #[test]
    fn quality_label_covers_preview() {
        let mut info = crate::soda::types::DownloadInfo::default();
        info.quality = "lossless".into();
        info.bitrate = 873_000;
        info.format = "flac".into();
        assert!(describe_quality(&info).contains("无损"));
        info.is_preview = true;
        assert!(describe_quality(&info).contains("试听"));
    }
}
