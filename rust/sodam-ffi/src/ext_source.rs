//! 外部音源的平台搜索数据源。
//!
//! 提供免签的 **kw（酷我）/ wy（网易云）/ kg（酷狗）/ tx（QQ）搜索**
//! （2026-10 Mac/手机出口实测可用）：
//! * 酷我：`http://search.kuwo.cn/r.s`（古老接口，免签；回包是 Python
//!   repr 风格的单引号伪 JSON，用正则逐字段抽取）；
//! * 网易云：`https://music.163.com/api/search/get`（legacy 免签）；
//! * 酷狗：`http://songsearch.kugou.com/song_search_v2`（老接口免签，
//!   songmid = FileHash）；
//! * QQ：`https://c.y.qq.com/soso/fcgi-bin/client_search_cp`（老接口，
//!   带 y.qq.com Referer 免签）。
//! * 咪咕（mg）老接口已 301 到 H5 页面（2026-10 实测），不支持。
//!
//! 另有 `platform_lyric`：kw/wy/kg/tx 四平台的免签歌词（统一 LRC 形态）。
//! `platform_chart_tracks`：kg/wy/tx 的免签**平台榜单**（首页按音源展示
//! 真实榜单的数据源；kw 无免签榜单，退化为关键词搜索）。
//!
//! 定位：lx 脚本只做 songmid→URL 转换，跨平台搜索由宿主（本模块）完成。
//! 原生酷我直连取流（anti.s convert_url）已移除——lx 脚本源已覆盖酷我，
//! 外部整曲统一走脚本链。

use serde_json::{json, Value};
use std::time::Duration;

const KUWO_SEARCH: &str = "http://search.kuwo.cn/r.s";

struct ExtTrack {
    rid: String,
    title: String,
    artist: String,
    duration_seconds: i64,
}

/// 每页条数（kw rn / wy limit 共用；也作为 hasMore 的满页判定基准）。
const PAGE_SIZE: i64 = 30;

fn http_options() -> Vec<crate::http::RequestOption> {
    vec![
        crate::http::RequestOption::new()
            .header(
                "User-Agent",
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_1_1 like Mac OS X) "
                    .to_string() + "AppleWebKit/605.1.15 (KHTML, like Gecko) "
                    + "Version/17.1 Mobile/15E148 Safari/604.1",
            )
            .timeout(Duration::from_secs(15)),
    ]
}

/// 酷我搜索（老接口免签；回包为 Python repr 单引号风格，正则抽字段）。
/// `page` 从 1 起：接口的 `pn` 是页号（0 基），`rn` 是页大小。
fn kuwo_search(keyword: &str, page: i64) -> Result<Vec<ExtTrack>, String> {
    let url = format!(
        "{KUWO_SEARCH}?all={}&ft=music&client=kt&cluster=0&rn={PAGE_SIZE}&pn={}\
         &itemset=web_2013&encoding=utf8&rformat=json",
        urlencode(keyword),
        (page - 1).max(0),
    );
    let raw = crate::http::get(&url, &http_options())
        .map_err(|err| format!("酷我搜索请求失败: {err}"))?;
    let text = String::from_utf8_lossy(&raw).to_string();
    if !text.contains("abslist") {
        return Err("酷我搜索响应异常（缺 abslist）".to_string());
    }
    Ok(parse_kuwo_response(&text))
}

