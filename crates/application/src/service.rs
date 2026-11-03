// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
use crate::{BlobStore, Error, Repository};
use aq_domain::{
    Book, Catalog, CropInsets, Format, Gap, Id, Operation, ReadingDirection, reverse_selected,
};
use std::time::{SystemTime, UNIX_EPOCH};

pub struct Reader<R, B> {
    pub repository: R,
    pub blobs: B,
}

impl<R: Repository, B: BlobStore> Reader<R, B> {
    pub fn catalog(&self) -> crate::Result<Catalog> {
        self.repository.load()
    }

    pub fn create_project(&mut self, parent: Id, name: &str) -> crate::Result<Id> {
        let mut c = self.repository.load()?;
        self.ensure_owned(&c, parent)?;
        let expected = c.revision;
        let id = c.add_project(parent, name)?;
        self.record(&mut c, "create_project", id, None, None);
        c.revision += 1;
        self.repository.save(expected, &c)?;
        Ok(id)
    }

    pub fn move_project(&mut self, project: Id, parent: Id) -> crate::Result<()> {
        let mut c = self.repository.load()?;
        self.ensure_owned(&c, project)?;
        self.ensure_owned(&c, parent)?;
        let expected = c.revision;
        c.move_project(project, parent)?;
        self.record(&mut c, "move_project", project, None, None);
        c.revision += 1;
        self.repository.save(expected, &c)
    }

    pub fn set_project_gap(&mut self, project: Id, gap: Option<Gap>) -> crate::Result<()> {
        let mut c = self.repository.load()?;
        self.ensure_owned(&c, project)?;
        let expected = c.revision;
        c.projects
            .iter_mut()
            .find(|p| p.id == project)
            .unwrap()
            .defaults
            .comic_gap = gap;
        self.record(&mut c, "set_project_comic_gap", project, None, None);
        c.revision += 1;
        self.repository.save(expected, &c)
    }

    pub fn set_book_gap(&mut self, book: Id, gap: Option<Gap>) -> crate::Result<()> {
        self.change_book(book, "set_book_gap", |b| {
            if !b.format.is_fixed_page() {
                return Err(aq_domain::Error::Invalid("只有漫画可设置页面间隔".into()));
            }
            b.gap = gap;
            b.revision += 1;
            Ok(())
        })
    }

    pub fn reverse_pages(&mut self, book: Id, selected: &[Id]) -> crate::Result<()> {
        self.change_book(book, "reverse_pages", |b| reverse_selected(b, selected))
    }

    /// Retained project preference; per-book directions deliberately ignore it.
    pub fn set_project_direction(
        &mut self,
        project: Id,
        direction: Option<ReadingDirection>,
    ) -> crate::Result<()> {
        self.set_project_direction_for_format(project, direction, Format::Comic)
    }
    pub fn set_project_direction_for_format(
        &mut self,
        project: Id,
        direction: Option<ReadingDirection>,
        format: Format,
    ) -> crate::Result<()> {
        if !format.is_fixed_page() {
            return Err(aq_domain::Error::Invalid("格式不支持方向".into()).into());
        }
        let mut c = self.repository.load()?;
        self.ensure_owned(&c, project)?;
        let expected = c.revision;
        let defaults = &mut c
            .projects
            .iter_mut()
            .find(|p| p.id == project)
            .ok_or(aq_domain::Error::NotFound("项目", project))?
            .defaults;
        if format == Format::Pdf {
            defaults.pdf_direction = direction;
        } else {
            defaults.comic_direction = direction;
        }
        self.record(&mut c, "set_project_direction", project, None, None);
        c.revision += 1;
        self.repository.save(expected, &c)
    }

    /// Single-book direction override; `None` restores the format default.
    pub fn set_book_direction(
        &mut self,
        book: Id,
        direction: Option<ReadingDirection>,
    ) -> crate::Result<()> {
        self.change_book(book, "set_book_direction", |b| {
            if !b.format.is_fixed_page() {
                return Err(aq_domain::Error::Invalid(
                    "只有固定页面可设置阅读方向".into(),
                ));
            }
            b.direction = direction;
            b.revision += 1;
            Ok(())
        })
    }

