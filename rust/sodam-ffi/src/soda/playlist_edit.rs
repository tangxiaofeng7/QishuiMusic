//! 歌单写操作:创建/改信息/删除/加删歌/排序/导入/敏感词检查
//! (照官方客户端 IDL 补的写接口;App 当前只读化,能力保留给引擎完整性)。
//!
//! | 能力 | 端点 | 体 |
//! | --- | --- | --- |
//! | 创建 | `POST /luna/pc/me/playlist` | `{name, is_private?, track_ids?/media?}` |
//! | 改信息 | `POST /luna/pc/me/playlist/update` | `{playlist_id, name?, …}` |
//! | 删除 | `POST /luna/pc/me/playlist/delete` | `{playlist_ids}` |
//! | 加/删歌 | `…/playlist/media/{append,delete}` | `{playlist_id, media[]}` |
//! | 排序 | `POST /luna/me/playlist/media/sort` | `{playlist_id, media[]}` |
//! | 敏感词 | `GET /luna/me/playlist/wordcheck` | `content` + `type` |
//!
//! 这些路径不在 bdticket 加签名单里,配好应用级签名即可用。

use super::media_ref::{media_array, MediaRef};
use super::Soda;
use crate::error::{Result, SodaError};

pub const CREATE_PLAYLIST_PATH: &str = "/luna/pc/me/playlist";
pub const UPDATE_PLAYLIST_PATH: &str = "/luna/pc/me/playlist/update";
pub const DELETE_PLAYLIST_PATH: &str = "/luna/pc/me/playlist/delete";
pub const APPEND_PLAYLIST_MEDIA_PATH: &str = "/luna/pc/me/playlist/media/append";
pub const DELETE_PLAYLIST_MEDIA_PATH: &str = "/luna/pc/me/playlist/media/delete";
/// 排序只有非 PC 路径(PC 形态 404)。
pub const SORT_PLAYLIST_MEDIA_PATH: &str = "/luna/me/playlist/media/sort";
pub const WORD_CHECK_PATH: &str = "/luna/me/playlist/wordcheck";
/// `track_ids` 版加歌(IDL 登记,PC 客户端未用)。
pub const APPEND_PLAYLIST_TRACKS_PATH: &str = "/luna/me/playlist/track/append";
/// `track_ids` 版删歌(字段名 `delete_track_ids`)。
pub const DELETE_PLAYLIST_TRACKS_PATH: &str = "/luna/me/playlist/track/delete";
/// `track_ids` 版排序。
pub const SORT_PLAYLIST_TRACKS_PATH: &str = "/luna/me/playlist/track/sort";
/// 导入外部歌单。
pub const IMPORT_PLAYLIST_PATH: &str = "/luna/me/playlist/import";
/// 查询导入任务。
pub const PLAYLIST_IMPORT_TASKS_PATH: &str = "/luna/me/playlist/import_task_info";

/// 敏感词检查类型:`name` 歌单名 / `desc` 歌单描述。
pub const WORD_CHECK_TYPE_PLAYLIST_NAME: &str = "name";
pub const WORD_CHECK_TYPE_PLAYLIST_DESCRIPTION: &str = "desc";

/// 歌单名字符上限(与服务端硬线一致:31 字符回 ERR_INVALID_PARAM)。
pub const PLAYLIST_NAME_MAX_CHARS: usize = 30;

fn require_cookie(soda: &Soda, what: &str) -> Result<()> {
    if !soda.has_cookie() {
        return Err(SodaError::invalid_input(format!("{what} requires cookie")));
    }
    Ok(())
}

/// 名字本地预检:非空且不超长,超限给可读错误(服务端只回 ERR_INVALID_PARAM)。
fn check_playlist_name(name: &str, what: &str) -> Result<()> {
    let trimmed = name.trim();
    if trimmed.is_empty() {
        return Err(SodaError::invalid_input(format!("{what} requires name")));
    }
    let chars = trimmed.chars().count();
    if chars > PLAYLIST_NAME_MAX_CHARS {
        return Err(SodaError::invalid_input(format!(
            "{what} name too long: {chars} > {PLAYLIST_NAME_MAX_CHARS} chars"
        )));
    }
    Ok(())
}

/// ids 归一:trim + 去空(是否为空由调用方决定报不报错)。
fn clean_ids(ids: &[String]) -> Vec<String> {
    ids.iter()
        .map(|id| id.trim().to_string())
        .filter(|id| !id.is_empty())
        .collect()
}

