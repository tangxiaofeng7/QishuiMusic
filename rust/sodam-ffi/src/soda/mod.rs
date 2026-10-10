//! 汽水客户端总装:会话状态(Cookie/签名/浏览器桥/冷却表)与 PC 端点公共层。
//!
//! 模块划分:
//! * 会话与取流配置 —— 本文件 `Soda`
//! * 数据契约 —— `types`
//! * 链接/id 解析 —— `link`
//! * 档位评分与择优 —— `quality`
//! * 搜索/联想 —— `search`
//! * 单曲详情与各端点取流 —— `track`、`song`
//! * 专辑/歌单/歌词/账号 —— `album`、`playlist(_edit)`、`lyric`、`account`
//! * 取流梯子与下载解密 —— `download`、`crypto`
//! * 扫码登录 —— `qr_login`(签名页浏览器抽象 `browser`)
//! * 签名注入 —— `signature`
//! * 推荐/发现/收藏/播放历史/艺人 —— `feed`、`collection`、`playback`、`artist`
//! * 写操作媒体引用 —— `media_ref`、`stream`(取流诊断)

pub mod account;
pub mod album;
pub mod artist;
pub mod browser;
pub mod collection;
pub mod crypto;
pub mod download;
pub mod feed;
pub mod link;
pub mod lyric;
pub mod media_ref;
pub mod playback;
pub mod playlist;
pub mod playlist_edit;
pub mod qr_login;
pub mod quality;
pub mod search;
pub mod signature;
pub mod song;
pub mod stream;
pub mod track;
pub mod types;
pub mod user_playlist;

use crate::model::{Playlist, PlaylistCategory, QRLoginResult, Song};
use crate::util::Params;
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

pub use types::DownloadInfo;

/// h5/mobile 层硬失败(端点不可达/风控)的冷却时长。
const OPEN_LAYER_HARD_COOLDOWN: Duration = Duration::from_secs(600);
/// 层探测「无增益」时的短冷却(之后自动重试)。
const OPEN_LAYER_SOFT_COOLDOWN: Duration = Duration::from_secs(30);

/// 汽水会话客户端:全部字段内部可变(`&self` 更新),天然支持 `Arc` 共享并发。
pub struct Soda {
    cookie: Mutex<String>,
    is_vip_cache: Mutex<Option<bool>>,
    /// 音质档位偏好(gear key:best/lossless/highest/medium…),空 = 永远最优。
    quality_preference: Mutex<String>,
    signature: Mutex<Option<Arc<dyn signature::SignatureProvider>>>,
    browser: Mutex<Option<Arc<dyn browser::BrowserRequester>>>,
    app_credentials: Mutex<Option<signature::AppCredentials>>,
    /// 免签开放层失败冷却表:层名 → 截止时刻(弱网下防止逐曲重复撞同一堵墙)。
    open_layer_cooldown: Mutex<HashMap<String, Instant>>,
}

// 手写 Debug:trait 对象无 Debug,且凭据值(签名头/cookie)绝不能进日志。
impl std::fmt::Debug for Soda {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Soda")
            .field("has_cookie", &self.has_cookie())
            .field("vip_cached", &self.cached_vip())
            .field(
                "signature_provider",
                &self.signature_provider().map(|provider| provider.name()),
            )
            .field(
                "app_credentials",
                &self
                    .app_credentials()
                    .map(|credentials| {
                        format!(
                            "complete={} device_id.len={} x_helios.len={} x_medusa.len={}",
                            credentials.is_complete(),
                            credentials.device_id.len(),
                            credentials.x_helios.len(),
                            credentials.x_medusa.len()
                        )
                    })
                    .unwrap_or_else(|| "none".to_string()),
            )
            .finish()
    }
}

impl Default for Soda {
    fn default() -> Self {
        Self::new("")
    }
}

