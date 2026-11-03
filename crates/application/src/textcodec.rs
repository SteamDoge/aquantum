// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
//! Text decoding port: detect common encodings, preview candidates, and let the
//! reader override a per-book choice. Original bytes and the imported resource are
//! never rewritten; only a small personal/reading choice is stored.
use crate::{Error, Reader, Repository};
use aq_domain::Id;
use serde::{Deserialize, Serialize};

/// One decodable candidate. `confidence` is 0–100 from the heuristics below; it
/// orders suggestions and never claims certainty.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct EncodingCandidate {
    pub encoding: String,
    pub label: String,
    pub confidence: u8,
    pub sample: String,
    /// Sum of mojibake penalties; lower is more plausible.
    pub penalty: u64,
    /// Character-shape bonus; higher is more plausible.
    #[serde(default)]
    pub bonus: i64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct EncodingInfo {
    /// The encoding actually used to produce `source`, either stored or detected.
    pub encoding: String,
    pub label: String,
    /// True when the result is unambiguous enough to read without asking.
    pub confident: bool,
    /// Whether the current choice was stored by the user rather than detected.
    pub stored: bool,
    pub candidates: Vec<EncodingCandidate>,
    /// 0–100 quality of the decoded text, higher is cleaner.
    pub quality: u8,
}

const SAMPLE_CHARS: usize = 160;

struct Encoding {
    name: &'static str,
    label: &'static str,
    decoder: &'static encoding_rs::Encoding,
}

/// BOM-carrying Unicode encodings get their own table so `by_name` can always
/// hand back a `'static` entry instead of a temporary.
const UNICODE_CANDIDATES: [Encoding; 3] = [
    Encoding {
        name: "UTF-8",
        label: "UTF-8",
        decoder: encoding_rs::UTF_8,
    },
    Encoding {
        name: "UTF-16LE",
        label: "UTF-16LE",
        decoder: encoding_rs::UTF_16LE,
    },
    Encoding {
        name: "UTF-16BE",
        label: "UTF-16BE",
        decoder: encoding_rs::UTF_16BE,
    },
];

/// Deliberately small: the common Chinese/Japanese encodings plus a Windows
/// fallback. BOM handling happens before candidate scoring.
const CANDIDATES: [Encoding; 6] = [
    Encoding {
        name: "GB18030",
        label: "GB18030 / GBK（简体中文）",
        decoder: encoding_rs::GB18030,
    },
    Encoding {
        name: "Big5",
        label: "Big5（繁体中文）",
        decoder: encoding_rs::BIG5,
    },
    Encoding {
        name: "Shift_JIS",
        label: "Shift_JIS / Windows-31J（日文）",
        decoder: encoding_rs::SHIFT_JIS,
    },
    Encoding {
        name: "EUC-JP",
        label: "EUC-JP（日文）",
        decoder: encoding_rs::EUC_JP,
    },
    Encoding {
        name: "EUC-KR",
        label: "EUC-KR（韩文）",
        decoder: encoding_rs::EUC_KR,
    },
    Encoding {
        name: "windows-1252",
        label: "Windows-1252（西欧）",
        decoder: encoding_rs::WINDOWS_1252,
    },
];

