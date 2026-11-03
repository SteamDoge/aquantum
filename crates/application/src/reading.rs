// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
use crate::{BlobStore, Error, Reader, Repository};
use aq_domain::{Catalog, Format, Id, Location, Note, ReadingProgress};
use serde::Serialize;

pub const TEXT_LIMIT: u64 = 32 * 1024 * 1024;

/// One note plus the stable anchor the reader can resolve back to a position.
#[derive(Debug, Serialize)]
pub struct NoteView {
    pub id: Id,
    pub markdown: String,
    /// [`Location`] as stable JSON, reused directly by `resolveLocation`.
    pub location: serde_json::Value,
    /// Paragraph index for text books.
    pub paragraph: Option<usize>,
    /// Stable page id for comic/PDF books.
    pub page: Option<Id>,
    /// Character anchor for document-format books (EPUB/MOBI/AZW3/FB2).
    pub anchor: Option<String>,
    /// Book revision at the time of the note; a mismatch means the anchor drifted.
    pub book_revision: u64,
    pub current_revision: u64,
    pub stale: bool,
}

impl NoteView {
    fn of(note: &Note, c: &Catalog) -> Self {
        let current_revision = c
            .books
            .iter()
            .find(|b| b.id == note.book)
            .map(|b| b.revision)
            .unwrap_or(note.book_revision);
        let (paragraph, page, anchor) = match &note.location {
            Location::Paragraph { index } => (Some(*index), None, None),
            Location::Page { page } => (None, Some(*page), None),
            Location::Document { anchor, .. } => (None, None, Some(anchor.clone())),
        };
        let location = match &note.location {
            Location::Paragraph { index } => serde_json::json!({"paragraph": index}),
            Location::Page { page } => serde_json::json!({"page": page}),
            Location::Document { anchor, progress } => {
                serde_json::json!({"document": anchor, "progress": progress})
            }
        };
        Self {
            id: note.id,
            markdown: note.markdown.clone(),
            location,
            paragraph,
            page,
            anchor,
            book_revision: note.book_revision,
            current_revision,
            stale: current_revision != note.book_revision,
        }
    }
}

/// One immutable managed resource handed to the browser reading engine.
#[derive(Debug, Serialize)]
pub struct DocumentResource {
    pub book: Id,
    pub revision: u64,
    pub resource: Id,
    pub name: String,
    pub format: Format,
    pub bytes: u64,
    pub sha256: String,
    /// Host path of the managed copy; never the user's original file.
    pub path: String,
}

#[derive(Debug, Serialize)]
pub struct TextDocument {
    pub book: Id,
    pub revision: u64,
    pub format: Format,
    /// Encoding actually used to produce `source` (stored choice or detection).
    pub encoding: String,
    /// Source paragraphs, not rendered Markdown blocks.
    pub paragraphs: Vec<String>,
    pub source: String,
    /// Heading outline for plain text; empty when the book carries no headings.
    pub outline: Vec<OutlineEntry>,
}

/// One navigable heading.
///
/// `index` is the paragraph index the reader should jump to, so the outline
/// never has to be re-derived on the client and cannot drift from what the
/// reader is actually displaying.
#[derive(Debug, Serialize)]
pub struct OutlineEntry {
    pub index: usize,
    /// UTF-16 offset within the unchanged source paragraph.
    pub offset: usize,
    pub title: String,
    pub level: u8,
}

/// Plain text has no structure, so the only honest outline is what the author
/// wrote: chapter-like headings. Long wrapped lines are deliberately not
/// treated as headings — guessing would invent structure that is not there.
///
/// Recognised forms, all requiring a short line that does not end a sentence:
/// `第N章/节/卷/篇/回/部/集` headings, `Chapter N`/`Part N`/`Book N`, Markdown
/// `#` prefixes that appear in a .txt file, and `一、` style enumerated titles.
pub fn outline_of(paragraphs: &[String]) -> Vec<OutlineEntry> {
    let mut outline = Vec::new();
    for (index, paragraph) in paragraphs.iter().enumerate() {
        let mut offset = 0;
        for line in paragraph.split_inclusive('\n') {
            if let Some((level, title)) = heading_of(line.trim()) {
                outline.push(OutlineEntry {
                    index,
                    offset,
                    title,
                    level,
                });
            }
            offset += line.encode_utf16().count();
        }
    }
    outline
}

