//! 搜索:Android 匿名搜索端点(单曲/艺人/专辑/歌单/综合)与 PC 联想词。
//!
//! Android 搜索接口免登录,但参数必须伪装成一台真实安卓设备;请求**不带
//! Cookie**——iOS 官方 App 的会话 Cookie 配安卓假设备身份一起发会被风控
//! 判为身份不一致直接回空(真机实测)。需要登录态的 PC 端点由 pc_get/pc_post
//! 自行附 Cookie。

use super::types::{
    SODA_ANDROID_API_BASE, SODA_ANDROID_SEARCH_PAGE_SIZE, SODA_ANDROID_SEARCH_USER_AGENT,
};
use super::Soda;
use crate::error::{Result, SodaError};
use crate::http::{self, RequestOption};
use crate::util::Params;

/// Android 搜索的设备伪装参数集(与官方 App 抓包对齐)。
pub fn android_search_params() -> Params {
    let mut params = Params::from_pairs([
        ("device_platform", "android"),
        ("os", "android"),
        ("ssmix", "a"),
        ("cdid", "46556f98-1720-4248-83da-62b74b60b46a"),
        ("channel", "xiaomi_8478_64"),
        ("aid", "8478"),
        ("app_name", "luna"),
        ("version_code", "100198030"),
        ("version_name", "19.8.0"),
        ("manifest_version_code", "100198030"),
        ("update_version_code", "100198030"),
        ("resolution", "1080*1920"),
        ("dpi", "480"),
        ("device_type", "ABR-AL80"),
        ("device_brand", "HUAWEI"),
        ("language", "zh"),
        ("os_api", "35"),
        ("os_version", "15"),
        ("ac", "wifi"),
        ("device_model", "ABR-AL80"),
        ("save_power", "0"),
        ("font_size", "1.00"),
        ("luna_first_launch_apk_type", "normal_apk"),
        ("diversion_channel_name", "xiaomi_8478_64"),
        ("is_car_play", "0"),
        ("battery", "0.99"),
        ("network_speed", "10156"),
        ("hybrid_version_code", "100198030"),
        ("tz_name", "Asia/Shanghai"),
        ("tz_offset", "28800"),
        ("luna_register_time", "1784311292"),
        (
            "diversion_category_level_two",
            "Xiaomi%E5%95%86%E5%BA%97-%E8%87%AA%E7%84%B6",
        ),
        ("package", "com.luna.music"),
        ("charge", "0"),
        ("luna_apk_type", "normal_apk"),
        ("output_device_type", "Phone"),
        ("volume", "1.00"),
        ("brightness", "0.08"),
        ("need_personal_recommend", "1"),
        ("is_teen_mode", "0"),
        ("sim_region", "cn"),
        (
            "diversion_category_level_one",
            "%E5%8E%82%E5%95%86%E5%95%86%E5%BA%97-%E8%87%AA%E7%84%B6",
        ),
        ("android_device_type", "default"),
        ("iid", "2204957404569386"),
        ("device_id", "2204957404565290"),
    ]);
    // 每次请求刷新时间戳
    params.set("_rticket", crate::util::now_millis().to_string());
    params
}

/// 组搜索 URL;`search_type` ∈ track/artist/album/playlist/all。
pub fn android_search_url(search_type: &str, keyword: &str, page: i64, page_size: i64) -> String {
    let page = page.max(1);
    let page_size = if page_size <= 0 {
        SODA_ANDROID_SEARCH_PAGE_SIZE
    } else {
        page_size
    };
    let mut params = android_search_params();
    params.set("q", keyword);
    params.set("cursor", ((page - 1) * page_size).to_string());
    params.set("count", page_size.to_string());
    // 搜索端点的 aid 与设备参数表里的不同(实测如此,勿"修正")
    params.set("aid", "386088");
    format!(
        "{SODA_ANDROID_API_BASE}/search/{search_type}?{}",
        params.encode()
    )
}

