// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
use crate::{BlobStore, Reader, Repository, TextIndexStore};
use aq_domain::{Catalog, Format, Id};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

/// Where a search runs. Absent project/book never widens to "all".
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SearchScope {
    /// Current project and every descendant project.
    Project { project: Id },
    /// A single book.
    Book { book: Id },
    /// Every shelf book, the default.
    #[default]
    All,
}

impl SearchScope {
    /// Missing ids are rejected so a stale UI cannot silently widen the scope.
    pub fn parse(scope: Option<&serde_json::Value>) -> crate::Result<Self> {
        let Some(value) = scope else {
            return Ok(Self::All);
        };
        let kind = value
            .get("kind")
            .and_then(serde_json::Value::as_str)
            .unwrap_or("all");
        let id = |key: &str| -> crate::Result<Id> {
            value
                .get(key)
                .and_then(serde_json::Value::as_str)
                .ok_or_else(|| aq_domain::Error::Invalid(format!("缺少范围编号 {key}")))?
                .parse()
                .map_err(|_| aq_domain::Error::Invalid(format!("范围编号无效 {key}")).into())
        };
        match kind {
            "book" => Ok(Self::Book { book: id("book")? }),
            "project" => Ok(Self::Project {
                project: id("project")?,
            }),
            "all" => Ok(Self::All),
            other => Err(aq_domain::Error::Invalid(format!("未知搜索范围：{other}")).into()),
        }
    }
    pub fn label(&self) -> &'static str {
        match self {
            Self::Project { .. } => "当前项目及子项目",
            Self::Book { .. } => "当前书",
            Self::All => "全部内容",
        }
    }
}

#[derive(Serialize)]
pub struct TextHit {
    pub book: Id,
    pub paragraph: usize,
    pub snippet: String,
}
#[derive(Serialize)]
pub struct IndexStatus {
    pub indexed: usize,
    pub eligible: usize,
    pub failures: Vec<String>,
}

fn indexed_books<'a>(
    c: &'a Catalog,
    scope: &SearchScope,
) -> crate::Result<Vec<&'a aq_domain::Book>> {
    // The allowed sets hold project ids, so books are matched by `b.project`;
    // a book scope compares book ids instead.
    let (projects, books) = match scope {
        SearchScope::All => (None, None),
        SearchScope::Book { book } => (None, Some(HashSet::from([c.book(*book)?.id]))),
        SearchScope::Project { project } => (Some(subtree(c, *project)?), None),
    };
    Ok(c.books
        .iter()
        .filter(|b| !b.archived && matches!(b.format, Format::Txt | Format::Markdown))
        .filter(|b| projects.as_ref().is_none_or(|set| set.contains(&b.project)))
        .filter(|b| books.as_ref().is_none_or(|set| set.contains(&b.id)))
        .collect())
}

/// The project plus all descendants. `parent` is an `Option`, so the loop walks
/// down through `Some(current)` instead of comparing against a bare id.
/// `set.insert` rejects cycles instead of looping forever.
fn subtree(c: &Catalog, project: Id) -> crate::Result<HashSet<Id>> {
    c.project(project)?;
    let mut set = HashSet::from([project]);
    let mut frontier = vec![project];
    while let Some(current) = frontier.pop() {
        for p in c.projects.iter().filter(|p| p.parent == Some(current)) {
            if set.insert(p.id) {
                frontier.push(p.id);
            }
        }
    }
    Ok(set)
}

// Use the operation's catalog snapshot, rather than reloading and decoding the
// entire catalog once per book merely to read its encoding preference.
fn text_index_key(catalog: &Catalog, book: Id, hash: &str) -> String {
    let encoding = catalog.text_encodings.get(&book).and_then(|v| v.as_deref());
    format!("{hash}:{}", encoding.unwrap_or("auto-v1"))
}

impl<R: Repository + TextIndexStore, B: BlobStore> Reader<R, B> {
    pub fn index_status(&self, scope: &SearchScope) -> crate::Result<IndexStatus> {
        let c = self.catalog()?;
        let mut status = IndexStatus {
            indexed: 0,
            eligible: 0,
            failures: vec![],
        };
        for b in indexed_books(&c, scope)? {
            status.eligible += 1;
            if let Some(page) = b.pages.first()
                && self
                    .repository
                    .has_text_index(b.id, &text_index_key(&c, b.id, &page.resource.sha256))?
            {
                status.indexed += 1;
            }
        }
        Ok(status)
    }
    pub fn build_text_index(&mut self, scope: &SearchScope) -> crate::Result<IndexStatus> {
        let c = self.catalog()?;
        let mut failures = vec![];
        for b in indexed_books(&c, scope)? {
            let Some(page) = b.pages.first() else {
                continue;
            };
            if self
                .repository
                .has_text_index(b.id, &text_index_key(&c, b.id, &page.resource.sha256))?
            {
                continue;
            }
            match self.text_in(&c, b.id) {
                Ok(doc) => self.repository.store_text_index(
                    b.id,
                    &text_index_key(&c, b.id, &page.resource.sha256),
                    &doc.paragraphs,
                )?,
                Err(e) => failures.push(format!("{}: {e}", b.title)),
            }
        }
        let mut status = self.index_status(scope)?;
        status.failures = failures;
        Ok(status)
    }
    pub fn search_text(&self, query: &str, scope: &SearchScope) -> crate::Result<Vec<TextHit>> {
        let query = query.trim().to_lowercase();
        if query.is_empty() || query.chars().count() > 200 {
            return Err(aq_domain::Error::Invalid("搜索词需为 1–200 个字符".into()).into());
        }
        let c = self.catalog()?;
        let mut results = vec![];
        for b in indexed_books(&c, scope)? {
            let Some(page) = b.pages.first() else {
                continue;
            };
            let hits = self.repository.query_text_index(
                b.id,
                &text_index_key(&c, b.id, &page.resource.sha256),
                &query,
                100 - results.len(),
            )?;
            results.extend(hits);
            if results.len() == 100 {
                break;
            }
        }
        Ok(results)
    }
}
