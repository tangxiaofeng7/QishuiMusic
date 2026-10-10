//! 单曲详情、各端点取流与 video_model(嵌套视频流 JSON)择优。
//!
//! 端点族:web track_v2(免签,SEO 兜底)/ h5 / mobile(免签开放端点,
//! 指纹风控)/ pc track_v2(应用签名,整曲)。回包字段名蛇形/帕斯卡混用,
//! 解析全部走候选键防御式取值。

use super::quality::{
    better_stream_candidate, normalize_bitrate, quality_hint, track_duration_seconds,
};
use super::types::{
    build_image_url, join_track_artists, max_bitrate_size, track_extra, track_link, DownloadInfo,
    PlayerInfo, PlayerInfoResponse, SeoTrackResponse, Track, TrackV2Response, USER_AGENT,
};
use super::Soda;
use crate::error::{Result, SodaError};
use crate::http::{self, RequestOption};
use crate::model::Song;
use crate::util::{json_first_string, json_float, json_int, json_object, json_string};
use serde_json::{Map, Value};

use super::types::SODA_SEO_BASE;

/// web 形态 track_v2(免签名)。
pub fn web_track_v2_url(track_id: &str) -> String {
    let mut params = crate::util::Params::new();
    params.set("track_id", track_id);
    params.set("media_type", "track");
    params.set("aid", "386088");
    params.set("device_platform", "web");
    params.set("channel", "pc_web");
    format!("https://api.qishui.com/luna/pc/track_v2?{}", params.encode())
}

/// SEO 分享页端点(免签名,回包带歌词/翻译/热门评论)。
pub fn seo_track_url(track_id: &str) -> String {
    let mut params = crate::util::Params::new();
    params.set("track_id", track_id);
    params.set("device_platform", "web");
    format!("{SODA_SEO_BASE}?{}", params.encode())
}

/// track_v2 回包解析(信封校验)。
pub fn parse_track_v2_response(body: &[u8]) -> Result<TrackV2Response> {
    let response: TrackV2Response = serde_json::from_slice(body)
        .map_err(|err| SodaError::json(format!("soda track_v2 json parse error: {err}")))?;
    let msg = response.status_info.status_msg.trim();
    if response.status_code != 0 {
        return Err(SodaError::api(
            response.status_code,
            if msg.is_empty() { "unknown error" } else { msg },
        ));
    }
    Ok(response)
}

/// SEO 回包 → track_v2 形态(歌词优先取内层,回退顶层;评论透传)。
pub fn fetch_seo_track_data(soda: &Soda, track_id: &str) -> Result<TrackV2Response> {
    let body = http::get(
        &seo_track_url(track_id),
        &[
            RequestOption::new().header("User-Agent", USER_AGENT),
            RequestOption::new().cookie(&soda.cookie()),
        ],
    )?;
    let seo: SeoTrackResponse = serde_json::from_slice(&body)
        .map_err(|err| SodaError::json(format!("soda seo_track json parse error: {err}")))?;
    let msg = seo.status_info.status_msg.trim();
    if seo.status_code != 0 {
        return Err(SodaError::api(
            seo.status_code,
            if msg.is_empty() { "unknown error" } else { msg },
        ));
    }

    let track = seo.seo_track.track.clone();
    // 歌词两处放:内层 seo_track.lyric 与顶层 lyric,取非空者
    let lyric_body = if !seo.seo_track.lyric.content.trim().is_empty() {
        seo.seo_track.lyric.clone()
    } else {
        seo.lyric.clone()
    };

    let response = TrackV2Response {
        status_code: 0,
        status_info: Default::default(),
        track: track.clone(),
        track_info: track,
        track_player: seo.track_player.clone(),
        lyric: lyric_body,
        comments: seo.comments.clone(),
    };
    if response.track.id.trim().is_empty() {
        return Err(SodaError::not_found("soda seo_track missing track id"));
    }
    Ok(response)
}

