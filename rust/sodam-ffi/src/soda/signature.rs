//! 签名提供者:`msToken` / `a_bogus` / `bd-ticket-guard-*` / 应用签名头的注入点。
//!
//! 汽水/抖音的风控参数不由 JS 产出,客户端交给原生层(mssdk/bdticket)计算,
//! 纯 Rust 无法自算。这里提供四种接法:
//!
//! | 实现 | 场景 |
//! | --- | --- |
//! | [`NoopSignature`] | 默认:不签名(只吃公开接口) |
//! | [`CapturedSignature`] | 抓包回填(静态头,会过期) |
//! | [`HttpSignature`] | 远程签名服务(App 配置的 signerUrl 即此) |
//! | [`CommandSignature`] | 外部命令(mssdk 桥接 / SSH 到 Windows) |

use crate::error::{Result, SodaError};
use crate::util::now_millis;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::io::Write;
use std::path::Path;
use std::process::{Command, Stdio};

// ---------------------------------------------------------------------------
// 应用凭证(设备指纹 + 应用签名头)
// ---------------------------------------------------------------------------

/// 应用级凭证:URL 设备指纹参数 + `x-helios`/`x-medusa` 头。
///
/// 实测语义:App 端点(POST track_v2)不带这几个头时回 HTTP 200 + 空 body
/// (不是 4xx);Web 侧 a_bogus 代替不了它们。值只能从官方客户端真实请求
/// 抓取,与设备/会话绑定会过期——过期后 App 端点重新回空 body,
/// `check_stream_access` 会透出 pc_error,重抓即可。
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct AppCredentials {
    /// URL 参数 `device_id`(16 位数字,与官方客户端同格式)。
    #[serde(alias = "deviceId", alias = "DEVICE_ID")]
    pub device_id: String,
    /// URL 参数 `iid`(install id)。
    #[serde(alias = "install_id", alias = "installId", alias = "IID")]
    pub iid: String,
    /// URL 参数 `fp`(通常等于 device_id)。
    pub fp: String,
    /// 请求头 `x-helios`。
    #[serde(alias = "xHelios", alias = "X-Helios", alias = "helios")]
    pub x_helios: String,
    /// 请求头 `x-medusa`。
    #[serde(alias = "xMedusa", alias = "X-Medusa", alias = "medusa")]
    pub x_medusa: String,
    /// 抓包时的客户端 UA(空则用内置 PC UA)。
    #[serde(alias = "userAgent", alias = "ua")]
    pub user_agent: String,
}

impl AppCredentials {
    /// 设备指纹 + 两个签名头齐备(静态抓包形态可用)。
    pub fn is_complete(&self) -> bool {
        !self.device_id.trim().is_empty()
            && !self.x_helios.trim().is_empty()
            && !self.x_medusa.trim().is_empty()
    }

    /// 只有设备指纹——配合实时签名器的形态:签名现算,这里只需保证
    /// URL 的 device_id/iid/fp 与签名器一致。
    pub fn has_device_fingerprint(&self) -> bool {
        !self.device_id.trim().is_empty()
    }

    /// `fp` 缺省回落 device_id(官方两者通常一致)。
    pub fn fp_or_device_id(&self) -> String {
        let fp = self.fp.trim();
        if fp.is_empty() {
            self.device_id.trim().to_string()
        } else {
            fp.to_string()
        }
    }

    pub fn user_agent_or_default(&self) -> String {
        let ua = self.user_agent.trim();
        if ua.is_empty() {
            super::types::PC_APP_USER_AGENT.to_string()
        } else {
            ua.to_string()
        }
    }

    /// 应用签名请求头(空值跳过)。
    pub fn headers(&self) -> Vec<(&'static str, String)> {
        [
            ("x-helios", self.x_helios.trim()),
            ("x-medusa", self.x_medusa.trim()),
        ]
        .into_iter()
        .filter(|(_, value)| !value.is_empty())
        .map(|(name, value)| (name, value.to_string()))
        .collect()
    }