/// 解析酷我 r.s 回包（Python repr 单引号风格，正则抽字段）。
/// 回包每条记录的字段按字母序排列（ARTIST → DURATION → MUSICRID →
/// SONGNAME）：顺序扫描累积再在下一个 MUSICRID 处落盘，会把每条的
/// ARTIST/DURATION 记到上一条头上（真机曾出现整列歌手错位一位、
/// 「孤勇者 / 旺仔小乔」此类张冠李戴，跨平台标题匹配随之失准）。
/// 改为先收集全部字段命中位置，再以 MUSICRID 为锚配对：歌手/时长
/// 取锚点窗口内最近的前置命中，歌名取锚点后最近的命中。
fn parse_kuwo_response(text: &str) -> Vec<ExtTrack> {
    let record_re = regex_lite(
        r"'MUSICRID'\s*:\s*'MUSIC_(\d+)'|'SONGNAME'\s*:\s*'([^']*)'|'ARTIST'\s*:\s*'([^']*)'|'DURATION'\s*:\s*'(\d+)'",
    );
    struct FieldHit {
        pos: usize,
        value: String,
    }
    let mut anchors: Vec<(usize, String)> = Vec::new();
    let mut titles: Vec<FieldHit> = Vec::new();
    let mut artists: Vec<FieldHit> = Vec::new();
    let mut durations: Vec<FieldHit> = Vec::new();
    for captures in record_re.captures_iter(&text) {
        let whole = captures.get(0).expect("alternation 必有整体命中");
        if let Some(rid) = captures.get(1) {
            anchors.push((whole.start(), rid.as_str().to_string()));
        } else if let Some(value) = captures.get(2) {
            titles.push(FieldHit {
                pos: whole.start(),
                value: value.as_str().to_string(),
            });
        } else if let Some(value) = captures.get(3) {
            artists.push(FieldHit {
                pos: whole.start(),
                value: value.as_str().to_string(),
            });
        } else if let Some(value) = captures.get(4) {
            durations.push(FieldHit {
                pos: whole.start(),
                value: value.as_str().to_string(),
            });
        }
    }
    let mut out = Vec::new();
    for (index, (pos, rid)) in anchors.iter().enumerate() {
        let next = anchors
            .get(index + 1)
            .map(|(next_pos, _)| *next_pos)
            .unwrap_or(usize::MAX);
        let prev = if index == 0 { 0 } else { anchors[index - 1].0 };
        let title = titles
            .iter()
            .find(|hit| hit.pos > *pos && hit.pos < next)
            .map(|hit| html_unescape(&hit.value))
            .unwrap_or_default();
        let artist = artists
            .iter()
            .rev()
            .find(|hit| hit.pos < *pos && hit.pos > prev)
            .map(|hit| html_unescape(&hit.value))
            .unwrap_or_default();
        let duration = durations
            .iter()
            .rev()
            .find(|hit| hit.pos < *pos && hit.pos > prev)
            .and_then(|hit| hit.value.parse().ok())
            .unwrap_or(0);
        out.push(ExtTrack {
            rid: rid.clone(),
            title,
            artist,
            duration_seconds: duration,
        });
    }
    out
}

/// 极简正则包装：编译失败视为无匹配（模式是常量，实际不会失败）。
fn regex_lite(pattern: &str) -> regex::Regex {
    regex::Regex::new(pattern).unwrap_or_else(|_| regex::Regex::new("^(?!)$").unwrap())
}

/// 酷我老接口回包是 HTML 转义过的（&nbsp; &amp; &#39; …，真机搜索
/// 实测标题形如「晴天&nbsp;(KTV版伴奏)」）：展示与匹配前解码。
fn html_unescape(text: &str) -> String {
    if !text.contains('&') {
        return text.to_string();
    }
    let named = text
        .replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">");
    // 数字实体 &#39; / &#x27; 形态
    let numeric = regex_lite(r"&#x([0-9a-fA-F]+);|&#(\d+);");
    numeric
        .replace_all(&named, |caps: &regex::Captures| {
            let code = caps
                .get(1)
                .and_then(|m| u32::from_str_radix(m.as_str(), 16).ok())
                .or_else(|| {
                    caps.get(2).and_then(|m| m.as_str().parse::<u32>().ok())
                });
            code.and_then(char::from_u32)
                .map(|ch| ch.to_string())
                .unwrap_or_default()
        })
        .into_owned()
}

