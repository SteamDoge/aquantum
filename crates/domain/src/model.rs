// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use uuid::Uuid;

pub type Id = Uuid;
pub const DATA_VERSION: u32 = 3;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("找不到{0}：{1}")]
    NotFound(&'static str, Id),
    #[error("无效操作：{0}")]
    Invalid(String),
    #[error("数据版本 {0} 不受支持，请使用兼容版本打开")]
    Version(u32),
}
pub type Result<T> = std::result::Result<T, Error>;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Format {
    Comic,
    Txt,
    Markdown,
    Pdf,
    /// Zipped publication read through the bundled foliate-js engine.
    Epub,
    /// Reflowable single-file ebook formats read through foliate-js.
    Mobi,
    Azw3,
    Fb2,
}

impl Format {
    pub fn from_extension(extension: &str) -> Option<Self> {
        match extension.to_ascii_lowercase().as_str() {
            "txt" => Some(Self::Txt),
            "md" | "markdown" => Some(Self::Markdown),
            "pdf" => Some(Self::Pdf),
            "epub" => Some(Self::Epub),
            "mobi" => Some(Self::Mobi),
            "azw3" => Some(Self::Azw3),
            "fb2" => Some(Self::Fb2),
            _ => None,
        }
    }
    /// Browsers and the foliate engine receive content as `application/zip`
    /// instead of a `file:` URL, so the import pipeline still needs the
    /// original suffix to tell a zipped publication from a plain text file.
    pub fn from_name(name: &str) -> Option<Self> {
        let lower = name.to_ascii_lowercase();
        for extension in [
            "txt", "md", "markdown", "pdf", "epub", "mobi", "azw3", "fb2",
        ] {
            if lower.ends_with(&format!(".{extension}")) {
                return Self::from_extension(extension);
            }
        }
        None
    }
    /// Formats whose position is a character-anchored location inside one
    /// document rather than a page index or a paragraph index.
    pub fn is_document(&self) -> bool {
        matches!(self, Self::Epub | Self::Mobi | Self::Azw3 | Self::Fb2)
    }
    /// Formats addressed by a stable page list (paged images or fixed pages).
    pub fn is_fixed_page(&self) -> bool {
        matches!(self, Self::Comic | Self::Pdf)
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Project {
    pub id: Id,
    pub parent: Option<Id>,
    pub name: String,
    /// Local identity now; future membership is independent of device identity.
    pub owner: Id,
    pub defaults: crate::ReadingDefaults,
    #[serde(default)]
    pub color: u8,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Resource {
    /// Immutable managed blob key (UUID); never an external absolute path.
    pub id: Id,
    pub sha256: String,
    pub bytes: u64,
    pub original_name: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Page {
    pub id: Id,
    pub resource: Resource,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct BookMetadata {
    #[serde(default)]
    pub author: String,
    #[serde(default)]
    pub publisher: String,
    #[serde(default)]
    pub isbn: String,
    #[serde(default)]
    pub summary: String,
    #[serde(default)]
    pub provider: String,
    #[serde(default)]
    pub source_id: String,
    #[serde(default)]
    pub cover: Option<Resource>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Book {
    pub id: Id,
    pub project: Id,
    pub title: String,
    pub format: Format,
    pub revision: u64,
    pub gap: Option<crate::Gap>,
    /// Personal reading direction; None follows the project chain.
    #[serde(default)]
    pub direction: Option<crate::ReadingDirection>,
    pub pages: Vec<Page>,
    /// User-requested removal from the shelf. Bytes and personal records remain.
    #[serde(default)]
    pub archived: bool,
    /// User-confirmed descriptive data and a separately managed cover copy.
    #[serde(default)]
    pub metadata: BookMetadata,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ReadingSession {
    pub id: Id,
    pub actor: Id,
    pub book: Id,
    /// Local calendar day at time of reading; never reinterpret on zone change.
    pub day: String,
    pub started_at: u64,
    pub elapsed_ms: u64,
    pub position: usize,
    pub total: usize,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum Location {
    Page {
        page: Id,
    },
    Paragraph {
        index: usize,
    },
    /// Position inside a document-format book. `anchor` is the engine's CFI for
    /// the current character position; `progress` is only a hint the engine
    /// recomputes, never the authoritative position.
    Document {
        anchor: String,
        #[serde(default)]
        progress: Option<u32>,
    },
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ReadingProgress {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content_progress: Option<u32>,
    pub book: Id,
    pub actor: Id,
    pub book_revision: u64,
    pub location: Location,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Note {
    pub id: Id,
    pub book: Id,
    pub actor: Id,
    pub book_revision: u64,
    pub location: Location,
    pub markdown: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DocumentInteraction {
    pub book: Id,
    pub actor: Id,
    pub source: Id,
    pub node: String,
    pub kind: String,
    pub value: bool,
    pub revision: u64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Operation {
    pub id: Id,
    pub actor: Id,
    pub unix_seconds: u64,
    pub action: String,
    pub target: Id,
    /// Reversible domain state only. Blob bytes remain immutable.
    pub before: Option<Book>,
    pub after: Option<Book>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CompletedImport {
    pub task: Id,
    pub projects: Vec<Id>,
    pub books: Vec<Id>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Catalog {
    pub schema_version: u32,
    pub id: Id,
    pub revision: u64,
    pub actor: Id,
    pub inbox: Id,
    pub projects: Vec<Project>,
    pub books: Vec<Book>,
    pub progress: Vec<ReadingProgress>,
    pub notes: Vec<Note>,
    pub operations: Vec<Operation>,
    pub imports: Vec<CompletedImport>,
    #[serde(default)]
    pub reading_sessions: Vec<ReadingSession>,
    #[serde(default)]
    pub document_interactions: Vec<DocumentInteraction>,
    /// Personal text decoding override per book; absence means "detect".
    #[serde(default)]
    pub text_encodings: BTreeMap<Id, Option<String>>,
    /// Book-wide crop (applies to every page without an override).
    #[serde(default)]
    pub crop_books: BTreeMap<Id, crate::CropInsets>,
    /// Per-page crop overrides, keyed by book then stable page id.
    #[serde(default)]
    pub crop: crate::CropRecords,
}

impl Default for Catalog {
    fn default() -> Self {
        let actor = Id::new_v4();
        let inbox = Id::new_v4();
        Self {
            schema_version: DATA_VERSION,
            id: Id::new_v4(),
            revision: 0,
            actor,
            inbox,
            projects: vec![Project {
                id: inbox,
                parent: None,
                name: "收件箱".into(),
                owner: actor,
                defaults: crate::ReadingDefaults::default(),
                color: 0,
            }],
            books: vec![],
            progress: vec![],
            notes: vec![],
            operations: vec![],
            imports: vec![],
            reading_sessions: vec![],
            document_interactions: vec![],
            text_encodings: BTreeMap::new(),
            crop_books: BTreeMap::new(),
            crop: BTreeMap::new(),
        }
    }
}