    /// 从 JSON 文本解析(字段名支持驼峰/大小写变体)。
    pub fn from_json(raw: &str) -> Result<Self> {
        serde_json::from_str(raw)
            .map_err(|err| SodaError::json(format!("app credentials json parse error: {err}")))
    }

    /// 从 JSON 文件解析。
    pub fn from_file(path: impl AsRef<Path>) -> Result<Self> {
        let path = path.as_ref();
        let raw = std::fs::read_to_string(path).map_err(|err| {
            SodaError::invalid_input(format!(
                "app credentials file {} read error: {err}",
                path.display()
            ))
        })?;
        Self::from_json(&raw)
    }

    /// 逐字段 trim(抓包结果里常见首尾空白与大小写变体)。
    pub fn normalized(mut self) -> Self {
        self.device_id = self.device_id.trim().to_string();
        self.iid = self.iid.trim().to_string();
        self.fp = self.fp.trim().to_string();
        self.x_helios = self.x_helios.trim().to_string();
        self.x_medusa = self.x_medusa.trim().to_string();
        self.user_agent = self.user_agent.trim().to_string();
        self
    }
}

// ---------------------------------------------------------------------------
// 签名契约
// ---------------------------------------------------------------------------

/// 一次签名请求的输入。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct SignRequest {
    pub url: String,
    pub method: String,
    pub body: String,
    pub ts_ms: i64,
    /// 这次请求**将要发送**的完整头集合。
    ///
    /// 应用签名覆盖「URL + 头」:签名器必须看到与实际发送一致的头,
    /// 尤其 cookie 与 x-ss-stub(body 的 MD5 大写),少一个即被判空响应。
    pub headers: BTreeMap<String, String>,
}

/// 签名结果;空字段忽略。
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct SignResponse {
    #[serde(alias = "msToken")]
    pub ms_token: String,
    #[serde(alias = "aBogus", alias = "a_bogus")]
    pub a_bogus: String,
    /// 额外头(bd-ticket-guard-* / x-tt-passport-trace-id / x-helios / x-medusa…)。
    pub headers: BTreeMap<String, String>,
}

impl SignResponse {
    pub fn is_empty(&self) -> bool {
        self.ms_token.is_empty() && self.a_bogus.is_empty() && self.headers.is_empty()
    }
}

/// 签名提供者抽象。
pub trait SignatureProvider: Send + Sync {
    /// 生成签名;出错返回 Err,调用方退化为不签名。
    fn sign(&self, request: &SignRequest) -> Result<SignResponse>;
    /// 诊断用名称。
    fn name(&self) -> &'static str;
}

/// 不签名(默认)。
#[derive(Debug, Clone, Copy, Default)]
pub struct NoopSignature;

impl SignatureProvider for NoopSignature {
    fn sign(&self, _request: &SignRequest) -> Result<SignResponse> {
        Ok(SignResponse::default())
    }
    fn name(&self) -> &'static str {
        "noop"
    }
}

/// 抓包回填:固定值原样携带。
#[derive(Debug, Clone, Default)]
pub struct CapturedSignature {
    pub ms_token: String,
    pub a_bogus: String,
    pub headers: BTreeMap<String, String>,
}

impl SignatureProvider for CapturedSignature {
    fn sign(&self, _request: &SignRequest) -> Result<SignResponse> {
        Ok(SignResponse {
            ms_token: self.ms_token.clone(),
            a_bogus: self.a_bogus.clone(),
            headers: self.headers.clone(),
        })
    }
    fn name(&self) -> &'static str {
        "captured"
    }
}

// ---------------------------------------------------------------------------
// 远程 HTTP 签名服务
// ---------------------------------------------------------------------------

/// 远程签名服务:x-helios/x-medusa 只能由原生组件(mssdk)产出,而它只有
/// Windows/macOS 版——把签名抽成独立服务,引擎经 HTTP 调用:
///
/// ```text
/// [App (任意平台)] --POST /sign--> [signer service (Win/mssdk 桥接)]
///                <-- {"headers":{"x-helios":"…","x-medusa":"…"}}
/// ```
///
/// 与 [`CommandSignature`] 共用同一份 JSON 契约,本地命令/SSH/HTTP 服务可互换;
/// 同时兼容 Meting-API 的 `{"ok":true,"X-Helios":"…"}` 扁平回包。
#[derive(Debug, Clone)]
pub struct HttpSignature {
    pub url: String,
    pub timeout_ms: u64,
    /// 附加请求头(如鉴权 Authorization)。
    pub headers: BTreeMap<String, String>,
}

