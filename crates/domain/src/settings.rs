// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
use crate::*;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum Gap {
    #[default]
    Gapped,
    Seamless,
}

/// Reading direction, stored independently from page order. Switching to
/// right-to-left never reverses the already curated page sequence.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum ReadingDirection {
    LeftToRight,
    RightToLeft,
    TopToBottom,
}

impl ReadingDirection {
    pub fn label(self) -> &'static str {
        match self {
            Self::LeftToRight => "从左到右",
            Self::RightToLeft => "从右到左",
            Self::TopToBottom => "从上到下",
        }
    }
    /// The three accepted spellings: Serde name, snake_case, and a short code.
    pub fn parse(value: &str) -> Option<Self> {
        match value {
            "LeftToRight" | "left_to_right" | "ltr" => Some(Self::LeftToRight),
            "RightToLeft" | "right_to_left" | "rtl" => Some(Self::RightToLeft),
            "TopToBottom" | "top_to_bottom" | "ttb" => Some(Self::TopToBottom),
            _ => None,
        }
    }
}

/// Non-destructive crop as a fraction of the page per edge. Image bytes are
/// never modified; the reader applies this as a sampling window.
#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct CropInsets {
    pub left: f32,
    pub top: f32,
    pub right: f32,
    pub bottom: f32,
}

/// Smallest visible share of a page; larger insets are rejected so a stray
/// value cannot hide the whole image.
pub const CROP_MIN_VISIBLE: f32 = 0.1;