/// web track_v2,请求/解析任一失败回落 SEO。
pub fn fetch_web_track_v2(soda: &Soda, track_id: &str) -> Result<TrackV2Response> {
    let direct = http::get(
        &web_track_v2_url(track_id),
        &[
            RequestOption::new().header("User-Agent", USER_AGENT),
            RequestOption::new().cookie(&soda.cookie()),
        ],
    );
    let stage = match &direct {
        Ok(body) => match parse_track_v2_response(body) {
            Ok(response) => return Ok(response),
            Err(parse_err) => format!("soda track_v2 parse failed: {parse_err}"),
        },
        Err(http_err) => format!("soda track_v2 failed: {http_err}"),
    };
    fetch_seo_track_data(soda, track_id)
        .map_err(|seo_err| SodaError::http(format!("{stage} (seo fallback: {seo_err})")))
}

/// H5 曲目端点(免签名;受指纹级风控,设备会话可过;直连被拒回落签名页代发)。
pub fn h5_track_url(track_id: &str) -> String {
    format!("https://api.qishui.com/luna/h5/track?track_id={track_id}")
}

/// 移动端开放接口族(aid=8478)曲目端点。
pub fn mobile_track_url(track_id: &str) -> String {
    let mut params = crate::util::Params::new();
    params.set("track_id", track_id);
    params.set("media_type", "track");
    params.set("aid", "8478");
    params.set("device_platform", "iphone");
    format!("https://api.qishui.com/luna/track?{}", params.encode())
}

/// h5/track 与 luna/track 的防御性解析:共享 track_v2 信封,曲目键名
/// (`track`/`data.track`)逐个备选位置探测。
fn parse_open_track_body(body: &[u8]) -> Result<TrackV2Response> {
    let value: Value = serde_json::from_slice(body)
        .map_err(|err| SodaError::json(format!("open track json parse error: {err}")))?;
    let status_code = value
        .get("status_code")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    if status_code != 0 {
        return Err(SodaError::api(
            status_code,
            value
                .pointer("/status_info/status_msg")
                .and_then(Value::as_str)
                .unwrap_or("unknown error"),
        ));
    }
    let mut response: TrackV2Response = serde_json::from_value(value.clone())
        .map_err(|err| SodaError::json(format!("open track shape error: {err}")))?;
    if response.track.id.is_empty() {
        for pointer in ["/data/track", "/data/track_info", "/track_info"] {
            let hit = value
                .pointer(pointer)
                .and_then(|track| serde_json::from_value::<Track>(track.clone()).ok())
                .filter(|track| !track.id.is_empty());
            if let Some(track) = hit {
                response.track = track;
                break;
            }
        }
    }
    if response.track_info.id.is_empty() {
        response.track_info = response.track.clone();
    }
    if response.track.id.is_empty()
        && response.track_player.url_player_info.trim().is_empty()
        && response.track_player.video_model.is_none()
    {
        return Err(SodaError::not_found(
            "open track response has neither track nor player",
        ));
    }
    Ok(response)
}

/// 被指纹风控拒绝时换签名页代发:页面 bdms 补 a_bogus,浏览器上下文自带
/// 设备身份。未配置签名页则透传原错误。
fn open_track_via_browser(soda: &Soda, url: &str, source_error: SodaError) -> Result<Vec<u8>> {
    let Some(requester) = soda.browser_requester() else {
        return Err(source_error);
    };
    let request = super::browser::BrowserRequest {
        session_key: "open-track".to_string(),
        method: "GET".to_string(),
        url: url.to_string(),
        headers: std::collections::BTreeMap::from([(
            "User-Agent".to_string(),
            USER_AGENT.to_string(),
        )]),
        body: None,
        ms_token: String::new(),
    };
    let response = requester.request(&request)?;
    if !response.ok || response.body.is_empty() {
        return Err(source_error);
    }
    Ok(response.body.into_bytes())
}

/// 免签开放端点一层(h5/mobile 共用):直连 → 1000062/空体时签名页代发。
fn fetch_open_track(soda: &Soda, url: &str) -> Result<TrackV2Response> {
    let direct = http::get(
        url,
        &[
            RequestOption::new().header("User-Agent", USER_AGENT),
            RequestOption::new().cookie(&soda.cookie()),
        ],
    );
    match direct {
        Ok(body) if !body.is_empty() => parse_open_track_body(&body),
        outcome => {
            let source_error = match outcome {
                Err(err) => err,
                Ok(_) => SodaError::http("open track returned empty body"),
            };
            // 只有指纹风控(1000062/空体)值得换通道;网络/解析错误直接失败
            let fingerprint_rejected = matches!(
                &source_error,
                SodaError::Api { status_code, .. } if *status_code == 100_0062
            ) || source_error.to_string().contains("empty body");
            if !fingerprint_rejected {
                return Err(source_error);
            }
            let body = open_track_via_browser(soda, url, source_error)?;
            parse_open_track_body(&body)
        }
    }
}

