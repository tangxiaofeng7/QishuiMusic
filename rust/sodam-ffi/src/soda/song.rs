//! 搜索与分享链接解析入口。

use super::search::{fetch_android_search, parse_track_search};
use super::track::{build_song_from_track, fetch_song_detail};
use super::types::{SODA_ANDROID_SEARCH_PAGE_SIZE, USER_AGENT};
use super::Soda;
use crate::error::{Result, SodaError};
use crate::http::{self, RequestOption};
use crate::model::Song;
use crate::soda::link::extract_track_id;

/// 按关键词搜单曲(首页大小,无分页参数——引擎当前消费方只要一页)。
pub fn search(soda: &Soda, keyword: &str) -> Result<Vec<Song>> {
    let body = fetch_android_search(soda, "track", keyword, 1, SODA_ANDROID_SEARCH_PAGE_SIZE)?;
    let tracks = parse_track_search(&body)?;
    Ok(tracks.iter().map(build_song_from_track).collect())
}

/// 解析一个分享链接/纯 id 为曲目:
/// 先在文本里本地找 track id;找不到再实际抓取分享页,
/// 从重定向地址或页面正文里继续找。
pub fn parse(soda: &Soda, link: &str) -> Result<Song> {
    if let Some(track_id) = first_id(link, extract_track_id) {
        return fetch_song_detail(soda, &track_id);
    }
    let response = http::get_full(
        link,
        &[
            RequestOption::new().header("User-Agent", USER_AGENT),
            RequestOption::new().cookie(&soda.cookie()),
        ],
    )?;
    if let Some(track_id) = first_id(&response.final_url, extract_track_id) {
        return fetch_song_detail(soda, &track_id);
    }
    if let Some(track_id) = first_id(&response.body_text(), extract_track_id) {
        return fetch_song_detail(soda, &track_id);
    }
    Err(SodaError::not_found("soda track id not found"))
}

fn first_id(text: &str, extract: fn(&str) -> String) -> Option<String> {
    match extract(text).trim() {
        "" => None,
        found => Some(found.to_string()),
    }
}

impl Soda {
    /// 搜单曲(见 [`search`])。
    pub fn search(&self, keyword: &str) -> Result<Vec<Song>> {
        search(self, keyword)
    }

    /// 解析链接(见 [`parse`])。
    pub fn parse(&self, link: &str) -> Result<Song> {
        parse(self, link)
    }
}