fn urlencode(value: &str) -> String {
    let mut out = String::new();
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 酷我 r.s 回包解析（离线夹具，形态取自真机抓包）：字段按字母序
    /// 排列（ARTIST → DURATION → MUSICRID → SONGNAME），歌手/时长必须
    /// 与各自的 MUSICRID 正确配对——顺序扫描曾在真机上整列错位一位。
    #[test]
    fn kuwo_parse_pairs_fields_by_record() {
        let fixture = concat!(
            "{'ARTISTPIC':'','HIT':'3429','PN':'0','RN':'2','abslist':[",
            "{'AARTIST':'','ALBUM':'孤勇者','ARTIST':'陈奕迅','DURATION':'269',",
            "'MUSICRID':'MUSIC_198554068','NAME':'孤勇者','SONGNAME':'孤勇者'},",
            "{'AARTIST':'','ALBUM':'如愿','ARTIST':'王菲&nbsp;&amp;&nbsp;常石磊','DURATION':'256',",
            "'MUSICRID':'MUSIC_193290598','NAME':'如愿','SONGNAME':'如愿&nbsp;(电视剧主题曲)'}",
            "]}"
        );
        let tracks = parse_kuwo_response(fixture);
        assert_eq!(tracks.len(), 2, "两条记录都应解析出来");
        assert_eq!(tracks[0].rid, "198554068");
        assert_eq!(tracks[0].title, "孤勇者");
        assert_eq!(tracks[0].artist, "陈奕迅", "首条歌手不能再错拿下一行的");
        assert_eq!(tracks[0].duration_seconds, 269);
        assert_eq!(tracks[1].rid, "193290598");
        assert_eq!(tracks[1].title, "如愿 (电视剧主题曲)", "HTML 实体应解码");
        assert_eq!(tracks[1].artist, "王菲 & 常石磊", "末条歌手取自身窗口的前置命中");
        assert_eq!(tracks[1].duration_seconds, 256);
    }

    /// 真网络冒烟（Mac/手机网络均可）：平台搜索。
    #[test]
    #[ignore = "network"]
    fn platform_search_smoke() {
        let value = platform_search("kw", "周杰伦 晴天", 1).unwrap();
        let results = value["results"].as_array().unwrap();
        assert!(!results.is_empty(), "搜索应有结果");
        assert_eq!(value["hasMore"], true, "首页应满页可翻页");
        println!("kw 搜索 {} 条，首条: {}", results.len(), results[0]["title"]);

        // 歌手必须与歌名同条配对（字母序回包曾让每条歌手错位到下一行）。
        // 取「如愿 王菲」结果中「相约一九九八」一行：其真实歌手是
        // 那英&王菲——旧解析器会错拿下一行（因为爱情，陈奕迅&王菲），
        // 该断言必挂；修复后配对正确。
        let ru = platform_search("kw", "如愿 王菲", 1).unwrap();
        let rows = ru["results"].as_array().unwrap();
        let hit = rows.iter().find(|r| {
            r["title"]
                .as_str()
                .unwrap_or_default()
                .contains("相约一九九八")
        });
        let hit = hit.expect("搜「如愿 王菲」应含「相约一九九八」一行");
        let artist = hit["artist"].as_str().unwrap_or_default();
        assert!(
            artist.contains("那英"),
            "「相约一九九八」的歌手应含那英（拿到的是 {artist:?}）"
        );
    }

    /// 真网络冒烟：kg/tx 搜索 + 四平台歌词。
    #[test]
    #[ignore = "network"]
    fn platform_ext_smoke() {
        for platform in ["kg", "tx"] {
            let value = platform_search(platform, "周杰伦 晴天", 1).unwrap();
            let results = value["results"].as_array().unwrap();
            assert!(!results.is_empty(), "{platform} 搜索应有结果");
            let songmid = results[0]["songmid"].as_str().unwrap();
            println!("{platform} 首条: {} / {} (songmid={songmid})",
                results[0]["title"], results[0]["artist"]);
            let lyric = platform_lyric(platform, songmid);
            println!("{platform} 歌词: {:?}",
                lyric.as_ref().map(|v| {
                    let text = v["lyric"].as_str().unwrap_or_default();
                    format!("{} 字节, 首行 {:?}", text.len(), text.lines().next())
                }).map_err(|e| e.clone()));
        }
        // kw/wy 歌词（kw 用真实 rid）
        let kw = platform_search("kw", "晴天", 1).unwrap();
        let kw_mid = kw["results"][0]["songmid"].as_str().unwrap().to_string();
        println!("kw 歌词(mid={kw_mid}): {:?}",
            platform_lyric("kw", &kw_mid).map(|v| v["lyric"].as_str().unwrap_or_default().lines().count())
                .map_err(|e| e.clone()));
        let wy = platform_search("wy", "晴天", 1).unwrap();
        let wy_mid = wy["results"][0]["songmid"].as_str().unwrap().to_string();
        println!("wy 歌词: {:?}", platform_lyric("wy", &wy_mid).ok()
            .map(|v| v["lyric"].as_str().unwrap_or_default().lines().count()));
    }

    /// 真网络冒烟：kg/wy/tx 真榜单 + kw 关键词榜（chart_id=关键词）。
    #[test]
    #[ignore = "network"]
    fn platform_chart_smoke() {
        let cases = [
            ("kg", "8888", "酷狗 TOP500"),
            ("wy", "3778678", "网易云热歌榜"),
            ("tx", "26", "QQ 巅峰榜·热歌"),
            ("kw", "热门", "酷我关键词榜"),
        ];
        for (platform, chart_id, label) in cases {
            let value = match platform_chart_tracks(platform, chart_id, 1) {
                Ok(v) => v,
                Err(e) => {
                    println!("{label}: FAIL {e}");
                    continue;
                }
            };
            let results = value["results"].as_array().unwrap();
            println!(
                "{label}: {} 条 (hasMore={}), 首条: {} - {}",
                results.len(),
                value["hasMore"],
                results.first().and_then(|v| v["title"].as_str()).unwrap_or("?"),
                results.first().and_then(|v| v["artist"].as_str()).unwrap_or("?"),
            );
            assert!(!results.is_empty(), "{label} 榜单应有曲目");
        }
        // wy/tx 本地切片翻页：第 2 页应与第 1 页不同
        let page1 = platform_chart_tracks("wy", "3778678", 1).unwrap();
        let page2 = platform_chart_tracks("wy", "3778678", 2).unwrap();
        let t1 = page1["results"][0]["songmid"].as_str().unwrap_or("");
        let t2 = page2["results"][0]["songmid"].as_str().unwrap_or("");
        assert_ne!(t1, t2, "wy 榜单第 2 页应是不同曲目");
    }
}

