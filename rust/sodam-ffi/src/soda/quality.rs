//! 音质档位评分与候选流择优。
//!
//! 服务端一条曲目会同时给出多档流(标准/较高/无损/全景声/录音室…),
//! 这里定义:单档评分、偏好档位的截断/精确匹配、候选间比较规则
//! (时长完整性 > 档位分 > 码率 > 体积 > 标签字典序)。

use super::types::{DownloadInfo, PlayerInfo, TrackPlayInfo};
use crate::util::normalize_token;

/// 码率归一:>1000 认为是 bps,折成 kbps。
pub fn normalize_bitrate(bitrate: i64) -> i64 {
    if bitrate > 1000 {
        bitrate / 1000
    } else {
        bitrate
    }
}

/// 时长归一:>1000 认为是毫秒,折成秒。
pub fn normalize_duration(duration: f64) -> f64 {
    if duration > 1000.0 {
        duration / 1000.0
    } else {
        duration
    }
}

// 档位分数刻度(越大越好;>=100 无损族,>=60 认为够好不必再探 PC 接口)
const RANK_HI_RES_LOSSLESS: i64 = 110;
const RANK_LOSSLESS: i64 = 100;
const RANK_HI_RES_LOSSY: i64 = 90;
const RANK_SPATIAL: i64 = 88;
const RANK_HQ: i64 = 80;
const RANK_HIGH: i64 = 70;
const RANK_STANDARD: i64 = 50;
const RANK_LOW: i64 = 10;

/// 单条流的档位评分:标签/容器/码率三路证据合成。
pub fn quality_rank(quality: &str, format: &str, bitrate: i64) -> i64 {
    let label = normalize_token(quality);
    let container = format.trim().to_lowercase();
    let br = normalize_bitrate(bitrate);

    let lossless_container = ["flac", "alac", "wav"].iter().any(|f| container.contains(f));
    let lossless_label = ["lossless", "flac", "sq", "svip"]
        .iter()
        .any(|token| label.contains(token));
    let hires_label = label.contains("hires") || label.contains("master");

    if hires_label && (lossless_container || br >= 900) {
        return RANK_HI_RES_LOSSLESS;
    }
    if lossless_label || lossless_container || br >= 900 {
        return RANK_LOSSLESS;
    }
    if hires_label {
        return RANK_HI_RES_LOSSY;
    }
    if ["atmos", "dolby", "spatial"].iter().any(|t| label.contains(t)) {
        return RANK_SPATIAL;
    }
    if ["highest", "excellent", "superhigh", "hq"].iter().any(|t| label.contains(t)) {
        return RANK_HQ;
    }
    if label.contains("higher") || label == "high" || label.contains("320") {
        return RANK_HIGH;
    }
    if ["standard", "medium", "normal", "128"]
        .iter()
        .any(|t| label.contains(t))
    {
        return RANK_STANDARD;
    }
    if label.contains("low") || label.contains("preview") {
        return RANK_LOW;
    }
    // 标签不可辨识时按码率归档
    match br {
        0 => 0,
        1..=127 => 20,
        128..=191 => RANK_STANDARD,
        192..=255 => 55,
        256..=319 => 65,
        320..=899 => RANK_HIGH,
        _ => RANK_LOSSLESS,
    }
}

/// 候选比较:`true` 表示 a 优于 b。完整性(时长)优先——半首无损不如整首 128k。
#[allow(clippy::too_many_arguments)]
pub fn better_stream_candidate(
    a_duration: f64,
    a_quality: &str,
    a_format: &str,
    a_bitrate: i64,
    a_size: i64,
    b_duration: f64,
    b_quality: &str,
    b_format: &str,
    b_bitrate: i64,
    b_size: i64,
) -> bool {
    // 任一方有时长数据时,时长差 >1s 即分胜负
    if a_duration > 0.0 || b_duration > 0.0 {
        if a_duration > b_duration + 1.0 {
            return true;
        }
        if b_duration > a_duration + 1.0 {
            return false;
        }
    }
    let decide = [
        quality_rank(a_quality, a_format, a_bitrate).cmp(&quality_rank(b_quality, b_format, b_bitrate)),
        normalize_bitrate(a_bitrate).cmp(&normalize_bitrate(b_bitrate)),
        a_size.cmp(&b_size),
        a_quality.trim().cmp(b_quality.trim()),
    ];
    // 逐级比较,首个分出高下的即结论(全相等时最后一级也判 false)
    decide
        .into_iter()
        .find(|ordering| ordering != &std::cmp::Ordering::Equal)
        .is_some_and(|ordering| ordering == std::cmp::Ordering::Greater)
}

