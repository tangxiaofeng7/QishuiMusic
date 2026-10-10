//! 收藏体系:喜欢单曲、收藏歌单/专辑/艺人,以及各类收藏列表读取。
//!
//! 四种实体的写操作是同一模式(端点 + ids 数组体),这里用路径表统一驱动。
//! ⚠️ 这些路径在官方客户端的「零信任加签」名单里(session_guard /
//! bd-ticket-guard-* 头);当前只带应用级签名(x-helios/x-medusa),若服务端
//! 开始强制校验 ticket guard,需补 bdticket 桥接(接口形状不变)。

use super::media_ref::{media_array, MediaRef};
use super::Soda;
use crate::error::{Result, SodaError};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const COLLECT_MEDIA_PATH: &str = "/luna/pc/me/collection/media";
pub const UNCOLLECT_MEDIA_PATH: &str = "/luna/pc/me/collection/media/delete";
pub const COLLECT_PLAYLIST_PATH: &str = "/luna/pc/me/collection/playlist";
pub const UNCOLLECT_PLAYLIST_PATH: &str = "/luna/pc/me/collection/playlist/delete";
pub const COLLECT_ALBUM_PATH: &str = "/luna/pc/me/collection/album";
pub const UNCOLLECT_ALBUM_PATH: &str = "/luna/pc/me/collection/album/delete";
pub const COLLECT_ARTIST_PATH: &str = "/luna/pc/me/collection/artist";
pub const UNCOLLECT_ARTIST_PATH: &str = "/luna/pc/me/collection/artist/delete";
/// 「我收藏的」混合列表(非 PC 路径:PC 形态实测只回空信封)。
pub const COLLECTED_MIXED_PATH: &str = "/luna/me/collection/mixed";
/// 我收藏的艺人。
pub const ARTIST_COLLECTION_PATH: &str = "/luna/me/collection/artist";
/// 指定用户的收藏混合列表。
pub const USER_MIXED_COLLECTION_PATH: &str = "/luna/pc/user/collection/mixed";
/// 已购/收藏的数字专辑。
pub const DIGITAL_ALBUMS_PATH: &str = "/luna/pc/me/assets/albums";
/// 我的音乐墙(PC 形态;移动端形态受会话级风控)。
pub const MUSIC_WALL_PATH: &str = "/luna/me/music_wall";

fn require_login(soda: &Soda, what: &str) -> Result<()> {
    if !soda.has_cookie() {
        return Err(SodaError::invalid_input(format!("{what} requires cookie")));
    }
    Ok(())
}

/// 分页 count 归一:非正数按 20,上限 100。
fn page_count(count: i64) -> i64 {
    if count <= 0 {
        20
    } else {
        count.min(100)
    }
}

/// 收藏单曲请求体(客户端 `scene` 固定空串)。
pub fn collect_media_body(media: &[MediaRef]) -> serde_json::Value {
    serde_json::json!({
        "scene": "",
        "media": media_array(media),
    })
}

/// 取消收藏请求体(无 `scene`)。
pub fn uncollect_media_body(media: &[MediaRef]) -> serde_json::Value {
    serde_json::json!({ "media": media_array(media) })
}

fn ensure_media(media: &[MediaRef], what: &str) -> Result<()> {
    if media.iter().all(|item| item.is_empty()) {
        return Err(SodaError::invalid_input(format!("{what} requires media")));
    }
    Ok(())
}

/// ids 清洗:trim + 去空,全空报错。
fn ensure_ids(ids: &[String], what: &str) -> Result<Vec<String>> {
    let cleaned: Vec<String> = ids
        .iter()
        .map(|id| id.trim().to_string())
        .filter(|id| !id.is_empty())
        .collect();
    if cleaned.is_empty() {
        return Err(SodaError::invalid_input(format!("{what} requires ids")));
    }
    Ok(cleaned)
}

/// 「按 id 收藏某类实体」的公共路径:校验 → `{<key>: ids}` 体 → POST。
fn collect_by_ids(
    soda: &Soda,
    what: &str,
    path: &str,
    ids: &[String],
    body_key: &str,
) -> Result<serde_json::Value> {
    require_login(soda, what)?;
    let ids = ensure_ids(ids, what)?;
    let body = serde_json::json!({ body_key: ids });
    super::pc_post_json(soda, path, &body)
}

/// 喜欢单曲(加入「我喜欢的音乐」)。
pub fn collect_media(soda: &Soda, media: &[MediaRef]) -> Result<serde_json::Value> {
    require_login(soda, "soda collect media")?;
    ensure_media(media, "soda collect media")?;
    super::pc_post_json(soda, COLLECT_MEDIA_PATH, &collect_media_body(media))
}