fn heading_of(paragraph: &str) -> Option<(u8, String)> {
    // A heading is one short line; anything wrapped across lines is body text.
    let line = paragraph.trim();
    if line.is_empty() || line.contains('\n') {
        return None;
    }
    let length = line.chars().count();
    if !(1..=60).contains(&length) {
        return None;
    }
    if line.ends_with([
        '。', '，', '；', '：', '！', '？', '.', ',', ';', ':', '!', '?',
    ]) {
        return None;
    }
    // Markdown headings in a plain text file are still a deliberate heading.
    if let Some(rest) = line.strip_prefix('#') {
        let hashes = 1 + rest.chars().take_while(|c| *c == '#').count();
        let title = rest.trim_start_matches('#').trim();
        if !title.is_empty() {
            return Some((hashes.min(6) as u8, title.to_owned()));
        }
    }
    if is_chapter_heading(line) {
        return Some((1, line.to_owned()));
    }
    if is_enumerated_heading(line) {
        return Some((2, line.to_owned()));
    }
    None
}

fn is_chapter_heading(line: &str) -> bool {
    const CJK: [&str; 7] = ["章", "节", "卷", "篇", "回", "部", "集"];
    let after_di = line.strip_prefix('第');
    if after_di.is_some_and(|rest| {
        // Chinese numerals ("一"…) are letters to `is_numeric`, so match both.
        let digits = rest.chars().take_while(is_chapter_number).count();
        // Require a number so "第三方" style prose is not mistaken for a heading.
        digits > 0
            && rest
                .chars()
                .nth(digits)
                .is_some_and(|c| CJK.contains(&c.to_string().as_str()))
    }) {
        return true;
    }
    let lower = line.to_ascii_lowercase();
    ["chapter", "part", "book", "section"].iter().any(|prefix| {
        lower
            .strip_prefix(prefix)
            .map(str::trim_start)
            .is_some_and(|rest| rest.chars().next().is_some_and(|c| c.is_ascii_digit()))
    })
}

/// Arabic digits plus the Chinese numerals used in chapter numbering.
///
/// Written as an explicit list, not `'零'..='九'`: that range is backwards in
/// code-point order (零 U+96F6 > 九 U+4E5D) and silently matches nothing.
fn is_chapter_number(c: &char) -> bool {
    c.is_numeric()
        || matches!(
            c,
            '零' | '〇'
                | '一'
                | '二'
                | '两'
                | '三'
                | '四'
                | '五'
                | '六'
                | '七'
                | '八'
                | '九'
                | '十'
                | '百'
                | '千'
                | '万'
        )
}

fn is_enumerated_heading(line: &str) -> bool {
    // "一、" "十二、" "1." with no trailing sentence punctuation already excluded.
    let mut chars = line.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    let numeric_run = if is_chapter_number(&first) && !first.is_ascii_digit() {
        line.chars().take_while(is_chapter_number).count()
    } else if first.is_numeric() {
        line.chars().take_while(|c| c.is_numeric()).count()
    } else {
        return false;
    };
    let rest: String = line.chars().skip(numeric_run).take(1).collect();
    matches!(rest.as_str(), "、" | "．") || (rest == "." && line.chars().count() > numeric_run + 1)
}