/// 偏好档位 → 允许的最高档位分;`None` = 不限(best/auto/未知档)。
///
/// | 偏好 | 上限 |
/// | --- | --- |
/// | hires | 110 |
/// | lossless / flac | 100 |
/// | dolby / spatial / atmos | 88 |
/// | highest / hq / high | 80 |
/// | medium / standard / 320k | 70 |
/// | low / 128k / saver | 50 |
pub fn preference_rank(preference: &str) -> Option<i64> {
    let key = preference.trim().to_ascii_lowercase();
    match key.as_str() {
        "" | "best" | "auto" => None,
        "hires" | "hi_res" | "hi-res" => Some(RANK_HI_RES_LOSSLESS),
        "lossless" | "flac" => Some(RANK_LOSSLESS),
        "dolby" | "dolby_atmos" | "spatial" | "atmos" => Some(RANK_SPATIAL),
        "highest" | "hq" | "high" => Some(RANK_HQ),
        "medium" | "standard" | "320k" => Some(RANK_HIGH),
        "low" | "128k" | "saver" => Some(RANK_STANDARD),
        // 未知档位按不限制处理,避免用户设置直接导致拿不到流
        _ => None,
    }
}

fn is_spatial_family(preference: &str) -> bool {
    matches!(
        preference,
        "spatial" | "atmos" | "dolby" | "dolby_atmos"
    )
}

fn is_hires_family(preference: &str) -> bool {
    !is_spatial_family(preference) && matches!(preference, "hires" | "hi_res" | "hi-res")
}

/// 全景声/录音室两档做**精确档族匹配**:只留该族候选。
///
/// 官方 App 逐档独立可选,若沿用"及以下"截断,hires 会实际拿到分数更高的
/// lossless(同 lossless 重复)。族内一个候选都没有时返回 `None`,
/// 调用方回落 [`filter_by_preference`] 的截断语义;非这两族不介入。
pub fn exact_tier_indices<T, S>(candidates: &[T], preference: &str, tier_name: S) -> Option<Vec<usize>>
where
    S: Fn(&T) -> String,
{
    let key = preference.trim().to_ascii_lowercase();
    let (spatial, hires) = (is_spatial_family(&key), is_hires_family(&key));
    if !spatial && !hires {
        return None;
    }
    let picked: Vec<usize> = candidates
        .iter()
        .enumerate()
        .filter(|(_, item)| {
            let label = normalize_token(&tier_name(item));
            if spatial {
                ["atmos", "dolby", "spatial"].iter().any(|t| label.contains(t))
            } else {
                ["hires", "master"].iter().any(|t| label.contains(t))
            }
        })
        .map(|(index, _)| index)
        .collect();
    (!picked.is_empty()).then_some(picked)
}

/// 候选是否落在偏好档位内(不限偏好恒 `true`)。
pub fn within_preference(quality: &str, format: &str, bitrate: i64, preference: &str) -> bool {
    match preference_rank(preference) {
        None => true,
        Some(cap) => quality_rank(quality, format, bitrate) <= cap,
    }
}

/// 按偏好筛候选下标;筛空则回退全量(用户选"标准"但该曲只有无损时仍要给流)。
pub fn filter_by_preference<T, F>(candidates: &[T], preference: &str, score: F) -> Vec<usize>
where
    F: Fn(&T) -> i64,
{
    let Some(cap) = preference_rank(preference) else {
        return (0..candidates.len()).collect();
    };
    let picked: Vec<usize> = candidates
        .iter()
        .enumerate()
        .filter(|(_, item)| score(item) <= cap)
        .map(|(index, _)| index)
        .collect();
    if picked.is_empty() {
        (0..candidates.len()).collect()
    } else {
        picked
    }
}

