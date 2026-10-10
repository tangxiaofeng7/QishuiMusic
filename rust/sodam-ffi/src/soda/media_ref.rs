//! 媒体引用:写操作接口里统一用 `{"id": "...", "type": "..."}` 指代一条媒体
//! (收藏、歌单增删曲目等)。给自写客户端补的基础类型。

use serde::{Deserialize, Serialize};

/// 媒体类型:单曲(collection / playlist media 接口固定值)。
pub const MEDIA_TYPE_TRACK: &str = "track";

/// 媒体类型:UGC 短片(歌单/收藏条目里会出现,客户端对它有独立分支)。
pub const MEDIA_TYPE_UGC_CLIP: &str = "ugc_clip";

/// 一条 `{id, type}` 媒体引用。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MediaRef {
    pub id: String,
    #[serde(rename = "type")]
    pub media_type: String,
}

impl MediaRef {
    /// 单曲引用。
    pub fn track(id: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            media_type: MEDIA_TYPE_TRACK.to_string(),
        }
    }

    pub fn new(id: impl Into<String>, media_type: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            media_type: media_type.into(),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.id.trim().is_empty()
    }
}

/// 序列化成接口需要的 JSON 数组;空白 id 条目剔除,两侧字段 trim。
pub(crate) fn media_array(media: &[MediaRef]) -> serde_json::Value {
    serde_json::Value::Array(
        media
            .iter()
            .filter(|item| !item.is_empty())
            .map(|item| {
                serde_json::json!({
                    "id": item.id.trim(),
                    "type": item.media_type.trim(),
                })
            })
            .collect(),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn track_ref_uses_track_type() {
        let item = MediaRef::track("7501674235158431760");
        assert_eq!(item.media_type, "track");
        assert_eq!(item.id, "7501674235158431760");
    }

    #[test]
    fn media_array_filters_blank_ids() {
        let value = media_array(&[
            MediaRef::track("1"),
            MediaRef::track("  "),
            MediaRef::track("2"),
        ]);
        assert_eq!(
            value,
            serde_json::json!([
                {"id": "1", "type": "track"},
                {"id": "2", "type": "track"},
            ])
        );
    }
}
