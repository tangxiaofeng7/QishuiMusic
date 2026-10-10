//! 歌单:搜索、分页详情(PC 端点)、web 形态兜底与推荐歌单。

use super::search::{fetch_android_search, parse_playlist_search};
use super::types::{
    build_image_url, playlist_link, PlaylistDetailResponse, UserPlaylistItem,
    SODA_ANDROID_SEARCH_PAGE_SIZE, USER_AGENT,
};
use super::Soda;
use crate::error::{Result, SodaError};
use crate::http::{self, RequestOption};
use crate::model::{Playlist, PlaylistCategory, Song, SOURCE_SODA};
use crate::soda::link::extract_playlist_id;
use crate::soda::track::build_song_from_track;
use crate::util::{first_non_empty, query_escape};
use std::collections::BTreeMap;

/// 关键词搜歌单(Android 搜索接口,首页)。
pub fn search_playlist(soda: &Soda, keyword: &str) -> Result<Vec<Playlist>> {
    let body = fetch_android_search(soda, "playlist", keyword, 1, SODA_ANDROID_SEARCH_PAGE_SIZE)?;
    let items = parse_playlist_search(&body)?;
    Ok(items
        .into_iter()
        .filter(|item| !item.id.is_empty())
        .map(|item| Playlist {
            source: SOURCE_SODA.to_string(),
            id: item.id.clone(),
            name: item.title.clone(),
            cover: build_image_url(&item.url_cover, "~c5_300x300.jpg"),
            track_count: item.count_tracks,
            creator: first_non_empty(&[&item.owner.public_name, &item.owner.nickname]),
            description: item.desc.clone(),
            link: playlist_link(&item.id),
            ..Default::default()
        })
        .collect())
}

/// 官方歌单实体(UserPlaylistItem)→ 通用 Playlist。
///
/// extra 只写"有值"的字段;隐私标记仅 `is_private=true` 时写入。
pub fn build_playlist_from_user_item(
    item: &UserPlaylistItem,
    current_user_id: &str,
    current_nickname: &str,
) -> Playlist {
    let playlist_id = item.id.trim().to_string();
    if playlist_id.is_empty() {
        return Playlist::default();
    }

    let name = first_non_empty(&[&item.title, &item.public_title, &playlist_id]);
    let creator = first_non_empty(&[
        &item.owner.public_name,
        &item.owner.nickname,
        current_nickname,
        current_user_id,
    ]);
    // 统计字段两套来源,主字段为 0 时用备选
    let track_count = match item.count_tracks {
        0 => item.resource_cnt.track_cnt,
        n => n,
    };
    let play_count = match item.play_count {
        0 => item.stats.count_played,
        n => n,
    };

    let mut extra = BTreeMap::new();
    extra.insert("user_id".to_string(), current_user_id.to_string());
    extra.insert("type".to_string(), item.playlist_type.to_string());
    if !item.owner.id.trim().is_empty() {
        extra.insert("owner_id".to_string(), item.owner.id.trim().to_string());
    }
    if !item.public_title.trim().is_empty() {
        extra.insert("public_title".to_string(), item.public_title.trim().to_string());
    }
    if !item.review_status.trim().is_empty() {
        extra.insert("review_status".to_string(), item.review_status.trim().to_string());
    }
    if item.stats.count_collected > 0 {
        extra.insert(
            "collect_count".to_string(),
            item.stats.count_collected.to_string(),
        );
    }
    if item.is_private {
        extra.insert("is_private".to_string(), "true".to_string());
    }

    Playlist {
        source: SOURCE_SODA.to_string(),
        id: playlist_id.clone(),
        name,
        cover: build_image_url(&item.url_cover, "~c5_300x300.jpg"),
        track_count,
        play_count,
        creator,
        description: item.desc.trim().to_string(),
        link: playlist_link(&playlist_id),
        extra,
    }
}

/// 歌单完整详情(分页拉全曲目)。
pub fn fetch_playlist_detail(soda: &Soda, id: &str) -> Result<(Playlist, Vec<Song>)> {
    fetch_playlist_detail_paged(soda, id)
}

