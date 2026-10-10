//! 汽水音频解密:`play_auth`(spade)密钥还原 + MP4/CENC 样本解密。
//!
//! 解密算法的算式与位运算顺序不可改动(密文格式决定),这里的"重写"
//! 体现在结构:box 遍历/解析器拆成独立小函数,防御上限集中定义。

use crate::error::{Result, SodaError};
use crate::util::bitcount;
use aes::cipher::{KeyIvInit, StreamCipher};
use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use base64::Engine;

type Aes128Ctr = ctr::Ctr128BE<aes::Aes128>;

const AES_BLOCK_SIZE: usize = 16;

/// 单个 box 允许的最大样本条目数。
///
/// MP4 头里的 sample_count 是 32 位字段,损坏文件可声明约 43 亿条,
/// 直接预分配会申请十几 GB(实测触发 OOM)。正常音频即使数小时也只有
/// 几万条,4M 极其宽裕。
const MAX_SAMPLE_ENTRIES: usize = 4 * 1024 * 1024;

/// MP4 box 视图:相对整个文件的偏移/尺寸 + 内容切片(去掉头之后)。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Mp4Box<'a> {
    pub offset: usize,
    pub size: usize,
    pub data: &'a [u8],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SencSubsample {
    pub clear: u16,
    pub encrypted: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SencSample {
    pub iv: Vec<u8>,
    pub subsamples: Vec<SencSubsample>,
}

fn read_u32_be(data: &[u8], at: usize) -> usize {
    u32::from_be_bytes([data[at], data[at + 1], data[at + 2], data[at + 3]]) as usize
}

/// 整文件解密:`play_auth` → AES 密钥 → 按 senc 样本解密 mdat。
pub fn decrypt_audio(file_data: &[u8], play_auth: &str) -> Result<Vec<u8>> {
    let hex_key = extract_key(play_auth)?;
    let key_bytes = hex_decode(&hex_key).ok_or_else(|| SodaError::crypto("invalid hex key"))?;
    decrypt_audio_with_key(file_data, &key_bytes)
}

/// 同 [`decrypt_audio`],但直接给 16 字节 AES 密钥(已解过密钥或测试场景)。
pub fn decrypt_audio_with_key(file_data: &[u8], key_bytes: &[u8]) -> Result<Vec<u8>> {
    if key_bytes.len() != 16 {
        return Err(SodaError::crypto("invalid aes key length"));
    }
    let data = file_data;
    let moov = find_box(data, b"moov", 0, data.len())
        .ok_or_else(|| SodaError::crypto("moov box not found"))?;
    let stbl = locate_stbl(data, moov).ok_or_else(|| SodaError::crypto("stbl box not found"))?;
    let stsz = find_box(data, b"stsz", stbl.offset + 8, stbl.offset + stbl.size)
        .ok_or_else(|| SodaError::crypto("stsz box not found"))?;
    let sample_sizes = parse_stsz(stsz.data);

    // senc 可挂在 moov 下或 stbl 下,两处都找
    let senc = find_box(data, b"senc", moov.offset + 8, moov.offset + moov.size)
        .or_else(|| find_box(data, b"senc", stbl.offset + 8, stbl.offset + stbl.size))
        .ok_or_else(|| SodaError::crypto("senc box not found"))?;
    let iv_size = default_per_sample_iv_size(data, stbl.offset, stbl.offset + stbl.size);
    let senc_samples = parse_senc(senc.data, iv_size);

    let mdat = find_box(data, b"mdat", 0, data.len())
        .ok_or_else(|| SodaError::crypto("mdat box not found"))?;

    // 逐样本过 mdat:有 senc 描述的样本解密,其余原样拷贝
    let mut decrypted_data = data.to_vec();
    let mut read_ptr = mdat.offset + 8;
    // mdat 尺寸同样来自文件头,不信任:预分配以真实文件长度为上限
    let mdat_capacity = mdat.size.saturating_sub(8).min(data.len());
    let mut decrypted_mdat: Vec<u8> = Vec::with_capacity(mdat_capacity);
    for (index, size) in sample_sizes.iter().enumerate() {
        let size = *size as usize;
        if read_ptr + size > decrypted_data.len() {
            break;
        }
        let chunk = &decrypted_data[read_ptr..read_ptr + size];
        match senc_samples.get(index) {
            Some(sample) => decrypted_mdat.extend_from_slice(&decrypt_senc_sample(key_bytes, chunk, sample)),
            None => decrypted_mdat.extend_from_slice(chunk),
        }
        read_ptr += size;
    }

    // 长度校验:解密不改变样本排布,总长必须精确等于 mdat 载荷长
    if decrypted_mdat.len() == mdat.size - 8 {
        let start = mdat.offset + 8;
        decrypted_data[start..start + decrypted_mdat.len()].copy_from_slice(&decrypted_mdat);
    } else {
        return Err(SodaError::crypto("decrypted size mismatch"));
    }

    // stsd 里的 `enca` 还原成 frma 指向的原始格式 4CC(播放器才能识别)
    if let Some(stsd) = find_box(data, b"stsd", stbl.offset + 8, stbl.offset + stbl.size) {
        patch_enca_to_original_format(&mut decrypted_data, stsd.offset, stsd.offset + stsd.size);
    }
    Ok(decrypted_data)
}

