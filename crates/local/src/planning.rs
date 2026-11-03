// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
use crate::{ensure_regular_path, fingerprint, storage};
use aq_application::{ImportPlan, PlannedBook, PlannedProject, PlannedResource, Result};
use aq_domain::{Catalog, Format, Id, Project, ReadingDefaults, natural_compare, unique_name};
use std::{
    fs,
    path::{Path, PathBuf},
};

/// Preview has no catalog or resource writes. IDs remain stable across retries.
pub fn plan_import(
    c: &Catalog,
    library_root: &Path,
    source: &Path,
    target: Id,
) -> Result<ImportPlan> {
    c.project(target)?;
    let source = std::path::absolute(source).map_err(storage)?;
    ensure_regular_path(&source)?;
    let source = fs::canonicalize(source).map_err(storage)?;
    let library = fs::canonicalize(library_root).map_err(storage)?;
    if source.starts_with(&library) || library.starts_with(&source) {
        return Err(storage("导入源不能是资料库内部，也不能包含资料库目录"));
    }
    let mut plan = ImportPlan {
        version: 1,
        task: Id::new_v4(),
        library: c.id,
        base_revision: c.revision,
        target,
        projects: vec![],
        books: vec![],
        issues: vec![],
    };
    if source.is_dir() {
        walk(&source, target, &mut plan, 0)?;
    } else if image(&source) {
        let title = stem(&source);
        let resource = planned(&source)?;
        plan.books.push(PlannedBook {
            id: Id::new_v4(),
            project: target,
            title,
            format: Format::Comic,
            resources: vec![resource],
        });
    } else {
        add_text(&source, target, &mut plan)?;
    }
    let scope = if source.is_dir() {
        source.as_path()
    } else {
        source.parent().ok_or_else(|| storage("源目录无效"))?
    };
    crate::markdown::collect_markdown_attachments(&mut plan, scope)?;
    // Preview the exact collision-resolved names used by the unchanged catalog.
    let mut projects = c.projects.clone();
    for p in &mut plan.projects {
        p.name = unique_name(
            &p.name,
            projects
                .iter()
                .filter(|x| x.parent == Some(p.parent))
                .map(|x| x.name.as_str()),
        );
        projects.push(Project {
            id: p.id,
            parent: Some(p.parent),
            name: p.name.clone(),
            owner: c.actor,
            defaults: ReadingDefaults::default(),
            color: 0,
        });
    }
    let mut book_names: Vec<_> = c
        .books
        .iter()
        .map(|b| (b.project, b.title.clone()))
        .collect();
    for b in &mut plan.books {
        b.title = unique_name(
            &b.title,
            book_names
                .iter()
                .filter(|(project, _)| *project == b.project)
                .map(|(_, title)| title.as_str()),
        );
        book_names.push((b.project, b.title.clone()));
    }
    Ok(plan)
}

fn walk(folder: &Path, parent: Id, plan: &mut ImportPlan, depth: usize) -> Result<()> {
    if depth > 64 {
        return Err(storage("目录嵌套超过 M0 的 64 层限制"));
    }
    let id = Id::new_v4();
    let name = name(folder);
    plan.projects.push(PlannedProject {
        id,
        parent,
        name: name.clone(),
    });
    let mut paths: Vec<PathBuf> = fs::read_dir(folder)
        .map_err(storage)?
        .map(|r| r.map(|e| e.path()).map_err(storage))
        .collect::<Result<_>>()?;
    paths.sort_by(|a, b| natural_compare(&name_of(a), &name_of(b)));
    let mut images = vec![];
    for path in paths {
        if let Err(error) = ensure_regular_path(&path) {
            plan.issues.push(error.to_string());
            continue;
        }
        if path.is_dir() {
            walk(&path, id, plan, depth + 1)?;
        } else if image(&path) {
            match planned(&path) {
                Ok(resource) => images.push(resource),
                Err(e) => plan.issues.push(e.to_string()),
            }
        } else {
            add_text(&path, id, plan)?;
        }
    }
    if !images.is_empty() {
        plan.books.push(PlannedBook {
            id: Id::new_v4(),
            project: id,
            title: name,
            format: Format::Comic,
            resources: images,
        });
    }
    Ok(())
}
fn add_text(path: &Path, project: Id, plan: &mut ImportPlan) -> Result<()> {
    let extension = path
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or_default();
    if let Some(format) = Format::from_extension(extension) {
        match planned(path) {
            Ok(resource) => plan.books.push(PlannedBook {
                id: Id::new_v4(),
                project,
                title: stem(path),
                format,
                resources: vec![resource],
            }),
            Err(e) => plan.issues.push(e.to_string()),
        }
    } else {
        plan.issues
            .push(format!("M0 暂不支持的文件：{}", path.display()));
    }
    Ok(())
}
fn planned(path: &Path) -> Result<PlannedResource> {
    let (bytes, sha256) = fingerprint(path)?;
    Ok(PlannedResource {
        id: Id::new_v4(),
        source: path.to_owned(),
        original_name: name(path),
        bytes,
        sha256,
    })
}
fn image(path: &Path) -> bool {
    matches!(
        path.extension()
            .and_then(|s| s.to_str())
            .unwrap_or_default()
            .to_ascii_lowercase()
            .as_str(),
        "jpg" | "jpeg" | "png" | "gif" | "webp"
    )
}
fn name(path: &Path) -> String {
    path.file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned()
}
fn name_of(path: &Path) -> String {
    name(path)
}
fn stem(path: &Path) -> String {
    path.file_stem()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned()
}