impl Encoding {
    fn by_name(name: &str) -> Option<&'static Encoding> {
        // Collapse case, separators and the label punctuation users type, so
        // "GB18030", "gb18030", "UTF_16LE" and "Shift-JIS" all resolve.
        let normalized: String = name
            .trim()
            .to_ascii_lowercase()
            .chars()
            .filter(|c| c.is_ascii_alphanumeric())
            .collect();
        if let Some(found) = UNICODE_CANDIDATES.iter().find(|e| {
            matches!(e.name, "UTF-8") && matches!(normalized.as_str(), "utf8")
                || matches!(e.name, "UTF-16LE")
                    && matches!(
                        normalized.as_str(),
                        "utf16le" | "utf16" | "unicode" | "unicodele"
                    )
                || matches!(e.name, "UTF-16BE")
                    && matches!(normalized.as_str(), "utf16be" | "unicodebe")
        }) {
            return Some(found);
        }
        CANDIDATES
            .iter()
            .find(|e| {
                let own = e
                    .name
                    .chars()
                    .filter(|c| c.is_ascii_alphanumeric())
                    .collect::<String>()
                    .to_ascii_lowercase();
                own == normalized || e.decoder.name() == normalized
            })
            .or_else(|| {
                // GBK is a strict GB18030 subset, so the same decoder serves it.
                if normalized == "gbk" {
                    CANDIDATES.iter().find(|e| matches!(e.name, "GB18030"))
                } else {
                    None
                }
            })
    }
}

/// Decode `bytes` with `encoding`. Malformed input becomes U+FFFD and lowers the
/// quality score instead of failing, so a wrong guess stays recoverable.
fn decode(bytes: &[u8], encoding: &Encoding) -> String {
    let (text, _) = encoding.decoder.decode_without_bom_handling(bytes);
    text.into_owned()
}

/// Strip BOMs and remember the encoding the BOM declares.
fn strip_bom(bytes: &[u8]) -> (&'static str, &[u8]) {
    if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
        ("UTF-8", &bytes[3..])
    } else if bytes.starts_with(&[0xFF, 0xFE, 0x00, 0x00]) {
        ("UTF-32LE", &bytes[4..])
    } else if bytes.starts_with(&[0x00, 0x00, 0xFE, 0xFF]) {
        ("UTF-32BE", &bytes[4..])
    } else if bytes.starts_with(&[0xFF, 0xFE]) {
        ("UTF-16LE", &bytes[2..])
    } else if bytes.starts_with(&[0xFE, 0xFF]) {
        ("UTF-16BE", &bytes[2..])
    } else {
        ("", bytes)
    }
}

/// Penalty for text that looks like a decoding accident.
fn penalty(text: &str) -> u64 {
    let mut penalty = 0u64;
    for ch in text.chars() {
        let code = ch as u32;
        penalty += match code {
            0xFFFD => 60,
            0xE000..=0xF8FF => 40,
            0x0080..=0x009F => 22,
            _ if is_rare_block(code) => 12,
            // Hangul syllable blocks: harmless in Korean text, but the classic
            // output of reading Chinese GBK bytes as EUC-KR. Scored just below
            // `is_rare_block` so a genuinely Korean file is not rejected while a
            // Hangul-heavy misread still loses to the right Chinese candidate.
            0xAC00..=0xD7AF => 10,
            0x07 => 8,
            _ if code > 0x2FFFF => 6,
            _ => 0,
        };
    }
    penalty
}

/// Blocks that indicate a wrong guess more often than real content: Hangul Jamo
/// filling, Katakana Phonetic Extensions, and CJK Compatibility Supplements.
fn is_rare_block(code: u32) -> bool {
    matches!(
        code,
        0x3130..=0x318F | 0x31F0..=0x31FF | 0x2E80..=0x2EFF | 0xFE30..=0xFE6F
    )
}

fn script_ratio(text: &str) -> f32 {
    let mut total = 0usize;
    let mut sensible = 0usize;
    for ch in text.chars() {
        total += 1;
        if !ch.is_control() || ch == '\n' || ch == '\t' {
            sensible += 1;
        }
    }
    if total == 0 {
        0.0
    } else {
        sensible as f32 / total as f32
    }
}

fn sample_of(text: &str) -> String {
    text.trim_start()
        .chars()
        .take(SAMPLE_CHARS)
        .collect::<String>()
        .replace(['\r', '\n'], " ")
        .trim()
        .to_owned()
}