/// stbl 定位:先在 moov 直下找,退化路径逐层下钻(moov→trak→mdia→minf→stbl)。
fn locate_stbl<'a>(data: &'a [u8], moov: Mp4Box<'a>) -> Option<Mp4Box<'a>> {
    if let Some(direct) = find_box(data, b"stbl", moov.offset, moov.offset + moov.size) {
        return Some(direct);
    }
    let trak = find_box(data, b"trak", moov.offset + 8, moov.offset + moov.size)?;
    let mdia = find_box(data, b"mdia", trak.offset + 8, trak.offset + trak.size)?;
    let minf = find_box(data, b"minf", mdia.offset + 8, mdia.offset + mdia.size)?;
    find_box(data, b"stbl", minf.offset + 8, minf.offset + minf.size)
}

/// 把 stsd 段内的 `enca` 四字符替换成原始格式四字符。
fn patch_enca_to_original_format(data: &mut [u8], start: usize, end: usize) {
    let Some(index) = find_subslice(&data[start..end], b"enca") else {
        return;
    };
    let original = encrypted_sample_original_format(&data[start..end]);
    let target = start + index;
    if target + 4 <= data.len() {
        data[target..target + 4].copy_from_slice(&original);
    }
}

/// `frma` box 里读原始格式;box 缺失/越界一律退 `mp4a`。
pub fn encrypted_sample_original_format(stsd_data: &[u8]) -> [u8; 4] {
    let Some(idx) = find_subslice(stsd_data, b"frma") else {
        return *b"mp4a";
    };
    if idx < 4 || idx + 8 > stsd_data.len() {
        return *b"mp4a";
    }
    let box_size = read_u32_be(stsd_data, idx - 4);
    if box_size < 12 || idx - 4 + box_size > stsd_data.len() {
        return *b"mp4a";
    }
    [
        stsd_data[idx + 4],
        stsd_data[idx + 5],
        stsd_data[idx + 6],
        stsd_data[idx + 7],
    ]
}

/// tenc box 声明的每样本 IV 长度;默认 8,只认 8/16。
pub fn default_per_sample_iv_size(data: &[u8], start: usize, end: usize) -> usize {
    match find_box_deep(data, b"tenc", start, end) {
        Some(tenc) if tenc.data.len() >= 8 => match tenc.data[7] as usize {
            size @ (8 | 16) => size,
            _ => 8,
        },
        _ => 8,
    }
}

/// 单样本解密:无 subsample 时整块 CTR;有则明文段直通、密文段 CTR。
pub fn decrypt_senc_sample(key: &[u8], chunk: &[u8], sample: &SencSample) -> Vec<u8> {
    // IV 不足 16 字节时右侧补零
    let mut iv = [0u8; AES_BLOCK_SIZE];
    let copy_len = sample.iv.len().min(AES_BLOCK_SIZE);
    iv[..copy_len].copy_from_slice(&sample.iv[..copy_len]);
    let mut cipher = Aes128Ctr::new(key.into(), (&iv).into());

    let mut dst = chunk.to_vec();
    if sample.subsamples.is_empty() {
        cipher.apply_keystream(&mut dst);
        return dst;
    }

    let mut pos = 0usize;
    for sub in &sample.subsamples {
        // 明文段:保持原样
        let clear_bytes = (sub.clear as usize).min(chunk.len().saturating_sub(pos));
        dst[pos..pos + clear_bytes].copy_from_slice(&chunk[pos..pos + clear_bytes]);
        pos += clear_bytes;
        if pos >= chunk.len() {
            return dst;
        }
        // 密文段:CTR 解密
        let encrypted_bytes = (sub.encrypted as usize).min(chunk.len().saturating_sub(pos));
        cipher.apply_keystream(&mut dst[pos..pos + encrypted_bytes]);
        pos += encrypted_bytes;
        if pos >= chunk.len() {
            return dst;
        }
    }
    // 描述覆盖不满整块时,尾巴原样保留
    if pos < chunk.len() {
        dst[pos..].copy_from_slice(&chunk[pos..]);
    }
    dst
}

