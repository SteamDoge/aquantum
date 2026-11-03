// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
use crate::*;
use std::collections::HashSet;

impl Catalog {
    /// Current, archived and recoverable historical states all pin their bytes.
    pub fn retained_resources(&self) -> impl Iterator<Item = &Resource> {
        self.books
            .iter()
            .chain(
                self.operations
                    .iter()
                    .flat_map(|op| op.before.iter().chain(op.after.iter())),
            )
            .flat_map(|book| {
                book.pages
                    .iter()
                    .map(|page| &page.resource)
                    .chain(book.metadata.cover.iter())
            })
    }
    pub fn project(&self, id: Id) -> Result<&Project> {
        self.projects
            .iter()
            .find(|p| p.id == id)
            .ok_or(Error::NotFound("项目", id))
    }
    pub fn book(&self, id: Id) -> Result<&Book> {
        self.books
            .iter()
            .find(|b| b.id == id)
            .ok_or(Error::NotFound("书籍", id))
    }
    pub fn book_mut(&mut self, id: Id) -> Result<&mut Book> {
        self.books
            .iter_mut()
            .find(|b| b.id == id)
            .ok_or(Error::NotFound("书籍", id))
    }
    pub fn add_project(&mut self, parent: Id, name: &str) -> Result<Id> {
        self.project(parent)?;
        let name = valid_name(name)?;
        let name = unique_name(
            &name,
            self.projects
                .iter()
                .filter(|p| p.parent == Some(parent))
                .map(|p| p.name.as_str()),
        );
        let id = Id::new_v4();
        self.projects.push(Project {
            id,
            parent: Some(parent),
            name,
            owner: self.actor,
            defaults: ReadingDefaults::default(),
            color: 0,
        });
        Ok(id)
    }
    pub fn move_project(&mut self, id: Id, new_parent: Id) -> Result<()> {
        if id == self.inbox {
            return Err(Error::Invalid("收件箱不可移动".into()));
        }
        self.project(id)?;
        let mut current = Some(new_parent);
        let mut visited = HashSet::new();
        while let Some(next) = current {
            if next == id || !visited.insert(next) {
                return Err(Error::Invalid("项目不能移入自身或子项目".into()));
            }
            current = self.project(next)?.parent;
        }
        let name = self.project(id)?.name.clone();
        let name = unique_name(
            &name,
            self.projects
                .iter()
                .filter(|p| p.parent == Some(new_parent) && p.id != id)
                .map(|p| p.name.as_str()),
        );
        let p = self.projects.iter_mut().find(|p| p.id == id).unwrap();
        p.parent = Some(new_parent);
        p.name = name;
        Ok(())
    }
    pub fn validate_version(&self) -> Result<()> {
        if self.schema_version != DATA_VERSION {
            return Err(Error::Version(self.schema_version));
        }
        Ok(())
    }
}

pub fn valid_name(name: &str) -> Result<String> {
    let name = name.trim();
    if name.is_empty() || name.chars().any(char::is_control) {
        return Err(Error::Invalid("名称不能为空或包含控制字符".into()));
    }
    Ok(name.to_string())
}

pub fn unique_name<'a>(desired: &str, existing: impl Iterator<Item = &'a str>) -> String {
    let names: HashSet<_> = existing.collect();
    if !names.contains(desired) {
        return desired.into();
    }
    for n in 1.. {
        let candidate = format!("{desired}（{n}）");
        if !names.contains(candidate.as_str()) {
            return candidate;
        }
    }
    unreachable!()
}

pub fn reverse_selected(book: &mut Book, selected: &[Id]) -> Result<()> {
    if book.format != Format::Comic {
        return Err(Error::Invalid("此格式不支持页面反转".into()));
    }
    let selection: HashSet<_> = selected.iter().copied().collect();
    if selection.is_empty()
        || selection.len() != selected.len()
        || selection
            .iter()
            .any(|id| !book.pages.iter().any(|p| p.id == *id))
    {
        return Err(Error::Invalid("选中页为空、重复或不存在".into()));
    }
    let indices: Vec<_> = book
        .pages
        .iter()
        .enumerate()
        .filter_map(|(i, p)| selection.contains(&p.id).then_some(i))
        .collect();
    for i in 0..indices.len() / 2 {
        book.pages.swap(indices[i], indices[indices.len() - 1 - i]);
    }
    book.revision += 1;
    Ok(())
}