/// 取消喜欢。
pub fn uncollect_media(soda: &Soda, media: &[MediaRef]) -> Result<serde_json::Value> {
    require_login(soda, "soda uncollect media")?;
    ensure_media(media, "soda uncollect media")?;
    super::pc_post_json(soda, UNCOLLECT_MEDIA_PATH, &uncollect_media_body(media))
}

/// 收藏歌单。
pub fn collect_playlists(soda: &Soda, playlist_ids: &[String]) -> Result<serde_json::Value> {
    collect_by_ids(soda, "soda collect playlist", COLLECT_PLAYLIST_PATH, playlist_ids, "playlist_ids")
}

/// 取消收藏歌单。
pub fn uncollect_playlists(soda: &Soda, playlist_ids: &[String]) -> Result<serde_json::Value> {
    collect_by_ids(
        soda,
        "soda uncollect playlist",
        UNCOLLECT_PLAYLIST_PATH,
        playlist_ids,
        "playlist_ids",
    )
}

/// 收藏专辑。
pub fn collect_albums(soda: &Soda, album_ids: &[String]) -> Result<serde_json::Value> {
    collect_by_ids(soda, "soda collect album", COLLECT_ALBUM_PATH, album_ids, "album_ids")
}

/// 取消收藏专辑。
pub fn uncollect_albums(soda: &Soda, album_ids: &[String]) -> Result<serde_json::Value> {
    collect_by_ids(
        soda,
        "soda uncollect album",
        UNCOLLECT_ALBUM_PATH,
        album_ids,
        "album_ids",
    )
}

/// 收藏艺人。
pub fn collect_artists(soda: &Soda, artist_ids: &[String]) -> Result<serde_json::Value> {
    collect_by_ids(soda, "soda collect artist", COLLECT_ARTIST_PATH, artist_ids, "artist_ids")
}

/// 取消收藏艺人。
pub fn uncollect_artists(soda: &Soda, artist_ids: &[String]) -> Result<serde_json::Value> {
    collect_by_ids(
        soda,
        "soda uncollect artist",
        UNCOLLECT_ARTIST_PATH,
        artist_ids,
        "artist_ids",
    )
}

/// 我收藏的混合列表;`item_types` 可过滤(`playable`/`playlist`/`album`/`artist`)。
///
/// ⚠️ 收藏为空时服务端只回 `{"status_info":…}` 不带 `mixed_collections`,
/// 须用 [`parse_mixed_collections`] 解析以免把"没有收藏"误判为失败。
pub fn collected_mixed(
    soda: &Soda,
    cursor: &str,
    count: i64,
    item_types: &[&str],
) -> Result<serde_json::Value> {
    require_login(soda, "soda collected mixed")?;
    let mut params: Vec<(&str, String)> = vec![
        ("cursor", cursor.trim().to_string()),
        ("count", page_count(count).to_string()),
    ];
    // 数组型参数编码成重复 key:item_types=a&item_types=b
    params.extend(
        item_types
            .iter()
            .map(|item_type| ("item_types", item_type.trim().to_string())),
    );
    super::pc_get_json(soda, COLLECTED_MIXED_PATH, &params)
}

/// 混合列表条目:单曲/歌单/专辑/艺人之一,未建模类型保留原始 JSON。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct MixedCollectionItem {
    pub playable: Option<serde_json::Value>,
    pub playlist: Option<serde_json::Value>,
    pub album: Option<serde_json::Value>,
    pub artist: Option<serde_json::Value>,
    #[serde(flatten)]
    pub extra: BTreeMap<String, serde_json::Value>,
}