/// 官方综合搜索原始回包(`/search/all`):top_results/playlists/artists/
/// tracks/albums 多个 result group,上层按需拍平。
pub fn fetch_search_all_body(
    soda: &Soda,
    keyword: &str,
    page: i64,
    page_size: i64,
) -> Result<Vec<u8>> {
    fetch_android_search(soda, "all", keyword, page, page_size)
}

/// 匿名搜索请求头(见模块注释:故意不带 Cookie)。
pub(crate) fn android_search_options(soda: &Soda) -> Vec<RequestOption> {
    let _ = soda; // 保留参数位,便于将来按会话切换身份
    vec![RequestOption::new()
        .header("User-Agent", SODA_ANDROID_SEARCH_USER_AGENT)
        .header("content-type", "application/json; charset=UTF-8")]
}

pub(crate) fn fetch_android_search(
    soda: &Soda,
    search_type: &str,
    keyword: &str,
    page: i64,
    page_size: i64,
) -> Result<Vec<u8>> {
    let url = android_search_url(search_type, keyword, page, page_size);
    http::get(&url, &android_search_options(soda))
}

// 回包骨架:result_groups[].data[].entity.<kind>
#[derive(Debug, serde::Deserialize)]
struct SearchResponse<E> {
    #[serde(default)]
    result_groups: Vec<SearchGroup<E>>,
}

#[derive(Debug, serde::Deserialize)]
struct SearchGroup<E> {
    #[serde(default)]
    data: Vec<SearchItem<E>>,
}

#[derive(Debug, serde::Deserialize)]
struct SearchItem<E> {
    entity: E,
}

/// 回包 → 实体列表的通用拍平:按 kind 取实体,丢弃空 id;单曲额外去重。
fn flatten_entities<E, T>(
    body: &[u8],
    context: &str,
    mut take: impl FnMut(E) -> Option<T>,
    id_of: impl Fn(&T) -> &str,
    dedup: bool,
) -> Result<Vec<T>>
where
    E: serde::de::DeserializeOwned + Default,
{
    let response: SearchResponse<E> = serde_json::from_slice(body)
        .map_err(|err| SodaError::json(format!("{context} json parse error: {err}")))?;
    let mut out: Vec<T> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for group in response.result_groups {
        for item in group.data {
            let Some(entity) = take(item.entity) else {
                continue;
            };
            let id = id_of(&entity).trim();
            if id.is_empty() {
                continue;
            }
            if dedup {
                if seen.iter().any(|known| known == id) {
                    continue;
                }
                seen.push(id.to_string());
            }
            out.push(entity);
        }
    }
    Ok(out)
}

pub(crate) fn parse_track_search(body: &[u8]) -> Result<Vec<super::types::Track>> {
    #[derive(Debug, Default, serde::Deserialize)]
    struct Wrap {
        #[serde(default)]
        track: super::types::Track,
    }
    flatten_entities(
        body,
        "soda search",
        |wrap: Wrap| Some(wrap.track),
        |track| &track.id,
        true,
    )
}

pub(crate) fn parse_artist_search(body: &[u8]) -> Result<Vec<super::types::Artist>> {
    #[derive(Debug, Default, serde::Deserialize)]
    struct Wrap {
        #[serde(default)]
        artist: super::types::Artist,
    }
    flatten_entities(
        body,
        "soda artist search",
        |wrap: Wrap| Some(wrap.artist),
        |artist| &artist.id,
        false,
    )
}

pub(crate) fn parse_album_search(body: &[u8]) -> Result<Vec<super::types::Album>> {
    #[derive(Debug, Default, serde::Deserialize)]
    struct Wrap {
        #[serde(default)]
        album: super::types::Album,
    }
    flatten_entities(
        body,
        "soda album search",
        |wrap: Wrap| Some(wrap.album),
        |album| &album.id,
        false,
    )
}

