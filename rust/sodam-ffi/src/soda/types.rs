//! 汽水接口的数据结构与公共构造子。
//!
//! 结构体字段名即服务端回包的 JSON 键(serde 契约,FFI 层与测试都依赖),
//! 改字段名等于改协议——除非抓包确认服务端改了,否则不要动。
//!
//! 分区:常量 → 艺人/专辑/曲目族 → 歌单族 → track_v2/SEO 回包族 →
//! player_info 族(PascalCase)→ 账号/用户歌单族 → 公共构造子。

use crate::util::{extra_from_pairs, join_artists};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

// ---------------------------------------------------------------------------
// 常量(UA / 端点 / 探针曲目)
// ---------------------------------------------------------------------------

/// PC 网页 UA。
pub const USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36";
/// PC 客户端 UA(`pc/me`、`pc/track_v2` 等)。
pub const PC_APP_USER_AGENT: &str = "LunaPC/3.3.0(359450208)";
/// VIP 探针曲目 id(账号会员态兜底探测用)。
pub const VIP_PROBE_TRACK_ID: &str = "7304719759323564095";
/// VIP 探针曲目短链。
pub const VIP_PROBE_TRACK_URL: &str = "https://qishui.douyin.com/s/iQeFw9cE/";
/// H5 SEO 单曲端点(免签名)。
pub const SODA_SEO_BASE: &str = "https://beta-luna.douyin.com/luna/h5/seo_track";
/// Android 搜索网关。
pub const SODA_ANDROID_API_BASE: &str = "https://api.qishui.com/luna";
/// Android 搜索 UA。
pub const SODA_ANDROID_SEARCH_USER_AGENT: &str = "com.luna.music/100198030 (Linux; U; Android 15; zh_CN_#Hans; ABR-AL80; Build/V417IR;tt-ok/3.12.13.19)";
/// Android 搜索每页条数。
pub const SODA_ANDROID_SEARCH_PAGE_SIZE: i64 = 20;
/// 抖音图床前缀。
pub const SODA_DOUYIN_IMAGE_BASE_URL: &str = "https://p3-luna.douyinpic.com/img/";

// ---------------------------------------------------------------------------
// 艺人 / 专辑 / 曲目族
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ArtistStats {
    pub count_collected: i64,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Artist {
    pub id: String,
    pub name: String,
    pub count_tracks: i64,
    pub stats: ArtistStats,
    pub url_avatar: Image,
}

/// 图床描述对象:CDN 前缀列表(`urls`)或 `uri`+`template_prefix` 模板形态。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Image {
    pub urls: Vec<String>,
    pub uri: String,
    pub template_prefix: String,
}

/// 单档码率描述(`br` 为 kbps)。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct BitRate {
    #[serde(rename = "br")]
    pub br: i64,
    pub quality: String,
    pub size: i64,
}