impl MixedCollectionItem {
    /// 实体类型名;判不出为空串。
    pub fn kind(&self) -> &'static str {
        match (self.playlist.is_some(), self.playable.is_some(), self.album.is_some(), self.artist.is_some()) {
            (true, _, _, _) => "playlist",
            (_, true, _, _) => "playable",
            (_, _, true, _) => "album",
            (_, _, _, true) => "artist",
            _ => "",
        }
    }

    /// 当前实体的原始 JSON(按 kind 的优先序)。
    fn payload(&self) -> Option<&serde_json::Value> {
        self.playlist
            .as_ref()
            .or(self.playable.as_ref())
            .or(self.album.as_ref())
            .or(self.artist.as_ref())
    }

    /// 条目 id。
    pub fn id(&self) -> String {
        self.payload()
            .and_then(|value| value.get("id"))
            .and_then(|id| id.as_str())
            .unwrap_or_default()
            .to_string()
    }

    /// 标题(`public_title` → `title` → `name`)。
    pub fn title(&self) -> String {
        let Some(payload) = self.payload() else {
            return String::new();
        };
        ["public_title", "title", "name"]
            .iter()
            .filter_map(|key| payload.get(*key).and_then(|v| v.as_str()))
            .map(str::trim)
            .find(|text| !text.is_empty())
            .map(str::to_string)
            .unwrap_or_default()
    }

    /// 封面地址(`url_cover` 对象按图床规则拼接)。
    pub fn cover_url(&self) -> String {
        let Some(image) = self
            .payload()
            .and_then(|value| value.get("url_cover"))
            .cloned()
        else {
            return String::new();
        };
        serde_json::from_value::<crate::soda::types::Image>(image)
            .map(|image| crate::soda::types::build_image_url(&image, ""))
            .unwrap_or_default()
    }
}

/// 解析混合列表回包;空列表/缺字段一律返回空 Vec。
pub fn parse_mixed_collections(value: &serde_json::Value) -> Vec<MixedCollectionItem> {
    value
        .get("mixed_collections")
        .and_then(|items| items.as_array())
        .into_iter()
        .flatten()
        .filter_map(|item| serde_json::from_value(item.clone()).ok())
        .collect()
}

/// 我收藏的内容(类型化直出)。
pub fn collected_items(
    soda: &Soda,
    cursor: &str,
    count: i64,
    item_types: &[&str],
) -> Result<Vec<MixedCollectionItem>> {
    let value = collected_mixed(soda, cursor, count, item_types)?;
    Ok(parse_mixed_collections(&value))
}

/// 我收藏的艺人。
pub fn collected_artists(soda: &Soda, cursor: &str, count: i64) -> Result<serde_json::Value> {
    require_login(soda, "soda collected artists")?;
    super::pc_get_json(
        soda,
        ARTIST_COLLECTION_PATH,
        &[
            ("cursor", cursor.trim().to_string()),
            ("count", page_count(count).to_string()),
        ],
    )
}

/// 指定用户的收藏混合列表(传自己的 user_id 即"我收藏的")。
pub fn user_mixed_collections(
    soda: &Soda,
    user_id: &str,
    cursor: &str,
    count: i64,
    item_types: &[&str],
) -> Result<serde_json::Value> {
    require_login(soda, "soda user mixed collections")?;
    if user_id.trim().is_empty() {
        return Err(SodaError::invalid_input(
            "soda user mixed collections requires user_id",
        ));
    }
    let mut params: Vec<(&str, String)> = vec![
        ("user_id", user_id.trim().to_string()),
        ("cursor", cursor.trim().to_string()),
        ("count", page_count(count).to_string()),
    ];
    params.extend(
        item_types
            .iter()
            .map(|item_type| ("item_types", item_type.trim().to_string())),
    );
    super::pc_get_json(soda, USER_MIXED_COLLECTION_PATH, &params)
}

/// 已购/收藏的数字专辑列表。
pub fn digital_albums(soda: &Soda, cursor: &str, count: i64) -> Result<serde_json::Value> {
    require_login(soda, "soda digital albums")?;
    super::pc_get_json(
        soda,
        DIGITAL_ALBUMS_PATH,
        &[
            ("cursor", cursor.trim().to_string()),
            ("count", page_count(count).to_string()),
        ],
    )
}

/// 我的音乐墙(`GET /luna/me/music_wall`,PC 形态):顶层 `tracks`(最爱曲,
/// 带服务端配色)+ `tags`(口味标签)。移动端形态对非官方会话 1000006,
/// PC 形态可过。
pub fn fetch_music_wall(soda: &Soda) -> Result<serde_json::Value> {
    require_login(soda, "soda music wall")?;
    super::pc_get_json(soda, MUSIC_WALL_PATH, &[])
}

impl Soda {
    /// 喜欢单曲。
    pub fn collect_media(&self, media: &[MediaRef]) -> Result<serde_json::Value> {
        collect_media(self, media)
    }

    /// 取消喜欢单曲。
    pub fn uncollect_media(&self, media: &[MediaRef]) -> Result<serde_json::Value> {
        uncollect_media(self, media)
    }

    /// 收藏歌单。
    pub fn collect_playlists(&self, playlist_ids: &[String]) -> Result<serde_json::Value> {
        collect_playlists(self, playlist_ids)
    }

    /// 取消收藏歌单。
    pub fn uncollect_playlists(&self, playlist_ids: &[String]) -> Result<serde_json::Value> {
        uncollect_playlists(self, playlist_ids)
    }

