//! 浏览器请求器:把 HTTP 请求交给一个跑着官方安全组件的页面执行。
//!
//! 页面内的请求桩(如 `window.__qishuiRequest`)会自动补 `a_bogus` 等
//! 签名参数并附加 `X-Helios` / `X-Medusa` 头——这些头只有页面上下文
//! 产得出来,所以请求必须由页面代发,本地直连必被拒。
//!
//! 序列化字段名(sessionKey / responseURL / ms_token…)是 Dart 侧签名桥
//! 的线上契约,不可改动。

use crate::error::{Result, SodaError};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
use std::io::Write;
use std::process::{Command, Stdio};

/// 交给浏览器页面执行的请求。
#[derive(Debug, Clone, Default, Serialize)]
pub struct BrowserRequest {
    /// 会话隔离键:一个二维码一个独立浏览器上下文(cookie jar + 设备身份),
    /// 共用上下文会被按设备限流;留空时签名服务退回旧的单上下文行为。
    #[serde(rename = "sessionKey", skip_serializing_if = "String::is_empty")]
    pub session_key: String,
    pub method: String,
    pub url: String,
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    pub headers: BTreeMap<String, String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    pub ms_token: String,
}

/// 页面执行后的结果。
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct BrowserResponse {
    #[serde(default)]
    pub ok: bool,
    pub status: u16,
    pub body: String,
    #[serde(rename = "responseURL", alias = "response_url")]
    pub response_url: String,
    pub headers: String,
    pub cookies: Vec<BrowserCookie>,
    #[serde(default)]
    pub error: String,
}

impl BrowserResponse {
    /// 浏览器上下文里的 Cookie → `name=value` 串列表(拼会话 Cookie 用)。
    pub fn cookie_pairs(&self) -> Vec<String> {
        self.cookies
            .iter()
            .filter(|cookie| !cookie.name.is_empty() && !cookie.value.is_empty())
            .map(|cookie| format!("{}={}", cookie.name, cookie.value))
            .collect()
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(default)]
pub struct BrowserCookie {
    pub name: String,
    pub value: String,
    pub domain: String,
}

/// 请求执行器抽象:不同宿主(App 内 WebView 签名桥 / 外部命令 / 桌面 CDP)
/// 各自实现。
pub trait BrowserRequester: Send + Sync {
    fn request(&self, request: &BrowserRequest) -> Result<BrowserResponse>;

    /// 关闭会话上下文;无会话语义的实现保持默认空操作。
    fn close_session(&self, _session_key: &str) -> Result<()> {
        Ok(())
    }

    /// 登记 2046 二次验证(扫码轮询触发):决策 JSON 原样给验证窗口,
    /// 网络请求经该 `session_key` 的上下文代发。默认不支持。
    fn register_second_verify(
        &self,
        _token: &str,
        _session_key: &str,
        _decision: &Value,
        _general_params: &Value,
    ) -> Result<()> {
        Err(SodaError::http(
            "当前签名服务不支持二次验证窗口，请改用官方客户端完成验证后导出 Cookie",
        ))
    }

    /// 二次验证窗口地址(系统浏览器打开,token 即能力凭证)。默认不支持。
    fn second_verify_url(&self, _token: &str) -> Result<String> {
        Err(SodaError::http(
            "当前签名服务不支持二次验证窗口，请改用官方客户端完成验证后导出 Cookie",
        ))
    }

    /// 在签名页浏览器里开**可见**验证窗口(同上下文,cookie/设备身份对齐,
    /// 无 CORS 缝隙)。默认不支持。
    fn open_second_verify_window(&self, _token: &str) -> Result<String> {
        Err(SodaError::http(
            "当前签名服务不支持在浏览器窗口中打开二次验证",
        ))
    }

    /// 验证是否已在窗口里完成(验证页回执置位)。
    fn second_verify_done(&self, _token: &str) -> bool {
        false
    }

    /// 消费完成标志(重发确认前调用,防同一回执触发多次重发)。
    fn ack_second_verify(&self, _token: &str) -> Result<()> {
        Ok(())
    }

    /// 登录结束/过期时清理登记。
    fn clear_second_verify(&self, _token: &str) -> Result<()> {
        Ok(())
    }

    fn name(&self) -> &'static str;
}

/// 外部命令式执行器:stdin 喂 JSON、stdout 收 JSON(对接本地签名 CLI)。
#[derive(Debug, Clone)]
pub struct CommandRequester {
    pub program: String,
    pub args: Vec<String>,
}

impl CommandRequester {
    pub fn new(program: impl Into<String>) -> Self {
        Self {
            program: program.into(),
            args: Vec::new(),
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

    /// 跑一次子进程:payload 进 stdin,stdout 全量返回。
    fn exec(&self, payload: &[u8]) -> Result<String> {
        let mut child = Command::new(&self.program)
            .args(&self.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|err| SodaError::http(format!("requester spawn {}: {err}", self.program)))?;
        {
            let stdin = child
                .stdin
                .as_mut()
                .ok_or_else(|| SodaError::http("requester stdin unavailable"))?;
            stdin
                .write_all(payload)
                .map_err(|err| SodaError::http(format!("requester stdin write: {err}")))?;
        }
        // 关闭我方 stdin 句柄,子进程读到 EOF 才会产出结果
        drop(child.stdin.take());
        let output = child
            .wait_with_output()
            .map_err(|err| SodaError::http(format!("requester wait: {err}")))?;
        Ok(String::from_utf8_lossy(&output.stdout).to_string())
    }
}

impl BrowserRequester for CommandRequester {
    fn request(&self, request: &BrowserRequest) -> Result<BrowserResponse> {
        let payload = serde_json::to_vec(request)
            .map_err(|err| SodaError::json(format!("browser request encode: {err}")))?;
        let text = self.exec(&payload)?;
        let parsed: BrowserResponse = serde_json::from_str(text.trim()).map_err(|err| {
            SodaError::json(format!(
                "requester 返回无法解析: {err}（输出: {}）",
                text.trim()
            ))
        })?;
        // ok=false 或"既无错误文案也无状态码"都视为没有拿到有效结果
        if !parsed.ok || (parsed.error.is_empty() && parsed.status == 0) {
            return Err(SodaError::http(if parsed.error.is_empty() {
                "签名服务未返回结果".to_string()
            } else {
                parsed.error.clone()
            }));
        }
        Ok(parsed)
    }

    fn close_session(&self, session_key: &str) -> Result<()> {
        if session_key.trim().is_empty() {
            return Ok(());
        }
        let payload = serde_json::json!({ "op": "close", "sessionKey": session_key });
        let text = self.exec(payload.to_string().as_bytes())?;
        let parsed: BrowserResponse = serde_json::from_str(text.trim())
            .map_err(|err| SodaError::json(format!("close session 返回无法解析: {err}")))?;
        if !parsed.ok {
            return Err(SodaError::http("签名服务关闭会话失败"));
        }
        Ok(())
    }

    fn name(&self) -> &'static str {
        "command-requester"
    }
}