// ---------------------------------------------------------------------------
// 平台搜索（lx 脚本只做 songmid→URL 转换，跨平台搜索由宿主完成）
// ---------------------------------------------------------------------------

/// 网易云搜索（legacy 免签接口）。`page` 从 1 起，映射为 offset。
fn wy_search(keyword: &str, page: i64) -> Result<Vec<ExtTrack>, String> {
    let url = format!(
        "https://music.163.com/api/search/get?s={}&type=1&limit={PAGE_SIZE}&offset={}",
        urlencode(keyword),
        ((page - 1).max(0)) * PAGE_SIZE,
    );
    let options = vec![crate::http::RequestOption::new()
        .header("Referer", "https://music.163.com")
        .header("User-Agent", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_1_1 like Mac OS X)")
        .timeout(Duration::from_secs(15))];
    let raw = crate::http::get(&url, &options)
        .map_err(|err| format!("网易云搜索请求失败: {err}"))?;
    let value: Value = serde_json::from_slice(&raw)
        .map_err(|err| format!("网易云搜索响应解析失败: {err}"))?;
    let songs = value
        .pointer("/result/songs")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut out = Vec::new();
    for song in songs {
        let id = song.get("id").and_then(Value::as_i64).unwrap_or(0);
        if id == 0 {
            continue;
        }
        let title = song
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let artist = song
            .pointer("/artists/0/name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let duration = song.get("duration").and_then(Value::as_i64).unwrap_or(0) / 1000;
        out.push(ExtTrack {
            rid: id.to_string(),
            title,
            artist,
            duration_seconds: duration,
        });
    }
    if out.is_empty() {
        return Err("网易云搜索无结果".to_string());
    }
    Ok(out)
}

/// 平台搜索统一入口：`{platform, results: [{songmid, title, artist,
/// durationSeconds}], hasMore}`（hasMore = 满页，Dart 侧据此决定翻页）。
pub fn platform_search(platform: &str, keyword: &str, page: i64) -> Result<Value, String> {
    if keyword.trim().is_empty() {
        return Err("搜索词为空".to_string());
    }
    let page = page.max(1);
    let results = match platform {
        "kw" => kuwo_search(keyword, page)?,
        "wy" => wy_search(keyword, page)?,
        "kg" => kugou_search(keyword, page)?,
        "tx" => qq_search(keyword, page)?,
        other => return Err(format!("平台 {other} 暂不支持搜索（需签名）")),
    };
    let has_more = results.len() as i64 >= PAGE_SIZE;
    let items: Vec<Value> = results
        .into_iter()
        .map(|ext| {
            json!({
                "songmid": ext.rid,
                "title": ext.title,
                "artist": ext.artist,
                "durationSeconds": ext.duration_seconds,
            })
        })
        .collect();
    Ok(json!({ "platform": platform, "results": items, "hasMore": has_more }))
}

/// 酷狗搜索（老接口免签；songmid = FileHash，取流脚本按 hash 出链）。
/// 回包 lists[] 字段为首字母大写（SongName/SingerName/Duration/FileHash），
/// SongName/SingerName 带 HTML 转义。
fn kugou_search(keyword: &str, page: i64) -> Result<Vec<ExtTrack>, String> {
    let url = format!(
        "http://songsearch.kugou.com/song_search_v2?keyword={}&page={page}&pagesize={PAGE_SIZE}",
        urlencode(keyword),
    );
    let raw = crate::http::get(&url, &http_options())
        .map_err(|err| format!("酷狗搜索请求失败: {err}"))?;
    let value: Value = serde_json::from_slice(&raw)
        .map_err(|err| format!("酷狗搜索响应解析失败: {err}"))?;
    let lists = value
        .pointer("/data/lists")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut out = Vec::new();
    for song in lists {
        let hash = song.get("FileHash").and_then(Value::as_str).unwrap_or_default();
        if hash.is_empty() {
            continue;
        }
        out.push(ExtTrack {
            rid: hash.to_uppercase(),
            title: html_unescape(song.get("SongName").and_then(Value::as_str).unwrap_or_default()),
            artist: html_unescape(
                song.get("SingerName").and_then(Value::as_str).unwrap_or_default(),
            ),
            duration_seconds: song.get("Duration").and_then(Value::as_i64).unwrap_or(0),
        });
    }
    if out.is_empty() {
        return Err("酷狗搜索无结果".to_string());
    }
    Ok(out)
}

/// QQ 音乐搜索（老接口免签，需 y.qq.com Referer；songmid 为 songmid 字段）。
fn qq_search(keyword: &str, page: i64) -> Result<Vec<ExtTrack>, String> {
    let url = format!(
        "https://c.y.qq.com/soso/fcgi-bin/client_search_cp?w={}&format=json\
         &p={page}&n={PAGE_SIZE}&cr=1&g_tk=5381",
        urlencode(keyword),
    );
    let options = vec![crate::http::RequestOption::new()
        .header("Referer", "https://y.qq.com")
        .header(
            "User-Agent",
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_1_1 like Mac OS X)",
        )
        .timeout(Duration::from_secs(15))];
    let raw = crate::http::get(&url, &options)
        .map_err(|err| format!("QQ 搜索请求失败: {err}"))?;
    let value: Value = serde_json::from_slice(&raw)
        .map_err(|err| format!("QQ 搜索响应解析失败: {err}"))?;
    let lists = value
        .pointer("/data/song/list")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut out = Vec::new();
    for song in lists {
        let songmid = song.get("songmid").and_then(Value::as_str).unwrap_or_default();
        if songmid.is_empty() {
            continue;
        }
        out.push(ExtTrack {
            rid: songmid.to_string(),
            title: html_unescape(song.get("songname").and_then(Value::as_str).unwrap_or_default()),
            artist: html_unescape(
                song.pointer("/singer/0/name")
                    .and_then(Value::as_str)
                    .unwrap_or_default(),
            ),
            duration_seconds: song.get("interval").and_then(Value::as_i64).unwrap_or(0),
        });
    }
    if out.is_empty() {
        return Err("QQ 搜索无结果".to_string());
    }
    Ok(out)
}