/// 创建歌单请求体(track_ids 版;空列表省略该字段)。
pub fn create_playlist_body(
    name: &str,
    is_private: bool,
    track_ids: &[String],
) -> serde_json::Value {
    let mut body = serde_json::json!({
        "name": name.trim(),
        "is_private": is_private,
    });
    let ids = clean_ids(track_ids);
    if !ids.is_empty() {
        body["track_ids"] = serde_json::json!(ids);
    }
    body
}

/// 创建歌单请求体(media 版,官方 PC 客户端的真实用法)。
pub fn create_playlist_media_body(
    name: &str,
    is_private: bool,
    media: &[MediaRef],
) -> serde_json::Value {
    serde_json::json!({
        "name": name.trim(),
        "is_private": is_private,
        "media": media_array(media),
    })
}

/// 从创建/导入回包取新歌单 id(字段名历版多变,候选路径全兜)。
pub fn extract_playlist_id(response: &serde_json::Value) -> String {
    for path in [
        &["data", "playlist_id"][..],
        &["data", "playlist", "id"][..],
        &["data", "id"][..],
        &["playlist", "id"][..],
        &["playlist_id"][..],
    ] {
        let Some(value) = path.iter().try_fold(response, |cursor, key| cursor.get(*key)) else {
            continue;
        };
        if let Some(text) = value.as_str().map(str::trim).filter(|t| !t.is_empty()) {
            return text.to_string();
        }
        if let Some(number) = value.as_i64() {
            return number.to_string();
        }
    }
    String::new()
}

/// 写操作回包判定:**成功时往往不带 `status_code`**(实测只有出错才带非 0 码),
/// 缺字段必须当成功,否则全部成功被误判。
pub fn response_is_ok(value: &serde_json::Value) -> bool {
    !matches!(
        value.get("status_code").and_then(|code| code.as_i64()),
        Some(code) if code != 0
    )
}

/// 回包错误文案(`status_info.status_msg`),成功/缺失为空串。
pub fn response_error_message(value: &serde_json::Value) -> String {
    value
        .get("status_info")
        .and_then(|info| info.get("status_msg"))
        .and_then(|msg| msg.as_str())
        .unwrap_or_default()
        .trim()
        .to_string()
}

/// 创建歌单(track_ids 版),返回新歌单 id(未回 id 为空串)。
pub fn create_playlist(
    soda: &Soda,
    name: &str,
    is_private: bool,
    track_ids: &[String],
) -> Result<String> {
    Ok(extract_playlist_id(&create_playlist_response(
        soda,
        name,
        is_private,
        track_ids,
    )?))
}

/// 创建歌单(track_ids 版),原始回包。
pub fn create_playlist_response(
    soda: &Soda,
    name: &str,
    is_private: bool,
    track_ids: &[String],
) -> Result<serde_json::Value> {
    require_cookie(soda, "soda create playlist")?;
    check_playlist_name(name, "soda create playlist")?;
    super::pc_post_json(
        soda,
        CREATE_PLAYLIST_PATH,
        &create_playlist_body(name, is_private, track_ids),
    )
}

/// 创建歌单(media 版),返回新歌单 id。
pub fn create_playlist_with_media(
    soda: &Soda,
    name: &str,
    is_private: bool,
    media: &[MediaRef],
) -> Result<String> {
    Ok(extract_playlist_id(&create_playlist_with_media_response(
        soda,
        name,
        is_private,
        media,
    )?))
}

/// 创建歌单(media 版),原始回包。
pub fn create_playlist_with_media_response(
    soda: &Soda,
    name: &str,
    is_private: bool,
    media: &[MediaRef],
) -> Result<serde_json::Value> {
    require_cookie(soda, "soda create playlist")?;
    check_playlist_name(name, "soda create playlist")?;
    if media.iter().all(|item| item.is_empty()) {
        return Err(SodaError::invalid_input(
            "soda create playlist requires media",
        ));
    }
    super::pc_post_json(
        soda,
        CREATE_PLAYLIST_PATH,
        &create_playlist_media_body(name, is_private, media),
    )
}