    /// Turn a book back to a clean direction source: an explicit
    /// `inherit=true` drops the book override, otherwise a label is required so
    /// a right-to-left comic cannot be reset by naming only one of the three
    /// choices. This keeps the project chain from intervening unless the user
    /// actively picks it.
    pub fn resolve_book_direction(
        &mut self,
        book: Id,
        inherit: bool,
        label: Option<&str>,
    ) -> crate::Result<()> {
        if inherit {
            return self.set_book_direction(book, None);
        }
        let c = self.repository.load()?;
        if !c.book(book)?.format.is_fixed_page() {
            return Err(aq_domain::Error::Invalid("只有固定页面可设置阅读方向".into()).into());
        }
        let fallback = c.effective_direction(book)?.value;
        match label {
            None => self.set_book_direction(book, Some(fallback)),
            Some(name) => {
                let value = ReadingDirection::parse(name)
                    .ok_or_else(|| aq_domain::Error::Invalid(format!("未知阅读方向：{name}")))?;
                self.set_book_direction(book, Some(value))
            }
        }
    }

    /// Project-level crop default; identity clears the record so heirs fall
    /// back further up the chain instead of storing an explicit zero.
    pub fn set_project_crop(&mut self, project: Id, insets: CropInsets) -> crate::Result<()> {
        self.set_project_crop_for_format(project, insets, Format::Comic)
    }
    pub fn set_project_crop_for_format(
        &mut self,
        project: Id,
        insets: CropInsets,
        format: Format,
    ) -> crate::Result<()> {
        if !format.is_fixed_page() {
            return Err(aq_domain::Error::Invalid("格式不支持裁边".into()).into());
        }
        insets.validate()?;
        let mut c = self.repository.load()?;
        self.ensure_owned(&c, project)?;
        let expected = c.revision;
        let p = c
            .projects
            .iter_mut()
            .find(|p| p.id == project)
            .ok_or(aq_domain::Error::NotFound("项目", project))?;
        let next = (!insets.is_identity()).then_some(insets);
        let value = if format == Format::Pdf {
            &mut p.defaults.pdf_crop
        } else {
            &mut p.defaults.comic_crop
        };
        if *value == next {
            return Ok(());
        }
        *value = next;
        self.record(&mut c, "set_project_crop", project, None, None);
        c.revision += 1;
        self.repository.save(expected, &c)
    }

    /// Book-wide crop for every page without an override. Insets are relative,
    /// so they survive pages being reordered or re-rendered.
    pub fn set_book_crop(&mut self, book: Id, insets: CropInsets) -> crate::Result<()> {
        insets.validate()?;
        let mut c = self.repository.load()?;
        self.ensure_owned(&c, c.book(book)?.project)?;
        if !c.book(book)?.format.is_fixed_page() {
            return Err(aq_domain::Error::Invalid("裁边只用于固定页面".into()).into());
        }
        let expected = c.revision;
        if insets.is_identity() {
            if c.crop_books.remove(&book).is_none() {
                return Ok(());
            }
        } else {
            c.crop_books.insert(book, insets);
        }
        self.record(&mut c, "set_book_crop", book, None, None);
        c.revision += 1;
        self.repository.save(expected, &c)
    }

    /// Crop for one page. Identity resets the page back to the book value.
    pub fn set_page_crop(&mut self, book: Id, page: Id, insets: CropInsets) -> crate::Result<()> {
        insets.validate()?;
        let mut c = self.repository.load()?;
        self.ensure_owned(&c, c.book(book)?.project)?;
        let b = c.book(book)?;
        if !b.format.is_fixed_page() {
            return Err(aq_domain::Error::Invalid("裁边只用于固定页面".into()).into());
        }
        if !insets.is_identity() && !b.pages.iter().any(|p| p.id == page) {
            return Err(aq_domain::Error::NotFound("页面", page).into());
        }
        let expected = c.revision;
        let pages = c.crop.entry(book).or_default();
        if insets.is_identity() {
            if pages.remove(&page).is_none() {
                return Ok(());
            }
        } else {
            pages.insert(page, insets);
        }
        if c.crop.get(&book).is_some_and(|pages| pages.is_empty()) {
            c.crop.remove(&book);
        }
        self.record(&mut c, "set_page_crop", book, None, None);
        c.revision += 1;
        self.repository.save(expected, &c)
    }