/// 分页详情:每页 100 条,最多 20 轮;**首页失败回落 web 接口**,后续页失败
/// 直接报错(已有内容的情况下 web 兜底拼不出完整列表)。
pub fn fetch_playlist_detail_paged(soda: &Soda, id: &str) -> Result<(Playlist, Vec<Song>)> {
    let playlist_id = id.trim();
    if playlist_id.is_empty() {
        return Err(SodaError::invalid_input("playlist id is empty"));
    }

    const PAGE_SIZE: i64 = 100;
    const MAX_PAGES: usize = 20;
    let mut cursor = String::new();
    let mut visited_cursors: Vec<String> = Vec::new();
    let mut seen_tracks: Vec<String> = Vec::new();
    let mut playlist: Option<Playlist> = None;
    let mut songs: Vec<Song> = Vec::new();

    for page in 0..MAX_PAGES {
        let response = match fetch_playlist_detail_page(soda, playlist_id, &cursor, PAGE_SIZE) {
            Ok(response) => response,
            Err(_) if page == 0 => return fetch_playlist_detail_web(soda, playlist_id),
            Err(err) => return Err(err),
        };

        // 首页回包里的歌单元数据(缺失时用请求 id 补一个可用的壳)
        if playlist.is_none() {
            let mut built = build_playlist_from_user_item(&response.playlist, "", "");
            if built.id.is_empty() {
                built.id = playlist_id.to_string();
                built.source = SOURCE_SODA.to_string();
                built.link = playlist_link(playlist_id);
            }
            playlist = Some(built);
        }

        for item in &response.media_resources {
            if item.resource_type != "track" {
                continue;
            }
            let track = &item.entity.track_wrapper.track;
            if track.id.is_empty() || seen_tracks.contains(&track.id) {
                continue;
            }
            seen_tracks.push(track.id.clone());
            // 缺封面就留空(客户端显示占位图),**不要**退歌单封面——那会让
            // 一批歌共用第一首的封面(实测发生过)
            songs.push(build_song_from_track(track));
        }

        // 终止判定:游标耗尽 / 原地打转 / 服务端宣告无更多
        let next_cursor = response.next_cursor.trim().to_string();
        let cursor_exhausted = next_cursor.is_empty()
            || next_cursor == cursor
            || visited_cursors.contains(&next_cursor);
        if cursor_exhausted {
            break;
        }
        if !response.has_more && (response.media_resources.len() as i64) < PAGE_SIZE {
            break;
        }
        visited_cursors.push(next_cursor.clone());
        cursor = next_cursor;
    }

    let Some(mut playlist) = playlist else {
        return Err(SodaError::not_found("playlist not found"));
    };
    if playlist.id.is_empty() {
        return Err(SodaError::not_found("playlist not found"));
    }
    if playlist.track_count == 0 {
        playlist.track_count = songs.len() as i64;
    }
    Ok((playlist, songs))
}

/// 歌单详情单页(PC 端点,含信封校验)。
pub fn fetch_playlist_detail_page(
    soda: &Soda,
    playlist_id: &str,
    cursor: &str,
    count: i64,
) -> Result<PlaylistDetailResponse> {
    let url = super::pc_playlist_detail_url(playlist_id, cursor, count);
    let body = http::get(&url, &super::pc_request_options(soda))?;
    let response: PlaylistDetailResponse = serde_json::from_slice(&body)
        .map_err(|err| SodaError::json(format!("soda playlist detail json error: {err}")))?;
    if response.status_code != 0 {
        let msg = response.status_info.status_msg.trim();
        return Err(SodaError::api(
            response.status_code,
            if msg.is_empty() { "unknown error" } else { msg },
        ));
    }
    Ok(response)
}

// web 兜底回包的骨架(字段名与 PC 端点有差异,独立建模)
#[derive(Debug, serde::Deserialize)]
struct WebPlaylistResponse {
    #[serde(default)]
    playlist: WebPlaylist,
    #[serde(default)]
    media_resources: Vec<WebMediaResource>,
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(default)]
struct WebPlaylist {
    id: String,
    title: String,
    desc: String,
    owner: WebOwner,
    count_tracks: i64,
    url_cover: WebImage,
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(default)]
struct WebOwner {
    nickname: String,
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(default)]
struct WebImage {
    urls: Vec<String>,
    uri: String,
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(default)]
struct WebMediaResource {
    #[serde(rename = "type")]
    resource_type: String,
    entity: WebEntity,
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(default)]
struct WebEntity {
    track_wrapper: WebTrackWrapper,
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(default)]
struct WebTrackWrapper {
    track: WebTrack,
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(default)]
struct WebTrack {
    id: String,
    name: String,
    duration: i64,
    artists: Vec<WebArtist>,
    album: WebAlbum,
    bit_rates: Vec<WebBitRate>,
    audio_info: WebAudioInfo,
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(default)]
struct WebArtist {
    name: String,
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(default)]
struct WebAlbum {
    name: String,
    url_cover: WebImage,
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(default)]
struct WebBitRate {
    size: i64,
    quality: String,
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(default)]
struct WebAudioInfo {
    play_info_list: Vec<WebPlayInfo>,
}