/// CFG/shape bonus used between the byte-level and character-level signals.
/// CJK ideographs and the common sentence punctuation of Chinese/Japanese text
/// raise the score; Hangul keeps a smaller raise so Korean files still win when
/// the byte pattern is actually Korean.
fn script_bonus(text: &str) -> i64 {
    let mut score = 0i64;
    let mut total = 0usize;
    for ch in text.chars() {
        total += 1;
        let code = ch as u32;
        score += match code {
            0x4E00..=0x9FFF | 0x3400..=0x4DBF => 18,
            0x3040..=0x30FF => 6,
            0xAC00..=0xD7AF => 4,
            0xFF01..=0xFF1F | 0x3001..=0x3002 | 0x2018..=0x201D | 0x2026 | 0x2014 => 8,
            0xE000..=0xF8FF => -30,
            _ => 0,
        };
    }
    if total >= 40 {
        score
    } else {
        score * total as i64 / 40
    }
}

fn is_ideograph(text: &str) -> bool {
    text.chars()
        .any(|ch| matches!(ch as u32, 0x4E00..=0x9FFF | 0x3400..=0x4DBF))
}

fn quality(len: usize, total_penalty: u64) -> u8 {
    if len == 0 {
        return 0;
    }
    let average = total_penalty as f32 / len as f32;
    let value = 100.0 - average * 2.0;
    value.clamp(0.0, 100.0) as u8
}

/// Decode `bytes` with an explicit or detected encoding, never writing them back.
pub fn decode_bytes(bytes: &[u8], requested: Option<&str>) -> crate::Result<(String, String)> {
    let (bom, body) = strip_bom(bytes);
    let Some(name) = requested else {
        if !bom.is_empty() {
            let encoding = Encoding::by_name(bom)
                .ok_or_else(|| Error::Unsupported(format!("暂不支持的文件起始标记：{bom}")))?;
            return Ok((decode(body, encoding), bom.to_owned()));
        }
        let detected = detect(bytes);
        let encoding = Encoding::by_name(&detected.encoding)
            .ok_or_else(|| Error::Unsupported(format!("未知编码：{}", detected.encoding)))?;
        return Ok((decode(body, encoding), detected.encoding));
    };
    let encoding =
        Encoding::by_name(name).ok_or_else(|| Error::Unsupported(format!("未知编码：{name}")))?;
    Ok((decode(body, encoding), encoding.name.to_owned()))
}

/// Candidate list for the reader's preview and manual override screen.
pub fn detect(bytes: &[u8]) -> EncodingInfo {
    let (bom, body) = strip_bom(bytes);
    if !bom.is_empty() {
        return with_default(bom, body);
    }
    if let Ok(text) = std::str::from_utf8(bytes) {
        return with_default_text("UTF-8", text);
    }
    let mut candidates: Vec<EncodingCandidate> = CANDIDATES
        .iter()
        .map(|encoding| {
            let text = decode(bytes, encoding);
            let score = score_of(&text);
            EncodingCandidate {
                encoding: encoding.name.to_owned(),
                label: encoding.label.to_owned(),
                confidence: quality(text.chars().count(), score),
                sample: sample_of(&text),
                penalty: score,
                bonus: script_bonus(&text),
            }
        })
        .collect();
    candidates.sort_by(|a, b| {
        rank_key(a)
            .cmp(&rank_key(b))
            .then_with(|| b.confidence.cmp(&a.confidence))
            .then_with(|| a.encoding.cmp(&b.encoding))
    });
    let Some(best) = candidates.first() else {
        return with_candidates("UTF-8".into(), 0, vec![], false);
    };
    let (encoding, confidence, best_key) = (best.encoding.clone(), best.confidence, rank_key(best));
    let clear = candidates
        .get(1)
        .map(|second| rank_key(second) > best_key)
        .unwrap_or(true);
    let confident = clear && confidence >= 25 && is_ideograph(&best.sample);
    with_candidates_confident(encoding, confidence, candidates, confident)
}

/// Mojibake penalty plus a share of control/rare characters.
fn score_of(text: &str) -> u64 {
    penalty(text) + ((1.0 - script_ratio(text)) * 100.0) as u64
}

