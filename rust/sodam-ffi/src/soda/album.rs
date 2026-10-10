//! 专辑:搜索、PC 详情端点、分享页(公开,无需登录)解析。

use super::search::{fetch_android_search, parse_album_search};
use super::types::{
    album_link, build_image_url, join_track_artists, max_bitrate_size, track_extra, track_link,
    ShareAlbumPage, SODA_ANDROID_SEARCH_PAGE_SIZE, USER_AGENT,
};
use super::Soda;
use crate::error::{Result, SodaError};
use crate::http::{self, RequestOption};
use crate::model::{Playlist, Song, SOURCE_SODA};
use crate::soda::link::extract_album_id;
use std::collections::BTreeMap;

/// PC 专辑详情端点前缀。
pub const PC_ALBUM_PATH: &str = "/luna/pc/albums";

/// PC 专辑详情(原始回包透出)。
pub fn fetch_pc_album_detail(soda: &Soda, album_id: &str) -> Result<serde_json::Value> {
    let id = album_id.trim();
    if id.is_empty() {
        return Err(SodaError::invalid_input(
            "soda pc album detail requires album_id",
        ));
    }
    super::pc_get_json(soda, &format!("{PC_ALBUM_PATH}/{id}"), &[])
}

/// 关键词搜专辑(Android 搜索接口,首页)。
pub fn search_album(soda: &Soda, keyword: &str) -> Result<Vec<Playlist>> {
    let body = fetch_android_search(soda, "album", keyword, 1, SODA_ANDROID_SEARCH_PAGE_SIZE)?;
    let albums = parse_album_search(&body)?;
    Ok(albums
        .into_iter()
        .filter(|album| !album.id.is_empty())
        .map(|album| {
            let mut extra = BTreeMap::new();
            extra.insert("album_id".to_string(), album.id.clone());
            if album.release_date > 0 {
                extra.insert("release_date".to_string(), album.release_date.to_string());
            }
            Playlist {
                source: SOURCE_SODA.to_string(),
                id: album.id.clone(),
                name: album.name.clone(),
                cover: build_image_url(&album.url_cover, "~c5_300x300.jpg"),
                track_count: album.count_tracks,
                creator: join_track_artists(&album.artists),
                description: album.company.trim().to_string(),
                link: album_link(&album.id),
                extra,
                ..Default::default()
            }
        })
        .collect())
}

/// 专辑分享页解析:一页同时产出歌单形态元数据 + 全曲目。
///
/// 页面数据藏在脚本变量 `_ROUTER_DATA = {...}` 里;该页公开可访问,
/// 无 Cookie 也能读(带 Cookie 请求保持会话一致性)。
pub fn fetch_album_detail(soda: &Soda, id: &str) -> Result<(Playlist, Vec<Song>)> {
    let body = http::get(
        &album_link(id),
        &[
            RequestOption::new().header("User-Agent", USER_AGENT),
            RequestOption::new().cookie(&soda.cookie()),
        ],
    )?;
    let page = parse_share_album_page(&body)?;
    let info = page.loader_data.album_page.album_info.clone();
    if info.id.is_empty() {
        return Err(SodaError::not_found("album not found"));
    }

    // 简介:PC 文案行优先,空则退厂牌名
    let mut description = info.pc_lines.join(" ").trim().to_string();
    if description.is_empty() {
        description = info.company.trim().to_string();
    }

    let mut extra = BTreeMap::new();
    extra.insert("album_id".to_string(), info.id.clone());
    if info.release_date > 0 {
        extra.insert("release_date".to_string(), info.release_date.to_string());
    }

    let mut album = Playlist {
        source: SOURCE_SODA.to_string(),
        id: info.id.clone(),
        name: info.name.clone(),
        cover: build_image_url(&info.url_cover, "~c5_300x300.jpg"),
        track_count: info.count_tracks,
        creator: join_track_artists(&info.artists),
        description,
        link: album_link(&info.id),
        extra,
        ..Default::default()
    };
    // 元数据里的曲数为 0 时以页面实际曲目列表为准
    if album.track_count == 0 {
        album.track_count = page.loader_data.album_page.track_list.len() as i64;
    }

    let songs = page
        .loader_data
        .album_page
        .track_list
        .iter()
        .filter(|track| !track.id.is_empty())
        .map(|track| song_from_share_track(track, &info, &album.creator))
        .collect::<Vec<_>>();
    if songs.is_empty() {
        return Err(SodaError::not_found("album has no songs"));
    }
    Ok((album, songs))
}

