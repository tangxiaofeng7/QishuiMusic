//! 下载与播放流解析:免签名取流梯子 + 整曲拉取落盘(必要时解密)。
//!
//! 取流梯子四层,逐层按音质偏好拿「偏好内最优」,命中偏好且非试听即短路:
//!
//! | 层 | 端点 | 签名 | 备注 |
//! | --- | --- | --- | --- |
//! | web | `GET pc/track_v2?device_platform=web`(+VOD) | 无 | 基线 |
//! | h5 | `GET /luna/h5/track`(+VOD) | 无 | 指纹级风控,设备会话可过;失败冷却 |
//! | mobile | `GET /luna/track?aid=8478`(+VOD) | 无 | 同上 |
//! | pc | `POST pc/track_v2` | 应用签名 | 签名器配置时才参与 |
//!
//! 自动/空偏好永不短路(走完整梯子拿最优);VIP 试听守卫见下。

use super::quality::{
    is_lossless, is_preview, quality_rank, satisfies_preference, track_duration_seconds,
};
use super::track::{
    best_from_video_model_with_preference, fetch_h5_track, fetch_mobile_track, fetch_pc_track_v2,
    fetch_player_info_with_preference, fetch_web_track_v2,
};
use super::types::DownloadInfo;
use super::Soda;
use crate::error::{Result, SodaError};
use crate::model::{Song, SOURCE_SODA};
use std::path::Path;
use std::time::Duration;

/// 曲目取流信息(resolve 失败时回落到歌曲内嵌的直链快照)。
pub fn get_download_info(soda: &Soda, song: &Song) -> Result<DownloadInfo> {
    if !song.source.is_empty() && song.source != SOURCE_SODA {
        return Err(SodaError::invalid_input("source mismatch"));
    }
    let track_id = song_track_id(song);
    let cached = cached_download_info(song);
    if !track_id.is_empty() {
        return match resolve_download_info(soda, &track_id, None) {
            Ok(info) => Ok(info),
            // 探测失败但歌曲自带直链:用快照兜底,保持旧语义
            Err(err) => cached
                .filter(|info| !info.url.is_empty())
                .ok_or(err),
        };
    }
    cached
        .filter(|info| !info.url.is_empty())
        .ok_or_else(|| SodaError::invalid_input("track id is empty"))
}

/// 从 `<url>#auth=<play_auth>` 恢复直链快照(搜索结果自带的形态)。
pub fn cached_download_info(song: &Song) -> Option<DownloadInfo> {
    let (url, auth) = song.url.split_once("#auth=")?;
    let play_auth = crate::util::query_unescape(auth).unwrap_or_else(|| auth.to_string());
    let quality = song
        .extra_get("quality")
        .map(|value| value.trim().to_string())
        .unwrap_or_default();
    Some(DownloadInfo {
        url: url.to_string(),
        play_auth,
        format: song.ext.clone(),
        size: song.size,
        duration: song.duration as f64,
        bitrate: song.bitrate,
        quality,
        ..Default::default()
    })
}

/// 曲目 id:extra.track_id 优先,回落 song.id。
pub fn song_track_id(song: &Song) -> String {
    match song.extra_get("track_id").map(str::trim) {
        Some(id) if !id.is_empty() => id.to_string(),
        _ => song.id.trim().to_string(),
    }
}

/// 从一个 track_v2 回包里提「偏好内最优」流:video_model 优先;
/// 无结果或只是试听时再经 url_player_info 走 VOD。
fn best_info_from_response(
    soda: &Soda,
    response: &super::types::TrackV2Response,
    preference: &str,
    full_duration: i64,
    last_err: &mut Option<SodaError>,
) -> Option<DownloadInfo> {
    let mut info = response
        .track_player
        .video_model
        .as_ref()
        .and_then(|model| best_from_video_model_with_preference(model, preference));
    let too_short = info
        .as_ref()
        .map(|value| is_preview(value, full_duration))
        .unwrap_or(false);
    if (info.is_none() || too_short) && !response.track_player.url_player_info.is_empty() {
        match fetch_player_info_with_preference(soda, &response.track_player.url_player_info, preference)
        {
            Ok(better) => info = Some(better),
            Err(err) => *last_err = Some(err),
        }
    }
    info
}