impl HttpSignature {
    /// 默认 6s 超时:签名服务通常同局域网,超时即视为不可用。
    pub fn new(url: impl Into<String>) -> Self {
        Self {
            url: url.into(),
            timeout_ms: 6_000,
            headers: BTreeMap::new(),
        }
    }

    pub fn timeout_ms(mut self, timeout_ms: u64) -> Self {
        self.timeout_ms = timeout_ms;
        self
    }

    pub fn header(mut self, name: impl Into<String>, value: impl Into<String>) -> Self {
        self.headers.insert(name.into(), value.into());
        self
    }

    /// `Authorization: Bearer <token>`(空 token 忽略)。
    pub fn with_token(self, token: impl AsRef<str>) -> Self {
        let token = token.as_ref().trim();
        if token.is_empty() {
            return self;
        }
        self.header("Authorization", format!("Bearer {token}"))
    }

    /// 从环境变量创建:
    /// `QISHUI_SIGNER_URL`(必填,空值未配置)+ `QISHUI_SIGNER_TOKEN`(可选)。
    pub fn from_env() -> Option<Self> {
        let url = std::env::var("QISHUI_SIGNER_URL").ok()?.trim().to_string();
        if url.is_empty() {
            return None;
        }
        let token = std::env::var("QISHUI_SIGNER_TOKEN").unwrap_or_default();
        Some(Self::new(url).with_token(token))
    }

    /// 解析签名服务回包;兼容结构化与 Meting 扁平两种形态。
    pub fn parse_response(raw: &[u8]) -> Result<SignResponse> {
        let value: serde_json::Value = serde_json::from_slice(raw)
            .map_err(|err| SodaError::json(format!("signer response decode: {err}")))?;
        if value.get("ok").and_then(|ok| ok.as_bool()) == Some(false) {
            let message = value
                .get("error")
                .and_then(|error| error.as_str())
                .unwrap_or("签名服务返回失败");
            let code = value
                .get("code")
                .and_then(|code| code.as_str())
                .unwrap_or_default();
            // 鉴权失败给可操作提示(libmssdk 回 ok:false + code=unauthorized)
            let unauthorized = code.eq_ignore_ascii_case("unauthorized")
                || message.to_ascii_lowercase().contains("unauthorized")
                || message.contains("401");
            return Err(SodaError::http(if unauthorized {
                format!(
                    "signer error: {message}（签名服务要求鉴权：设置 QISHUI_SIGNER_TOKEN，\
                     或用 HttpSignature::new(url).with_token(..) / .header(\"Authorization\", ..)）"
                )
            } else {
                format!("signer error: {message}")
            }));
        }
        let mut response: SignResponse = serde_json::from_value(value.clone())
            .map_err(|err| SodaError::json(format!("signer response decode: {err}")))?;
        // 扁平形态:{"ok":true,"X-Helios":"…","X-Medusa":"…"}
        for (alias, canonical) in [
            ("X-Helios", "x-helios"),
            ("X-Medusa", "x-medusa"),
            ("x-helios", "x-helios"),
            ("x-medusa", "x-medusa"),
        ] {
            if let Some(text) = value
                .get(alias)
                .and_then(|item| item.as_str())
                .map(str::trim)
                .filter(|text| !text.is_empty())
            {
                response
                    .headers
                    .insert(canonical.to_string(), text.to_string());
            }
        }
        Ok(response)
    }
}

impl SignatureProvider for HttpSignature {
    fn sign(&self, request: &SignRequest) -> Result<SignResponse> {
        let payload = serde_json::to_vec(request)
            .map_err(|err| SodaError::json(format!("sign request encode: {err}")))?;
        let mut option = crate::http::RequestOption::new()
            .header("Content-Type", "application/json; charset=utf-8")
            .header("Accept", "application/json")
            .timeout(std::time::Duration::from_millis(self.timeout_ms));
        for (name, value) in &self.headers {
            option = option.header(name.clone(), value.clone());
        }
        let raw = crate::http::post_json(&self.url, &payload, &[option])?;
        Self::parse_response(&raw)
    }