impl CropInsets {
    pub fn is_identity(&self) -> bool {
        *self == Self::default()
    }
    /// Reject values outside 0–1 or that would leave less than [`CROP_MIN_VISIBLE`].
    pub fn validate(&self) -> Result<()> {
        let values = [self.left, self.top, self.right, self.bottom];
        if values
            .iter()
            .any(|v| !v.is_finite() || *v < 0.0 || *v >= 1.0)
        {
            return Err(Error::Invalid("裁边比例必须在 0 到 1 之间".into()));
        }
        if 1.0 - (self.left + self.right) < CROP_MIN_VISIBLE {
            return Err(Error::Invalid("左右裁边合计过大，至少保留 10% 宽度".into()));
        }
        if 1.0 - (self.top + self.bottom) < CROP_MIN_VISIBLE {
            return Err(Error::Invalid("上下裁边合计过大，至少保留 10% 高度".into()));
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct ReadingDefaults {
    /// None stores inheritance, never the last resolved value.
    pub comic_gap: Option<Gap>,
    pub pdf_gap: Option<Gap>,
    #[serde(default)]
    pub comic_direction: Option<ReadingDirection>,
    #[serde(default)]
    pub comic_crop: Option<CropInsets>,
    #[serde(default)]
    pub pdf_direction: Option<ReadingDirection>,
    #[serde(default)]
    pub pdf_crop: Option<CropInsets>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct EffectiveGap {
    pub value: Gap,
    pub source: Option<Id>,
    pub description: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct EffectiveDirection {
    pub value: ReadingDirection,
    pub source: Option<Id>,
    pub description: String,
}

impl Catalog {
    pub fn effective_gap(&self, book: Id) -> Result<EffectiveGap> {
        let book = self.book(book)?;
        if !book.format.is_fixed_page() {
            return Err(Error::Invalid("文字格式不使用页面间隔".into()));
        }
        if let Some(value) = book.gap {
            return Ok(EffectiveGap {
                value,
                source: Some(book.id),
                description: format!("{}（本文件自定义）", gap_label(value)),
            });
        }
        let mut parent = Some(book.project);
        let mut visited = HashSet::new();
        while let Some(id) = parent {
            if !visited.insert(id) {
                return Err(Error::Invalid("项目继承出现循环".into()));
            }
            let p = self.project(id)?;
            if let Some(value) = if book.format == Format::Pdf {
                p.defaults.pdf_gap
            } else {
                p.defaults.comic_gap
            } {
                return Ok(EffectiveGap {
                    value,
                    source: Some(id),
                    description: format!("默认（{}，继承自：{}）", gap_label(value), p.name),
                });
            }
            parent = p.parent;
        }
        Ok(EffectiveGap {
            value: Gap::default(),
            source: None,
            description: format!("默认（{}，继承自：全局默认）", gap_label(Gap::default())),
        })
    }

    /// Direction is file-local; project defaults are retained but never consulted.
    pub fn effective_direction(&self, book: Id) -> Result<EffectiveDirection> {
        let book = self.book(book)?;
        if !book.format.is_fixed_page() {
            return Err(Error::Invalid("只有固定页面使用阅读方向".into()));
        }
        if let Some(value) = book.direction {
            return Ok(EffectiveDirection {
                value,
                source: Some(book.id),
                description: format!("{}（本文件自定义）", value.label()),
            });
        }
        let value = if book.format == Format::Pdf {
            ReadingDirection::TopToBottom
        } else {
            ReadingDirection::LeftToRight
        };
        Ok(EffectiveDirection {
            value,
            source: None,
            description: format!("格式默认（{}）", value.label()),
        })
    }

    /// Crop for one page. A page override replaces the book-wide value whole;
    /// both are personal reading records and never touch image bytes. The
    /// project chain supplies the fallback so a whole series can share one
    /// trim without writing a record per book.
    pub fn effective_crop(&self, book: Id, page: Id) -> Result<CropInsets> {
        let b = self.book(book)?;
        if !b.format.is_fixed_page() {
            return Err(Error::Invalid("裁边只用于固定页面".into()));
        }
        if !b.pages.iter().any(|p| p.id == page) {
            return Err(Error::NotFound("页面", page));
        }
        if let Some(insets) = self
            .crop
            .get(&book)
            .and_then(|pages| pages.get(&page))
            .copied()
            .or_else(|| self.crop_books.get(&book).copied())
        {
            return Ok(insets);
        }
        let mut parent = Some(b.project);
        let mut visited = HashSet::new();
        while let Some(id) = parent {
            if !visited.insert(id) {
                return Err(Error::Invalid("项目继承出现循环".into()));
            }
            let p = self.project(id)?;
            if let Some(insets) = if b.format == Format::Pdf {
                p.defaults.pdf_crop
            } else {
                p.defaults.comic_crop
            } {
                return Ok(insets);
            }
            parent = p.parent;
        }
        Ok(CropInsets::default())
    }

    /// Where a page's crop currently comes from, mirroring
    /// [`Self::effective_direction`] so the panel can name the source.
    pub fn effective_crop_source(&self, book: Id) -> Result<Option<Id>> {
        let b = self.book(book)?;
        if !b.format.is_fixed_page() {
            return Err(Error::Invalid("裁边只用于固定页面".into()));
        }
        if self.crop_books.contains_key(&book) {
            return Ok(Some(book));
        }
        let mut parent = Some(b.project);
        let mut visited = HashSet::new();
        while let Some(id) = parent {
            if !visited.insert(id) {
                return Err(Error::Invalid("项目继承出现循环".into()));
            }
            let p = self.project(id)?;
            if (if b.format == Format::Pdf {
                p.defaults.pdf_crop
            } else {
                p.defaults.comic_crop
            })
            .is_some()
            {
                return Ok(Some(id));
            }
            parent = p.parent;
        }
        Ok(None)
    }

    /// Whether an explicit page-level override exists (drives "重置此页").
    pub fn has_page_crop(&self, book: Id, page: Id) -> bool {
        self.crop
            .get(&book)
            .is_some_and(|pages| pages.contains_key(&page))
    }
}

/// Book-wide crop, then per-page overrides.
pub type CropRecords = BTreeMap<Id, BTreeMap<Id, CropInsets>>;

fn gap_label(gap: Gap) -> &'static str {
    match gap {
        Gap::Gapped => "有缝",
        Gap::Seamless => "无缝",
    }
}