/// 分享页单条 track → Song;缺省字段逐级回退到专辑级信息。
fn song_from_share_track(
    track: &super::types::Track,
    info: &super::types::ShareAlbumInfo,
    album_creator: &str,
) -> Song {
    // 体积:正式流与试听流取更大者
    let mut display_size = max_bitrate_size(&track.bit_rates);
    let preview_size = max_bitrate_size(&track.preview.bit_rates);
    if preview_size > display_size {
        display_size = preview_size;
    }
    let artist_id = track
        .artists
        .first()
        .map(|a| a.id.trim())
        .unwrap_or_default()
        .to_string();
    let artist = {
        let joined = join_track_artists(&track.artists);
        if joined.is_empty() {
            album_creator.to_string()
        } else {
            joined
        }
    };
    // 封面:曲目级优先,专辑级兜底
    let cover = {
        let own = build_image_url(&track.album.url_cover, "~c5_375x375.jpg");
        if own.is_empty() {
            build_image_url(&info.url_cover, "~c5_375x375.jpg")
        } else {
            own
        }
    };
    let album_id = if track.album.id.is_empty() {
        info.id.clone()
    } else {
        track.album.id.clone()
    };
    let album_name = {
        let name = track.album.name.trim();
        if name.is_empty() {
            info.name.clone()
        } else {
            name.to_string()
        }
    };
    let duration = track.duration / 1000;
    let bitrate = if duration > 0 && display_size > 0 {
        display_size * 8 / 1000 / duration
    } else {
        0
    };
    Song {
        source: SOURCE_SODA.to_string(),
        id: track.id.clone(),
        name: track.name.clone(),
        artist,
        album: album_name,
        album_id: album_id.clone(),
        duration,
        size: display_size,
        bitrate,
        cover,
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
    }
}

/// 解析链接/纯 id → 专辑(id 提不出直接报错)。
pub fn parse_album(soda: &Soda, link: &str) -> Result<(Playlist, Vec<Song>)> {
    let album_id = extract_album_id(link);
    if album_id.is_empty() {
        return Err(SodaError::invalid_input("invalid soda album link"));
    }
    fetch_album_detail(soda, &album_id)
}

impl Soda {
    /// PC 专辑详情(原始回包)。
    pub fn fetch_pc_album_detail(&self, album_id: &str) -> Result<serde_json::Value> {
        fetch_pc_album_detail(self, album_id)
    }

    /// 搜专辑。
    pub fn search_album(&self, keyword: &str) -> Result<Vec<Playlist>> {
        search_album(self, keyword)
    }

    /// 专辑曲目(分享页解析)。
    pub fn get_album_songs(&self, id: &str) -> Result<Vec<Song>> {
        Ok(fetch_album_detail(self, id)?.1)
    }

    /// 解析专辑链接。
    pub fn parse_album(&self, link: &str) -> Result<(Playlist, Vec<Song>)> {
        parse_album(self, link)
    }
}

/// 分享页 HTML → 结构化:定位 `_ROUTER_DATA = ` 后取出其 JSON 值。
pub fn parse_share_album_page(body: &[u8]) -> Result<ShareAlbumPage> {
    let page = String::from_utf8_lossy(body);
    let json = extract_json_block(&page, "_ROUTER_DATA = ")?;
    serde_json::from_str(&json)
        .map_err(|err| SodaError::json(format!("soda album page json error: {err}")))
}

/// 从 `marker` 之后按花括号配平截取一段 JSON 对象文本
/// (字符串字面量里的括号不计入配平)。
pub fn extract_json_block(page: &str, marker: &str) -> Result<String> {
    let start = page
        .find(marker)
        .map(|at| at + marker.len())
        .ok_or_else(|| SodaError::not_found("soda router data not found"))?;
    let bytes = page.as_bytes();
    let mut depth: i32 = 0;
    let mut in_string = false;
    let mut escaped = false;
    for index in start..bytes.len() {
        let byte = bytes[index];
        if in_string {
            // 转义字符只保护它后面那一个字节
            if escaped {
                escaped = false;
            } else {
                match byte {
                    b'\\' => escaped = true,
                    b'"' => in_string = false,
                    _ => {}
                }
            }
            continue;
        }
        match byte {
            b'"' => in_string = true,
            b'{' => depth += 1,
            b'}' => {
                depth -= 1;
                if depth == 0 {
                    return Ok(page[start..=index].to_string());
                }
            }
            _ => {}
        }
    }
    Err(SodaError::not_found("soda router data is incomplete"))
}