impl Soda {
    /// 创建会话;空 cookie = 匿名(只能拿免费明文流)。
    pub fn new(cookie: impl Into<String>) -> Self {
        Self {
            cookie: Mutex::new(cookie.into()),
            is_vip_cache: Mutex::new(None),
            quality_preference: Mutex::new(String::new()),
            signature: Mutex::new(None),
            browser: Mutex::new(None),
            app_credentials: Mutex::new(None),
            open_layer_cooldown: Mutex::new(HashMap::new()),
        }
    }

    /// 设置应用签名凭证(x-helios/x-medusa + 设备指纹);写入时归一化空白。
    pub fn set_app_credentials(&self, credentials: signature::AppCredentials) {
        if let Ok(mut slot) = self.app_credentials.lock() {
            *slot = Some(credentials.normalized());
        }
    }

    /// 从 JSON 文件加载应用签名凭证。
    pub fn load_app_credentials(&self, path: impl AsRef<std::path::Path>) -> crate::error::Result<()> {
        let credentials = signature::AppCredentials::from_file(path)?;
        self.set_app_credentials(credentials);
        Ok(())
    }

    /// 当前应用签名凭证。
    pub fn app_credentials(&self) -> Option<signature::AppCredentials> {
        self.app_credentials
            .lock()
            .ok()
            .and_then(|slot| slot.clone())
    }

    /// 清空应用签名凭证。
    pub fn clear_app_credentials(&self) {
        if let Ok(mut slot) = self.app_credentials.lock() {
            *slot = None;
        }
    }

    /// 诊断用:当前会附加到 App 端点的签名头(不含 Cookie)。
    pub fn app_signature_headers(&self) -> Vec<(String, String)> {
        pc_request_options(self)
            .into_iter()
            .flat_map(|option| option.headers().to_vec())
            .filter(|(name, _)| {
                name.eq_ignore_ascii_case("x-helios") || name.eq_ignore_ascii_case("x-medusa")
            })
            .collect()
    }

    /// 设置浏览器请求器(请求交给跑官方安全组件的页面代发,自带签名)。
    pub fn set_browser_requester(&self, requester: Arc<dyn browser::BrowserRequester>) {
        if let Ok(mut slot) = self.browser.lock() {
            *slot = Some(requester);
        }
    }

    /// 当前浏览器请求器(`None` = 本地直连)。
    pub fn browser_requester(&self) -> Option<Arc<dyn browser::BrowserRequester>> {
        self.browser.lock().ok().and_then(|slot| slot.clone())
    }

    /// 设置签名提供者(实时签名 / 抓包回填 / 外部命令)。
    pub fn set_signature_provider(&self, provider: Arc<dyn signature::SignatureProvider>) {
        if let Ok(mut slot) = self.signature.lock() {
            *slot = Some(provider);
        }
    }

    /// 当前签名提供者(`None` = 不签名)。
    pub fn signature_provider(&self) -> Option<Arc<dyn signature::SignatureProvider>> {
        self.signature.lock().ok().and_then(|slot| slot.clone())
    }

    /// 当前 Cookie。
    pub fn cookie(&self) -> String {
        self.cookie
            .lock()
            .map(|guard| guard.clone())
            .unwrap_or_default()
    }

    /// 更新 Cookie;同时作废 VIP 探测缓存(登录态变了,旧判定不可信)。
    pub fn set_cookie(&self, cookie: impl Into<String>) {
        if let Ok(mut guard) = self.cookie.lock() {
            *guard = cookie.into();
        }
        if let Ok(mut cache) = self.is_vip_cache.lock() {
            *cache = None;
        }
    }

    pub(crate) fn has_cookie(&self) -> bool {
        !self.cookie().trim().is_empty()
    }

    pub(crate) fn cached_vip(&self) -> Option<bool> {
        self.is_vip_cache.lock().ok().and_then(|cache| *cache)
    }

    pub(crate) fn set_cached_vip(&self, value: bool) {
        if let Ok(mut cache) = self.is_vip_cache.lock() {
            *cache = Some(value);
        }
    }