/// `GET /luna/h5/track`(免签)。
pub fn fetch_h5_track(soda: &Soda, track_id: &str) -> Result<TrackV2Response> {
    fetch_open_track(soda, &h5_track_url(track_id))
}

/// `GET /luna/track?aid=8478`(免签)。
pub fn fetch_mobile_track(soda: &Soda, track_id: &str) -> Result<TrackV2Response> {
    fetch_open_track(soda, &mobile_track_url(track_id))
}

/// `POST pc/track_v2`(需 Cookie + 应用签名;空 body = 签名被拒)。
pub fn fetch_pc_track_v2(soda: &Soda, track_id: &str) -> Result<TrackV2Response> {
    if !soda.has_cookie() {
        return Err(SodaError::invalid_input("soda pc track_v2 requires cookie"));
    }

    let payload = serde_json::json!({
        "track_id": track_id,
        "media_type": "track",
        "queue_type": "favorite_track_playlist",
        "scene_name": "library",
    });
    let body = serde_json::to_vec(&payload)
        .map_err(|err| SodaError::json(format!("soda pc track_v2 json encode error: {err}")))?;

    let credentials = soda.app_credentials();
    let mut options = super::pc_request_options(soda);
    options.push(
        // X-SS-STUB = body 的 MD5 大写:应用签名覆盖它,必须与 body 一起算、一起发
        RequestOption::new()
            .header("Content-Type", "application/json; charset=utf-8")
            .header("X-SS-STUB", super::qr_login::md5_hex_upper(&body)),
    );
    let mut url = super::pc_track_v2_url_with(credentials.as_ref());

    // 整曲端点要求逐请求应用签名(同一对签名换 body 即判空),交给
    // SignatureProvider 现算回填
    let body_text = String::from_utf8_lossy(&body).to_string();
    if let Some(signed) = super::signature::apply_stream_signature(soda, &url, &body_text, &mut options)
    {
        url = signed;
    }

    let response = http::post_json(&url, &body, &options)?;
    if response.is_empty() {
        // 「缺少应用签名头」的服务端表现:HTTP 200 + 0 字节(不是 4xx)
        let credentials_complete = credentials
            .as_ref()
            .map(|value| value.is_complete())
            .unwrap_or(false);
        return Err(SodaError::http(if credentials_complete {
            "soda pc track_v2 returned empty body: 应用签名凭证可能已过期，请重新抓包更新 x-helios / x-medusa"
        } else {
            "soda pc track_v2 returned empty body: 缺少应用级签名头（x-helios / x-medusa），整曲取流需要 set_app_credentials()；见 docs/FULL-QUALITY-STREAM.md"
        }));
    }
    parse_track_v2_response(&response)
}

/// VOD player_info(整体最优)。
pub fn fetch_player_info(soda: &Soda, player_info_url: &str) -> Result<DownloadInfo> {
    fetch_player_info_with_preference(soda, player_info_url, "")
}

/// VOD player_info 整表:择优交给调用方(梯子要按偏好选档)。
pub fn fetch_player_info_list(soda: &Soda, player_info_url: &str) -> Result<Vec<PlayerInfo>> {
    let body = http::get(
        player_info_url,
        &[
            RequestOption::new().header("User-Agent", USER_AGENT),
            RequestOption::new().cookie(&soda.cookie()),
        ],
    )?;
    let parsed: PlayerInfoResponse = serde_json::from_slice(&body)
        .map_err(|err| SodaError::json(format!("parse play info response error: {err}")))?;
    let list = parsed.result.data.play_info_list;
    if list.is_empty() {
        let message = parsed.response_metadata.error.message;
        return match message.trim() {
            "" => Err(SodaError::not_found("no audio stream found")),
            text => Err(SodaError::not_found(text.to_string())),
        };
    }
    Ok(list)
}

