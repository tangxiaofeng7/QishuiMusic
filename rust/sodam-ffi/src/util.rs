//! 引擎通用工具:查询参数编码、防御式 JSON 取值、UUID、系统浏览器拉起等。

use std::collections::BTreeMap;

// ---------------------------------------------------------------------------
// 查询参数集合
// ---------------------------------------------------------------------------

/// 有序查询参数集合,保持插入顺序,支持同 key 多值。
///
/// 两种编码形态:
/// * [`Params::encode`]——key 字典序(服务端签名/缓存 key 对参数序不敏感时用);
/// * [`Params::encode_order`]——指定 key 优先(参数顺序参与服务端校验的接口用)。
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Params {
    entries: Vec<(String, String)>,
}

impl Params {
    pub fn new() -> Self {
        Self::default()
    }

    /// 从 `(key, value)` 序列构造。
    pub fn from_pairs<I, K, V>(pairs: I) -> Self
    where
        I: IntoIterator<Item = (K, V)>,
        K: Into<String>,
        V: Into<String>,
    {
        let mut params = Params::new();
        for (key, value) in pairs {
            params.set(key, value);
        }
        params
    }

    fn index_of(&self, key: &str) -> Option<usize> {
        self.entries.iter().position(|(k, _)| k == key)
    }

    /// 覆盖式写入:同名 key 只保留最新值。
    pub fn set(&mut self, key: impl Into<String>, value: impl Into<String>) {
        let key = key.into();
        match self.index_of(&key) {
            Some(at) => self.entries[at].1 = value.into(),
            None => {
                let value = value.into();
                self.entries.push((key, value));
            }
        }
    }

    /// 追加式写入:同 key 允许重复(数组型参数编码成重复 key,如
    /// `item_types=a&item_types=b`,收藏/歌单列表接口需要该语义)。
    pub fn add(&mut self, key: impl Into<String>, value: impl Into<String>) {
        self.entries.push((key.into(), value.into()));
    }

    pub fn get(&self, key: &str) -> Option<&str> {
        self.index_of(key).map(|at| self.entries[at].1.as_str())
    }

    /// 删除该 key 的全部条目。
    pub fn remove(&mut self, key: &str) {
        self.entries.retain(|(k, _)| k != key);
    }

