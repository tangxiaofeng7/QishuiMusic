//! 极简 HTTP 客户端封装(ureq 2.x)。
//!
//! 设计要点:
//! * 进程级共享 agent(连接池 keep-alive 复用):同一 host 的连续请求
//!   免掉重复 DNS/TCP/TLS 握手(移动网络下每次 1~3 个 RTT,歌单分页/
//!   取流梯子这类串行链路被握手时间放大是页面慢的最大单因,对齐官方
//!   客户端的持久连接行为);agent 级超时只是兜底,单请求预算仍由
//!   `request.timeout()` 显式覆盖(含响应体读取);
//! * 整次请求外加总预算线程(见 [`bounded`]):DNS 解析不受任何 ureq 超时
//!   管辖,弱网下 getaddrinfo 卡死同样会挂死调用方。
//!   以上两类挂死都会把 FFI 串行队列整体堵死(真机自检实测过的转圈根因),
//!   所以这里做了双保险。

use crate::error::{Result, SodaError};
use std::collections::BTreeMap;
use std::io::Read;
use std::sync::OnceLock;
use std::time::Duration;

/// 兜底 UA(桌面 Chrome);调用方一般都会覆盖。
pub const DEFAULT_USER_AGENT: &str =
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36";

/// 单请求默认超时:探测链是多个端点串行,单级 12s 才能把一次 prepare
/// 控制在秒级;大文件下载必须显式传更长的 timeout。
const DEFAULT_TIMEOUT: Duration = Duration::from_secs(12);

/// 进程级共享 agent:连接池跨请求复用(keep-alive),空闲连接按 host 保留。
fn shared_agent() -> &'static ureq::Agent {
    static AGENT: OnceLock<ureq::Agent> = OnceLock::new();
    AGENT.get_or_init(|| {
        ureq::AgentBuilder::new()
            // 兜底超时:正常路径每个请求都会用 request.timeout() 覆盖;
            // 这里只防"漏配"时把调用方挂死(与旧每请求 agent 行为一致)。
            .timeout_connect(DEFAULT_TIMEOUT)
            .timeout_read(Duration::from_secs(30))
            .timeout_write(DEFAULT_TIMEOUT)
            .max_idle_connections(16)
            .max_idle_connections_per_host(6)
            .build()
    })
}

/// 请求选项:头集合 + 超时,链式组装。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequestOption {
    headers: Vec<(String, String)>,
    timeout: Option<Duration>,
}

impl Default for RequestOption {
    fn default() -> Self {
        Self::new()
    }
}

impl RequestOption {
    pub fn new() -> Self {
        Self {
            headers: Vec::new(),
            timeout: None,
        }
    }

    /// 设置头(同名不区分大小写,后设覆盖先设)。
    pub fn header(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        let key = key.into();
        self.headers
            .retain(|(existing, _)| !existing.eq_ignore_ascii_case(&key));
        let value = value.into();
        self.headers.push((key, value));
        self
    }

    /// 设置 Cookie 头;空白串视作未登录,不加头。
    pub fn cookie(self, cookie: &str) -> Self {
        let cookie = cookie.trim();
        if cookie.is_empty() {
            self
        } else {
            self.header("Cookie", cookie.to_string())
        }
    }

    pub fn timeout(mut self, timeout: Duration) -> Self {
        self.timeout = Some(timeout);
        self
    }

    pub fn headers(&self) -> &[(String, String)] {
        &self.headers
    }

    pub fn timeout_value(&self) -> Duration {
        self.timeout.unwrap_or(DEFAULT_TIMEOUT)
    }
}

/// 合并多个选项:头后者覆盖前者,超时取最后出现的非空值。
pub fn merge_options(options: &[RequestOption]) -> RequestOption {
    let mut merged = RequestOption::new();
    for option in options {
        for (key, value) in option.headers() {
            merged = merged.header(key.clone(), value.clone());
        }
        if let Some(timeout) = option.timeout {
            merged.timeout = Some(timeout);
        }
    }
    merged
}