    /// 收藏专辑。
    pub fn collect_albums(&self, album_ids: &[String]) -> Result<serde_json::Value> {
        collect_albums(self, album_ids)
    }

    /// 取消收藏专辑。
    pub fn uncollect_albums(&self, album_ids: &[String]) -> Result<serde_json::Value> {
        uncollect_albums(self, album_ids)
    }

    /// 收藏艺人。
    pub fn collect_artists(&self, artist_ids: &[String]) -> Result<serde_json::Value> {
        collect_artists(self, artist_ids)
    }

    /// 取消收藏艺人。
    pub fn uncollect_artists(&self, artist_ids: &[String]) -> Result<serde_json::Value> {
        uncollect_artists(self, artist_ids)
    }

    /// 我收藏的内容(混合列表,原始回包)。
    pub fn collected_mixed(
        &self,
        cursor: &str,
        count: i64,
        item_types: &[&str],
    ) -> Result<serde_json::Value> {
        collected_mixed(self, cursor, count, item_types)
    }

    /// 我的音乐墙。
    pub fn fetch_music_wall(&self) -> Result<serde_json::Value> {
        fetch_music_wall(self)
    }

    /// 我收藏的内容(类型化列表)。
    pub fn collected_items(
        &self,
        cursor: &str,
        count: i64,
        item_types: &[&str],
    ) -> Result<Vec<MixedCollectionItem>> {
        collected_items(self, cursor, count, item_types)
    }

    /// 我收藏的艺人。
    pub fn collected_artists(&self, cursor: &str, count: i64) -> Result<serde_json::Value> {
        collected_artists(self, cursor, count)
    }

    /// 指定用户的收藏混合列表。
    pub fn user_mixed_collections(
        &self,
        user_id: &str,
        cursor: &str,
        count: i64,
        item_types: &[&str],
    ) -> Result<serde_json::Value> {
        user_mixed_collections(self, user_id, cursor, count, item_types)
    }

    /// 已购/收藏的数字专辑。
    pub fn digital_albums(&self, cursor: &str, count: i64) -> Result<serde_json::Value> {
        digital_albums(self, cursor, count)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn collect_body_matches_client_shape() {
        let body = collect_media_body(&[MediaRef::track("123")]);
        assert_eq!(body["scene"], "");
        assert_eq!(body["media"][0]["type"], "track");
        assert_eq!(body["media"][0]["id"], "123");
        assert!(body.get("collect_action").is_none());
    }

    #[test]
    fn uncollect_body_has_no_scene() {
        let body = uncollect_media_body(&[MediaRef::track("123")]);
        assert!(body.get("scene").is_none());
        assert_eq!(body["media"][0]["id"], "123");
    }

    #[test]
    fn ensure_ids_rejects_blank() {
        assert!(ensure_ids(&["  ".to_string()], "x").is_err());
        assert_eq!(ensure_ids(&[" a ".to_string()], "x").unwrap(), vec!["a"]);
    }
}

#[cfg(test)]
mod mixed_tests {
    use super::*;

    #[test]
    fn empty_response_yields_empty_list() {
        // 服务端在"没有收藏"时只回 status_info,不返回 mixed_collections
        let value = serde_json::json!({"status_info": {"now": 1789445945}});
        assert!(parse_mixed_collections(&value).is_empty());
    }

    #[test]
    fn playlist_item_is_parsed() {
        // 字段取自真机回包
        let value = serde_json::json!({
            "total_num": 1,
            "mixed_collections": [{
                "playlist": {
                    "id": "7306662862905147427",
                    "title": "华语",
                    "public_title": "华语热歌",
                    "url_cover": {
                        "template_prefix": "tplv-b829550vbb",
                        "uri": "ies-music/cover",
                        "urls": ["https://p3-luna.douyinpic.com/img/"]
                    }
                }
            }]
        });
        let items = parse_mixed_collections(&value);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].kind(), "playlist");
        assert_eq!(items[0].id(), "7306662862905147427");
        assert_eq!(items[0].title(), "华语热歌");
        assert!(items[0]
            .cover_url()
            .starts_with("https://p3-luna.douyinpic.com/img/"));
    }

    #[test]
    fn unknown_item_kind_keeps_raw_payload() {
        let value =
            serde_json::json!({"mixed_collections": [{"album": {"id": "999", "name": "专辑"}}]});
        let items = parse_mixed_collections(&value);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].kind(), "album");
        assert_eq!(items[0].id(), "999");
        assert_eq!(items[0].title(), "专辑");
    }
}