#[derive(Debug, Default, serde::Deserialize)]
#[serde(default)]
struct WebPlayInfo {
    #[serde(rename = "main_play_url")]
    main_play_url: String,
    #[serde(rename = "play_auth")]
    play_auth: String,
    #[serde(rename = "size")]
    size: i64,
    #[serde(rename = "format")]
    format: String,
    #[serde(rename = "bitrate")]
    bitrate: i64,
    #[serde(rename = "quality")]
    quality: String,
}

/// web 形态歌单详情(`device_platform=web` 参数族):分页接口失败时的兜底。
pub fn fetch_playlist_detail_web(soda: &Soda, id: &str) -> Result<(Playlist, Vec<Song>)> {
    let mut params = crate::util::Params::new();
    params.set("playlist_id", id);
    params.set("cursor", "0");
    params.set("cnt", "20");
    params.set("aid", "386088");
    params.set("device_platform", "web");
    params.set("channel", "pc_web");
    let url = format!(
        "https://api.qishui.com/luna/pc/playlist/detail?{}",
        params.encode()
    );

    let body = http::get(
        &url,
        &[
            RequestOption::new().header("User-Agent", USER_AGENT),
            RequestOption::new().cookie(&soda.cookie()),
        ],
    )?;
    let response: WebPlaylistResponse = serde_json::from_slice(&body)
        .map_err(|err| SodaError::json(format!("soda playlist detail json error: {err}")))?;

    let mut playlist = Playlist {
        source: SOURCE_SODA.to_string(),
        id: id.to_string(),
        name: response.playlist.title.clone(),
        creator: response.playlist.owner.nickname.clone(),
        description: response.playlist.desc.clone(),
        track_count: response.playlist.count_tracks,
        link: playlist_link(id),
        ..Default::default()
    };
    if let Some(cover) = web_cover_url(&response.playlist.url_cover, "~c5_300x300.jpg") {
        playlist.cover = cover;
    }

    let songs = response
        .media_resources
        .iter()
        .filter(|item| item.resource_type == "track")
        .map(|item| &item.entity.track_wrapper.track)
        .filter(|track| !track.id.is_empty())
        .map(web_track_to_song)
        .collect();
    Ok((playlist, songs))
}

/// web 图片对象(urls[0] 前缀 + uri + 模板后缀)→ 完整地址。
fn web_cover_url(image: &WebImage, suffix: &str) -> Option<String> {
    let prefix = image.urls.first()?;
    let mut url = prefix.clone();
    if !image.uri.is_empty() && !url.contains(&image.uri) {
        url.push_str(&image.uri);
    }
    if !url.contains('~') {
        url.push_str(suffix);
    }
    Some(url)
}

/// web 形态 track → Song:尺寸取 bit_rates 与 play_info 的最大值,
/// 直链取体积最大的 play_info(附 `#auth=` 加密凭证)。
fn web_track_to_song(track: &WebTrack) -> Song {
    let mut display_size = track.bit_rates.iter().map(|br| br.size).max().unwrap_or(0);
    for play_info in &track.audio_info.play_info_list {
        display_size = display_size.max(play_info.size);
    }

    let artist = track
        .artists
        .iter()
        .map(|artist| artist.name.as_str())
        .collect::<Vec<_>>()
        .join("、");
    let cover = track
        .album
        .url_cover
        .urls
        .first()
        .filter(|prefix| !prefix.is_empty())
        .map(|prefix| {
            let uri = &track.album.url_cover.uri;
            if !uri.is_empty() && !prefix.contains(uri.as_str()) {
                format!("{prefix}{uri}~c5_375x375.jpg")
            } else {
                format!("{prefix}~c5_375x375.jpg")
            }
        })
        .unwrap_or_default();

    let seconds = track.duration / 1000;
    let bitrate = if seconds > 0 && display_size > 0 {
        display_size * 8 / 1000 / seconds
    } else {
        0
    };

    let mut song = Song {
        source: SOURCE_SODA.to_string(),
        id: track.id.clone(),
        name: track.name.clone(),
        artist,
        album: track.album.name.clone(),
        duration: seconds,
        size: display_size,
        bitrate,
        cover,
        link: crate::soda::types::track_link(&track.id),
        extra: crate::util::extra_from_pairs([("track_id", track.id.clone())]),
        ..Default::default()
    };

    // 平手取先出现的档位(与既有探测行为一致)
    let best = track.audio_info.play_info_list.iter().fold(
        None::<&WebPlayInfo>,
        |winner, info| match winner {
            Some(current) if current.size >= info.size => winner,
            _ => Some(info),
        },
    );
    if let Some(best) = best {
        if !best.main_play_url.is_empty() {
            song.url = format!(
                "{}#auth={}",
                best.main_play_url,
                query_escape(&best.play_auth)
            );
            if song.size == 0 {
                song.size = best.size;
            }
            song.ext = best.format.clone();
            song.bitrate = crate::soda::quality::normalize_bitrate(best.bitrate);
        }
        if !best.quality.trim().is_empty() {
            song.extra_set("quality", best.quality.trim().to_string());
        }
    }
    song
}

