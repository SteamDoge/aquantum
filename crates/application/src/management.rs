// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
//! Metadata operations preserve stable IDs, original blobs and personal records.
use crate::{BlobStore, Reader, Repository};
use aq_domain::{Id, unique_name, valid_name};

impl<R: Repository, B: BlobStore> Reader<R, B> {
    /// Persist an explicitly confirmed selection; never modify source bytes.
    /// The caller cannot forge a cover resource: only verified import plans may
    /// create one. Old covers remain pinned by operation history.
    pub fn update_book_metadata(
        &mut self,
        id: Id,
        revision: u64,
        title: &str,
        mut metadata: aq_domain::BookMetadata,
        cover: Option<&crate::PlannedResource>,
        clear_cover: bool,
    ) -> crate::Result<aq_domain::Book> {
        let mut c = self.catalog()?;
        let before = c.book(id)?.clone();
        self.ensure_owned(&c, before.project)?;
        if before.revision != revision {
            return Err(crate::Error::Conflict(
                "书籍已变化，请重新打开信息页".into(),
            ));
        }
        let title = valid_name(title)?;
        if title.chars().count() > 512
            || [
                &metadata.author,
                &metadata.publisher,
                &metadata.isbn,
                &metadata.provider,
                &metadata.source_id,
            ]
            .iter()
            .any(|v| v.chars().count() > 2048)
            || metadata.summary.chars().count() > 20000
        {
            return Err(aq_domain::Error::Invalid("书籍信息超过长度上限".into()).into());
        }
        let title = unique_name(
            &title,
            c.books
                .iter()
                .filter(|b| b.project == before.project && b.id != id)
                .map(|b| b.title.as_str()),
        );
        let expected = c.revision;
        metadata.cover = if clear_cover {
            None
        } else {
            before.metadata.cover.clone()
        };
        let _lease = if let Some(source) = cover {
            if source.bytes == 0 || source.bytes > 8 * 1024 * 1024 {
                return Err(aq_domain::Error::Invalid("封面须为不超过8MiB的图片".into()).into());
            }
            // A standalone cover has one immutable resource; its identity also
            // identifies the publication pin for the local caller to retire.
            let lease = self.blobs.begin_import(source.id, &[source.id])?;
            metadata.cover = Some(self.blobs.put(source)?);
            Some(lease)
        } else {
            None
        };
        let book = c.book_mut(id)?;
        book.title = title;
        book.metadata = metadata;
        book.revision += 1;
        let after = book.clone();
        self.record(
            &mut c,
            "book_metadata",
            id,
            Some(before),
            Some(after.clone()),
        );
        c.revision += 1;
        self.repository.save(expected, &c)?;
        Ok(after)
    }

    pub fn move_books(&mut self, ids: &[Id], target: Id) -> crate::Result<()> {
        let mut c = self.catalog()?;
        self.ensure_owned(&c, target)?;
        if ids.is_empty()
            || ids.len() > 512
            || ids.iter().collect::<std::collections::HashSet<_>>().len() != ids.len()
        {
            return Err(aq_domain::Error::Invalid("批量文件为空、重复或超过上限".into()).into());
        }
        for id in ids {
            self.ensure_owned(&c, c.book(*id)?.project)?;
        }
        let expected = c.revision;
        for id in ids {
            let before = c.book(*id)?.clone();
            let title = unique_name(
                &before.title,
                c.books
                    .iter()
                    .filter(|b| b.project == target && b.id != *id)
                    .map(|b| b.title.as_str()),
            );
            let b = c.book_mut(*id)?;
            b.title = title;
            b.project = target;
            b.revision += 1;
            let after = c.book(*id)?.clone();
            self.record(&mut c, "book_move", *id, Some(before), Some(after));
        }
        c.revision += 1;
        self.repository.save(expected, &c)
    }
    pub fn rename_project(&mut self, id: Id, name: &str) -> crate::Result<()> {
        let mut c = self.catalog()?;
        self.ensure_owned(&c, id)?;
        let parent = c.project(id)?.parent;
        let name = unique_name(
            &valid_name(name)?,
            c.projects
                .iter()
                .filter(|p| p.parent == parent && p.id != id)
                .map(|p| p.name.as_str()),
        );
        let expected = c.revision;
        c.projects.iter_mut().find(|p| p.id == id).unwrap().name = name;
        self.record(&mut c, "rename_project", id, None, None);
        c.revision += 1;
        self.repository.save(expected, &c)
    }