/// 四层取流梯子(见模块注释)。`web_response` 允许复用调用方已抓到的
/// web 回包,省一次重复探测。
pub fn resolve_download_info(
    soda: &Soda,
    track_id: &str,
    web_response: Option<&super::types::TrackV2Response>,
) -> Result<DownloadInfo> {
    let track_id = track_id.trim();
    if track_id.is_empty() {
        return Err(SodaError::invalid_input("track id is empty"));
    }

    let owned_response;
    let response = match web_response {
        Some(response) => response,
        None => {
            owned_response = fetch_web_track_v2(soda, track_id)?;
            &owned_response
        }
    };

    let track = response.primary_track();
    let mut full_duration = track_duration_seconds(track.duration);
    let mut is_vip_track = track.label_info.is_vip();
    let mut last_err: Option<SodaError> = None;
    let preference = soda.quality_preference();

    // —— web 层(免签名)——
    let web_info = best_info_from_response(soda, response, &preference, full_duration, &mut last_err);
    if let Some(info) = web_info.as_ref().filter(|info| {
        satisfies_preference(info, full_duration, &preference)
    }) {
        let mut info = annotate(info.clone(), full_duration, "");
        info.origin = "web".to_string();
        return Ok(info);
    }

    // 未短路:web 候选入池,记录档位基准(后续层算"有无增益"用)
    let mut candidates: Vec<DownloadInfo> = Vec::new();
    let web_best_rank = web_info
        .as_ref()
        .map(|info| quality_rank(&info.quality, &info.format, info.bitrate))
        .unwrap_or(0);
    if let Some(info) = web_info {
        let mut info = annotate(info, full_duration, "");
        info.origin = "web".to_string();
        candidates.push(info);
    }

    // VIP 试听守卫:web 层(Cookie 已随 VOD 令牌带上)整层只回试听,说明
    // 当前账号对该曲没有整曲权益——同 Cookie 的 h5/mobile 也不会有,
    // 跳过免签层,把延迟预算留给 needsExt 外部链回落。
    let web_preview_blocked = is_vip_track
        && candidates
            .iter()
            .all(|info| is_preview(info, full_duration));

    // —— h5 / mobile 层(免签名开放端点;失败冷却防弱网反复撞墙)——
    // 两层互不依赖:auto/空偏好下梯子永不短路(见 satisfies_preference),
    // 串行时首播延迟=各层之和;并发预取后择优顺序不变(h5 → mobile),
    // 失败冷却/增益反馈语义照旧。
    let mut open_fetched: Vec<(
        &'static str,
        std::result::Result<super::types::TrackV2Response, SodaError>,
    )> = Vec::new();
    if !web_preview_blocked {
        let layers: [(
            &'static str,
            fn(&Soda, &str) -> std::result::Result<super::types::TrackV2Response, SodaError>,
        ); 2] = [("h5", fetch_h5_track), ("mobile", fetch_mobile_track)];
        std::thread::scope(|scope| {
            let mut handles = Vec::new();
            for (layer, fetch) in layers {
                if !soda.open_layer_available(layer) {
                    continue;
                }
                handles.push((layer, scope.spawn(move || fetch(soda, track_id))));
            }
            for (layer, handle) in handles {
                let outcome = handle.join().unwrap_or_else(|_| {
                    Err(SodaError::http(format!("soda {layer} 层探测线程崩溃")))
                });
                open_fetched.push((layer, outcome));
            }
        });
    }
    for (layer, outcome) in open_fetched {
        let open_response = match outcome {
            Ok(value) => value,
            Err(err) => {
                soda.open_layer_cooldown_start(layer);
                last_err = Some(err);
                continue;
            }
        };
        let open_track = open_response.primary_track();
        if full_duration == 0 {
            full_duration = track_duration_seconds(open_track.duration);
        }
        if open_track.label_info.is_vip() {
            is_vip_track = true;
        }

        match best_info_from_response(soda, &open_response, &preference, full_duration, &mut last_err) {
            Some(info) => {
                let mut info = annotate(info, full_duration, "");
                info.origin = layer.to_string();
                if satisfies_preference(&info, full_duration, &preference) {
                    if is_vip_track {
                        soda.set_cached_vip(true);
                    }
                    soda.open_layer_note_uplift(layer, true);
                    return Ok(info);
                }
                // 无增益短冷却:免费曲常驻 3 档时,无损偏好用户不必每首
                // 都白付两跳 RTT;解锁整曲或档位高于 web 才算有增益
                let rank = quality_rank(&info.quality, &info.format, info.bitrate);
                let uplift = !is_preview(&info, full_duration) && rank > web_best_rank;
                soda.open_layer_note_uplift(layer, uplift);
                candidates.push(info);
            }
            None => {
                // 端点活着但没有可用流(VIP 曲 video_list 空、VOD 只回试听且无
                // URL):不算端点故障,不冷却,只记录原因
                last_err = Some(SodaError::not_found(format!(
                    "soda {layer} track returned no stream"
                )));
            }
        }
    }

    // —— pc 层(应用签名;仅签名器配置时参与)——
    let web_is_preview = candidates
        .iter()
        .all(|info| is_preview(info, full_duration));
    let should_try_pc = soda.has_cookie()
        && soda.signature_provider().is_some()
        && (is_vip_track || web_is_preview || !candidates.iter().any(|info| is_lossless(info)));
    if should_try_pc {
        match fetch_pc_track_v2(soda, track_id) {
            Ok(pc_response) => {
                let pc_track = pc_response.primary_track();
                if full_duration == 0 {
                    full_duration = track_duration_seconds(pc_track.duration);
                }
                if pc_track.label_info.is_vip() {
                    is_vip_track = true;
                }
                // pc 层只认整曲:video_model 与 VOD 任一给出非试听即收
                let mut pc_info = pc_response
                    .track_player
                    .video_model
                    .as_ref()
                    .and_then(|model| best_from_video_model_with_preference(model, &preference))
                    .filter(|info| !is_preview(info, full_duration));
                if pc_info.is_none() && !pc_response.track_player.url_player_info.is_empty() {
                    match fetch_player_info_with_preference(
                        soda,
                        &pc_response.track_player.url_player_info,
                        &preference,
                    ) {
                        Ok(info) => {
                            if !is_preview(&info, full_duration) {
                                pc_info = Some(info);
                            } else {
                                last_err = Some(SodaError::not_found(
                                    "soda pc track_v2 returned preview stream",
                                ));
                            }
                        }
                        Err(err) => last_err = Some(err),
                    }
                } else if pc_info.is_none() && pc_response.track_player.url_player_info.is_empty()
                {
                    last_err =
                        Some(SodaError::not_found("soda pc track_v2 missing player info url"));
                }
                if let Some(info) = pc_info {
                    if is_vip_track {
                        soda.set_cached_vip(true);
                    }
                    let mut info = annotate(info, full_duration, "");
                    info.origin = "pc".to_string();
                    return Ok(info);
                }
            }
            Err(err) => last_err = Some(err),
        }
    }

    // —— 兜底:候选池按「完整 > 试听,同完整度比档位」择优 ——
    let best = candidates
        .into_iter()
        .filter(|info| !info.url.is_empty())
        .fold(None::<DownloadInfo>, |winner, info| match winner {
            None => Some(info),
            Some(current) => {
                let better = match (
                    is_preview(&info, full_duration),
                    is_preview(&current, full_duration),
                ) {
                    (a, b) if a != b => !a,
                    _ => quality_rank(&info.quality, &info.format, info.bitrate)
                        > quality_rank(&current.quality, &current.format, current.bitrate),
                };
                if better {
                    Some(info)
                } else {
                    Some(current)
                }
            }
        });

    match best {
        Some(info) => {
            let is_best_preview = is_preview(&info, full_duration);
            if is_vip_track && is_best_preview {
                if soda.has_cookie() {
                    // 登录态下仍只拿到 VIP 曲试听:会员缓存校正为否
                    soda.set_cached_vip(false);
                }
                // 完整流(需签名/VIP)拿不到时,退平台允许的预览流并注明成因
                return Ok(annotate(
                    info,
                    full_duration,
                    &preview_note(soda, &last_err),
                ));
            }
            Ok(annotate(info, full_duration, ""))
        }
        None => match last_err {
            Some(err) => Err(err),
            None => Err(SodaError::not_found("player info url not found")),
        },
    }
}