/// 同层查找 box:`[start, end)` 内按 size 步进,命中返回视图。
pub fn find_box<'a>(
    data: &'a [u8],
    box_type: &[u8; 4],
    start: usize,
    end: usize,
) -> Option<Mp4Box<'a>> {
    let end = end.min(data.len());
    let mut pos = start;
    while pos + 8 <= end {
        let size = read_u32_be(data, pos);
        if size < 8 {
            break;
        }
        if &data[pos + 4..pos + 8] == box_type {
            let box_end = (pos + size).min(data.len());
            return Some(Mp4Box {
                offset: pos,
                size,
                data: &data[pos + 8..box_end],
            });
        }
        pos += size;
    }
    None
}

/// 递归查找 box:进入已知容器(支持 largesize=1 的 64 位长度形态)。
pub fn find_box_deep<'a>(
    data: &'a [u8],
    box_type: &[u8; 4],
    start: usize,
    end: usize,
) -> Option<Mp4Box<'a>> {
    let end = end.min(data.len());
    let mut pos = start;
    while pos + 8 <= end {
        let mut size = read_u32_be(data, pos);
        let mut header_size = 8usize;
        if size == 1 {
            // largesize 形态:8 字节头 + 8 字节 64 位长度
            if pos + 16 > end {
                break;
            }
            let mut bytes = [0u8; 8];
            bytes.copy_from_slice(&data[pos + 8..pos + 16]);
            let size64 = u64::from_be_bytes(bytes);
            if size64 > (end - pos) as u64 {
                break;
            }
            size = size64 as usize;
            header_size = 16;
        }
        if size < header_size || pos + size > end {
            break;
        }
        let current_type = &data[pos + 4..pos + 8];
        if current_type == box_type {
            return Some(Mp4Box {
                offset: pos,
                size,
                data: &data[pos + header_size..pos + size],
            });
        }
        // 容器 box 才递归下钻
        if let Some(child_start) = box_child_start(current_type, pos, header_size) {
            if child_start < pos + size {
                if let Some(found) = find_box_deep(data, box_type, child_start, pos + size) {
                    return Some(found);
                }
            }
        }
        pos += size;
    }
    None
}

/// 哪些 box 装子 box,以及子 box 相对偏移(纯容器=头后即子;stsd 多 8 字节
/// 版本/条目数;音频采样 entry 多 28 字节固定字段)。
pub fn box_child_start(box_type: &[u8], offset: usize, header_size: usize) -> Option<usize> {
    match box_type {
        b"moov" | b"trak" | b"mdia" | b"minf" | b"stbl" | b"sinf" | b"schi" => {
            Some(offset + header_size)
        }
        b"stsd" => Some(offset + header_size + 8),
        b"enca" | b"mp4a" | b"alac" | b"fLaC" => Some(offset + header_size + 28),
        _ => None,
    }
}

/// stsz(样本尺寸表):定长形态展开成等值数组;变长形态逐条读。
///
/// 不信任头部声明的 count:变长按"实际可读条数"封顶,定长用硬上限
/// (此时不读表,仅控制展开量)。
pub fn parse_stsz(data: &[u8]) -> Vec<u32> {
    if data.len() < 12 {
        return Vec::new();
    }
    let fixed = read_u32_be(data, 4);
    let declared = read_u32_be(data, 8);
    let count = if fixed != 0 {
        declared.min(MAX_SAMPLE_ENTRIES)
    } else {
        let readable = data.len().saturating_sub(12) / 4;
        declared.min(readable).min(MAX_SAMPLE_ENTRIES)
    };
    let mut sizes = vec![0u32; count];
    if fixed != 0 {
        sizes.fill(fixed as u32);
    } else {
        for (index, slot) in sizes.iter_mut().enumerate() {
            let start = 12 + index * 4;
            if start + 4 <= data.len() {
                *slot = read_u32_be(data, start) as u32;
            }
        }
    }
    sizes
}

