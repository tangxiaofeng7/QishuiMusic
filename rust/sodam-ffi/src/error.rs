//! 引擎统一错误类型。
//!
//! 注意:部分调用方靠 `Display` 输出的**固定子串**判别错误族(如
//! `"requires cookie"`、`"returned preview stream"`),改文案前先全局
//! 搜引用(`is_missing_entitlement` / `is_cookie_required`)。

use std::fmt;

/// 引擎对外的唯一错误类型;每个变体对应一层故障来源。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SodaError {
    /// 连接失败、超时、非 2xx 状态码等传输层故障。
    Http(String),
    /// 回包不是合法 JSON 或与预期结构不符。
    Json(String),
    /// 服务端业务拒绝:`status_code != 0`。
    Api { status_code: i64, status_msg: String },
    /// 音频解密失败(box 结构缺失、密钥非法、长度不符等)。
    Crypto(String),
    /// 当前实现不覆盖的能力。
    Unsupported(String),
    /// 调用方传参不合法(空 id、非法链接等)。
    InvalidInput(String),
    /// 目标资源在服务端不存在。
    NotFound(String),
    /// 本地 IO 故障。
    Io(String),
}

/// 单字符串负载的变体构造器:统一走这个小宏,保证形态一致。
macro_rules! simple_ctors {
    ($($fn_name:ident => $variant:ident),* $(,)?) => {
        $(
            pub fn $fn_name(msg: impl Into<String>) -> Self {
                SodaError::$variant(msg.into())
            }
        )*
    };
}

impl SodaError {
    simple_ctors! {
        http => Http,
        json => Json,
        crypto => Crypto,
        unsupported => Unsupported,
        invalid_input => InvalidInput,
        not_found => NotFound,
    }

    /// 业务错误;`status_msg` 为空时兜底占位,避免上层显示空文案。
    pub fn api(status_code: i64, status_msg: impl Into<String>) -> Self {
        let status_msg = {
            let text = status_msg.into();
            if text.trim().is_empty() {
                "unknown error".to_string()
            } else {
                text
            }
        };
        SodaError::Api {
            status_code,
            status_msg,
        }
    }

    /// 判定"账号权益不足拿不到整曲"类错误(VIP 探测、取流梯子等处依赖)。
    /// 匹配的是 `Display` 文案子串,与既有调用约定一致。
    pub fn is_missing_entitlement(&self) -> bool {
        const ENTITLEMENT_MARKERS: [&str; 4] = [
            "requires cookie",
            "full stream unavailable",
            "returned preview stream",
            "requires logged-in user id",
        ];
        let text = self.to_string();
        ENTITLEMENT_MARKERS.iter().any(|marker| text.contains(marker))
    }

    /// 判定"缺少登录态"类错误。
    pub fn is_cookie_required(&self) -> bool {
        self.to_string().contains("requires cookie")
    }
}

impl fmt::Display for SodaError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            // 纯文本变体直接透出原因;业务错误带结构化字段,拼成可 grep 的形态。
            SodaError::Http(msg)
            | SodaError::Json(msg)
            | SodaError::Crypto(msg)
            | SodaError::Unsupported(msg)
            | SodaError::InvalidInput(msg)
            | SodaError::NotFound(msg)
            | SodaError::Io(msg) => f.write_str(msg),
            SodaError::Api {
                status_code,
                status_msg,
            } => write!(f, "status_code={status_code} status_msg={status_msg}"),
        }
    }
}

impl std::error::Error for SodaError {}

impl From<std::io::Error> for SodaError {
    fn from(err: std::io::Error) -> Self {
        SodaError::Io(err.to_string())
    }
}

impl From<serde_json::Error> for SodaError {
    fn from(err: serde_json::Error) -> Self {
        SodaError::Json(err.to_string())
    }
}

/// 引擎统一的 `Result` 别名。
pub type Result<T> = std::result::Result<T, SodaError>;