/// 歌单曲目列表。
pub fn get_playlist_songs(soda: &Soda, id: &str) -> Result<Vec<Song>> {
    Ok(fetch_playlist_detail(soda, id)?.1)
}

/// 解析链接/纯 id → 歌单详情(文本提取 → 抓分享页 → 再提取)。
pub fn parse_playlist(soda: &Soda, link: &str) -> Result<(Playlist, Vec<Song>)> {
    let playlist_id = extract_playlist_id(link);
    if !playlist_id.is_empty() {
        return fetch_playlist_detail(soda, &playlist_id);
    }
    let response = http::get_full(
        link,
        &[
            RequestOption::new().header("User-Agent", USER_AGENT),
            RequestOption::new().cookie(&soda.cookie()),
        ],
    )?;
    if let Some(id) = non_empty(extract_playlist_id(&response.final_url)) {
        return fetch_playlist_detail(soda, &id);
    }
    if let Some(id) = non_empty(extract_playlist_id(&response.body_text())) {
        return fetch_playlist_detail(soda, &id);
    }
    Err(SodaError::not_found("soda playlist id not found"))
}

/// 每日推荐歌单(官方无此能力,保留兼容占位)。
pub fn get_recommended_playlists(_soda: &Soda) -> Result<Vec<Playlist>> {
    Err(SodaError::unsupported(
        "soda daily recommendation not supported",
    ))
}

/// 「为你推荐歌单」端点。
pub const RECOMMEND_PLAYLIST_PATH: &str = "/luna/me/playlist/recommend";

/// 推荐歌单(`GET /luna/me/playlist/recommend`,无查询参数)。
pub fn get_recommend_playlists(soda: &Soda) -> Result<Vec<Playlist>> {
    let value = super::pc_get_json(soda, RECOMMEND_PLAYLIST_PATH, &[])?;
    Ok(parse_recommend_playlists(&value))
}

/// 解析推荐歌单回包;`playlists` 缺失按空列表(冷账号常态)。
pub fn parse_recommend_playlists(value: &serde_json::Value) -> Vec<Playlist> {
    value
        .get("playlists")
        .and_then(|list| list.as_array())
        .into_iter()
        .flatten()
        .filter_map(|item| serde_json::from_value::<UserPlaylistItem>(item.clone()).ok())
        .map(|parsed| build_playlist_from_user_item(&parsed, "", ""))
        .filter(|playlist| !playlist.id.is_empty())
        .collect()
}

/// 歌单分类(官方无此能力,保留兼容占位)。
pub fn get_playlist_categories(_soda: &Soda) -> Result<Vec<PlaylistCategory>> {
    Err(SodaError::unsupported("playlist categories not supported"))
}

/// 分类歌单列表(同上,不支持)。
pub fn get_category_playlists(
    _soda: &Soda,
    _category_id: &str,
    _page: i64,
    _limit: i64,
) -> Result<Vec<Playlist>> {
    Err(SodaError::unsupported("playlist categories not supported"))
}

fn non_empty(value: String) -> Option<String> {
    match value.trim() {
        "" => None,
        _ => Some(value),
    }
}

impl Soda {
    /// 推荐歌单。
    pub fn get_recommend_playlists(&self) -> Result<Vec<Playlist>> {
        get_recommend_playlists(self)
    }

    /// 搜歌单。
    pub fn search_playlist(&self, keyword: &str) -> Result<Vec<Playlist>> {
        search_playlist(self, keyword)
    }

    /// 歌单曲目列表。
    pub fn get_playlist_songs(&self, id: &str) -> Result<Vec<Song>> {
        get_playlist_songs(self, id)
    }

    /// 解析歌单链接。
    pub fn parse_playlist(&self, link: &str) -> Result<(Playlist, Vec<Song>)> {
        parse_playlist(self, link)
    }

    /// 每日推荐(不支持,见 [`get_recommended_playlists`])。
    pub fn get_recommended_playlists(&self) -> Result<Vec<Playlist>> {
        get_recommended_playlists(self)
    }

    /// 歌单分类(不支持)。
    pub fn get_playlist_categories(&self) -> Result<Vec<PlaylistCategory>> {
        get_playlist_categories(self)
    }

    /// 分类歌单(不支持)。
    pub fn get_category_playlists(
        &self,
        category_id: &str,
        page: i64,
        limit: i64,
    ) -> Result<Vec<Playlist>> {
        get_category_playlists(self, category_id, page, limit)
    }
}