/// 改名/描述/可见性/封面,只传要改的字段。
pub fn update_playlist_info(
    soda: &Soda,
    playlist_id: &str,
    name: Option<&str>,
    description: Option<&str>,
    is_private: Option<bool>,
    cover_uri: Option<&str>,
) -> Result<serde_json::Value> {
    require_cookie(soda, "soda update playlist")?;
    if playlist_id.trim().is_empty() {
        return Err(SodaError::invalid_input(
            "soda update playlist requires playlist_id",
        ));
    }
    let mut body = serde_json::json!({ "playlist_id": playlist_id.trim() });
    if let Some(name) = name {
        check_playlist_name(name, "soda update playlist")?;
        body["name"] = serde_json::json!(name.trim());
    }
    if let Some(description) = description {
        body["description"] = serde_json::json!(description.trim());
    }
    if let Some(is_private) = is_private {
        body["is_private"] = serde_json::json!(is_private);
    }
    if let Some(cover_uri) = cover_uri {
        body["cover_uri"] = serde_json::json!(cover_uri.trim());
    }
    super::pc_post_json(soda, UPDATE_PLAYLIST_PATH, &body)
}

/// 批量删除歌单。
pub fn delete_playlists(soda: &Soda, playlist_ids: &[String]) -> Result<serde_json::Value> {
    require_cookie(soda, "soda delete playlists")?;
    let ids = clean_ids(playlist_ids);
    if ids.is_empty() {
        return Err(SodaError::invalid_input(
            "soda delete playlists requires playlist_ids",
        ));
    }
    super::pc_post_json(soda, DELETE_PLAYLIST_PATH, &serde_json::json!({ "playlist_ids": ids }))
}

/// 加/删歌/排序共用的 `{playlist_id, media}` 体。
fn media_body(playlist_id: &str, media: &[MediaRef]) -> Result<serde_json::Value> {
    if playlist_id.trim().is_empty() {
        return Err(SodaError::invalid_input(
            "soda playlist media requires playlist_id",
        ));
    }
    let items = media_array(media);
    if items.as_array().map(|list| list.is_empty()).unwrap_or(true) {
        return Err(SodaError::invalid_input(
            "soda playlist media requires media",
        ));
    }
    Ok(serde_json::json!({
        "playlist_id": playlist_id.trim(),
        "media": items,
    }))
}

/// 往歌单加歌。
pub fn append_playlist_media(
    soda: &Soda,
    playlist_id: &str,
    media: &[MediaRef],
) -> Result<serde_json::Value> {
    require_cookie(soda, "soda append playlist media")?;
    super::pc_post_json(soda, APPEND_PLAYLIST_MEDIA_PATH, &media_body(playlist_id, media)?)
}

/// 从歌单删歌。
pub fn delete_playlist_media(
    soda: &Soda,
    playlist_id: &str,
    media: &[MediaRef],
) -> Result<serde_json::Value> {
    require_cookie(soda, "soda delete playlist media")?;
    super::pc_post_json(soda, DELETE_PLAYLIST_MEDIA_PATH, &media_body(playlist_id, media)?)
}

/// 歌单排序(media 按目标顺序传入;全量替换语义)。
pub fn sort_playlist_media(
    soda: &Soda,
    playlist_id: &str,
    media: &[MediaRef],
) -> Result<serde_json::Value> {
    require_cookie(soda, "soda sort playlist media")?;
    super::pc_post_json(soda, SORT_PLAYLIST_MEDIA_PATH, &media_body(playlist_id, media)?)
}

/// 敏感词检查:`true` = 命中(官方回 `{status_code, is_passed}`)。
pub fn text_has_sensitive_word(soda: &Soda, content: &str, kind: &str) -> Result<bool> {
    require_cookie(soda, "soda word check")?;
    if content.trim().is_empty() {
        return Err(SodaError::invalid_input("soda word check requires content"));
    }
    let response = super::pc_get_json(
        soda,
        WORD_CHECK_PATH,
        &[
            ("content", content.trim().to_string()),
            ("type", kind.trim().to_string()),
        ],
    )?;
    // 接口级错误先暴露,避免把 ERR_INVALID_PARAM 误判成"命中敏感词"
    if !response_is_ok(&response) {
        let message = response_error_message(&response);
        let status_code = response
            .get("status_code")
            .and_then(|code| code.as_i64())
            .unwrap_or_default();
        return Err(SodaError::http(format!(
            "soda word check failed: {message}（status_code={status_code}）"
        )));
    }
    for path in [&["is_passed"][..], &["data", "is_passed"][..]] {
        let passed = path
            .iter()
            .try_fold(&response, |cursor, key| cursor.get(*key))
            .and_then(|value| value.as_bool());
        if let Some(passed) = passed {
            return Ok(!passed);
        }
    }
    Err(SodaError::json(
        "soda word check response missing is_passed".to_string(),
    ))
}