/// 打试听标记与说明,防下游把 30 秒试听当整曲缓存。
fn annotate(mut info: DownloadInfo, full_duration: i64, note: &str) -> DownloadInfo {
    info.is_preview = is_preview(&info, full_duration);
    if !note.trim().is_empty() {
        info.note = note.trim().to_string();
    } else if info.is_preview {
        info.note = "试听片段".to_string();
    }
    info
}

/// 试听成因:优先提示"凭证过期/无权益",其次"缺凭证";带回 App 端点原始错误。
fn preview_note(soda: &Soda, last_err: &Option<SodaError>) -> String {
    let credentials_complete = soda
        .app_credentials()
        .map(|credentials| credentials.is_complete())
        .unwrap_or(false);
    let base = if credentials_complete {
        "试听片段：应用签名凭证可能已过期，或账号对该曲目没有整曲权益"
    } else {
        "试听片段：整曲需要应用签名凭证（x-helios / x-medusa），见 docs/FULL-QUALITY-STREAM.md"
    };
    match last_err {
        Some(err) => format!("{base}（App 端点：{err}）"),
        None => base.to_string(),
    }
}

/// 直链(含 `#auth=`)。
pub fn get_download_url(soda: &Soda, song: &Song) -> Result<String> {
    Ok(get_download_info(soda, song)?.full_url())
}