/// 曲目单档播放流(track_v2 形态,蛇形命名)。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct TrackPlayInfo {
    pub main_play_url: String,
    pub backup_play_url: String,
    pub play_auth: String,
    pub size: i64,
    pub format: String,
    pub bitrate: i64,
    pub quality: String,
    pub duration: i64,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct TrackAudioInfo {
    pub play_info_list: Vec<TrackPlayInfo>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Album {
    pub id: String,
    pub name: String,
    pub url_cover: Image,
    /// 搜索结果携带的主艺人列表。
    pub artists: Vec<Artist>,
    /// 发行厂牌。
    pub company: String,
    pub count_tracks: i64,
    /// 发行时间(毫秒时间戳)。
    pub release_date: i64,
    /// 分享页简介行。
    #[serde(rename = "pclines")]
    pub pc_lines: Vec<String>,
}

/// 试听片段描述(vid 为 preview 媒体 id)。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Preview {
    #[serde(rename = "vid")]
    pub vid: String,
    pub start: i64,
    pub duration: i64,
    pub bit_rates: Vec<BitRate>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct QualityBenefit {
    pub condition: String,
    pub need_vip: bool,
    pub need_purchase: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct QualityPolicy {
    pub play_detail: Option<QualityBenefit>,
    pub download_detail: Option<QualityBenefit>,
}

/// 版权/权益标签:决定曲目是否需要 VIP 及哪些档位受限。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct LabelInfo {
    pub only_vip_download: bool,
    pub only_vip_playable: bool,
    pub quality_only_vip_can_download: Vec<String>,
    pub quality_only_vip_can_play: Vec<String>,
    pub quality_map: BTreeMap<String, QualityPolicy>,
}

impl LabelInfo {
    /// 任一维度要求 VIP 即为 VIP 曲目。
    pub fn is_vip(&self) -> bool {
        let flagged_whole_track = self.only_vip_download
            || self.only_vip_playable
            || !self.quality_only_vip_can_download.is_empty()
            || !self.quality_only_vip_can_play.is_empty();
        if flagged_whole_track {
            return true;
        }
        // 逐档策略里只要有一档要求 VIP 也算
        self.quality_map.values().any(|policy| {
            [policy.play_detail.as_ref(), policy.download_detail.as_ref()]
                .into_iter()
                .flatten()
                .any(|benefit| benefit.need_vip)
        })
    }
}

/// 曲目实体(搜索/详情/歌单条目通用)。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Track {
    pub id: String,
    pub name: String,
    pub duration: i64,
    #[serde(rename = "vid")]
    pub vid: String,
    pub artists: Vec<Artist>,
    pub album: Album,
    pub bit_rates: Vec<BitRate>,
    pub preview: Preview,
    pub label_info: LabelInfo,
    pub audio_info: TrackAudioInfo,
}

// ---------------------------------------------------------------------------
// 歌单族
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ApiStatusInfo {
    pub status_msg: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct UserPlaylistOwner {
    pub id: String,
    pub nickname: String,
    pub public_name: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ResourceCount {
    pub track_cnt: i64,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct PlaylistStats {
    pub count_played: i64,
    pub count_collected: i64,
}

/// 歌单条目(搜索结果/歌单详情/我的歌单三处共用同一形态)。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct UserPlaylistItem {
    pub id: String,
    pub title: String,
    pub public_title: String,
    pub desc: String,
    pub url_cover: Image,
    pub count_tracks: i64,
    pub play_count: i64,
    pub owner: UserPlaylistOwner,
    pub review_status: String,
    /// 隐私歌单标记(客户端「设为隐私/公开」读写的就是它)。
    pub is_private: bool,
    #[serde(rename = "type")]
    pub playlist_type: i64,
    pub resource_cnt: ResourceCount,
    pub stats: PlaylistStats,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct TrackWrapper {
    pub track: Track,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct MediaResourceEntity {
    pub track_wrapper: TrackWrapper,
}

/// 歌单/电台等内容流里的单条媒体(`type=track` 之外还可能是视频等)。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct MediaResource {
    #[serde(rename = "type")]
    pub resource_type: String,
    pub entity: MediaResourceEntity,
}

/// PC 歌单详情单页回包。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct PlaylistDetailResponse {
    pub status_code: i64,
    pub status_info: ApiStatusInfo,
    pub next_cursor: String,
    pub has_more: bool,
    pub playlist: UserPlaylistItem,
    pub media_resources: Vec<MediaResource>,
}

/// 用户歌单列表单页回包。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct UserPlaylistResponse {
    pub status_code: i64,
    pub status_info: ApiStatusInfo,
    pub next_cursor: String,
    pub has_more: bool,
    pub playlists: Vec<UserPlaylistItem>,
}

// ---------------------------------------------------------------------------
// track_v2 / SEO 回包族
// ---------------------------------------------------------------------------

/// 歌词体:主 LRC + 多语言翻译。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct LyricBody {
    pub content: String,
    /// 翻译:语言码("cn"…)→ LRC 全文。SEO 链路实证存在;中文歌空对象
    /// 属正常,无翻译时序列化省略。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub translations: Option<BTreeMap<String, String>>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct TrackPlayer {
    pub media_id: String,
    pub url_player_info: String,
    /// 视频流模型,原始 JSON 透传给取流解析层。
    pub video_model: Option<serde_json::Value>,
}