// ---------------------------------------------------------------------------
// 平台榜单（kg/wy/tx 免签真榜单；kw 无免签榜单接口，chart_id 即搜索关键词）
// ---------------------------------------------------------------------------

/// 平台榜单曲目（免签接口 2026-10 实测）：
/// * 酷狗：`http://mobilecdn.kugou.com/api/v3/rank/song?rankid=`（chart_id =
///   rankid，如 8888=TOP500；原生翻页；songmid = hash，与搜索同语义）；
/// * 网易云：`https://music.163.com/api/playlist/detail?id=`（榜单即官方
///   歌单，chart_id = 歌单 id，如 3778678=热歌榜；一次全量、App 侧切片）；
/// * QQ：`https://i.y.qq.com/v8/fcg-bin/fcg_v8_toplist_cp.fcg?topid=`
///   （chart_id = topid，如 26=巅峰榜·热歌；一次取 100 首、切片翻页）；
/// * 酷我：官方榜单接口全线加签（2026-10 实测），chart_id 退化为关键词，
///   直接复用 [kuwo_search]。
///
/// 回包与 [platform_search] 同形（`{platform, results, hasMore}`），
/// Dart 侧可零成本复用 Track 构造。
pub fn platform_chart_tracks(
    platform: &str,
    chart_id: &str,
    page: i64,
) -> Result<Value, String> {
    if chart_id.trim().is_empty() {
        return Err("榜单 id 为空".to_string());
    }
    let page = page.max(1);
    let (tracks, has_more) = match platform {
        "kg" => {
            let url = format!(
                "http://mobilecdn.kugou.com/api/v3/rank/song?apiver=4&rankid={chart_id}\
                 &page={page}&pagesize={PAGE_SIZE}",
            );
            let raw = crate::http::get(&url, &http_options())
                .map_err(|err| format!("酷狗榜单请求失败: {err}"))?;
            let value: Value = serde_json::from_slice(&raw)
                .map_err(|err| format!("酷狗榜单响应解析失败: {err}"))?;
            let total = value.pointer("/data/total").and_then(Value::as_i64).unwrap_or(0);
            let mut out = Vec::new();
            for song in value
                .pointer("/data/info")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default()
            {
                let hash = song.get("hash").and_then(Value::as_str).unwrap_or_default();
                if hash.is_empty() {
                    continue;
                }
                let artist = song
                    .pointer("/authors/0/author_name")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string();
                out.push(ExtTrack {
                    rid: hash.to_uppercase(),
                    title: html_unescape(
                        song.get("songname").and_then(Value::as_str).unwrap_or_default(),
                    ),
                    artist: html_unescape(&artist),
                    duration_seconds: song
                        .get("duration_high")
                        .or_else(|| song.get("duration"))
                        .and_then(Value::as_i64)
                        .unwrap_or(0),
                });
            }
            // 酷狗原生翻页：total 是榜单总量，未必全在本次回包里
            let has_more = !out.is_empty() && (page * PAGE_SIZE) < total;
            (out, has_more)
        }
        "wy" => {
            let url =
                format!("https://music.163.com/api/playlist/detail?id={chart_id}");
            let options = vec![crate::http::RequestOption::new()
                .header("Referer", "https://music.163.com")
                .header("User-Agent", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_1_1 like Mac OS X)")
                .timeout(Duration::from_secs(15))];
            let raw = crate::http::get(&url, &options)
                .map_err(|err| format!("网易云榜单请求失败: {err}"))?;
            let value: Value = serde_json::from_slice(&raw)
                .map_err(|err| format!("网易云榜单响应解析失败: {err}"))?;
            // 榜单即官方歌单：一次带回全量曲目（100~200 首），本地切片翻页
            chart_page(
                value
                    .pointer("/result/tracks")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default(),
                page,
                |song| ExtTrack {
                    rid: song.get("id").and_then(Value::as_i64).unwrap_or(0).to_string(),
                    title: song
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    artist: song
                        .pointer("/artists/0/name")
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string(),
                    // 网易云 duration 单位是毫秒
                    duration_seconds: song.get("duration").and_then(Value::as_i64).unwrap_or(0)
                        / 1000,
                },
            )
        }
        "tx" => {
            let url = format!(
                "https://i.y.qq.com/v8/fcg-bin/fcg_v8_toplist_cp.fcg?topid={chart_id}\
                 &type=top&song_num=100&format=json",
            );
            let options = vec![crate::http::RequestOption::new()
                .header("Referer", "https://y.qq.com")
                .header(
                    "User-Agent",
                    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_1_1 like Mac OS X)",
                )
                .timeout(Duration::from_secs(15))];
            let raw = crate::http::get(&url, &options)
                .map_err(|err| format!("QQ 榜单请求失败: {err}"))?;
            let value: Value = serde_json::from_slice(&raw)
                .map_err(|err| format!("QQ 榜单响应解析失败: {err}"))?;
            // 榜单全量一次取回（song_num=100 覆盖全部名次），本地切片翻页
            chart_page(
                value
                    .get("songlist")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default(),
                page,
                |song| {
                    let data = song.get("data").cloned().unwrap_or(Value::Null);
                    ExtTrack {
                        rid: data
                            .get("songmid")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string(),
                        title: html_unescape(
                            data.get("songname").and_then(Value::as_str).unwrap_or_default(),
                        ),
                        artist: data
                            .pointer("/singer/0/name")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string(),
                        duration_seconds: data.get("interval").and_then(Value::as_i64).unwrap_or(0),
                    }
                },
            )
        }
        "kw" => {
            // 酷我榜单接口需签名：chart_id 即关键词，榜单=搜索流
            let out = kuwo_search(chart_id, page)?;
            let has_more = out.len() as i64 >= PAGE_SIZE;
            (out, has_more)
        }
        other => return Err(format!("平台 {other} 暂不支持榜单")),
    };
    Ok(json!({
        "platform": platform,
        "chartId": chart_id,
        "results": tracks_to_json(tracks),
        "hasMore": has_more,
    }))
}