    /// Undo only an unchanged book's last compatible state. Never silently overwrite.
    pub fn undo_book_change(&mut self, operation: Id) -> crate::Result<()> {
        let mut c = self.repository.load()?;
        let op = c
            .operations
            .iter()
            .find(|o| o.id == operation)
            .cloned()
            .ok_or(aq_domain::Error::NotFound("操作记录", operation))?;
        let (Some(mut before), Some(after)) = (op.before, op.after) else {
            return Err(Error::Unsupported("此操作没有可撤销的书籍快照".into()));
        };
        let current = c.book(op.target)?.clone();
        self.ensure_owned(&c, current.project)?;
        if current.revision != after.revision {
            return Err(Error::Conflict("书籍在该操作后发生了新修改".into()));
        }
        // External references can change without incrementing the book revision.
        // Reject an unsafe undo instead of silently removing personal data.
        self.ensure_owned(&c, before.project)?;
        let retained: std::collections::HashSet<_> =
            before.pages.iter().map(|page| page.id).collect();
        let removed: std::collections::HashSet<_> = current
            .pages
            .iter()
            .filter(|page| !retained.contains(&page.id))
            .map(|page| page.id)
            .collect();
        let referenced = c
            .notes
            .iter()
            .map(|n| (n.book, &n.location))
            .chain(c.progress.iter().map(|p| (p.book, &p.location)))
            .any(|(book, location)| {
                book == op.target
                    && matches!(location,
                aq_domain::Location::Page { page } if removed.contains(page))
            });
        let cropped = c
            .crop
            .get(&op.target)
            .is_some_and(|pages| removed.iter().any(|page| pages.contains_key(page)));
        if referenced || cropped {
            return Err(Error::Conflict(
                "撤销会移除已有笔记、阅读位置或裁边的页面，已保留当前书籍".into(),
            ));
        }
        before.title = aq_domain::unique_name(
            &before.title,
            c.books
                .iter()
                .filter(|book| book.id != op.target && book.project == before.project)
                .map(|book| book.title.as_str()),
        );
        before.revision = current.revision + 1;
        let expected = c.revision;
        *c.book_mut(op.target)? = before.clone();
        self.record(
            &mut c,
            "undo_book_change",
            op.target,
            Some(current),
            Some(before),
        );
        c.revision += 1;
        c.validate_integrity()?;
        self.repository.save(expected, &c)
    }

    pub(crate) fn change_book(
        &mut self,
        book: Id,
        action: &str,
        change: impl FnOnce(&mut Book) -> aq_domain::Result<()>,
    ) -> crate::Result<()> {
        let mut c = self.repository.load()?;
        let before = c.book(book)?.clone();
        self.ensure_owned(&c, before.project)?;
        let expected = c.revision;
        change(c.book_mut(book)?)?;
        let after = c.book(book)?.clone();
        self.record(&mut c, action, book, Some(before), Some(after));
        c.revision += 1;
        self.repository.save(expected, &c)
    }

    pub(crate) fn ensure_owned(&self, c: &Catalog, project: Id) -> crate::Result<()> {
        if c.project(project)?.owner != c.actor {
            return Err(aq_domain::Error::Invalid(
                "M0 仅开放本机所有者操作，协作权限尚未实现".into(),
            )
            .into());
        }
        Ok(())
    }
    pub(crate) fn record(
        &self,
        c: &mut Catalog,
        action: &str,
        target: Id,
        before: Option<Book>,
        after: Option<Book>,
    ) {
        c.operations.push(Operation {
            id: Id::new_v4(),
            actor: c.actor,
            unix_seconds: SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap_or_default()
                .as_secs(),
            action: action.into(),
            target,
            before,
            after,
        });
    }
}
