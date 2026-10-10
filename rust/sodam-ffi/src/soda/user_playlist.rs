//! 用户歌单:PC 侧边栏「创建的歌单」与全量用户歌单分页读取,外加账号信息。

use super::playlist::build_playlist_from_user_item;
use super::types::{PCMeResponse, UserPlaylistItem, UserPlaylistResponse};
use super::Soda;
use crate::error::{Result, SodaError};
use crate::http;
use crate::model::Playlist;

/// 「我创建的歌单」端点。
pub const MY_PLAYLISTS_PATH: &str = "/luna/pc/me/playlist";

/// 「我创建的歌单」一页。
#[derive(Debug, Clone, Default, PartialEq)]
pub struct MyPlaylistsPage {
    pub playlists: Vec<Playlist>,
    pub has_more: bool,
    pub next_cursor: String,
}

/// 拉一页「我创建的歌单」(cursor 空串 = 首页;count 非法值按 50,上限 100)。
pub fn get_my_playlists(soda: &Soda, cursor: &str, count: i64) -> Result<MyPlaylistsPage> {
    if !soda.has_cookie() {
        return Err(SodaError::invalid_input("soda my playlists require cookie"));
    }
    let count = if count <= 0 { 50 } else { count.min(100) };
    let value = super::pc_get_json(
        soda,
        MY_PLAYLISTS_PATH,
        &[
            ("cursor", cursor.trim().to_string()),
            ("count", count.to_string()),
        ],
    )?;
    Ok(parse_my_playlists(&value))
}

/// 解析「我创建的歌单」回包;`playlists` 字段缺失(空账号)按空列表处理。
pub fn parse_my_playlists(value: &serde_json::Value) -> MyPlaylistsPage {
    MyPlaylistsPage {
        playlists: parse_my_playlist_items(value),
        has_more: value
            .get("has_more")
            .and_then(|flag| flag.as_bool())
            .unwrap_or(false),
        next_cursor: value
            .get("next_cursor")
            .and_then(|cursor| cursor.as_str())
            .unwrap_or_default()
            .trim()
            .to_string(),
    }
}

fn parse_my_playlist_items(value: &serde_json::Value) -> Vec<Playlist> {
    value
        .get("playlists")
        .and_then(|list| list.as_array())
        .into_iter()
        .flatten()
        // 与 /luna/pc/playlist/detail 的 playlist 实体同构,复用同一解析
        .filter_map(|item| serde_json::from_value::<UserPlaylistItem>(item.clone()).ok())
        .map(|parsed| build_playlist_from_user_item(&parsed, "", ""))
        .filter(|playlist| !playlist.id.is_empty())
        .collect()
}

/// 全量用户歌单翻页版:页码从 1 起;跨页去重 + 环路保护(重复 cursor)。
pub fn get_user_playlists(soda: &Soda, page: i64, limit: i64) -> Result<Vec<Playlist>> {
    if !soda.has_cookie() {
        return Err(SodaError::invalid_input(
            "soda user playlists require cookie",
        ));
    }
    let page = page.max(1);
    let limit = if limit <= 0 { 30 } else { limit.min(100) };

    let me = fetch_pc_me(soda)?;
    let user_id = me.my_info.id.trim().to_string();
    if user_id.is_empty() {
        return Err(SodaError::invalid_input(
            "soda user playlists require logged-in user id",
        ));
    }

    // 目标条数 = page*limit,可能极大:单页请求条数夹在 [50,100],
    // 轮次上限 20,容量按 2048 兜底
    let target_count = page * limit;
    let request_count = target_count.clamp(50, 100);
    let mut playlists: Vec<Playlist> = Vec::with_capacity(target_count.clamp(0, 2048) as usize);
    let mut seen_ids: Vec<String> = Vec::new();
    let mut seen_cursors: Vec<String> = Vec::new();
    let mut cursor = String::new();

    let mut rounds = 0;
    while rounds < 20 && (playlists.len() as i64) < target_count {
        rounds += 1;
        let response = fetch_user_playlist_page(soda, &user_id, &cursor, request_count)?;
        for item in &response.playlists {
            let playlist = build_playlist_from_user_item(item, &user_id, &me.my_info.nickname);
            if playlist.id.is_empty() || seen_ids.contains(&playlist.id) {
                continue;
            }
            seen_ids.push(playlist.id.clone());
            playlists.push(playlist);
        }
        // 环路与自然终点判定:cursor 空/原地打转/服务端宣告无更多
        let next_cursor = response.next_cursor.trim().to_string();
        let cursor_loops = next_cursor.is_empty()
            || next_cursor == cursor
            || seen_cursors.contains(&next_cursor);
        if cursor_loops {
            break;
        }
        if !response.has_more && (response.playlists.len() as i64) < request_count {
            break;
        }
        seen_cursors.push(next_cursor.clone());
        cursor = next_cursor;
    }

    let start = ((page - 1) * limit) as usize;
    let Some(slice) = playlists.get(start..) else {
        return Ok(Vec::new());
    };
    Ok(slice[..slice.len().min(limit as usize)].to_vec())
}

/// 账号信息(`GET /luna/pc/me`)。
pub fn fetch_pc_me(soda: &Soda) -> Result<PCMeResponse> {
    let body = http::get(&super::pc_me_url(), &super::pc_request_options(soda))?;
    let response: PCMeResponse = serde_json::from_slice(&body)
        .map_err(|err| SodaError::json(format!("soda me json parse error: {err}")))?;
    ensure_status_ok(response.status_code, &response.status_info.status_msg)?;
    Ok(response)
}

/// 用户歌单一页(`GET /luna/pc/user/{id}/playlist`)。
pub fn fetch_user_playlist_page(
    soda: &Soda,
    user_id: &str,
    cursor: &str,
    count: i64,
) -> Result<UserPlaylistResponse> {
    let url = super::pc_user_playlist_url(user_id, cursor, count);
    let body = http::get(&url, &super::pc_request_options(soda))?;
    let response: UserPlaylistResponse = serde_json::from_slice(&body)
        .map_err(|err| SodaError::json(format!("soda user playlist json parse error: {err}")))?;
    ensure_status_ok(response.status_code, &response.status_info.status_msg)?;
    Ok(response)
}

/// 信封校验:status_code 非 0 即业务失败。
fn ensure_status_ok(status_code: i64, status_msg: &str) -> Result<()> {
    if status_code == 0 {
        return Ok(());
    }
    let msg = {
        let text = status_msg.trim();
        if text.is_empty() {
            "unknown error".to_string()
        } else {
            text.to_string()
        }
    };
    Err(SodaError::Api {
        status_code,
        status_msg: msg,
    })
}

impl Soda {
    /// 我创建的歌单(cursor 空串取第一页)。
    pub fn get_my_playlists(&self, cursor: &str, count: i64) -> Result<MyPlaylistsPage> {
        get_my_playlists(self, cursor, count)
    }

    /// 全量用户歌单分页(见 [`get_user_playlists`])。
    pub fn get_user_playlists(&self, page: i64, limit: i64) -> Result<Vec<Playlist>> {
        get_user_playlists(self, page, limit)
    }
}
