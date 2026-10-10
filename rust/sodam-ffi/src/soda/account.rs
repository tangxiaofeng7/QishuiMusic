//! 账号会员态探测(带会话级缓存)。
//!
//! 判定优先级:Cookie 缺失 → 非会员;`/luna/pc/me` 的账号自身标记 → 定论;
//! 两者都拿不到 → 用一首已知 VIP 曲目能否出整曲流兜底探测。

use super::quality::is_preview;
use super::types::{VIP_PROBE_TRACK_ID, VIP_PROBE_TRACK_URL};
use super::Soda;
use crate::error::Result;
use crate::model::{Song, SOURCE_SODA};

/// 当前 Cookie 是否具备会员权益;结果缓存在会话上,登录态变化时失效。
pub fn is_vip_account(soda: &Soda) -> Result<bool> {
    if let Some(cached) = soda.cached_vip() {
        return Ok(cached);
    }
    if !soda.has_cookie() {
        soda.set_cached_vip(false);
        return Ok(false);
    }

    // 首选账号自身标记:按"某首探测曲能否拿整流"判定会把 SVIP 误判成
    // 非会员(实测 is_vip=true 却探测失败),账号字段不受单曲可播性影响。
    if let Ok(me) = super::user_playlist::fetch_pc_me(soda) {
        let stage = me.my_info.vip_stage.trim().to_lowercase();
        let is_vip = me.my_info.is_vip || matches!(stage.as_str(), "vip" | "svip");
        soda.set_cached_vip(is_vip);
        return Ok(is_vip);
    }

    // 兜底:VIP 探针曲出流测试(完整流 = 会员,试听 = 非会员)
    let probe = Song {
        id: VIP_PROBE_TRACK_ID.to_string(),
        source: SOURCE_SODA.to_string(),
        link: VIP_PROBE_TRACK_URL.to_string(),
        extra: crate::util::extra_from_pairs([("track_id", VIP_PROBE_TRACK_ID)]),
        ..Default::default()
    };
    match super::download::get_download_info(soda, &probe) {
        Ok(info) => {
            let is_vip = !info.url.is_empty() && !is_preview(&info, 180);
            soda.set_cached_vip(is_vip);
            Ok(is_vip)
        }
        // 权益类错误按"非会员"落缓存,避免每首歌重复撞墙
        Err(err) if err.is_missing_entitlement() => {
            soda.set_cached_vip(false);
            Ok(false)
        }
        Err(err) => Err(err),
    }
}

impl Soda {
    /// 会员态探测(见 [`is_vip_account`])。
    pub fn is_vip_account(&self) -> Result<bool> {
        is_vip_account(self)
    }
}
