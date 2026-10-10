//! 跨音源的数据模型(歌曲 / 歌单 / 扫码登录会话)。
//!
//! 字段名即 JSON 序列化契约(FFI 层与持久化都按这些键读写),不可随意改名。

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// 给带 `extra: BTreeMap<String, String>` 字段的模型统一生成取值/存值方法。
macro_rules! extra_accessors {
    ($ty:ty) => {
        impl $ty {
            /// 读一条源特有元数据,空值视作不存在。
            pub fn extra_get(&self, key: &str) -> Option<&str> {
                self.extra.get(key).map(|value| value.as_str())
            }
        }
    };
}

/// 通用歌曲条目。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Song {
    pub id: String,
    pub name: String,
    pub artist: String,
    pub album: String,
    /// 部分音源用它二次拉取封面。
    pub album_id: String,
    /// 时长(秒)。
    pub duration: i64,
    /// 已知文件大小(字节),未知为 0。
    pub size: i64,
    /// 已知码率(kbps),未知为 0。
    pub bitrate: i64,
    /// 来源标识,汽水固定 [`SOURCE_SODA`]。
    pub source: String,
    /// 音频直链;加密流形如 `<url>#auth=<percent-encoded play_auth>`。
    pub url: String,
    /// 音频容器后缀(mp3 / m4a / flac …)。
    pub ext: String,
    pub cover: String,
    /// 曲目对应的网页地址。
    pub link: String,
    /// 源特有键值(`track_id` / `quality` / `is_vip` …)。
    pub extra: BTreeMap<String, String>,
    /// 探测失败后打的无效标记。
    pub is_invalid: bool,
    /// 需要 VIP/付费权益才能拿整曲。
    pub is_vip: bool,
}

impl Song {
    /// 存一条元数据;空白值直接忽略,避免污染 extra 表。
    pub fn extra_set(&mut self, key: &str, value: impl Into<String>) {
        let value = value.into();
        if !value.trim().is_empty() {
            self.extra.insert(key.to_string(), value);
        }
    }
}

extra_accessors!(Song);

/// 通用歌单/专辑条目。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Playlist {
    pub id: String,
    pub name: String,
    pub cover: String,
    pub track_count: i64,
    pub play_count: i64,
    pub creator: String,
    pub description: String,
    pub source: String,
    pub link: String,
    pub extra: BTreeMap<String, String>,
}

extra_accessors!(Playlist);

/// 歌单广场的分类标签。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct PlaylistCategory {
    pub id: String,
    pub name: String,
    pub group: String,
    pub source: String,
    pub count: i64,
    pub hot: bool,
    pub extra: BTreeMap<String, String>,
}

extra_accessors!(PlaylistCategory);

/// 扫码登录的五态机。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum QRLoginStatus {
    /// 尚未扫码。
    #[default]
    Waiting,
    /// 已扫码,等手机确认(或触发短信二次验证)。
    Scanned,
    /// 服务端已放行,会话 Cookie 已就位。
    Success,
    /// 二维码超时作废。
    Expired,
    /// 其它失败形态。
    Failed,
}

impl QRLoginStatus {
    /// 小写标识串,FFI 层按它映射 Dart 侧枚举。
    pub fn as_str(self) -> &'static str {
        match self {
            QRLoginStatus::Waiting => "waiting",
            QRLoginStatus::Scanned => "scanned",
            QRLoginStatus::Success => "success",
            QRLoginStatus::Expired => "expired",
            QRLoginStatus::Failed => "failed",
        }
    }
}

impl std::fmt::Display for QRLoginStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// 一次二维码登录会话(创建后待轮询)。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct QRLoginSession {
    /// 来源标识。
    pub source: String,
    /// 轮询 key/token。
    pub key: String,
    /// 二维码内容(通常可直接渲染为图)。
    pub url: String,
    /// 服务端给的二维码图片地址或 base64 data URL。
    pub image_url: String,
    /// 过期时刻(Unix 秒)。
    pub expires_at: i64,
    /// 附加键值(token、scan_login_url、is_frontier …)。
    pub extra: BTreeMap<String, String>,
}

/// 一次轮询的结果快照。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct QRLoginResult {
    pub source: String,
    /// 本次轮询的 key。
    pub key: String,
    pub status: QRLoginStatus,
    /// 服务端提示文案(面向用户展示)。
    pub message: String,
    /// 登录成功后回填的 Cookie 串(`k=v; k2=v2` 形态)。
    pub cookie: String,
    /// 登录成功后的 Cookie 名值对。
    pub cookies: BTreeMap<String, String>,
    /// 附加键值(MFA、限流、API 状态…)。
    pub extra: BTreeMap<String, String>,
}

impl QRLoginResult {
    /// 无条件写入(区别于 Song::extra_set 的空白过滤;轮询附加信息允许占位值)。
    pub fn extra_set(&mut self, key: &str, value: impl Into<String>) {
        self.extra.insert(key.to_string(), value.into());
    }
}

/// 汽水源的固定来源标识。
pub const SOURCE_SODA: &str = "soda";