pub(crate) fn parse_playlist_search(body: &[u8]) -> Result<Vec<super::types::UserPlaylistItem>> {
    #[derive(Debug, Default, serde::Deserialize)]
    struct Wrap {
        #[serde(default)]
        playlist: super::types::UserPlaylistItem,
    }
    flatten_entities(
        body,
        "soda playlist",
        |wrap: Wrap| Some(wrap.playlist),
        |playlist| &playlist.id,
        false,
    )
}

/// 搜艺人(首页)。
pub fn search_artist(soda: &Soda, keyword: &str) -> Result<Vec<super::types::Artist>> {
    let body = fetch_android_search(soda, "artist", keyword, 1, SODA_ANDROID_SEARCH_PAGE_SIZE)?;
    parse_artist_search(&body)
}

impl Soda {
    /// 官方综合搜索原始回包。
    pub fn fetch_search_all_body(
        &self,
        keyword: &str,
        page: i64,
        page_size: i64,
    ) -> Result<Vec<u8>> {
        fetch_search_all_body(self, keyword, page, page_size)
    }

    /// 搜艺人。
    pub fn search_artist(&self, keyword: &str) -> Result<Vec<super::types::Artist>> {
        search_artist(self, keyword)
    }
}

// ---------------------------------------------------------------------------
// 搜索联想 / 热搜词(PC 端点)
// ---------------------------------------------------------------------------

/// 联想词端点(客户端搜索框 `sug_scene = "main"`)。
pub const SUG_PATH: &str = "/luna/pc/sug";

/// 热搜/推荐词端点前缀。
pub const SUGGEST_WORDS_PATH: &str = "/luna/suggest-words";

/// 联想词查询参数;`sug_search_id` 每次一个 v4 UUID(与客户端一致)。
pub fn sug_params(keyword: &str, sug_search_id: &str) -> Vec<(&'static str, String)> {
    let search_id = match sug_search_id.trim() {
        "" => crate::util::random_uuid_v4(),
        given => given.to_string(),
    };
    vec![
        ("q", keyword.trim().to_string()),
        ("sug_scene", "main".to_string()),
        ("sug_search_id", search_id),
    ]
}

/// 搜索联想词(原始回包,`sugs` 数组)。
pub fn suggest(soda: &Soda, keyword: &str) -> Result<serde_json::Value> {
    if keyword.trim().is_empty() {
        return Err(SodaError::invalid_input("soda suggest requires keyword"));
    }
    let params = sug_params(keyword, "");
    super::pc_get_json(soda, SUG_PATH, &params)
}

/// 热搜/推荐搜索词;`suggest_type` 空值按 `default`。
pub fn suggest_words(soda: &Soda, suggest_type: &str) -> Result<serde_json::Value> {
    let suggest_type = match suggest_type.trim() {
        "" => "default",
        given => given,
    };
    let path = format!("{SUGGEST_WORDS_PATH}/{suggest_type}");
    super::pc_get_json(soda, &path, &[])
}

impl Soda {
    /// 搜索联想词。
    pub fn suggest(&self, keyword: &str) -> Result<serde_json::Value> {
        suggest(self, keyword)
    }

    /// 热搜/推荐搜索词。
    pub fn suggest_words(&self, suggest_type: &str) -> Result<serde_json::Value> {
        suggest_words(self, suggest_type)
    }
}

#[cfg(test)]
mod sug_tests {
    use super::*;

    #[test]
    fn sug_params_carry_scene_and_uuid() {
        let params = sug_params("周杰伦", "");
        assert_eq!(params[0], ("q", "周杰伦".to_string()));
        assert_eq!(params[1], ("sug_scene", "main".to_string()));
        assert_eq!(params[2].1.len(), 36);
        assert_eq!(params[2].1.matches('-').count(), 4);
    }

    #[test]
    fn sug_params_keep_given_search_id() {
        let params = sug_params(" 林俊杰 ", "fixed-id");
        assert_eq!(params[0], ("q", "林俊杰".to_string()));
        assert_eq!(params[2], ("sug_search_id", "fixed-id".to_string()));
    }
}