/// 带偏好的 player_info 取流(空偏好 = 整体最优)。
pub fn fetch_player_info_with_preference(
    soda: &Soda,
    player_info_url: &str,
    preference: &str,
) -> Result<DownloadInfo> {
    let list = fetch_player_info_list(soda, player_info_url)?;
    let best = super::quality::best_player_info_with_preference(&list, preference)
        .ok_or_else(|| SodaError::not_found("invalid download url"))?;
    let url = pick_play_url(&best.main_play_url, &best.backup_play_url)
        .ok_or_else(|| SodaError::not_found("invalid download url"))?;
    Ok(DownloadInfo {
        url,
        play_auth: best.play_auth,
        format: best.format,
        size: best.size,
        duration: best.duration,
        bitrate: best.bitrate,
        quality: best.quality,
        ..Default::default()
    })
}

fn pick_play_url(main: &str, backup: &str) -> Option<String> {
    if !main.trim().is_empty() {
        return Some(main.trim().to_string());
    }
    if !backup.trim().is_empty() {
        return Some(backup.trim().to_string());
    }
    None
}

/// 曲目详情(元数据 + 顺手 resolve 直链)。
pub fn fetch_song_detail(soda: &Soda, track_id: &str) -> Result<Song> {
    let response = fetch_web_track_v2(soda, track_id)?;
    let track = response.primary_track();
    if track.id.is_empty() {
        return Err(SodaError::not_found("track info not found"));
    }
    let mut song = build_song_from_track(&track);
    if let Ok(info) = super::download::resolve_download_info(soda, &track.id, Some(&response)) {
        apply_download_info(&mut song, &info);
    }
    Ok(song)
}

/// Track 实体 → Song(尺寸取正式/试听码率表最大值;直链取 audio_info 最优档)。
pub fn build_song_from_track(track: &Track) -> Song {
    let mut display_size = max_bitrate_size(&track.bit_rates).max(max_bitrate_size(&track.preview.bit_rates));
    let duration = track_duration_seconds(track.duration);
    let bitrate = if duration > 0 && display_size > 0 {
        display_size * 8 / 1000 / duration
    } else {
        0
    };

    let album_id = track.album.id.trim().to_string();
    let artist_id = track
        .artists
        .first()
        .map(|a| a.id.trim())
        .unwrap_or_default()
        .to_string();

    let mut song = Song {
        source: crate::model::SOURCE_SODA.to_string(),
        id: track.id.clone(),
        name: track.name.clone(),
        artist: join_track_artists(&track.artists),
        album: track.album.name.clone(),
        album_id: album_id.clone(),
        duration,
        size: display_size,
        bitrate,
        cover: build_image_url(&track.album.url_cover, "~c5_375x375.jpg"),
        link: track_link(&track.id),
        extra: track_extra(
            &track.id,
            &track.label_info,
            &[
                ("album_id", album_id.as_str()),
                ("artist_id", artist_id.as_str()),
            ],
        ),
        is_vip: track.label_info.is_vip(),
        ..Default::default()
    };

    // audio_info 自带播放信息时,取最优档直接内嵌成 `<url>#auth=` 形态
    if let Some(best) = super::quality::best_track_play_info(&track.audio_info.play_info_list) {
        if let Some(mut url) = pick_play_url(&best.main_play_url, &best.backup_play_url) {
            if !best.play_auth.trim().is_empty() {
                url.push_str(&format!(
                    "#auth={}",
                    crate::util::query_escape(&best.play_auth)
                ));
            }
            song.url = url;
            display_size = display_size.max(best.size);
            song.size = display_size;
            if !best.format.trim().is_empty() {
                song.ext = best.format.clone();
            }
            if best.bitrate > 0 {
                song.bitrate = normalize_bitrate(best.bitrate);
            }
            if !best.quality.trim().is_empty() {
                song.extra_set("quality", best.quality.trim().to_string());
            }
        }
    }
    song
}

/// 把 resolve 结果回填到 Song(空字段不覆盖)。
pub fn apply_download_info(song: &mut Song, info: &DownloadInfo) {
    let download_url = info.full_url();
    if !download_url.is_empty() {
        song.url = download_url;
    }
    if info.size > 0 {
        song.size = info.size;
    }
    if !info.format.trim().is_empty() {
        song.ext = info.format.clone();
    }
    if info.bitrate > 0 {
        song.bitrate = normalize_bitrate(info.bitrate);
    } else if song.duration > 0 && info.size > 0 {
        song.bitrate = info.size * 8 / 1000 / song.duration;
    }
    if info.duration > 0.0 && song.duration == 0 {
        song.duration = (info.duration + 0.5) as i64;
    }
    if !info.quality.trim().is_empty() {
        song.extra_set("quality", info.quality.trim().to_string());
        song.extra_set("download_quality", info.quality.trim().to_string());
    }
}