    fn name(&self) -> &'static str {
        "http"
    }
}

// ---------------------------------------------------------------------------
// 外部命令签名
// ---------------------------------------------------------------------------

/// 子进程签名:stdin 喂 [`SignRequest`] JSON,stdout 收 [`SignResponse`] JSON。
///
/// 落点形态任意:Windows mssdk 桥接器 / `ssh win-box mssdk-bridge.exe` /
/// wine 下的小工具 / Frida 脚本。
#[derive(Debug, Clone)]
pub struct CommandSignature {
    pub program: String,
    pub args: Vec<String>,
    pub timeout_ms: u64,
}

impl CommandSignature {
    /// 默认 5s 超时。
    pub fn new(program: impl Into<String>) -> Self {
        Self {
            program: program.into(),
            args: Vec::new(),
            timeout_ms: 5_000,
        }
    }

    pub fn args<I, S>(mut self, args: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        self.args = args.into_iter().map(Into::into).collect();
        self
    }

    pub fn timeout_ms(mut self, timeout_ms: u64) -> Self {
        self.timeout_ms = timeout_ms;
        self
    }
}

impl SignatureProvider for CommandSignature {
    fn sign(&self, request: &SignRequest) -> Result<SignResponse> {
        let payload = serde_json::to_vec(request)
            .map_err(|err| SodaError::json(format!("sign request encode: {err}")))?;

        let mut child = Command::new(&self.program)
            .args(&self.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|err| SodaError::http(format!("signer spawn {}: {err}", self.program)))?;
        {
            let stdin = child
                .stdin
                .as_mut()
                .ok_or_else(|| SodaError::http("signer stdin unavailable"))?;
            stdin
                .write_all(&payload)
                .map_err(|err| SodaError::http(format!("signer stdin write: {err}")))?;
        }
        drop(child.stdin.take());
        let output = child
            .wait_with_output()
            .map_err(|err| SodaError::http(format!("signer wait: {err}")))?;
        if !output.status.success() {
            return Err(SodaError::http(format!(
                "signer exited with {}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr).trim()
            )));
        }
        serde_json::from_slice(&output.stdout)
            .map_err(|err| SodaError::json(format!("sign response decode: {err}")))
    }

    fn name(&self) -> &'static str {
        "command"
    }
}

// ---------------------------------------------------------------------------
// URL/请求签名应用
// ---------------------------------------------------------------------------

/// 把 `msToken`/`a_bogus` 追加到 URL 查询参数(原有参数保留)。
pub fn apply_signature_to_url(url: &str, response: &SignResponse) -> String {
    if response.ms_token.is_empty() && response.a_bogus.is_empty() {
        return url.to_string();
    }
    let mut params = crate::util::Params::from_pairs(parse_query_pairs(url));
    if !response.ms_token.is_empty() {
        params.set("msToken", response.ms_token.clone());
    }
    if !response.a_bogus.is_empty() {
        params.set("a_bogus", response.a_bogus.clone());
    }
    let base = url.split('?').next().unwrap_or(url);
    format!("{base}?{}", params.encode())
}

/// 拆出 URL 查询段为键值对(值做一次 unescape,失败保留原文)。
fn parse_query_pairs(url: &str) -> Vec<(String, String)> {
    let Some((_, query)) = url.split_once('?') else {
        return Vec::new();
    };
    let query = query.split('#').next().unwrap_or(query);
    query
        .split('&')
        .filter(|pair| !pair.is_empty())
        .map(|pair| {
            let (key, value) = pair.split_once('=').unwrap_or((pair, ""));
            (
                crate::util::query_unescape(key).unwrap_or_else(|| key.to_string()),
                crate::util::query_unescape(value).unwrap_or_else(|| value.to_string()),
            )
        })
        .collect()
}