/// 请求总预算执行器:工作搬到独立线程,主线程限时等待。
///
/// 预算比请求自身超时多 5s 缓冲,让 ureq 的错误信息(更具体)优先冒出来;
/// 只有连 DNS 都卡死的极端场景才轮到这里的兜底文案。超时后工作线程被
/// 弃置(泄漏),仅在网络栈异常时刻发生,可接受。
fn bounded<T, F>(deadline: Duration, work: F) -> Result<T>
where
    T: Send + 'static,
    F: FnOnce() -> Result<T> + Send + 'static,
{
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(work());
    });
    rx.recv_timeout(deadline + Duration::from_secs(5)).unwrap_or_else(|_| {
        Err(SodaError::http(format!(
            "请求总预算 {deadline:?} 超时（含 DNS/建连/读响应体）"
        )))
    })
}

/// HTTP 响应快照:状态码、重定向后的最终地址、响应体、Set-Cookie 集合。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HttpResponse {
    pub status: u16,
    pub final_url: String,
    pub body: Vec<u8>,
    pub cookies: BTreeMap<String, String>,
}

impl HttpResponse {
    pub fn body_text(&self) -> String {
        String::from_utf8_lossy(&self.body).to_string()
    }
}

/// GET(保留最终 URL,分享页解析需要重定向后的地址)。
pub fn get_full(url: &str, options: &[RequestOption]) -> Result<HttpResponse> {
    execute("GET", url.to_string(), None, options)
}

/// GET(只要响应体)。
pub fn get(url: &str, options: &[RequestOption]) -> Result<Vec<u8>> {
    Ok(get_full(url, options)?.body)
}

/// POST JSON(只要响应体)。
pub fn post_json(url: &str, body: &[u8], options: &[RequestOption]) -> Result<Vec<u8>> {
    Ok(post_bytes(url, body, options)?.body)
}

/// POST(完整响应,passport 登录链路要吃 Set-Cookie)。
pub fn post_bytes(url: &str, body: &[u8], options: &[RequestOption]) -> Result<HttpResponse> {
    execute("POST", url.to_string(), Some(body.to_vec()), options)
}

/// GET/POST 共用执行路径,在线程内完成建连与收包。
fn execute(
    method: &'static str,
    url: String,
    payload: Option<Vec<u8>>,
    options: &[RequestOption],
) -> Result<HttpResponse> {
    let merged = merge_options(options);
    let timeout = merged.timeout_value();
    bounded(timeout, move || {
        let mut request = shared_agent()
            .request(method, &url)
            // 单请求总预算(建连→响应头→响应体),覆盖 agent 兜底超时
            .timeout(timeout)
            .set("User-Agent", DEFAULT_USER_AGENT);
        for (key, value) in merged.headers() {
            request = request.set(key, value);
        }
        // 非 2xx 时 ureq 返回 Status 错误,统一转成带状态码的 Http 错误
        let response = match payload {
            Some(body) => request.send_bytes(&body),
            None => request.call(),
        }
        .map_err(|err| match err {
            ureq::Error::Status(status, response) => {
                let final_url = response.get_url().to_string();
                SodaError::http(format!("http request failed: status {status} ({final_url})"))
            }
            other => SodaError::http(other.to_string()),
        })?;

        let status = response.status();
        let final_url = response.get_url().to_string();
        let cookies = collect_cookies(&response);
        let mut body = Vec::new();
        response
            .into_reader()
            .read_to_end(&mut body)
            .map_err(|err| SodaError::http(err.to_string()))?;
        Ok(HttpResponse {
            status,
            final_url,
            body,
            cookies,
        })
    })
}

/// 汇总响应里全部 `Set-Cookie` 的名值对(属性段丢弃)。
fn collect_cookies(response: &ureq::Response) -> BTreeMap<String, String> {
    response
        .all("Set-Cookie")
        .iter()
        .filter_map(|raw| parse_set_cookie(raw))
        .collect()
}

/// `name=value; Path=/; ...` → `(name, value)`。
fn parse_set_cookie(raw: &str) -> Option<(String, String)> {
    let head = raw.split(';').next()?.trim();
    let (name, value) = head.split_once('=')?;
    let (name, value) = (name.trim(), value.trim());
    if name.is_empty() || value.is_empty() {
        return None;
    }
    Some((name.to_string(), value.to_string()))
}