    /// 设置音质偏好(gear key):best/auto/空 = 永远最优;取流按「不超过该档」
    /// 择优,档内无候选回退整体最优。
    pub fn set_quality_preference(&self, preference: impl Into<String>) {
        if let Ok(mut slot) = self.quality_preference.lock() {
            *slot = preference.into().trim().to_string();
        }
    }

    /// 当前音质偏好(空串 = 不限)。
    pub fn quality_preference(&self) -> String {
        self.quality_preference
            .lock()
            .map(|slot| slot.clone())
            .unwrap_or_default()
    }

    /// 免签开放层(h5/mobile)是否已过冷却期(锁异常时按可用处理,不阻塞取流)。
    pub fn open_layer_available(&self, layer: &str) -> bool {
        self.open_layer_cooldown
            .lock()
            .map(|map| {
                map.get(layer)
                    .map(|deadline| Instant::now() >= *deadline)
                    .unwrap_or(true)
            })
            .unwrap_or(true)
    }

    /// 层硬失败(请求失败/风控):进 10 分钟冷却。
    pub fn open_layer_cooldown_start(&self, layer: &str) {
        if let Ok(mut map) = self.open_layer_cooldown.lock() {
            map.insert(layer.to_string(), Instant::now() + OPEN_LAYER_HARD_COOLDOWN);
        }
    }

    /// 层增益反馈:无增益进 30s 短冷却(免费曲常驻 3 档时,无损偏好用户不必
    /// 每首都白付两跳 RTT);有增益清零立即恢复。
    pub fn open_layer_note_uplift(&self, layer: &str, uplift: bool) {
        if let Ok(mut map) = self.open_layer_cooldown.lock() {
            if uplift {
                map.remove(layer);
            } else {
                map.insert(layer.to_string(), Instant::now() + OPEN_LAYER_SOFT_COOLDOWN);
            }
        }
    }
}

/// 进程级默认实例(包级便捷函数的执行载体)。
pub fn default_instance() -> &'static Soda {
    static INSTANCE: OnceLock<Soda> = OnceLock::new();
    INSTANCE.get_or_init(Soda::default)
}

/// 默认实例简写。
pub fn soda() -> &'static Soda {
    default_instance()
}

// ---------------------------------------------------------------------------
// PC App 端点公共层(参数/URL/请求头/GET/POST)
// ---------------------------------------------------------------------------

/// PC App 端公共查询参数(匿名形态)。
pub fn pc_app_params() -> Params {
    pc_app_params_with(None)
}

/// PC 公共参数:带凭证时设备指纹用凭证里的(服务端校验「指纹与签名头一致」,
/// 带了 x-helios/x-medusa 就必须用抓包那台设备的指纹);匿名时逐次现造。
pub fn pc_app_params_with(credentials: Option<&signature::AppCredentials>) -> Params {
    let now = crate::util::now_millis();
    let pick = |value: Option<String>, fallback: String| {
        value
            .map(|text| text.trim().to_string())
            .filter(|text| !text.is_empty())
            .unwrap_or(fallback)
    };
    let device_id = pick(
        credentials.map(|value| value.device_id.clone()),
        now.to_string(),
    );
    let iid = pick(
        credentials.map(|value| value.iid.clone()),
        (now + 1).to_string(),
    );
    let fp = pick(
        credentials.map(|value| value.fp_or_device_id()),
        device_id.clone(),
    );

    let mut params = Params::new();
    for (key, value) in [
        ("aid", "386088"),
        ("app_name", "luna_pc"),
        ("region", "cn"),
        ("geo_region", "cn"),
        ("os_region", "cn"),
        ("sim_region", ""),
        ("device_id", &device_id),
        ("cdid", ""),
        ("iid", &iid),
        ("version_name", "3.3.0"),
        ("version_code", "30030000"),
        ("channel", "official"),
        ("build_mode", "master"),
        ("network_carrier", ""),
        ("ac", "wifi"),
        ("tz_name", "Asia/Shanghai"),
        ("resolution", ""),
        ("device_platform", "windows"),
        ("device_type", "Windows"),
        ("os_version", "Windows 11"),
        ("fp", &fp),
    ] {
        params.set(key, value);
    }
    params
}

