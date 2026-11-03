// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
use crate::{BlobStore, Error, Reader, Repository};
use aq_domain::{
    Book, CompletedImport, Format, Id, Page, Project, ReadingDefaults, unique_name, valid_name,
};
use serde::{Deserialize, Serialize};
use std::{collections::HashSet, path::PathBuf};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PlannedResource {
    pub id: Id,
    pub source: PathBuf,
    pub original_name: String,
    pub bytes: u64,
    pub sha256: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PlannedProject {
    pub id: Id,
    pub parent: Id,
    pub name: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PlannedBook {
    pub id: Id,
    pub project: Id,
    pub title: String,
    pub format: Format,
    pub resources: Vec<PlannedResource>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct ImportPlan {
    pub version: u32,
    pub task: Id,
    pub library: Id,
    pub base_revision: u64,
    pub target: Id,
    pub projects: Vec<PlannedProject>,
    pub books: Vec<PlannedBook>,
    /// The CLI requires explicit --skip-issues to accept omissions.
    pub issues: Vec<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct AppendPlacement {
    pub book: Id,
    pub revision: u64,
    /// None appends; Some inserts before a stable existing page.
    pub before: Option<Id>,
}

impl<R: Repository, B: BlobStore> Reader<R, B> {
    /// One task is atomic at catalog level; replaying the same task is idempotent.
    pub fn import(
        &mut self,
        plan: &ImportPlan,
        skip_issues: bool,
    ) -> crate::Result<CompletedImport> {
        self.import_with_placement(plan, skip_issues, None)
    }

    pub fn import_with_placement(
        &mut self,
        plan: &ImportPlan,
        skip_issues: bool,
        append: Option<&AppendPlacement>,
    ) -> crate::Result<CompletedImport> {
        let mut catalog = self.repository.load()?;
        if plan.library != catalog.id || plan.version != 1 {
            return Err(Error::Unsupported("导入计划版本或目标资料库不匹配".into()));
        }
        if let Some(done) = catalog.imports.iter().find(|i| i.task == plan.task) {
            return Ok(done.clone());
        }
        if catalog.revision != plan.base_revision {
            return Err(Error::Conflict("导入预览后资料库已改变，请重新预览".into()));
        }
        self.ensure_owned(&catalog, plan.target)?;
        if let Some(placement) = append {
            let book = catalog.book(placement.book)?;
            self.ensure_owned(&catalog, book.project)?;
            if book.archived
                || book.format != Format::Comic
                || book.revision != placement.revision
                || plan.books.len() != 1
                || plan.books[0].format != Format::Comic
                || !plan.projects.is_empty()
                || placement
                    .before
                    .is_some_and(|id| !book.pages.iter().any(|p| p.id == id))
            {
                return Err(Error::Conflict(
                    "追加目标、版本或图片计划无效，请重新预览".into(),
                ));
            }
        }
        if !skip_issues && !plan.issues.is_empty() {
            return Err(Error::Unsupported(
                "预览存在异常；修复后重建计划，或明确 --skip-issues".into(),
            ));
        }
        if plan.books.is_empty() {
            return Err(Error::Unsupported("计划没有可导入的内容".into()));
        }
        let expected = catalog.revision;
        // Validate all topology and names before any bytes are copied.
        let mut identities: HashSet<Id> = catalog
            .projects
            .iter()
            .map(|p| p.id)
            .chain(catalog.books.iter().map(|b| b.id))
            .chain(
                catalog
                    .books
                    .iter()
                    .flat_map(|b| b.pages.iter().flat_map(|p| [p.id, p.resource.id])),
            )
            .collect();
        let mut allowed: HashSet<_> = catalog
            .projects
            .iter()
            .filter(|p| p.owner == catalog.actor)
            .map(|p| p.id)
            .collect();
        for p in &plan.projects {
            if !allowed.contains(&p.parent) || !identities.insert(p.id) {
                return Err(aq_domain::Error::Invalid("导入项目层级或身份无效".into()).into());
            }
            let name = valid_name(&p.name)?;
            let name = unique_name(
                &name,
                catalog
                    .projects
                    .iter()
                    .filter(|x| x.parent == Some(p.parent))
                    .map(|x| x.name.as_str()),
            );
            catalog.projects.push(Project {
                id: p.id,
                parent: Some(p.parent),
                name,
                owner: catalog.actor,
                defaults: ReadingDefaults::default(),
                color: 0,
            });
            allowed.insert(p.id);
        }
        for b in &plan.books {
            if !allowed.contains(&b.project)
                || !identities.insert(b.id)
                || b.resources.is_empty()
                || (matches!(b.format, Format::Txt | Format::Pdf) && b.resources.len() != 1)
            {
                return Err(aq_domain::Error::Invalid("导入书籍结构或身份无效".into()).into());
            }
            valid_name(&b.title)?;
            for resource in &b.resources {
                if !identities.insert(resource.id) {
                    return Err(aq_domain::Error::Invalid("资源身份重复".into()).into());
                }
            }
        }
        let resource_ids: Vec<_> = plan
            .books
            .iter()
            .flat_map(|book| book.resources.iter().map(|r| r.id))
            .collect();
        let _resource_lease = self.blobs.begin_import(plan.task, &resource_ids)?;
        for b in &plan.books {
            let mut pages = vec![];
            for source in &b.resources {
                pages.push(Page {
                    id: Id::new_v4(),
                    resource: self.blobs.put(source)?,
                });
            }
            if let Some(placement) = append {
                let before = catalog.book(placement.book)?.clone();
                let target = catalog.book_mut(placement.book)?;
                let index = placement
                    .before
                    .map(|id| target.pages.iter().position(|p| p.id == id).unwrap())
                    .unwrap_or(target.pages.len());
                target.pages.splice(index..index, pages);
                target.revision += 1;
                let after = target.clone();
                self.record(
                    &mut catalog,
                    "append_pages",
                    placement.book,
                    Some(before),
                    Some(after),
                );
                continue;
            }
            let title = valid_name(&b.title)?;
            let title = unique_name(
                &title,
                catalog
                    .books
                    .iter()
                    .filter(|x| x.project == b.project)
                    .map(|x| x.title.as_str()),
            );
            let book = Book {
                metadata: Default::default(),
                archived: false,
                id: b.id,
                project: b.project,
                title,
                format: b.format,
                revision: 1,
                gap: None,
                direction: None,
                pages,
            };
            self.record(
                &mut catalog,
                "import_book",
                book.id,
                None,
                Some(book.clone()),
            );
            catalog.books.push(book);
        }
        let completed = CompletedImport {
            task: plan.task,
            projects: plan.projects.iter().map(|p| p.id).collect(),
            books: append
                .map(|p| vec![p.book])
                .unwrap_or_else(|| plan.books.iter().map(|b| b.id).collect()),
        };
        catalog.imports.push(completed.clone());
        catalog.revision += 1;
        self.repository.save(expected, &catalog)?;
        Ok(completed)
    }
}