/// Ranking key: a lower `penalty` is better, then a higher `bonus`. Kept as one
/// integer so candidates sort without floats.
fn rank_key(candidate: &EncodingCandidate) -> i64 {
    candidate.penalty as i64 * 4 - candidate.bonus
}

fn with_default(encoding: &str, body: &[u8]) -> EncodingInfo {
    let text = Encoding::by_name(encoding).map(|e| decode(body, e));
    with_default_text(encoding, text.as_deref().unwrap_or_default())
}

fn with_default_text(encoding: &str, text: &str) -> EncodingInfo {
    let confidence = quality(text.chars().count(), score_of(text));
    let label = Encoding::by_name(encoding)
        .map(|e| e.label.to_owned())
        .unwrap_or_else(|| encoding.to_owned());
    EncodingInfo {
        encoding: encoding.to_owned(),
        label: label.clone(),
        confident: true,
        stored: false,
        candidates: vec![EncodingCandidate {
            encoding: encoding.to_owned(),
            label,
            confidence,
            sample: sample_of(text),
            penalty: 0,
            bonus: script_bonus(text),
        }],
        quality: confidence,
    }
}

fn with_candidates(
    encoding: String,
    confidence: u8,
    candidates: Vec<EncodingCandidate>,
    clear: bool,
) -> EncodingInfo {
    let confident = clear && confidence >= 25;
    with_candidates_confident(encoding, confidence, candidates, confident)
}

fn with_candidates_confident(
    encoding: String,
    confidence: u8,
    candidates: Vec<EncodingCandidate>,
    confident: bool,
) -> EncodingInfo {
    let label = candidates
        .iter()
        .find(|c| c.encoding == encoding)
        .map(|c| c.label.clone())
        .unwrap_or_else(|| encoding.clone());
    EncodingInfo {
        encoding,
        label,
        confident,
        stored: false,
        candidates,
        quality: confidence,
    }
}

impl<R: Repository, B: crate::BlobStore> Reader<R, B> {
    /// Detected encodings plus any stored reading choice for this book.
    pub fn text_encoding(&self, book: Id) -> crate::Result<EncodingInfo> {
        let c = self.repository.load()?;
        let bytes = self.text_bytes_in(&c, book)?;
        let stored = c.text_encodings.get(&book).cloned().flatten();
        let mut info = match &stored {
            Some(name) => {
                let (text, used) = decode_bytes(&bytes, Some(name))?;
                let mut info = with_candidates(used.clone(), 100, ranking(&bytes, &used), true);
                info.quality = quality(text.chars().count(), score_of(&text));
                info
            }
            None => detect(&bytes),
        };
        info.stored = stored.is_some();
        Ok(info)
    }

    /// Store a per-book reading choice. `None` clears it and restores detection.
    pub fn set_text_encoding(&mut self, book: Id, encoding: Option<&str>) -> crate::Result<()> {
        let mut c = self.repository.load()?;
        self.ensure_owned(&c, c.book(book)?.project)?;
        let bytes = self.text_bytes_in(&c, book)?;
        if let Some(name) = encoding {
            let (_, used) = decode_bytes(&bytes, Some(name))?;
            if c.text_encodings.get(&book).and_then(|v| v.as_deref()) == Some(used.as_str()) {
                return Ok(());
            }
            let expected = c.revision;
            c.text_encodings.insert(book, Some(used));
            c.book_mut(book)?.revision += 1;
            self.record(&mut c, "set_text_encoding", book, None, None);
            c.revision += 1;
            return self.repository.save(expected, &c);
        }
        if c.text_encodings.remove(&book).is_none() {
            return Ok(());
        }
        let expected = c.revision;
        c.book_mut(book)?.revision += 1;
        self.record(&mut c, "set_text_encoding", book, None, None);
        c.revision += 1;
        self.repository.save(expected, &c)
    }
}