/// Percent-encode everything outside the unreserved set so a CFI, which
/// contains `[`, `]`, `(`, `)`, `,` and `:`, survives inside a query value.
fn percent_encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.as_bytes() {
        if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
            out.push(*byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

impl<R: Repository, B: BlobStore> Reader<R, B> {
    /// Raw managed bytes of the book's source text; never rewritten.
    pub(crate) fn text_bytes_in(&self, c: &Catalog, book: Id) -> crate::Result<Vec<u8>> {
        let b = c.book(book)?;
        if !matches!(b.format, Format::Txt | Format::Markdown) {
            return Err(Error::Unsupported("此格式不提供文字编码".into()));
        }
        let page = b
            .pages
            .first()
            .ok_or_else(|| aq_domain::Error::Invalid("书籍缺少正文资源".into()))?;
        self.blobs.read(page.resource.id, TEXT_LIMIT)
    }

    /// A document-format book (EPUB/MOBI/AZW3/FB2) is handed to the browser
    /// engine as one immutable managed resource. The core determines the
    /// original suffix so the client never guesses from a stale title.
    pub fn document_resource(&self, book: Id) -> crate::Result<DocumentResource> {
        let c = self.repository.load()?;
        let b = c.book(book)?;
        if !b.format.is_document() {
            return Err(Error::Unsupported("此书不是文档格式".into()));
        }
        let page = b
            .pages
            .first()
            .ok_or_else(|| aq_domain::Error::Invalid("书籍缺少正文资源".into()))?;
        Ok(DocumentResource {
            book,
            revision: b.revision,
            resource: page.resource.id,
            name: page.resource.original_name.clone(),
            format: b.format,
            bytes: page.resource.bytes,
            sha256: page.resource.sha256.clone(),
            path: self
                .blobs
                .resource_path(page.resource.id)?
                .to_string_lossy()
                .into_owned(),
        })
    }

    pub fn text(&self, book: Id) -> crate::Result<TextDocument> {
        let c = self.repository.load()?;
        self.text_in(&c, book)
    }

    pub(crate) fn text_in(&self, c: &Catalog, book: Id) -> crate::Result<TextDocument> {
        let b = c.book(book)?;
        if !matches!(b.format, Format::Txt | Format::Markdown) {
            return Err(Error::Unsupported(
                "漫画通过稳定页面清单访问；M0 不提供图像界面".into(),
            ));
        }
        let bytes = self.text_bytes_in(c, book)?;
        let stored = c.text_encodings.get(&book).cloned().flatten();
        let (text, encoding) = crate::textcodec::decode_bytes(&bytes, stored.as_deref())?;
        let text = text
            .trim_start_matches('\u{feff}')
            .replace("\r\n", "\n")
            .replace('\r', "\n");
        let paragraphs: Vec<String> = text
            .split("\n\n")
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .collect();
        let outline = outline_of(&paragraphs);
        remember_paragraph_count(text_count_key(c, book)?, paragraphs.len());
        Ok(TextDocument {
            book,
            revision: b.revision,
            format: b.format,
            encoding,
            paragraphs,
            source: text,
            outline,
        })
    }

    pub fn save_progress(&mut self, book: Id, location: Location) -> crate::Result<()> {
        self.save_progress_measured(book, location, None)
    }

    /// Optional content-length hint for shelves; the location remains authoritative.
    pub fn save_progress_measured(
        &mut self,
        book: Id,
        location: Location,
        content_progress: Option<u32>,
    ) -> crate::Result<()> {
        if content_progress.is_some_and(|value| value > 10000) {
            return Err(aq_domain::Error::Invalid("内容进度超出范围".into()).into());
        }
        let mut c = self.repository.load()?;
        self.ensure_owned(&c, c.book(book)?.project)?;
        self.validate_location(&c, book, &location)?;
        let expected = c.revision;
        let b = c.book(book)?;
        let progress = ReadingProgress {
            content_progress,
            book,
            actor: c.actor,
            book_revision: b.revision,
            location,
        };
        c.progress
            .retain(|p| !(p.book == book && p.actor == c.actor));
        c.progress.push(progress);
        c.revision += 1;
        self.repository.save(expected, &c)
    }

    pub fn add_note(
        &mut self,
        book: Id,
        location: Location,
        markdown: String,
    ) -> crate::Result<Id> {
        if markdown.trim().is_empty() {
            return Err(aq_domain::Error::Invalid("笔记不能为空".into()).into());
        }
        let mut c = self.repository.load()?;
        self.ensure_owned(&c, c.book(book)?.project)?;
        self.validate_location(&c, book, &location)?;
        let expected = c.revision;
        let id = Id::new_v4();
        let revision = c.book(book)?.revision;
        c.notes.push(Note {
            id,
            book,
            actor: c.actor,
            book_revision: revision,
            location,
            markdown,
        });
        self.record(&mut c, "add_note", book, None, None);
        c.revision += 1;
        self.repository.save(expected, &c)?;
        Ok(id)
    }

    /// Reader-facing note list so the UI can jump back to each anchor without
    /// parsing the Markdown export.
    pub fn notes(&self, book: Id) -> crate::Result<Vec<NoteView>> {
        let c = self.repository.load()?;
        c.book(book)?;
        Ok(c.notes
            .iter()
            .filter(|n| n.book == book && n.actor == c.actor)
            .map(|n| NoteView::of(n, &c))
            .collect())
    }

    /// A single virtual associated MD per source identity, materialized on export.
    /// The authoritative body and anchors commit together in SQLite.
    pub fn notes_markdown(&self, book: Id) -> crate::Result<String> {
        let c = self.repository.load()?;
        let b = c.book(book)?;
        let notes: Vec<_> = c
            .notes
            .iter()
            .filter(|n| n.book == book && n.actor == c.actor)
            .collect();
        if notes.is_empty() {
            return Err(Error::Unsupported("尚无关联笔记，不生成空 MD".into()));
        }
        let mut output = format!("# {} · 阅读笔记\n\n", b.title);
        for n in notes {
            let position = match &n.location {
                Location::Page { page } => format!("page={page}"),
                Location::Paragraph { index } => format!("paragraph={index}"),
                Location::Document { anchor, .. } => {
                    format!("document={}", percent_encode(anchor))
                }
            };
            output.push_str(&format!(
                "## 笔记 {}\n\n{}\n\n来源：[{}](aqreader://book/{}?{}&revision={})\n\n",
                n.id, n.markdown, b.title, book, position, n.book_revision
            ));
        }
        Ok(output)
    }

    fn validate_location(&self, c: &Catalog, book: Id, location: &Location) -> crate::Result<()> {
        let b = c.book(book)?;
        let valid = match location {
            Location::Page { page } => {
                b.format.is_fixed_page() && b.pages.iter().any(|p| p.id == *page)
            }
            Location::Paragraph { index } => {
                matches!(b.format, Format::Txt | Format::Markdown)
                    && *index < self.paragraph_count(c, book)?
            }
            // The engine resolves the anchor, so the core only guarantees the
            // format and that the anchor is a bounded, opaque CFI-like value.
            Location::Document { anchor, .. } => {
                b.format.is_document()
                    && !anchor.is_empty()
                    && anchor.len() <= 512
                    && !anchor.chars().any(char::is_control)
            }
        };
        if !valid {
            return Err(aq_domain::Error::Invalid("阅读位置不存在或与格式不匹配".into()).into());
        }
        Ok(())
    }

    pub(crate) fn paragraph_count(&self, c: &Catalog, book: Id) -> crate::Result<usize> {
        let key = text_count_key(c, book)?;
        if let Ok(cache) = paragraph_counts().lock()
            && let Some((_, count)) = cache.iter().find(|(entry, _)| entry == &key)
        {
            return Ok(*count);
        }
        Ok(self.text_in(c, book)?.paragraphs.len())
    }
}

// Only small derived counts are retained, never full decoded books. Content hashes
// and encoding choices make counts safe across sessions, renames and library switches.
fn paragraph_counts() -> &'static std::sync::Mutex<std::collections::VecDeque<(String, usize)>> {
    static COUNTS: std::sync::OnceLock<
        std::sync::Mutex<std::collections::VecDeque<(String, usize)>>,
    > = std::sync::OnceLock::new();
    COUNTS.get_or_init(Default::default)
}
fn text_count_key(c: &Catalog, book: Id) -> crate::Result<String> {
    let b = c.book(book)?;
    let page = b
        .pages
        .first()
        .ok_or_else(|| aq_domain::Error::Invalid("书籍缺少正文资源".into()))?;
    Ok(format!(
        "{}:{}:{}",
        page.resource.sha256,
        page.resource.bytes,
        c.text_encodings
            .get(&book)
            .and_then(|v| v.as_deref())
            .unwrap_or("auto-v1")
    ))
}
fn remember_paragraph_count(key: String, count: usize) {
    if let Ok(mut cache) = paragraph_counts().lock() {
        cache.retain(|(entry, _)| entry != &key);
        if cache.len() == 128 {
            cache.pop_front();
        }
        cache.push_back((key, count));
    }
}

#[cfg(test)]
mod tests {
    use super::outline_of;

    fn paragraphs(lines: &[&str]) -> Vec<String> {
        lines.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn chapter_headings_become_outline_entries() {
        let found = outline_of(&paragraphs(&["第一章 起风", "正文第一段。", "第二卷 归途"]));
        assert_eq!(found.len(), 2);
        assert_eq!(found[0].index, 0);
        assert_eq!(found[0].title, "第一章 起风");
        assert_eq!(found[0].level, 1);
        assert_eq!(found[1].index, 2);
    }

    #[test]
    fn prose_is_never_mistaken_for_a_heading() {
        // "第三方" has no number; a sentence ending in punctuation is body text;
        // a wrapped line is body text even when it starts like a heading.
        let found = outline_of(&paragraphs(&[
            "第三方服务需要注意。",
            "这本书值得一读。",
            "第一章\n后面还有换行",
            "他走过去，第二章其实在讲别的。",
        ]));
        assert_eq!(
            found.len(),
            1,
            "only the explicit heading line is recognised"
        );
        assert_eq!(found[0].title, "第一章");
        assert_eq!(found[0].offset, 0);
    }

    #[test]
    fn enumerated_and_markdown_headings_carry_their_level() {
        let found = outline_of(&paragraphs(&[
            "一、缘起",
            "正文。",
            "## 小节标题",
            "1. 编号标题",
        ]));
        assert_eq!(found.len(), 3);
        assert_eq!(found[0].level, 2);
        assert_eq!(found[1].level, 2, "a txt file may still carry # headings");
        assert_eq!(found[1].title, "小节标题");
        assert_eq!(found[2].index, 3);
    }

    #[test]
    fn single_newline_chapters_keep_utf16_source_offsets() {
        let source = "开篇😀。\n第一章 起风\n正文。\n第二章 归途\n结尾。";
        let found = outline_of(&[source.to_string()]);
        assert_eq!(found.len(), 2);
        assert_eq!(found[1].index, 0);
        assert_eq!(
            found[1].offset,
            source[..source.find("第二章").unwrap()]
                .encode_utf16()
                .count()
        );
    }

    #[test]
    fn english_chapter_prefixes_need_a_number() {
        let found = outline_of(&paragraphs(&[
            "Chapter 12",
            "Part 3",
            "Chapterhouse is a word.",
        ]));
        assert_eq!(found.len(), 2);
        assert_eq!(found[1].title, "Part 3");
    }
}