// ---------------------------------------------------------------------------
// video_model(嵌套视频流 JSON)解析
// ---------------------------------------------------------------------------

/// video_model 里拍平出的一条流描述。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct VideoModelEntry {
    pub main_play_url: String,
    pub backup_play_url: String,
    pub play_auth: String,
    pub size: i64,
    pub format: String,
    pub bitrate: i64,
    pub quality: String,
    pub duration: f64,
}

/// video_model 择优(整体最优)。
pub fn best_from_video_model(raw: &Value) -> Option<DownloadInfo> {
    best_from_video_model_with_preference(raw, "")
}

/// 带偏好的 video_model 择优:全景声/录音室精确档族匹配,其余按偏好截断,
/// 空档回退整体最优。
pub fn best_from_video_model_with_preference(
    raw: &Value,
    preference: &str,
) -> Option<DownloadInfo> {
    // 服务端会把 JSON 再编码成字符串(实测嵌套最多 3 层),逐层剥开
    let mut value = raw.clone();
    for _ in 0..3 {
        match &value {
            Value::String(text) => match serde_json::from_str::<Value>(text) {
                Ok(parsed) => value = parsed,
                Err(_) => break,
            },
            _ => break,
        }
    }
    if value.is_null() {
        return None;
    }

    let mut entries: Vec<VideoModelEntry> = Vec::new();
    collect_video_model_entries(&value, "", "", 0.0, &mut entries);
    let usable: Vec<VideoModelEntry> = entries
        .into_iter()
        .filter(|entry| {
            !(entry.main_play_url.trim().is_empty() && entry.backup_play_url.trim().is_empty())
        })
        .collect();
    let allowed: Vec<usize> =
        super::quality::exact_tier_indices(&usable, preference, |entry| entry.quality.clone())
            .unwrap_or_else(|| {
                super::quality::filter_by_preference(&usable, preference, |entry| {
                    super::quality::quality_rank(&entry.quality, &entry.format, entry.bitrate)
                })
            });
    let best = allowed
        .into_iter()
        .filter_map(|index| usable.get(index).cloned())
        .fold(None::<VideoModelEntry>, |winner, entry| match winner {
            None => Some(entry),
            Some(current) => {
                let better = better_stream_candidate(
                    entry.duration,
                    &entry.quality,
                    &entry.format,
                    entry.bitrate,
                    entry.size,
                    current.duration,
                    &current.quality,
                    &current.format,
                    current.bitrate,
                    current.size,
                );
                if better {
                    Some(entry)
                } else {
                    Some(current)
                }
            }
        })?;

    let url = pick_play_url(&best.main_play_url, &best.backup_play_url)?;
    Some(DownloadInfo {
        url,
        play_auth: best.play_auth.trim().to_string(),
        format: best.format.trim().to_string(),
        size: best.size,
        duration: best.duration,
        bitrate: best.bitrate,
        quality: best.quality.trim().to_string(),
        ..Default::default()
    })
}

/// 深度优先遍历 video_model,沿途继承 play_auth / duration / 键名档位提示。
pub fn collect_video_model_entries(
    value: &Value,
    key_hint: &str,
    inherited_auth: &str,
    inherited_duration: f64,
    entries: &mut Vec<VideoModelEntry>,
) {
    match value {
        Value::Object(map) => {
            let auth = match video_model_play_auth(map) {
                own if !own.is_empty() => own,
                _ => inherited_auth.trim().to_string(),
            };
            let duration = match json_float(map, &["video_duration", "duration", "Duration"]) {
                own if own > 0.0 => super::quality::normalize_duration(own),
                _ => inherited_duration,
            };
            if let Some(entry) = video_model_entry_from_map(map, key_hint, &auth, duration) {
                entries.push(entry);
            }
            for (key, child) in map {
                collect_video_model_entries(child, key, &auth, duration, entries);
            }
        }
        Value::Array(items) => {
            for child in items {
                collect_video_model_entries(
                    child,
                    key_hint,
                    inherited_auth,
                    inherited_duration,
                    entries,
                );
            }
        }
        _ => {}
    }
}