/// 一次全量接口的页切片：把 `songs` 按 [PAGE_SIZE] 切出第 `page` 页。
/// hasMore = 本地仍有剩余（wy/tx 的榜单曲目在一次回包里已取全）。
fn chart_page<F>(songs: Vec<Value>, page: i64, convert: F) -> (Vec<ExtTrack>, bool)
where
    F: Fn(Value) -> ExtTrack,
{
    let start = ((page - 1) * PAGE_SIZE).max(0) as usize;
    let end = (start + PAGE_SIZE as usize).min(songs.len());
    let out = if start >= songs.len() {
        Vec::new()
    } else {
        songs[start..end].iter().cloned().map(convert).collect()
    };
    (out, end < songs.len())
}

fn tracks_to_json(tracks: Vec<ExtTrack>) -> Vec<Value> {
    tracks
        .into_iter()
        .map(|ext| {
            json!({
                "songmid": ext.rid,
                "title": ext.title,
                "artist": ext.artist,
                "durationSeconds": ext.duration_seconds,
            })
        })
        .collect()
}

// ---------------------------------------------------------------------------
// 平台歌词（kw/wy/kg/tx 免签，统一输出 LRC 全文 + 可选翻译）
// ---------------------------------------------------------------------------

/// 平台歌词：`{platform, lyric, translation?}`。失败返回 Err（调用方按
/// 「暂无歌词」处理）。translation 仅网易云接口天然提供。
pub fn platform_lyric(platform: &str, songmid: &str) -> Result<Value, String> {
    if songmid.trim().is_empty() {
        return Err("songmid 为空".to_string());
    }
    match platform {
        "kw" => kuwo_lyric(songmid),
        "wy" => netease_lyric(songmid),
        "kg" => kugou_lyric(songmid),
        "tx" => qq_lyric(songmid),
        other => Err(format!("平台 {other} 暂不支持歌词")),
    }
}

