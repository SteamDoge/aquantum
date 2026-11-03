// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
//! Stable page identities, ordering and optimistic edits shared by every client.
use crate::{BlobStore, Error, Reader, Repository, Result};
use aq_domain::{Book, Format, Id, Page};
use std::collections::HashSet;

pub fn selected_pages(book: &Book, ids: &[Id]) -> Result<Vec<Page>> {
    let selected: HashSet<_> = ids.iter().copied().collect();
    if book.format != Format::Comic || selected.is_empty() || selected.len() != ids.len() {
        return Err(Error::Unsupported("请选择不重复的漫画页面".into()));
    }
    let pages: Vec<_> = book
        .pages
        .iter()
        .filter(|p| selected.contains(&p.id))
        .cloned()
        .collect();
    if pages.len() != selected.len() {
        return Err(Error::Conflict("所选页面已改变".into()));
    }
    Ok(pages)
}

impl<R: Repository, B: BlobStore> Reader<R, B> {
    /// Complete permutation prevents accidentally dropping/duplicating a page.
    pub fn reorder_pages(&mut self, book: Id, revision: u64, order: &[Id]) -> Result<()> {
        self.change_book(book, "reorder_pages", |b| {
            if b.revision != revision {
                return Err(aq_domain::Error::Invalid("页面已更新，请刷新后重试".into()));
            }
            let ids: HashSet<_> = order.iter().copied().collect();
            if b.format != Format::Comic
                || order.len() != b.pages.len()
                || ids.len() != order.len()
                || b.pages.iter().any(|p| !ids.contains(&p.id))
            {
                return Err(aq_domain::Error::Invalid(
                    "页序必须完整包含所有页面且不能重复".into(),
                ));
            }
            let mut pages: std::collections::HashMap<_, _> = std::mem::take(&mut b.pages)
                .into_iter()
                .map(|p| (p.id, p))
                .collect();
            b.pages = order.iter().map(|id| pages.remove(id).unwrap()).collect();
            b.revision += 1;
            Ok(())
        })
    }

    /// Stable anchor is interpreted after removing the selection. None means end.
    pub fn move_pages(
        &mut self,
        book: Id,
        revision: u64,
        selected: &[Id],
        before: Option<Id>,
    ) -> Result<()> {
        let c = self.catalog()?;
        let b = c.book(book)?;
        let pages = selected_pages(b, selected)?;
        if before.is_some_and(|id| pages.iter().any(|p| p.id == id)) {
            return Err(Error::Unsupported("目标页不能包含在所选页面中".into()));
        }
        let mut order: Vec<_> = b
            .pages
            .iter()
            .filter(|p| !selected.contains(&p.id))
            .map(|p| p.id)
            .collect();
        let index = match before {
            Some(id) => order
                .iter()
                .position(|p| *p == id)
                .ok_or_else(|| Error::Conflict("目标页已不存在".into()))?,
            None => order.len(),
        };
        order.splice(index..index, pages.iter().map(|p| p.id));
        self.reorder_pages(book, revision, &order)
    }

    /// Called only after a verified archive has been published successfully.
    pub fn cut_exported_pages(&mut self, book: Id, revision: u64, selected: &[Id]) -> Result<()> {
        let mut c = self.catalog()?;
        let original = c.book(book)?.clone();
        selected_pages(&original, selected)?;
        self.ensure_owned(&c, original.project)?;
        if original.revision != revision {
            return Err(Error::Conflict(
                "已导出副本，但源书发生变化，未剪切任何页面".into(),
            ));
        }
        if selected.len() == original.pages.len() {
            return Err(Error::Unsupported(
                "保留至少一页；整书移出请使用书架操作".into(),
            ));
        }
        // Do not invalidate existing personal anchors. A copy export is always safe.
        let referenced = c.notes.iter().map(|n| (&n.book, &n.location))
            .chain(c.progress.iter().map(|p| (&p.book, &p.location)))
            .any(|(id, location)| *id == book && matches!(location, aq_domain::Location::Page { page } if selected.contains(page)));
        let cropped = c
            .crop
            .get(&book)
            .is_some_and(|pages| selected.iter().any(|page| pages.contains_key(page)));
        if referenced || cropped {
            return Err(Error::Unsupported(
                "已导出副本；所选页包含笔记、阅读位置或裁边，保留源页以保护关联".into(),
            ));
        }
        let expected = c.revision;
        let b = c.book_mut(book)?;
        b.pages.retain(|p| !selected.contains(&p.id));
        b.revision += 1;
        let after = b.clone();
        self.record(
            &mut c,
            "cut_exported_pages",
            book,
            Some(original),
            Some(after),
        );
        c.revision += 1;
        self.repository.save(expected, &c)
    }
}