/// senc(CENC 样本描述):flags 带 0x02 表示有 subsample 划分。
///
/// count 同样不信任:按"每样本最少字节数"(iv + 可选 2 字节计数)夹到
/// 实际数据可容纳的范围,再套硬上限。
pub fn parse_senc(data: &[u8], iv_size: usize) -> Vec<SencSample> {
    if data.len() < 8 {
        return Vec::new();
    }
    let iv_size = match iv_size {
        8 | 16 => iv_size,
        _ => 8,
    };
    let flags = read_u32_be(data, 0) & 0x00FF_FFFF;
    let has_subsamples = (flags & 0x02) != 0;
    let declared = read_u32_be(data, 4);
    let per_sample = if has_subsamples { iv_size + 2 } else { iv_size };
    let max_by_data = data.len().saturating_sub(8) / per_sample.max(1);
    let sample_count = declared.min(max_by_data).min(MAX_SAMPLE_ENTRIES);

    let mut samples = Vec::with_capacity(sample_count);
    let mut ptr = 8usize;
    for _ in 0..sample_count {
        if ptr + iv_size > data.len() {
            break;
        }
        let mut sample = SencSample {
            iv: data[ptr..ptr + iv_size].to_vec(),
            subsamples: Vec::new(),
        };
        ptr += iv_size;
        if has_subsamples {
            if ptr + 2 > data.len() {
                break;
            }
            let sub_count = u16::from_be_bytes([data[ptr], data[ptr + 1]]) as usize;
            ptr += 2;
            if ptr + sub_count * 6 > data.len() {
                break;
            }
            for _ in 0..sub_count {
                sample.subsamples.push(SencSubsample {
                    clear: u16::from_be_bytes([data[ptr], data[ptr + 1]]),
                    encrypted: u32::from_be_bytes([
                        data[ptr + 2],
                        data[ptr + 3],
                        data[ptr + 4],
                        data[ptr + 5],
                    ]),
                });
                ptr += 6;
            }
        }
        samples.push(sample);
    }
    samples
}

/// Base36 单字符解码;非法字符 0xFF。
pub fn decode_base36(byte: u8) -> u8 {
    match byte {
        b'0'..=b'9' => byte - b'0',
        b'a'..=b'z' => byte - b'a' + 10,
        _ => 0xFF,
    }
}

/// spade 内层变换:前缀 {0xFA,0x55} 与密钥错位异或,再减位计数与常数,
/// 负值绕回 255。
pub fn decrypt_spade_inner(key_bytes: &[u8]) -> Vec<u8> {
    let mut buff = Vec::with_capacity(key_bytes.len() + 2);
    buff.push(0xFA);
    buff.push(0x55);
    buff.extend_from_slice(key_bytes);

    key_bytes
        .iter()
        .enumerate()
        .map(|(index, &byte)| {
            let mut value = (byte ^ buff[index]) as i32 - bitcount(index as u32) as i32 - 21;
            while value < 0 {
                value += 255;
            }
            value as u8
        })
        .collect()
}

/// `play_auth` → 十六进制 AES 密钥:base64 → 去头/尾衬垫 → spade 内层 → 截取。
pub fn extract_key(play_auth: &str) -> Result<String> {
    let bytes_data = BASE64_STANDARD
        .decode(play_auth.trim())
        .map_err(|err| SodaError::crypto(format!("base64 decode failed: {err}")))?;
    if bytes_data.len() < 3 {
        return Err(SodaError::crypto("auth data too short"));
    }

    // 尾部衬垫长度藏在头三个字节的异或里(-48 校准)
    let padding_len = (bytes_data[0] ^ bytes_data[1] ^ bytes_data[2]) as i32 - 48;
    if padding_len < 0 {
        return Err(SodaError::crypto("invalid padding length"));
    }
    let padding_len = padding_len as usize;
    if bytes_data.len() < padding_len + 2 {
        return Err(SodaError::crypto("invalid padding length"));
    }

    // 去掉首字节与尾部衬垫后做 spade 内层变换
    let inner_input = &bytes_data[1..bytes_data.len() - padding_len];
    let tmp_buff = decrypt_spade_inner(inner_input);
    if tmp_buff.is_empty() {
        return Err(SodaError::crypto("decryption failed"));
    }

    // 首字符 base36 值 = 起始噪声长度,据此截出有效区间
    let skip_bytes = decode_base36(tmp_buff[0]) as usize;
    let end_index = 1 + (bytes_data.len() - padding_len - 2) - skip_bytes;
    if end_index > tmp_buff.len() || end_index < 1 {
        return Err(SodaError::crypto("index out of bounds"));
    }
    Ok(String::from_utf8_lossy(&tmp_buff[1..end_index]).to_string())
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || haystack.len() < needle.len() {
        return None;
    }
    haystack
        .windows(needle.len())
        .position(|window| window == needle)
}

/// 十六进制解码(零依赖实现)。
pub fn hex_decode(value: &str) -> Option<Vec<u8>> {
    let bytes = value.as_bytes();
    if bytes.len() % 2 != 0 {
        return None;
    }
    bytes
        .chunks(2)
        .map(|pair| {
            let high = (pair[0] as char).to_digit(16)?;
            let low = (pair[1] as char).to_digit(16)?;
            Some((high * 16 + low) as u8)
        })
        .collect()
}