/// 酷我歌词：`m.kuwo.cn/newh5/singles/songinfoandlrc`（免签），
/// lrclist[{lineLyric, time(秒)}] → 拼 LRC。
fn kuwo_lyric(songmid: &str) -> Result<Value, String> {
    let url = format!("http://m.kuwo.cn/newh5/singles/songinfoandlrc?musicId={songmid}");
    let raw = crate::http::get(&url, &http_options())
        .map_err(|err| format!("酷我歌词请求失败: {err}"))?;
    let value: Value = serde_json::from_slice(&raw)
        .map_err(|err| format!("酷我歌词响应解析失败: {err}"))?;
    let lines = value
        .pointer("/data/lrclist")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if lines.is_empty() {
        return Err("酷我歌词无内容".to_string());
    }
    let mut lrc = String::new();
    for line in lines {
        let text = line.get("lineLyric").and_then(Value::as_str).unwrap_or_default();
        let seconds = line
            .get("time")
            .and_then(|t| t.as_str().and_then(|s| s.parse::<f64>().ok()).or_else(|| t.as_f64()))
            .unwrap_or(0.0);
        lrc.push_str(&format!("[{:02}:{:05.2}]{}\n", (seconds as i64) / 60, seconds % 60.0, text));
    }
    Ok(json!({ "platform": "kw", "lyric": lrc }))
}

