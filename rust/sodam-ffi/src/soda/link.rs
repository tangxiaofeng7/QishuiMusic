//! 分享链接 / 各类 id 形态解析。
//!
//! 输入可能是:纯 id、完整分享 URL、URL 编码过的 URL、含 JSON 的页面正文。
//! 解析策略按"候选文本(原文 + 一次 URL 解码)× 提取模式(查询参数 / JSON
//! 字段 / 路径标记)"穷举,命中即返回;全部落空返回空串。

use crate::util::{is_digits, query_unescape};

/// 专辑 id:`album_id=`/`id=` 参数、`album/` 路径段、或裸 id。
pub fn extract_album_id(link: &str) -> String {
    if let Some(found) = first_some(
        find_param_digits(link, "album_id"),
        find_param_digits(link, "id"),
        find_after_marker(link, "album/"),
    ) {
        return found;
    }
    bare_id(link, 10)
}

/// 歌单 id:`playlist_id`/`playlistId` 参数或 JSON 字段、`playlist/` 路径段
/// (大小写与 URL 编码形态都认)、裸 id。
pub fn extract_playlist_id(text: &str) -> String {
    let text = text.trim();
    if bare_id_ok(text) && !text.contains('/') {
        return text.to_string();
    }
    for candidate in candidates(text) {
        for key in ["playlist_id", "playlistId"] {
            if let Some(found) = find_param_digits(&candidate, key) {
                return found;
            }
            if let Some(found) = find_json_digits(&candidate, key) {
                return found;
            }
        }
        for marker in [
            "playlist/",
            "/playlist/",
            "%2fplaylist%2f",
            "%2Fplaylist%2F",
        ] {
            if let Some(found) = find_after_marker_ci(&candidate, marker) {
                return found;
            }
        }
    }
    String::new()
}

/// 曲目 id:同歌单形态,但 id 至少 10 位数字(track/`song/` 标记都认)。
pub fn extract_track_id(text: &str) -> String {
    let text = text.trim();
    if text.len() > 10 && is_digits(text) && !text.contains('/') {
        return text.to_string();
    }
    for candidate in candidates(text) {
        if let Some(found) = find_param_digits_min(&candidate, "track_id", 10) {
            return found;
        }
        if let Some(found) = find_json_digits_min(&candidate, "track_id", 10) {
            return found;
        }
        // 带斜杠的完整标记优先(更精确),再试不带斜杠的宽松形态
        for marker in [
            "/track/",
            "/song/",
            "%2Ftrack%2F",
            "%2Fsong%2F",
            "%2ftrack%2f",
            "%2fsong%2f",
        ] {
            if let Some(found) = find_after_marker_min(&candidate, marker, 10) {
                return found;
            }
        }
        for marker in ["track/", "song/"] {
            if let Some(found) = find_after_marker_min(&candidate, marker, 10) {
                return found;
            }
        }
    }
    String::new()
}

// ---------------------------------------------------------------------------
// 内部扫描原语
// ---------------------------------------------------------------------------

/// 候选文本:原文 + 一次 URL 解码(解码结果与原文相同时去重)。
fn candidates(text: &str) -> Vec<String> {
    let mut list = vec![text.to_string()];
    if let Some(decoded) = query_unescape(text) {
        if decoded != text {
            list.push(decoded);
        }
    }
    list
}

fn first_some(a: Option<String>, b: Option<String>, c: Option<String>) -> Option<String> {
    a.or(b).or(c)
}

/// 裸 id:无 `/` 且长度过阈值的原串。
fn bare_id(link: &str, min_len: usize) -> String {
    let trimmed = link.trim();
    if trimmed.len() > min_len && !trimmed.contains('/') {
        trimmed.to_string()
    } else {
        String::new()
    }
}

fn bare_id_ok(text: &str) -> bool {
    !text.is_empty() && is_digits(text)
}

/// 从 `start` 起取连续数字段;长度不足 `min_len` 视为没找到。
fn digits_at(value: &str, start: usize, min_len: usize) -> Option<String> {
    let tail = &value.as_bytes()[start..];
    let length = tail.iter().take_while(|byte| byte.is_ascii_digit()).count();
    (length >= min_len).then(|| value[start..start + length].to_string())
}

/// 在文本里找 `key=digits`(key 须位于串首或前邻 `?`/`&`)。
fn find_param_digits_min(text: &str, key: &str, min_len: usize) -> Option<String> {
    let bytes = text.as_bytes();
    let mut search_from = 0usize;
    while let Some(found) = text[search_from..].find(key) {
        let at = search_from + found;
        let value_at = at + key.len() + 1; // '=' 的下一位
        let key_boundary = at == 0 || matches!(bytes[at - 1], b'?' | b'&');
        if key_boundary && bytes.get(at + key.len()) == Some(&b'=') {
            if let Some(value) = digits_at(text, value_at, min_len) {
                return Some(value);
            }
        }
        search_from = at + key.len();
    }
    None
}

fn find_param_digits(text: &str, key: &str) -> Option<String> {
    find_param_digits_min(text, key, 1)
}

/// 在文本里找 `"key": "123"` / `"key":"123"`(引号可省)。
fn find_json_digits_min(text: &str, key: &str, min_len: usize) -> Option<String> {
    let needle = format!("\"{key}\"");
    let bytes = text.as_bytes();
    let mut search_from = 0usize;
    while let Some(found) = text[search_from..].find(&needle) {
        let after_key = search_from + found + needle.len();
        // 冒号两侧允许空白;值前的引号可选
        let mut cursor = after_key;
        while matches!(bytes.get(cursor), Some(b' ') | Some(b'\t')) {
            cursor += 1;
        }
        if bytes.get(cursor) != Some(&b':') {
            search_from = after_key;
            continue;
        }
        cursor += 1;
        while matches!(bytes.get(cursor), Some(b' ') | Some(b'\t')) {
            cursor += 1;
        }
        if bytes.get(cursor) == Some(&b'"') {
            cursor += 1;
        }
        if let Some(value) = digits_at(text, cursor, min_len) {
            return Some(value);
        }
        search_from = after_key;
    }
    None
}

fn find_json_digits(text: &str, key: &str) -> Option<String> {
    find_json_digits_min(text, key, 1)
}

/// 标记之后紧跟数字段。
fn find_after_marker_min(text: &str, marker: &str, min_len: usize) -> Option<String> {
    let at = text.find(marker)?;
    digits_at(text, at + marker.len(), min_len)
}

fn find_after_marker(text: &str, marker: &str) -> Option<String> {
    find_after_marker_min(text, marker, 1)
}

/// 标记大小写不敏感版:在小写副本里定位(长度不变,索引通用),原文取值。
fn find_after_marker_ci(text: &str, marker: &str) -> Option<String> {
    let at = text.to_lowercase().find(&marker.to_lowercase())?;
    digits_at(text, at + marker.len(), 1)
}