/// 构造签名请求上下文(无头形态)。
pub fn sign_request(url: &str, method: &str, body: &str) -> SignRequest {
    SignRequest {
        url: url.to_string(),
        method: method.to_string(),
        body: body.to_string(),
        ts_ms: now_millis(),
        headers: BTreeMap::new(),
    }
}

/// 同上,但把"将要发送的头"一并交给签名器(取流场景必须)。
pub fn sign_request_with_headers(
    url: &str,
    method: &str,
    body: &str,
    headers: &[(String, String)],
) -> SignRequest {
    SignRequest {
        url: url.to_string(),
        method: method.to_string(),
        body: body.to_string(),
        ts_ms: now_millis(),
        headers: headers.iter().cloned().collect(),
    }
}

/// 取流请求的应用签名:签好后把返回头写回 options、URL 查询参数补 msToken/a_bogus。
///
/// 必须逐请求签:同一对 x-helios/x-medusa 换 body(哪怕只变 JSON 键序)或换
/// track_id,App 端点即回 0 字节;原样重放才通过。签名器不可用返回 `None`,
/// 调用方按"未签名"发出(服务端回空 body,上层给可读错误)。
pub(crate) fn apply_stream_signature(
    soda: &super::Soda,
    url: &str,
    body: &str,
    options: &mut Vec<crate::http::RequestOption>,
) -> Option<String> {
    let provider = soda.signature_provider()?;
    // 合并"这次真的要发出去的头"再交给签名器:汽水签名覆盖 URL+头,
    // 少 cookie/x-ss-stub 都会判空。
    let mut merged = crate::http::merge_options(options);
    let request = sign_request_with_headers(url, "POST", body, merged.headers());
    let response = provider.sign(&request).ok()?;
    if response.is_empty() {
        return None;
    }
    // 整体替换成签名后的头集合,调用方不必关心顺序
    for (name, value) in &response.headers {
        merged = merged.header(name.clone(), value.clone());
    }
    *options = vec![merged];
    match apply_signature_to_url(url, &response) {
        signed if signed == url => None,
        signed => Some(signed),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;

    #[test]
    fn stream_signature_injects_helios_and_medusa_headers() {
        let soda = super::super::Soda::new("sessionid_ss=test");
        let mut captured = CapturedSignature {
            ms_token: "token-value".to_string(),
            ..Default::default()
        };
        captured
            .headers
            .insert("x-helios".to_string(), "helios-from-bridge".to_string());
        captured
            .headers
            .insert("x-medusa".to_string(), "medusa-from-bridge".to_string());
        soda.set_signature_provider(Arc::new(captured));

        let mut options = vec![crate::http::RequestOption::new()
            .header("User-Agent", "LunaPC/3.8.0(467160162)")
            .header("Content-Type", "application/json; charset=utf-8")];
        let signed = apply_stream_signature(
            &soda,
            "https://api.qishui.com/luna/pc/track_v2?aid=386088",
            r#"{"track_id":"1","media_type":"track"}"#,
            &mut options,
        )
        .expect("签名器返回了参数，URL 应被改写");

        assert!(signed.contains("msToken=token-value"));
        assert!(signed.contains("aid=386088"), "原有查询参数不能被丢掉");
        let merged = crate::http::merge_options(&options);
        let names: Vec<String> = merged
            .headers()
            .iter()
            .map(|(name, _)| name.to_ascii_lowercase())
            .collect();
        assert!(names.contains(&"x-helios".to_string()));
        assert!(names.contains(&"x-medusa".to_string()));
        assert!(
            names.contains(&"user-agent".to_string()),
            "原有头不应被覆盖掉"
        );
    }

    #[test]
    fn stream_signature_without_provider_keeps_request_untouched() {
        let soda = super::super::Soda::new("sessionid_ss=test");
        let mut options =
            vec![crate::http::RequestOption::new().header("User-Agent", "LunaPC/3.8.0(467160162)")];
        let signed = apply_stream_signature(
            &soda,
            "https://api.qishui.com/luna/pc/track_v2?aid=386088",
            "{}",
            &mut options,
        );
        assert!(signed.is_none());
        assert_eq!(options.len(), 1);
    }
}