/// 无损族判定(分 >=100)。
pub fn is_lossless(info: &DownloadInfo) -> bool {
    quality_rank(&info.quality, &info.format, info.bitrate) >= RANK_LOSSLESS
}

/// 试听判定:候选时长明显短于整曲(留 5s 容差)即为片段。
pub fn is_preview(info: &DownloadInfo, full_duration_seconds: i64) -> bool {
    if info.duration <= 0.0 || full_duration_seconds <= 0 {
        return false;
    }
    info.duration + 5.0 < full_duration_seconds as f64
}

fn has_play_url(main: &str, backup: &str) -> bool {
    !(main.trim().is_empty() && backup.trim().is_empty())
}

/// 择优模板:比较器由调用方给 duration 提取方式,逻辑同 [`better_stream_candidate`]。
fn pick_best<T, D>(list: &[T], duration_of: D, quality_of: fn(&T) -> &str, format_of: fn(&T) -> &str, bitrate_of: fn(&T) -> i64, size_of: fn(&T) -> i64, playable: fn(&T) -> bool) -> Option<T>
where
    T: Clone,
    D: Fn(&T) -> f64,
{
    let mut best: Option<T> = None;
    for item in list.iter().filter(|item| playable(item)) {
        let replace = match &best {
            None => true,
            Some(current) => better_stream_candidate(
                duration_of(item),
                quality_of(item),
                format_of(item),
                bitrate_of(item),
                size_of(item),
                duration_of(current),
                quality_of(current),
                format_of(current),
                bitrate_of(current),
                size_of(current),
            ),
        };
        if replace {
            best = Some(item.clone());
        }
    }
    best
}

/// `TrackPlayInfo` 列表取最优(无可用流返回 `None`)。
pub fn best_track_play_info(list: &[TrackPlayInfo]) -> Option<TrackPlayInfo> {
    pick_best(
        list,
        |info| info.duration as f64,
        |info| &info.quality,
        |info| &info.format,
        |info| info.bitrate,
        |info| info.size,
        |info| has_play_url(&info.main_play_url, &info.backup_play_url),
    )
}

/// `PlayerInfo` 列表取最优。
pub fn best_player_info(list: &[PlayerInfo]) -> Option<PlayerInfo> {
    pick_best(
        list,
        |info| info.duration,
        |info| &info.quality,
        |info| &info.format,
        |info| info.bitrate,
        |info| info.size,
        |info| has_play_url(&info.main_play_url, &info.backup_play_url),
    )
}

/// 带偏好的 `PlayerInfo` 择优:全景声/录音室先精确档族匹配,其余按偏好
/// 截断,无候选回退整体最优。
pub fn best_player_info_with_preference(
    list: &[PlayerInfo],
    preference: &str,
) -> Option<PlayerInfo> {
    let usable: Vec<&PlayerInfo> = list
        .iter()
        .filter(|info| has_play_url(&info.main_play_url, &info.backup_play_url))
        .collect();
    if usable.is_empty() {
        return None;
    }
    let allowed: Vec<usize> =
        exact_tier_indices(&usable, preference, |info| info.quality.clone()).unwrap_or_else(|| {
            filter_by_preference(&usable, preference, |info| {
                quality_rank(&info.quality, &info.format, info.bitrate)
            })
        });
    let tier: Vec<PlayerInfo> = allowed
        .into_iter()
        .filter_map(|index| usable.get(index).map(|info| (*info).clone()))
        .collect();
    pick_best(
        &tier,
        |info| info.duration,
        |info| &info.quality,
        |info| &info.format,
        |info| info.bitrate,
        |info| info.size,
        |_| true,
    )
    .or_else(|| best_player_info(list))
}