/// `/luna/pc/me` 完整地址。
pub fn pc_me_url() -> String {
    format!("https://api.qishui.com/luna/pc/me?{}", pc_app_params().encode())
}

/// `/luna/pc/track_v2` 完整地址(匿名形态)。
pub fn pc_track_v2_url() -> String {
    pc_track_v2_url_with(None)
}

/// `/luna/pc/track_v2` 完整地址(带凭证)。
pub fn pc_track_v2_url_with(credentials: Option<&signature::AppCredentials>) -> String {
    format!(
        "https://api.qishui.com/luna/pc/track_v2?{}",
        pc_app_params_with(credentials).encode()
    )
}

/// `/luna/pc/user/playlist` 完整地址(count 非法值按 50)。
pub fn pc_user_playlist_url(user_id: &str, cursor: &str, count: i64) -> String {
    let count = if count <= 0 { 50 } else { count };
    let mut params = pc_app_params();
    params.set("user_id", user_id.trim());
    params.set("cursor", cursor.trim());
    params.set("count", count.to_string());
    format!(
        "https://api.qishui.com/luna/pc/user/playlist?{}",
        params.encode()
    )
}

/// `/luna/pc/playlist/detail` 完整地址(count 非法值按 100)。
pub fn pc_playlist_detail_url(playlist_id: &str, cursor: &str, count: i64) -> String {
    let count = if count <= 0 { 100 } else { count };
    let mut params = pc_app_params();
    params.set("playlist_id", playlist_id.trim());
    params.set("cursor", cursor.trim());
    params.set("count", count.to_string());
    format!(
        "https://api.qishui.com/luna/pc/playlist/detail?{}",
        params.encode()
    )
}

/// PC 端点 GET:公共参数 + 业务参数(数组参数用重复 key 语义)。
pub(crate) fn pc_get_json(
    soda: &Soda,
    path: &str,
    extra: &[(&str, String)],
) -> crate::error::Result<serde_json::Value> {
    let credentials = soda.app_credentials();
    let mut params = pc_app_params_with(credentials.as_ref());
    for (key, value) in extra {
        params.add(*key, value.clone());
    }
    let url = format!("https://api.qishui.com{path}?{}", params.encode());
    let raw = crate::http::get(&url, &pc_request_options(soda))?;
    if raw.is_empty() {
        return Err(crate::error::SodaError::http(format!(
            "soda {path} returned empty body（通常是缺应用级签名头，或设备指纹与签名器不一致）"
        )));
    }
    serde_json::from_slice(&raw).map_err(|err| {
        crate::error::SodaError::json(format!("soda {path} json decode error: {err}"))
    })
}

/// PC 端点 POST:公共参数 → X-SS-STUB → 逐请求签名 → 发送。
/// 签名覆盖「URL+全部头+body」,所以一切必须在签名前就位。
pub(crate) fn pc_post_json(
    soda: &Soda,
    path: &str,
    body: &serde_json::Value,
) -> crate::error::Result<serde_json::Value> {
    let credentials = soda.app_credentials();
    let body_bytes = serde_json::to_vec(body).map_err(|err| {
        crate::error::SodaError::json(format!("soda {path} json encode error: {err}"))
    })?;
    let mut options = pc_request_options(soda);
    options.push(
        crate::http::RequestOption::new()
            .header("Content-Type", "application/json; charset=utf-8")
            .header("X-SS-STUB", qr_login::md5_hex_upper(&body_bytes)),
    );
    let mut url = format!(
        "https://api.qishui.com{path}?{}",
        pc_app_params_with(credentials.as_ref()).encode()
    );
    let body_text = String::from_utf8_lossy(&body_bytes).to_string();
    if let Some(signed) = signature::apply_stream_signature(soda, &url, &body_text, &mut options) {
        url = signed;
    }
    let raw = crate::http::post_json(&url, &body_bytes, &options)?;
    if raw.is_empty() {
        return Err(crate::error::SodaError::http(format!(
            "soda {path} returned empty body（通常是缺应用级签名头，或设备指纹与签名器不一致）"
        )));
    }
    serde_json::from_slice(&raw).map_err(|err| {
        crate::error::SodaError::json(format!("soda {path} json decode error: {err}"))
    })
}