/// 网易云歌词：`music.163.com/api/song/lyric`（legacy 免签），
/// lrc.lyric 为 LRC 原文；tlyric.lyric 为翻译（若有）。
fn netease_lyric(songmid: &str) -> Result<Value, String> {
    let url = format!(
        "https://music.163.com/api/song/lyric?id={songmid}&lv=1&kv=1&tv=-1"
    );
    let options = vec![crate::http::RequestOption::new()
        .header("Referer", "https://music.163.com")
        .header("User-Agent", "Mozilla/5.0 (iPhone; CPU iPhone OS 17_1_1 like Mac OS X)")
        .timeout(Duration::from_secs(15))];
    let raw = crate::http::get(&url, &options)
        .map_err(|err| format!("网易云歌词请求失败: {err}"))?;
    let value: Value = serde_json::from_slice(&raw)
        .map_err(|err| format!("网易云歌词响应解析失败: {err}"))?;
    let lyric = value
        .pointer("/lrc/lyric")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    if lyric.trim().is_empty() {
        return Err("网易云歌词无内容".to_string());
    }
    let translation = value
        .pointer("/tlyric/lyric")
        .and_then(Value::as_str)
        .map(|text| text.to_string());
    Ok(json!({ "platform": "wy", "lyric": lyric, "translation": translation }))
}

/// 酷狗歌词（两步免签）：krcs search（hash → id+accesskey）→
/// lyrics download（fmt=lrc，content 为 base64 的 LRC）。
fn kugou_lyric(songmid: &str) -> Result<Value, String> {
    let search_url = format!(
        "http://krcs.kugou.com/search?ver=1&man=yes&client=mobi&keyword=&duration=&hash={songmid}"
    );
    let raw = crate::http::get(&search_url, &http_options())
        .map_err(|err| format!("酷狗歌词检索失败: {err}"))?;
    let value: Value = serde_json::from_slice(&raw)
        .map_err(|err| format!("酷狗歌词检索解析失败: {err}"))?;
    let candidate = value
        .pointer("/candidates/0")
        .cloned()
        .ok_or_else(|| "酷狗歌词无匹配".to_string())?;
    let id = candidate.get("id").and_then(Value::as_str).unwrap_or_default();
    let accesskey = candidate.get("accesskey").and_then(Value::as_str).unwrap_or_default();
    if id.is_empty() || accesskey.is_empty() {
        return Err("酷狗歌词凭证缺失".to_string());
    }
    let download_url = format!(
        "http://lyrics.kugou.com/download?ver=1&client=pc&id={id}&accesskey={accesskey}\
         &fmt=lrc&charset=utf8"
    );
    let raw = crate::http::get(&download_url, &http_options())
        .map_err(|err| format!("酷狗歌词下载失败: {err}"))?;
    let value: Value = serde_json::from_slice(&raw)
        .map_err(|err| format!("酷狗歌词下载解析失败: {err}"))?;
    let encoded = value.get("content").and_then(Value::as_str).unwrap_or_default();
    let decoded = base64::Engine::decode(&base64::engine::general_purpose::STANDARD, encoded)
        .map_err(|err| format!("酷狗歌词解码失败: {err}"))?;
    let lyric = String::from_utf8_lossy(&decoded).to_string();
    if lyric.trim().is_empty() {
        return Err("酷狗歌词无内容".to_string());
    }
    Ok(json!({ "platform": "kg", "lyric": lyric }))
}

/// QQ 歌词：`c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg`
/// （免签，nobase64=1 明文；内部换行为 \r\n 字面转义，还原成真换行）。
fn qq_lyric(songmid: &str) -> Result<Value, String> {
    let url = format!(
        "https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid={songmid}\
         &format=json&nobase64=1"
    );
    let options = vec![crate::http::RequestOption::new()
        .header("Referer", "https://y.qq.com")
        .header(
            "User-Agent",
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_1_1 like Mac OS X)",
        )
        .timeout(Duration::from_secs(15))];
    let raw = crate::http::get(&url, &options)
        .map_err(|err| format!("QQ 歌词请求失败: {err}"))?;
    let value: Value = serde_json::from_slice(&raw)
        .map_err(|err| format!("QQ 歌词响应解析失败: {err}"))?;
    let lyric = value
        .get("lyric")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .replace("\\r\\n", "\n")
        .replace("\\n", "\n");
    if lyric.trim().is_empty() {
        return Err("QQ 歌词无内容".to_string());
    }
    Ok(json!({ "platform": "tx", "lyric": lyric }))
}