/// 取流梯子的"命中偏好"判定(逐层短路用):
/// * 试听不命中;自动/空偏好永不命中(走完整梯子拿最优);
/// * 全景声/录音室要求候选在档族内;
/// * 其余档位要求分数恰好等于该档上限。
pub fn satisfies_preference(info: &DownloadInfo, full_duration: i64, preference: &str) -> bool {
    if is_preview(info, full_duration) {
        return false;
    }
    let key = normalize_token(preference);
    if key.is_empty() || key == "best" || key == "auto" {
        return false;
    }
    if is_spatial_family(&key) || is_hires_family(&key) {
        let label = normalize_token(&info.quality);
        if is_spatial_family(&key) {
            return ["atmos", "dolby", "spatial"].iter().any(|t| label.contains(t));
        }
        return label.contains("hires") || label.contains("master");
    }
    match preference_rank(&key) {
        None => true,
        Some(cap) => quality_rank(&info.quality, &info.format, info.bitrate) == cap,
    }
}

/// 曲目时长毫秒 → 秒(<=1000 认为已是秒)。
pub fn track_duration_seconds(duration: i64) -> i64 {
    if duration > 1000 {
        duration / 1000
    } else {
        duration
    }
}

/// 从 key 名猜音质标签(如 `quality_hi_res_320` → `hires`)。
pub fn quality_hint(key: &str) -> String {
    let normalized = normalize_token(key.trim());
    for token in [
        "hires", "lossless", "sq", "flac", "highest", "higher", "standard", "normal",
    ] {
        if normalized.contains(token) {
            return token.to_string();
        }
    }
    String::new()
}

#[cfg(test)]
mod preference_tests {
    use super::*;

    #[test]
    fn preference_rank_maps_client_gears() {
        assert_eq!(preference_rank(""), None);
        assert_eq!(preference_rank("best"), None);
        assert_eq!(preference_rank("lossless"), Some(100));
        assert_eq!(preference_rank("spatial"), Some(88));
        assert_eq!(preference_rank("hires"), Some(110));
        assert_eq!(preference_rank("highest"), Some(80));
        assert_eq!(preference_rank("medium"), Some(70));
        assert_eq!(preference_rank("low"), Some(50));
        // 未知档位不限制,避免把用户设置变成"拿不到流"
        assert_eq!(preference_rank("whatever"), None);
    }

    #[test]
    fn exact_tier_indices_picks_only_that_family() {
        let tiers = ["lossless", "hi_res", "spatial", "highest"];
        // 录音室:只留 hi_res,不能让分数更高的 lossless 挤进来
        assert_eq!(
            exact_tier_indices(&tiers, "hires", |t| t.to_string()),
            Some(vec![1])
        );
        // 全景声:只留 spatial
        assert_eq!(
            exact_tier_indices(&tiers, "spatial", |t| t.to_string()),
            Some(vec![2])
        );
        // 档族缺失 → None(调用方回落截断语义)
        let plain = ["lossless", "highest"];
        assert_eq!(
            exact_tier_indices(&plain, "spatial", |t| t.to_string()),
            None
        );
        // 非精确档位偏好 → 不介入
        assert_eq!(
            exact_tier_indices(&tiers, "lossless", |t| t.to_string()),
            None
        );
    }

    #[test]
    fn within_preference_respects_cap() {
        assert!(within_preference("lossless", "flac", 900_000, "lossless"));
        assert!(!within_preference("lossless", "flac", 900_000, "highest"));
        assert!(within_preference("320k", "mp3", 320_000, "medium"));
        assert!(within_preference("lossless", "flac", 900_000, ""));
    }

    #[test]
    fn filter_by_preference_falls_back_when_nothing_matches() {
        let scores = [110_i64, 100];
        // 只允许 <=80,没有任何候选 → 回退成全量
        assert_eq!(filter_by_preference(&scores, "highest", |s| *s), vec![0, 1]);
        // 允许 <=100 → 只留 100
        assert_eq!(filter_by_preference(&scores, "lossless", |s| *s), vec![1]);
        // 不限制 → 全量
        assert_eq!(filter_by_preference(&scores, "", |s| *s), vec![0, 1]);
    }
}