/// 歌单名敏感词检查(`true` = 命中)。
pub fn playlist_name_has_sensitive_word(soda: &Soda, name: &str) -> Result<bool> {
    text_has_sensitive_word(soda, name, WORD_CHECK_TYPE_PLAYLIST_NAME)
}

/// 歌单描述敏感词检查(`true` = 命中)。
pub fn playlist_description_has_sensitive_word(soda: &Soda, description: &str) -> Result<bool> {
    text_has_sensitive_word(soda, description, WORD_CHECK_TYPE_PLAYLIST_DESCRIPTION)
}

/// `track_ids` 版公共体(字段名/报错文案由调用方给)。
fn track_ids_body(
    playlist_id: &str,
    field: &str,
    track_ids: &[String],
    what: &str,
) -> Result<serde_json::Value> {
    if playlist_id.trim().is_empty() {
        return Err(SodaError::invalid_input(format!(
            "{what} requires playlist_id"
        )));
    }
    let ids = clean_ids(track_ids);
    if ids.is_empty() {
        return Err(SodaError::invalid_input(format!(
            "{what} requires track_ids"
        )));
    }
    Ok(serde_json::json!({
        "playlist_id": playlist_id.trim(),
        field: ids,
    }))
}

/// `track_ids` 版加歌请求体。
pub fn append_playlist_tracks_body(
    playlist_id: &str,
    track_ids: &[String],
) -> Result<serde_json::Value> {
    track_ids_body(
        playlist_id,
        "track_ids",
        track_ids,
        "soda append playlist tracks",
    )
}

/// `track_ids` 版删歌请求体(字段名 `delete_track_ids`)。
pub fn delete_playlist_tracks_body(
    playlist_id: &str,
    track_ids: &[String],
) -> Result<serde_json::Value> {
    track_ids_body(
        playlist_id,
        "delete_track_ids",
        track_ids,
        "soda delete playlist tracks",
    )
}

/// `track_ids` 版排序请求体。
pub fn sort_playlist_tracks_body(
    playlist_id: &str,
    track_ids: &[String],
) -> Result<serde_json::Value> {
    track_ids_body(
        playlist_id,
        "track_ids",
        track_ids,
        "soda sort playlist tracks",
    )
}

/// `track_ids` 版加歌(IDL 兼容;官方实际用 media 版)。
pub fn append_playlist_tracks(
    soda: &Soda,
    playlist_id: &str,
    track_ids: &[String],
) -> Result<serde_json::Value> {
    require_cookie(soda, "soda append playlist tracks")?;
    super::pc_post_json(
        soda,
        APPEND_PLAYLIST_TRACKS_PATH,
        &append_playlist_tracks_body(playlist_id, track_ids)?,
    )
}

/// `track_ids` 版删歌。
pub fn delete_playlist_tracks(
    soda: &Soda,
    playlist_id: &str,
    track_ids: &[String],
) -> Result<serde_json::Value> {
    require_cookie(soda, "soda delete playlist tracks")?;
    super::pc_post_json(
        soda,
        DELETE_PLAYLIST_TRACKS_PATH,
        &delete_playlist_tracks_body(playlist_id, track_ids)?,
    )
}

/// `track_ids` 版排序(按目标顺序)。
pub fn sort_playlist_tracks(
    soda: &Soda,
    playlist_id: &str,
    track_ids: &[String],
) -> Result<serde_json::Value> {
    require_cookie(soda, "soda sort playlist tracks")?;
    super::pc_post_json(
        soda,
        SORT_PLAYLIST_TRACKS_PATH,
        &sort_playlist_tracks_body(playlist_id, track_ids)?,
    )
}

/// 导入请求体。
pub fn import_playlist_body(url: &str) -> serde_json::Value {
    serde_json::json!({ "url": url.trim() })
}

/// 导入外部歌单,返回新歌单 id;导入异步,进度走 [`playlist_import_tasks`]。
pub fn import_playlist(soda: &Soda, url: &str) -> Result<String> {
    Ok(extract_playlist_id(&import_playlist_response(soda, url)?))
}

/// 导入外部歌单,原始回包。
pub fn import_playlist_response(soda: &Soda, url: &str) -> Result<serde_json::Value> {
    require_cookie(soda, "soda import playlist")?;
    if url.trim().is_empty() {
        return Err(SodaError::invalid_input(
            "soda import playlist requires url",
        ));
    }
    super::pc_post_json(soda, IMPORT_PLAYLIST_PATH, &import_playlist_body(url))
}