/// track_v2 形态回包(PC/web 同骨架)。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct TrackV2Response {
    pub status_code: i64,
    pub status_info: ApiStatusInfo,
    pub track: Track,
    pub track_info: Track,
    pub track_player: TrackPlayer,
    pub lyric: LyricBody,
    /// SEO 链路顶层热门评论(`{comments:[...], count}`);PC 回包恒 `None`。
    #[serde(skip_serializing_if = "Option::is_none")]
    pub comments: Option<serde_json::Value>,
}

impl TrackV2Response {
    /// 主曲目:`track` 优先,缺 id 退 `track_info`。
    pub fn primary_track(&self) -> Track {
        match self.track.id.is_empty() {
            false => self.track.clone(),
            true => self.track_info.clone(),
        }
    }
}

// ---------------------------------------------------------------------------
// 分享页(专辑)与 SEO 单曲
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ShareAlbumInfo {
    pub id: String,
    pub name: String,
    pub artists: Vec<Artist>,
    pub company: String,
    pub count_tracks: i64,
    pub url_cover: Image,
    pub release_date: i64,
    #[serde(rename = "pclines")]
    pub pc_lines: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct SeoAlbumPage {
    #[serde(rename = "albumInfo")]
    pub album_info: ShareAlbumInfo,
    #[serde(rename = "trackList")]
    pub track_list: Vec<Track>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct SeoLoaderData {
    pub album_page: SeoAlbumPage,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct ShareAlbumPage {
    #[serde(rename = "loaderData")]
    pub loader_data: SeoLoaderData,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct SeoTrack {
    pub track: Track,
    pub lyric: LyricBody,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct SeoTrackResponse {
    pub status_code: i64,
    pub status_info: ApiStatusInfo,
    pub track_player: TrackPlayer,
    pub seo_track: SeoTrack,
    pub lyric: LyricBody,
    /// 分享页内嵌热门评论(同 TrackV2Response::comments)。
    #[serde(default)]
    pub comments: Option<serde_json::Value>,
}

// ---------------------------------------------------------------------------
// player_info 族(VOD GetPlayInfo,PascalCase 契约)
// ---------------------------------------------------------------------------

/// 解析后的下载/播放流快照。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct DownloadInfo {
    pub url: String,
    pub play_auth: String,
    pub format: String,
    pub size: i64,
    pub duration: f64,
    pub bitrate: i64,
    pub quality: String,
    /// 是否试听片段:未带应用签名(x-helios/x-medusa)的请求,服务端对
    /// "仅会员可播"曲目只下发 30~60 秒流;播放器靠此标记避免把试听当整曲。
    #[serde(default)]
    pub is_preview: bool,
    /// 人工可读补充说明(如"试听片段:需要应用签名凭证")。
    #[serde(default)]
    pub note: String,
    /// 取流梯子命中层:`web` / `h5` / `mobile` / `pc`。
    #[serde(default)]
    pub origin: String,
}

impl DownloadInfo {
    /// 可播/可下地址:play_auth 非空时附 `#auth=` 片段。
    pub fn full_url(&self) -> String {
        if self.play_auth.trim().is_empty() {
            return self.url.clone();
        }
        format!(
            "{}#auth={}",
            self.url,
            crate::util::query_escape(&self.play_auth)
        )
    }
}

/// player_info 的单档流(注意字段 PascalCase)。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct PlayerInfo {
    #[serde(rename = "MainPlayUrl")]
    pub main_play_url: String,
    #[serde(rename = "BackupPlayUrl")]
    pub backup_play_url: String,
    #[serde(rename = "PlayAuth")]
    pub play_auth: String,
    #[serde(rename = "Size")]
    pub size: i64,
    #[serde(rename = "Bitrate")]
    pub bitrate: i64,
    #[serde(rename = "Format")]
    pub format: String,
    #[serde(rename = "Duration")]
    pub duration: f64,
    #[serde(rename = "Quality")]
    pub quality: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct PlayerInfoResponse {
    #[serde(rename = "ResponseMetadata")]
    pub response_metadata: PlayerInfoMetadata,
    #[serde(rename = "Result")]
    pub result: PlayerInfoResult,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct PlayerInfoMetadata {
    #[serde(rename = "Error")]
    pub error: PlayerInfoError,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct PlayerInfoError {
    #[serde(rename = "Message")]
    pub message: String,
    #[serde(rename = "Code")]
    pub code: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct PlayerInfoResult {
    #[serde(rename = "Data")]
    pub data: PlayerInfoData,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct PlayerInfoData {
    #[serde(rename = "PlayInfoList")]
    pub play_info_list: Vec<PlayerInfo>,
}

// ---------------------------------------------------------------------------
// 账号
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct PCMeResponse {
    pub status_code: i64,
    pub status_info: ApiStatusInfo,
    pub my_info: PCMeInfo,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct PCMeInfo {
    pub id: String,
    pub nickname: String,
    pub public_name: String,
    pub larger_avatar_url: Image,
    /// 账号自身会员标记(比探测曲目完整流可靠)。
    #[serde(default)]
    pub is_vip: bool,
    /// 会员档位:`vip` / `svip` / `free`。
    #[serde(default)]
    pub vip_stage: String,
}

// ---------------------------------------------------------------------------
// 公共构造子
// ---------------------------------------------------------------------------

/// 曲目 extra 表:track_id + 权益标记 + 调用方追加键(空值忽略)。
pub fn track_extra(
    track_id: &str,
    label: &LabelInfo,
    values: &[(&str, &str)],
) -> BTreeMap<String, String> {
    let mut extra = extra_from_pairs([
        ("track_id", track_id),
        ("is_vip", if label.is_vip() { "true" } else { "false" }),
    ]);
    if label.only_vip_download {
        extra.insert("only_vip_download".into(), "true".into());
    }
    if label.only_vip_playable {
        extra.insert("only_vip_playable".into(), "true".into());
    }
    if !label.quality_only_vip_can_download.is_empty() {
        extra.insert(
            "vip_download_qualities".into(),
            label.quality_only_vip_can_download.join(","),
        );
    }
    if !label.quality_only_vip_can_play.is_empty() {
        extra.insert(
            "vip_play_qualities".into(),
            label.quality_only_vip_can_play.join(","),
        );
    }
    extra.extend(
        values
            .iter()
            .filter(|(_, value)| !value.trim().is_empty())
            .map(|(key, value)| ((*key).to_string(), (*value).to_string())),
    );
    extra
}

/// 艺人名列表 → `" / "` 连接。
pub fn join_track_artists(artists: &[Artist]) -> String {
    join_artists(artists.iter().map(|artist| artist.name.as_str()))
}

/// `https://www.qishui.com/track/<id>`。
pub fn track_link(track_id: &str) -> String {
    format!("https://www.qishui.com/track/{track_id}")
}

/// `https://www.qishui.com/playlist/<id>`。
pub fn playlist_link(playlist_id: &str) -> String {
    format!("https://www.qishui.com/playlist/{playlist_id}")
}

/// 专辑分享页地址。
pub fn album_link(album_id: &str) -> String {
    format!(
        "https://www.qishui.com/share/album?album_id={}",
        album_id.trim()
    )
}

/// 图床对象 → 完整 CDN 地址。
///
/// 两种形态:`uri`+`template_prefix` 走模板拼接(960 方图);
/// 否则 `urls[0]` 前缀 + `uri`,无 `~` 后缀时补传入的 size 模板。
pub fn build_image_url(image: &Image, suffix: &str) -> String {
    let uri = image.uri.trim();
    let template_prefix = image.template_prefix.trim();
    if !uri.is_empty() && !template_prefix.is_empty() {
        return format!(
            "{}/{uri}~{template_prefix}-resize:960:960.png",
            SODA_DOUYIN_IMAGE_BASE_URL.trim_end_matches('/')
        );
    }
    let Some(first) = image.urls.first() else {
        return String::new();
    };
    let mut cover = first.trim().to_string();
    if !uri.is_empty() && !cover.contains(uri) {
        cover.push_str(uri);
    }
    if cover.is_empty() {
        return String::new();
    }
    if !suffix.is_empty() && !cover.contains('~') {
        cover.push_str(suffix);
    }
    cover
}

/// 码率表里的最大体积(字节)。
pub fn max_bitrate_size(bit_rates: &[BitRate]) -> i64 {
    bit_rates.iter().map(|item| item.size).max().unwrap_or(0)
}