/// PC 端点公共请求头:PC UA + x-luna-* 三头 + (有凭证时的)签名头 + Cookie。
pub(crate) fn pc_request_options(soda: &Soda) -> Vec<crate::http::RequestOption> {
    let credentials = soda.app_credentials();
    let user_agent = credentials
        .as_ref()
        .map(|value| value.user_agent_or_default())
        .unwrap_or_else(|| types::PC_APP_USER_AGENT.to_string());
    let mut option = crate::http::RequestOption::new()
        .header("User-Agent", user_agent)
        .header("x-luna-background-type", "foreground")
        .header("x-luna-is-background-req", "0")
        .header("x-luna-is-local-user", "1");
    if let Some(credentials) = &credentials {
        for (name, value) in credentials.headers() {
            option = option.header(name, value);
        }
    }
    vec![option.cookie(&soda.cookie())]
}

// ---------------------------------------------------------------------------
// 包级便捷函数(默认实例)
// ---------------------------------------------------------------------------

pub fn search(keyword: &str) -> crate::error::Result<Vec<Song>> {
    default_instance().search(keyword)
}

pub fn parse(link: &str) -> crate::error::Result<Song> {
    default_instance().parse(link)
}

pub fn search_album(keyword: &str) -> crate::error::Result<Vec<Playlist>> {
    default_instance().search_album(keyword)
}

pub fn get_album_songs(id: &str) -> crate::error::Result<Vec<Song>> {
    default_instance().get_album_songs(id)
}

pub fn parse_album(link: &str) -> crate::error::Result<(Playlist, Vec<Song>)> {
    default_instance().parse_album(link)
}

pub fn search_playlist(keyword: &str) -> crate::error::Result<Vec<Playlist>> {
    default_instance().search_playlist(keyword)
}

pub fn get_playlist_songs(id: &str) -> crate::error::Result<Vec<Song>> {
    default_instance().get_playlist_songs(id)
}

pub fn parse_playlist(link: &str) -> crate::error::Result<(Playlist, Vec<Song>)> {
    default_instance().parse_playlist(link)
}

pub fn get_recommended_playlists() -> crate::error::Result<Vec<Playlist>> {
    default_instance().get_recommended_playlists()
}

pub fn get_playlist_categories() -> crate::error::Result<Vec<PlaylistCategory>> {
    default_instance().get_playlist_categories()
}

pub fn get_category_playlists(
    category_id: &str,
    page: i64,
    limit: i64,
) -> crate::error::Result<Vec<Playlist>> {
    default_instance().get_category_playlists(category_id, page, limit)
}

pub fn get_user_playlists(page: i64, limit: i64) -> crate::error::Result<Vec<Playlist>> {
    default_instance().get_user_playlists(page, limit)
}

pub fn get_lyrics(song: &Song) -> crate::error::Result<String> {
    default_instance().get_lyrics(song)
}

pub fn is_vip_account() -> crate::error::Result<bool> {
    default_instance().is_vip_account()
}

pub fn get_download_info(song: &Song) -> crate::error::Result<DownloadInfo> {
    default_instance().get_download_info(song)
}

pub fn get_download_url(song: &Song) -> crate::error::Result<String> {
    default_instance().get_download_url(song)
}

pub fn download(song: &Song, output_path: &std::path::Path) -> crate::error::Result<()> {
    default_instance().download(song, output_path)
}

pub fn create_qr_login() -> crate::error::Result<qr_login::QrCreateResult> {
    qr_login::create_qr(default_instance())
}

pub fn check_qr_login(key: &str) -> crate::error::Result<QRLoginResult> {
    qr_login::check_qr(default_instance(), key)
}