    pub fn color_project(&mut self, id: Id, color: u8) -> crate::Result<()> {
        if color > 5 {
            return Err(aq_domain::Error::Invalid("文件夹颜色无效".into()).into());
        }
        let mut c = self.catalog()?;
        self.ensure_owned(&c, id)?;
        let expected = c.revision;
        c.projects.iter_mut().find(|p| p.id == id).unwrap().color = color;
        self.record(&mut c, "color_project", id, None, None);
        c.revision += 1;
        self.repository.save(expected, &c)
    }

    pub fn delete_empty_project(&mut self, id: Id) -> crate::Result<()> {
        let mut c = self.catalog()?;
        self.ensure_owned(&c, id)?;
        if id == c.inbox
            || c.projects.iter().any(|p| p.parent == Some(id))
            || c.books.iter().any(|b| b.project == id)
        {
            return Err(aq_domain::Error::Invalid(
                "仅可删除空项目；请先移动其全部内容，收件箱不可删除".into(),
            )
            .into());
        }
        let expected = c.revision;
        c.projects.retain(|p| p.id != id);
        self.record(&mut c, "delete_empty_project", id, None, None);
        c.revision += 1;
        self.repository.save(expected, &c)
    }

    pub fn manage_book(
        &mut self,
        id: Id,
        action: &str,
        name: Option<&str>,
        target: Option<Id>,
    ) -> crate::Result<Id> {
        let mut c = self.catalog()?;
        let before = c.book(id)?.clone();
        self.ensure_owned(&c, before.project)?;
        if let Some(target) = target {
            self.ensure_owned(&c, target)?;
        }
        let expected = c.revision;
        let result = match action {
            "rename" => {
                let title = unique_name(
                    &valid_name(name.unwrap_or(""))?,
                    c.books
                        .iter()
                        .filter(|b| b.project == before.project && b.id != id)
                        .map(|b| b.title.as_str()),
                );
                c.book_mut(id)?.title = title;
                id
            }
            "move" | "remove" => {
                let project = if action == "remove" {
                    c.inbox
                } else {
                    target.ok_or_else(|| aq_domain::Error::Invalid("缺少目标项目".into()))?
                };
                let title = unique_name(
                    &before.title,
                    c.books
                        .iter()
                        .filter(|b| b.project == project && b.id != id)
                        .map(|b| b.title.as_str()),
                );
                let book = c.book_mut(id)?;
                book.project = project;
                book.title = title;
                id
            }
            "copy" => {
                let mut copy = before.clone();
                copy.id = Id::new_v4();
                copy.project = target.unwrap_or(before.project);
                copy.title = unique_name(
                    &before.title,
                    c.books
                        .iter()
                        .filter(|b| b.project == copy.project)
                        .map(|b| b.title.as_str()),
                );
                copy.revision = 1;
                copy.archived = false;
                for page in &mut copy.pages {
                    page.id = Id::new_v4();
                }
                let copied = copy.id;
                c.books.push(copy);
                copied
            }
            "archive" | "restore" => {
                c.book_mut(id)?.archived = action == "archive";
                id
            }
            _ => return Err(aq_domain::Error::Invalid("不支持的文件操作".into()).into()),
        };
        if result == id {
            c.book_mut(id)?.revision += 1;
        }
        let after = c.book(result)?.clone();
        self.record(
            &mut c,
            &format!("book_{action}"),
            result,
            if action == "copy" { None } else { Some(before) },
            Some(after),
        );
        c.revision += 1;
        self.repository.save(expected, &c)?;
        Ok(result)
    }
}