fn video_model_entry_from_map(
    values: &Map<String, Value>,
    key_hint: &str,
    inherited_auth: &str,
    inherited_duration: f64,
) -> Option<VideoModelEntry> {
    let mut entry = VideoModelEntry {
        main_play_url: json_string(
            values,
            &[
                "main_play_url",
                "MainPlayUrl",
                "main_url",
                "MainUrl",
                "url",
                "URL",
                "play_url",
                "PlayURL",
            ],
        ),
        backup_play_url: json_string(
            values,
            &[
                "backup_play_url",
                "BackupPlayUrl",
                "backup_url",
                "BackupUrl",
                "backup_url_1",
                "backup_url_2",
                "backup_url_3",
            ],
        ),
        play_auth: json_string(values, &["play_auth", "PlayAuth"]),
        size: json_int(
            values,
            &[
                "size",
                "Size",
                "file_size",
                "FileSize",
                "data_size",
                "DataSize",
            ],
        ),
        format: json_string(
            values,
            &[
                "format",
                "Format",
                "vtype",
                "VType",
                "file_format",
                "FileFormat",
            ],
        ),
        bitrate: json_int(values, &["bitrate", "Bitrate", "br", "BR", "bit_rate", "BitRate"]),
        quality: json_string(
            values,
            &[
                "quality",
                "Quality",
                "definition",
                "Definition",
                "quality_type",
                "QualityType",
            ],
        ),
        duration: json_float(values, &["duration", "Duration"]),
    };

    // video_meta 子对象:本级字段缺失时逐项补
    if let Some(meta) = json_object(values, &["video_meta"]) {
        if entry.size == 0 {
            entry.size = json_int(meta, &["size", "Size", "file_size", "FileSize"]);
        }
        if entry.format.is_empty() {
            entry.format = json_string(
                meta,
                &["format", "Format", "vtype", "VType", "codec_type", "CodecType"],
            );
        }
        if entry.bitrate == 0 {
            entry.bitrate = json_int(
                meta,
                &[
                    "bitrate",
                    "Bitrate",
                    "real_bitrate",
                    "RealBitrate",
                    "bit_rate",
                    "BitRate",
                ],
            );
        }
        if entry.quality.is_empty() {
            entry.quality = json_string(
                meta,
                &[
                    "quality",
                    "Quality",
                    "definition",
                    "Definition",
                    "quality_type",
                    "QualityType",
                ],
            );
        }
        if entry.duration == 0.0 {
            entry.duration = json_float(meta, &["duration", "Duration"]);
        }
    }

    // 逐级回退:备份地址列表 → 本级 encrypt_info → 继承的 auth;
    // 档位标签:gear_des_key → 键名提示
    if entry.backup_play_url.is_empty() {
        entry.backup_play_url =
            json_first_string(values, &["backup_urls", "backupUrls", "url_list", "UrlList"]);
    }
    if entry.play_auth.is_empty() {
        entry.play_auth = video_model_play_auth(values);
    }
    if entry.play_auth.is_empty() {
        entry.play_auth = inherited_auth.trim().to_string();
    }
    if entry.quality.is_empty() {
        entry.quality = quality_hint(&json_string(values, &["gear_des_key", "GearDesKey"]));
    }
    if entry.quality.is_empty() {
        entry.quality = quality_hint(key_hint);
    }
    if entry.duration == 0.0 {
        entry.duration = inherited_duration;
    }

    (pick_play_url(&entry.main_play_url, &entry.backup_play_url).is_some()).then_some(entry)
}

/// encrypt_info 里的 spade 加密凭证。
fn video_model_play_auth(values: &Map<String, Value>) -> String {
    for key in ["encrypt_info", "EncryptInfo", "encryptInfo"] {
        let Some(child) = json_object(values, &[key]) else {
            continue;
        };
        let auth =
            json_string(child, &["spade_a", "SpadeA", "spadeA", "play_auth", "PlayAuth"]);
        if !auth.is_empty() {
            return auth;
        }
    }
    String::new()
}