/// Detected ranking with the stored choice present, so the panel can show every
/// alternative including the one in use.
fn ranking(bytes: &[u8], chosen: &str) -> Vec<EncodingCandidate> {
    let mut info = detect(bytes);
    if !info.candidates.iter().any(|c| c.encoding == chosen)
        && let Some(encoding) = Encoding::by_name(chosen)
    {
        let (bom, body) = strip_bom(bytes);
        let text = decode(if bom.is_empty() { bytes } else { body }, encoding);
        info.candidates.push(EncodingCandidate {
            encoding: chosen.to_owned(),
            label: encoding.label.to_owned(),
            confidence: quality(text.chars().count(), score_of(&text)),
            sample: sample_of(&text),
            penalty: score_of(&text),
            bonus: script_bonus(&text),
        });
    }
    info.candidates
}

/// UTF-8 detection is intentionally strict: a valid UTF-8 stream with many
/// multi-byte characters is almost never produced by accident in a GBK file.
#[cfg(test)]
mod tests {

    #[test]
    fn explicit_encoding_is_not_silently_replaced_by_the_bom() {
        let bytes = b"\xef\xbb\xbf\xc3\xa9";
        assert_eq!(
            super::decode_bytes(bytes, None).unwrap(),
            ("é".into(), "UTF-8".into())
        );
        assert_eq!(
            super::decode_bytes(bytes, Some("windows-1252")).unwrap(),
            ("Ã©".into(), "windows-1252".into())
        );
    }
    use super::*;

    fn penalty_of(bytes: &[u8], name: &str) -> u64 {
        let encoding = Encoding::by_name(name).unwrap();
        penalty(&decode(bytes, encoding))
    }

    #[test]
    fn utf8_and_bom_are_detected_first() {
        assert_eq!(detect("正文 abc".as_bytes()).encoding, "UTF-8");
        let info = detect(&[0xEF, 0xBB, 0xBF, b'a']);
        assert_eq!(info.encoding, "UTF-8");
        assert!(info.candidates[0].sample.starts_with('a'));
        let info = detect(&[0xFF, 0xFE, b'a', 0x00]);
        assert_eq!(info.encoding, "UTF-16LE");
        assert!(info.candidates[0].sample.starts_with('a'));
    }

    #[test]
    fn gb18030_text_beats_big5_and_shift_jis() {
        let encoding = encoding_rs::GB18030;
        let (bytes, _, _) = encoding.encode("第一段中文测试内容，包含标点符号。");
        let info = detect(&bytes);
        assert_eq!(info.encoding, "GB18030");
        assert!(info.confident);
        assert!(penalty_of(&bytes, "gb18030") < penalty_of(&bytes, "big5"));
        assert!(penalty_of(&bytes, "gb18030") < penalty_of(&bytes, "shift_jis"));
    }

    #[test]
    fn explicit_override_round_trips_and_rejects_unknown_names() {
        let (bytes, _, _) = encoding_rs::GB18030.encode("中文内容");
        let (text, used) = decode_bytes(&bytes, Some("GB18030")).unwrap();
        assert_eq!(text, "中文内容");
        assert_eq!(used, "GB18030");
        assert!(decode_bytes(&bytes, Some("klingon")).is_err());
        // WHATWG aliases (gbk, shift-jis, big-5) resolve to the same decoder.
        let (text, used) = decode_bytes(&bytes, Some("gbk")).unwrap();
        assert_eq!((text.as_str(), used.as_str()), ("中文内容", "GB18030"));
        let (_, used) = decode_bytes(b"abc", Some("UTF_16LE")).unwrap();
        assert_eq!(used, "UTF-16LE");
        assert!(Encoding::by_name("shift-jis").is_some());
        assert!(Encoding::by_name("big-5").is_some());
    }

    #[test]
    fn quality_falls_with_replacement_characters() {
        assert!(quality(10, 0) > quality(10, 100));
    }
}
