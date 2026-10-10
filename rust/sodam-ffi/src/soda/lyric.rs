//! 歌词:汽水逐字歌词格式转标准 LRC。
//!
//! 汽水原始形态每行是 `[起始毫秒,持续毫秒]歌词<逐字时间标记>词<...>`,
//! LRC 目标形态是 `[mm:ss.cc]歌词`(逐字标记剥掉)。

use super::track::fetch_web_track_v2;
use super::Soda;
use crate::error::{Result, SodaError};
use crate::model::{Song, SOURCE_SODA};

/// 取某首歌的歌词(空串 = 服务端没有歌词数据)。
pub fn get_lyrics(soda: &Soda, song: &Song) -> Result<String> {
    // 引擎只服务汽水源;跨源曲目直接拒绝,防止拿别家 id 去查汽水
    if !song.source.is_empty() && song.source != SOURCE_SODA {
        return Err(SodaError::invalid_input("source mismatch"));
    }
    let track_id = song
        .extra_get("track_id")
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or(&song.id);
    let response = fetch_web_track_v2(soda, track_id)?;
    if response.lyric.content.trim().is_empty() {
        return Ok(String::new());
    }
    Ok(parse_soda_lyric(&response.lyric.content))
}

/// `[start,duration]内容` → `[mm:ss.cc]内容`;无法解析的行静默丢弃。
pub fn parse_soda_lyric(raw: &str) -> String {
    let mut out = String::new();
    for line in raw.lines().map(str::trim).filter(|l| !l.is_empty()) {
        let Some(start_ms) = line_start_ms(line) else {
            continue;
        };
        let text = line
            .split_once(']')
            .map(|(_, content)| strip_word_tags(content))
            .unwrap_or_default();
        let (minutes, seconds, centis) = split_ms(start_ms);
        out.push_str(&format!("[{minutes:02}:{seconds:02}.{centis:02}]{text}\n"));
    }
    out
}

/// 行首 `[数字,` 里的起始毫秒;不匹配该形态返回 `None`。
fn line_start_ms(line: &str) -> Option<i64> {
    let body = line.strip_prefix('[')?;
    let (start, rest) = body.split_once(',')?;
    if !rest.contains(']') {
        return None;
    }
    start.trim().parse().ok()
}

/// 毫秒 → (分, 秒, 厘秒)。
fn split_ms(ms: i64) -> (i64, i64, i64) {
    (ms / 60_000, (ms % 60_000) / 1000, (ms % 1000) / 10)
}

/// 剥掉 `<...>` 逐字时间标记,只留可显示文本。
fn strip_word_tags(content: &str) -> String {
    let mut text = String::with_capacity(content.len());
    let mut in_tag = false;
    for ch in content.chars() {
        match ch {
            '<' => in_tag = true,
            '>' => in_tag = false,
            _ if !in_tag => text.push(ch),
            _ => {}
        }
    }
    text
}

impl Soda {
    /// 取歌词(见 [`get_lyrics`])。
    pub fn get_lyrics(&self, song: &Song) -> Result<String> {
        get_lyrics(self, song)
    }
}