    pub fn iter(&self) -> impl Iterator<Item = (&str, &str)> {
        self.entries.iter().map(|(k, v)| (k.as_str(), v.as_str()))
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// 字典序编码(未转义安全字符集:`A-Za-z0-9-_.~`,空格作 `+`)。
    pub fn encode(&self) -> String {
        let mut sorted: Vec<&(String, String)> = self.entries.iter().collect();
        sorted.sort_by(|a, b| a.0.cmp(&b.0));
        encode_pairs(sorted.into_iter())
    }

    /// 指定序编码:`order` 里列出的 key 按给定顺序在前(含重复值),
    /// 未列出的 key 按字典序垫底。
    pub fn encode_order(&self, order: &[&str]) -> String {
        let mut ordered: Vec<&(String, String)> = Vec::with_capacity(self.entries.len());
        for key in order {
            ordered.extend(self.entries.iter().filter(|(k, _)| k == key));
        }
        let mut rest: Vec<&(String, String)> = self
            .entries
            .iter()
            .filter(|(k, _)| !order.contains(&k.as_str()))
            .collect();
        rest.sort_by(|a, b| a.0.cmp(&b.0));
        encode_pairs(ordered.into_iter().chain(rest.into_iter()))
    }
}

/// 把 `(key, value)` 对编码成 `k1=v1&k2=v2` 形态。
fn encode_pairs<'a, I>(pairs: I) -> String
where
    I: Iterator<Item = &'a (String, String)>,
{
    pairs
        .map(|(k, v)| format!("{}={}", query_escape(k), query_escape(v)))
        .collect::<Vec<_>>()
        .join("&")
}

// ---------------------------------------------------------------------------
// URL 转义
// ---------------------------------------------------------------------------

/// application/x-www-form-urlencoded 转义:空格作 `+`,安全字符直通,其余 `%XX`。
pub fn query_escape(value: &str) -> String {
    const SAFE: fn(u8) -> bool = |byte| {
        byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_' | b'.' | b'~')
    };
    let mut out = String::with_capacity(value.len());
    for byte in value.as_bytes() {
        if SAFE(*byte) {
            out.push(*byte as char);
        } else if *byte == b' ' {
            out.push('+');
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

/// 逆变换:`+` 还原空格、`%XX` 解码;遇到非法转义序列整体失败返回 `None`。
pub fn query_unescape(value: &str) -> Option<String> {
    let bytes = value.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut cursor = 0;
    while cursor < bytes.len() {
        let byte = bytes[cursor];
        if byte == b'+' {
            out.push(b' ');
            cursor += 1;
            continue;
        }
        if byte != b'%' {
            out.push(byte);
            cursor += 1;
            continue;
        }
        // % 后必须恰好跟两个十六进制字符
        let hex = bytes.get(cursor + 1..cursor + 3)?;
        let high = (hex[0] as char).to_digit(16)?;
        let low = (hex[1] as char).to_digit(16)?;
        out.push((high * 16 + low) as u8);
        cursor += 3;
    }
    String::from_utf8(out).ok()
}

// ---------------------------------------------------------------------------
// 防御式 JSON 取值(接口回包字段名随版本漂移,统一走候选 key + 形态容错)
// ---------------------------------------------------------------------------

type JsonMap = serde_json::Map<String, serde_json::Value>;

/// 依次尝试候选 key,取第一个非空字符串值。
pub fn json_string(values: &JsonMap, keys: &[&str]) -> String {
    keys.iter()
        .filter_map(|key| values.get(*key))
        .map(any_string)
        .find(|text| !text.is_empty())
        .unwrap_or_default()
}

/// 依次尝试候选 key,把值当数组取第一个非空字符串元素。
pub fn json_first_string(values: &JsonMap, keys: &[&str]) -> String {
    for key in keys {
        let Some(serde_json::Value::Array(items)) = values.get(*key) else {
            continue;
        };
        let hit = items.iter().map(any_string).find(|text| !text.is_empty());
        if let Some(text) = hit {
            return text;
        }
    }
    String::new()
}

/// 单值转文本:字符串 trim;数组递归取首个非空;其余形态作空。
pub fn any_string(value: &serde_json::Value) -> String {
    match value {
        serde_json::Value::String(text) => text.trim().to_string(),
        serde_json::Value::Array(items) => items
            .iter()
            .map(any_string)
            .find(|text| !text.is_empty())
            .unwrap_or_default(),
        _ => String::new(),
    }
}

/// 依次尝试候选 key 取数字;JSON number 或数字字符串都接受,缺省 0.0。
pub fn json_float(values: &JsonMap, keys: &[&str]) -> f64 {
    for key in keys {
        let Some(value) = values.get(*key) else {
            continue;
        };
        let parsed = match value {
            serde_json::Value::Number(number) => number.as_f64(),
            serde_json::Value::String(text) => text.trim().parse::<f64>().ok(),
            _ => None,
        };
        if let Some(number) = parsed {
            return number;
        }
    }
    0.0
}

/// 浮点取整版 [`json_float`](四舍五入)。
pub fn json_int(values: &JsonMap, keys: &[&str]) -> i64 {
    (json_float(values, keys) + 0.5) as i64
}

/// 取第一个非空白串。
pub fn first_non_empty(values: &[&str]) -> String {
    values
        .iter()
        .map(|v| v.trim())
        .find(|v| !v.is_empty())
        .map(str::to_string)
        .unwrap_or_default()
}

/// 艺人名列表归并展示:`" / "` 连接非空项。
pub fn join_artists<'a, I>(names: I) -> String
where
    I: IntoIterator<Item = &'a str>,
{
    names
        .into_iter()
        .map(str::trim)
        .filter(|name| !name.is_empty())
        .collect::<Vec<_>>()
        .join(" / ")
}

/// 音质/档位标识归一化:去 `-`/`_`/空格并转小写(比较 `hi-res` 与 `hires` 用)。
pub fn normalize_token(value: &str) -> String {
    value
        .trim()
        .to_lowercase()
        .chars()
        .filter(|ch| !matches!(ch, '-' | '_' | ' '))
        .collect()
}

/// 非空纯数字判定(区分资源 id 与杂项字段)。
pub fn is_digits(value: &str) -> bool {
    !value.is_empty() && value.bytes().all(|byte| byte.is_ascii_digit())
}

/// 深度优先收集整棵 JSON 树上指定字段名的全部非空字符串值
/// (服务端把目标 id 埋在任意层级时兜底用)。
pub fn collect_strings(value: &serde_json::Value, field: &str, out: &mut Vec<String>) {
    match value {
        serde_json::Value::Object(map) => {
            for (key, child) in map {
                if key == field {
                    let text = any_string(child);
                    if !text.is_empty() {
                        out.push(text);
                    }
                }
                collect_strings(child, field, out);
            }
        }
        serde_json::Value::Array(items) => {
            for item in items {
                collect_strings(item, field, out);
            }
        }
        _ => {}
    }
}

/// 依次尝试候选 key 取子对象。
pub fn json_object<'a>(values: &'a JsonMap, keys: &[&str]) -> Option<&'a JsonMap> {
    keys.iter().find_map(|key| match values.get(*key) {
        Some(serde_json::Value::Object(child)) => Some(child),
        _ => None,
    })
}

/// 32 位整数的置位数(popcount)。
pub fn bitcount(value: u32) -> u32 {
    value.count_ones()
}

/// `BTreeMap<String, String>` 便捷构造。
pub fn extra_from_pairs<I, K, V>(pairs: I) -> BTreeMap<String, String>
where
    I: IntoIterator<Item = (K, V)>,
    K: Into<String>,
    V: Into<String>,
{
    pairs
        .into_iter()
        .map(|(key, value)| (key.into(), value.into()))
        .collect()
}

/// 当前 Unix 毫秒时间戳(时钟异常时返回 0)。
pub fn now_millis() -> i64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as i64)
        .unwrap_or(0)
}

