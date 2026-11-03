// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
//! Validate restored catalogs before any active library selection can change.
use crate::*;
use std::collections::{HashMap, HashSet};

impl Catalog {
    pub fn validate_integrity(&self) -> Result<()> {
        self.validate_version()?;
        let mut ids = HashSet::new();
        for p in &self.projects {
            if !ids.insert(p.id) {
                return Err(Error::Invalid("项目身份重复".into()));
            }
            valid_name(&p.name)?;
        }
        if self.project(self.inbox)?.parent.is_some() {
            return Err(Error::Invalid("收件箱不能有父项目".into()));
        }
        for p in &self.projects {
            let mut seen = HashSet::new();
            let mut next = Some(p.id);
            while let Some(id) = next {
                if !seen.insert(id) {
                    return Err(Error::Invalid("项目层级循环".into()));
                }
                next = self.project(id)?.parent;
            }
        }
        let mut current_pages = HashSet::new();
        for b in &self.books {
            if !ids.insert(b.id) || b.pages.is_empty() || b.revision == 0 {
                return Err(Error::Invalid("书籍身份、版本或资源无效".into()));
            }
            self.project(b.project)?;
            valid_name(&b.title)?;
            if b.format == Format::Txt && b.pages.len() != 1 {
                return Err(Error::Invalid("TXT 正文结构无效".into()));
            }
            let mut per_book = HashSet::new();
            for p in &b.pages {
                if !per_book.insert(p.id) || !current_pages.insert(p.id) {
                    return Err(Error::Invalid("当前页面身份重复".into()));
                }
            }
            if b.format == Format::Pdf
                && b.pages
                    .iter()
                    .any(|p| p.resource.id != b.pages[0].resource.id)
            {
                return Err(Error::Invalid("PDF 固定页必须引用相同原件".into()));
            }
        }
        let mut resources = HashMap::new();
        for r in self.retained_resources() {
            if r.sha256.len() != 64
                || !r.sha256.bytes().all(|b| b.is_ascii_hexdigit())
                || ids.contains(&r.id)
                || current_pages.contains(&r.id)
            {
                return Err(Error::Invalid("资源身份或校验信息无效".into()));
            }
            if let Some(old) = resources.insert(r.id, (r.bytes, r.sha256.as_str()))
                && old != (r.bytes, r.sha256.as_str())
            {
                return Err(Error::Invalid("同身份资源字节信息不一致".into()));
            }
        }
        let mut personal = HashSet::new();
        for p in &self.progress {
            self.book(p.book)?;
            if !personal.insert((p.actor, p.book)) {
                return Err(Error::Invalid("个人进度重复".into()));
            }
        }
        for n in &self.notes {
            self.book(n.book)?;
            if !ids.insert(n.id) || n.markdown.trim().is_empty() {
                return Err(Error::Invalid("笔记身份或正文无效".into()));
            }
        }
        let mut operations = HashSet::new();
        for op in &self.operations {
            if !operations.insert(op.id) {
                return Err(Error::Invalid("历史身份重复".into()));
            }
        }
        let mut tasks = HashSet::new();
        for task in &self.imports {
            if !tasks.insert(task.task) {
                return Err(Error::Invalid("导入完成回执重复".into()));
            }
        }
        for (book, encoding) in &self.text_encodings {
            if self.books.iter().all(|b| b.id != *book) {
                return Err(Error::Invalid("编码选择指向不存在的书籍".into()));
            }
            if !matches!(self.book(*book)?.format, Format::Txt | Format::Markdown) {
                return Err(Error::Invalid("编码选择只能用于文字书籍".into()));
            }
            if let Some(name) = encoding
                && (name.trim().is_empty() || name.chars().count() > 40)
            {
                return Err(Error::Invalid("编码名称无效".into()));
            }
        }
        for book in self
            .crop_books
            .keys()
            .chain(self.crop.keys())
            .collect::<HashSet<_>>()
        {
            if !self.book(*book)?.format.is_fixed_page() {
                return Err(Error::Invalid("裁边记录只能用于图片页书籍".into()));
            }
        }
        for insets in self.crop_books.values() {
            insets.validate()?;
        }
        // Project-level defaults are inherited by every comic below them, so an
        // invalid value must never reach storage in the first place.
        for project in &self.projects {
            if let Some(insets) = project.defaults.pdf_crop {
                insets.validate()?;
            }
            if let Some(insets) = project.defaults.comic_crop {
                insets.validate()?;
            }
        }
        for (book, pages) in &self.crop {
            for (page, insets) in pages {
                let b = self.book(*book)?;
                if !b.pages.iter().any(|p| p.id == *page) {
                    return Err(Error::Invalid("裁边记录指向不存在的页面".into()));
                }
                insets.validate()?;
            }
        }
        Ok(())
    }
}