/// 查询导入任务状态(回包 `{task_infos:{id:{…}}}`)。
pub fn playlist_import_tasks(soda: &Soda, task_ids: &[String]) -> Result<serde_json::Value> {
    require_cookie(soda, "soda playlist import tasks")?;
    let ids = clean_ids(task_ids);
    if ids.is_empty() {
        return Err(SodaError::invalid_input(
            "soda playlist import tasks requires task_ids",
        ));
    }
    super::pc_post_json(
        soda,
        PLAYLIST_IMPORT_TASKS_PATH,
        &serde_json::json!({ "task_ids": ids }),
    )
}

impl Soda {
    /// 创建歌单(新歌单 id,未回 id 为空串)。
    pub fn create_playlist(
        &self,
        name: &str,
        is_private: bool,
        track_ids: &[String],
    ) -> Result<String> {
        create_playlist(self, name, is_private, track_ids)
    }

    /// 创建歌单(原始回包)。
    pub fn create_playlist_response(
        &self,
        name: &str,
        is_private: bool,
        track_ids: &[String],
    ) -> Result<serde_json::Value> {
        create_playlist_response(self, name, is_private, track_ids)
    }

    /// 创建歌单(media 版)。
    pub fn create_playlist_with_media(
        &self,
        name: &str,
        is_private: bool,
        media: &[MediaRef],
    ) -> Result<String> {
        create_playlist_with_media(self, name, is_private, media)
    }

    /// `track_ids` 版加歌。
    pub fn append_playlist_tracks(
        &self,
        playlist_id: &str,
        track_ids: &[String],
    ) -> Result<serde_json::Value> {
        append_playlist_tracks(self, playlist_id, track_ids)
    }

    /// `track_ids` 版删歌。
    pub fn delete_playlist_tracks(
        &self,
        playlist_id: &str,
        track_ids: &[String],
    ) -> Result<serde_json::Value> {
        delete_playlist_tracks(self, playlist_id, track_ids)
    }

    /// `track_ids` 版排序。
    pub fn sort_playlist_tracks(
        &self,
        playlist_id: &str,
        track_ids: &[String],
    ) -> Result<serde_json::Value> {
        sort_playlist_tracks(self, playlist_id, track_ids)
    }

    /// 导入外部歌单。
    pub fn import_playlist(&self, url: &str) -> Result<String> {
        import_playlist(self, url)
    }

    /// 查询导入任务。
    pub fn playlist_import_tasks(&self, task_ids: &[String]) -> Result<serde_json::Value> {
        playlist_import_tasks(self, task_ids)
    }

    /// 改信息(名字/描述/可见性/封面)。
    pub fn update_playlist_info(
        &self,
        playlist_id: &str,
        name: Option<&str>,
        description: Option<&str>,
        is_private: Option<bool>,
        cover_uri: Option<&str>,
    ) -> Result<serde_json::Value> {
        update_playlist_info(self, playlist_id, name, description, is_private, cover_uri)
    }

    /// 批量删除歌单。
    pub fn delete_playlists(&self, playlist_ids: &[String]) -> Result<serde_json::Value> {
        delete_playlists(self, playlist_ids)
    }

    /// 加歌。
    pub fn append_playlist_media(
        &self,
        playlist_id: &str,
        media: &[MediaRef],
    ) -> Result<serde_json::Value> {
        append_playlist_media(self, playlist_id, media)
    }

    /// 删歌。
    pub fn delete_playlist_media(
        &self,
        playlist_id: &str,
        media: &[MediaRef],
    ) -> Result<serde_json::Value> {
        delete_playlist_media(self, playlist_id, media)
    }

    /// 排序。
    pub fn sort_playlist_media(
        &self,
        playlist_id: &str,
        media: &[MediaRef],
    ) -> Result<serde_json::Value> {
        sort_playlist_media(self, playlist_id, media)
    }

    /// 歌单名敏感词检查。
    pub fn playlist_name_has_sensitive_word(&self, name: &str) -> Result<bool> {
        playlist_name_has_sensitive_word(self, name)
    }

    /// 歌单描述敏感词检查。
    pub fn playlist_description_has_sensitive_word(&self, description: &str) -> Result<bool> {
        playlist_description_has_sensitive_word(self, description)
    }
}