/// 拉流 →(必要时)解密 → 写文件。
pub fn download(soda: &Soda, song: &Song, output_path: &Path) -> Result<()> {
    download_with_info(soda, song, output_path).map(|_| ())
}

/// 同 [`download`],额外返回实际拉到的流信息(档位/格式/码率/试听)。
pub fn download_with_info(soda: &Soda, song: &Song, output_path: &Path) -> Result<DownloadInfo> {
    let info = get_download_info(soda, song)?;
    download_resolved(&info, output_path)?;
    Ok(info)
}

/// 用**已 resolve** 的流信息直接拉流落盘——调用方先
/// [`resolve_download_info`] 拿 info(判试听/选档),整个取流只探测一次。
pub fn download_resolved(info: &DownloadInfo, output_path: &Path) -> Result<()> {
    let url = info.url.trim();
    if url.is_empty() {
        return Err(SodaError::invalid_input("invalid download url"));
    }
    let body = crate::http::get(
        url,
        &[crate::http::RequestOption::new()
            .header("User-Agent", super::types::USER_AGENT)
            // 整曲下载(无损几十 MB)不受信令 12s 默认超时约束
            .timeout(Duration::from_secs(60))],
    )?;
    // 免费曲的 SEO VOD 流是明文 m4a(无 play_auth);加密流必须解密
    let data = if info.play_auth.trim().is_empty() {
        body
    } else {
        super::crypto::decrypt_audio(&body, &info.play_auth)
            .map_err(|err| SodaError::crypto(format!("decrypt failed: {err}")))?
    };
    if let Some(parent) = output_path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent)?;
        }
    }
    std::fs::write(output_path, data)?;
    Ok(())
}

impl Soda {
    /// 曲目取流信息。
    pub fn get_download_info(&self, song: &Song) -> Result<DownloadInfo> {
        get_download_info(self, song)
    }

    /// 直链(含 `#auth=`)。
    pub fn get_download_url(&self, song: &Song) -> Result<String> {
        get_download_url(self, song)
    }

    /// 下载整曲到文件。
    pub fn download(&self, song: &Song, output_path: &Path) -> Result<()> {
        download(self, song, output_path)
    }

    /// 下载并返回实际流信息。
    pub fn download_with_info(&self, song: &Song, output_path: &Path) -> Result<DownloadInfo> {
        download_with_info(self, song, output_path)
    }
}