/// 用系统默认浏览器拉起一个地址(扫码二次验证窗口用)。
///
/// Windows 的 `start` 会把首个带引号参数当窗口标题,必须先垫一个空标题。
/// 只负责拉起不等待加载;失败时调用方提示用户手动复制地址。
pub fn open_system_browser(url: &str) -> std::io::Result<()> {
    use std::process::Command;

    #[cfg(target_os = "macos")]
    fn spawn(url: &str) -> std::process::Command {
        let mut command = Command::new("open");
        command.arg(url);
        command
    }
    #[cfg(windows)]
    fn spawn(url: &str) -> std::process::Command {
        let mut command = Command::new("cmd");
        command.args(["/C", "start", "", url]);
        command
    }
    #[cfg(all(unix, not(target_os = "macos")))]
    fn spawn(url: &str) -> std::process::Command {
        let mut command = Command::new("xdg-open");
        command.arg(url);
        command
    }

    let status = spawn(url).status()?;
    if !status.success() {
        let code = status.code().map(|c| c.to_string()).unwrap_or_default();
        return Err(std::io::Error::other(format!("打开浏览器失败（exit={code}）")));
    }
    Ok(())
}

/// 生成 v4 UUID(随机源直接读 `/dev/urandom`;读不到时退化为时间戳种子,
/// 保证形状合法)。零依赖实现,避免为此引入 `uuid`/`rand`。
pub fn random_uuid_v4() -> String {
    let mut bytes = [0u8; 16];
    let entropy = std::fs::File::open("/dev/urandom")
        .and_then(|mut file| {
            use std::io::Read;
            file.read_exact(&mut bytes).map(|_| ())
        })
        .is_ok();
    if !entropy {
        // 极端环境兜底:毫秒时间戳展宽到 16 字节,形状仍合法
        bytes.copy_from_slice(&(now_millis() as u128).to_le_bytes()[..16]);
    }
    // RFC 4122:版本 nibble=4,变体高两位=10
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex: String = bytes.iter().map(|byte| format!("{byte:02x}")).collect();
    [
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..32],
    ]
    .join("-")
}
