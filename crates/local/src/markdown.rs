// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
//! Offline Markdown dependencies. Referenced bytes stay within the selected scope.
use crate::{ensure_regular_path, fingerprint, storage};
use aq_application::{ImportPlan, PlannedResource, Result};
use aq_domain::{Format, Id};
use pulldown_cmark::{Event, Options, Parser, Tag};
use std::{collections::HashSet, fs, path::Path};

pub fn suppress_attachment_comics(plan: &mut ImportPlan) {
    let consumed: HashSet<_> = plan
        .books
        .iter()
        .filter(|b| b.format == Format::Markdown)
        .flat_map(|b| b.resources.iter().skip(1).map(|r| r.source.clone()))
        .collect();
    for book in &mut plan.books {
        if book.format == Format::Comic {
            book.resources.retain(|r| !consumed.contains(&r.source));
        }
    }
    plan.books.retain(|b| !b.resources.is_empty());
}

pub(crate) fn collect_markdown_attachments(plan: &mut ImportPlan, scope: &Path) -> Result<()> {
    let scope = fs::canonicalize(scope).map_err(storage)?;
    let mut consumed = HashSet::new();
    for book in &mut plan.books {
        if book.format != Format::Markdown {
            continue;
        }
        let source = book.resources[0].source.clone();
        if book.resources[0].bytes > aq_application::reading::TEXT_LIMIT {
            plan.issues
                .push(format!("{}：Markdown 超过 32 MiB", book.title));
            continue;
        }
        let bytes = fs::read(&source).map_err(storage)?;
        let Ok(text) = String::from_utf8(bytes) else {
            plan.issues
                .push(format!("{}：Markdown 编码当前无法解析附件", book.title));
            continue;
        };
        book.resources[0].original_name = source
            .strip_prefix(&scope)
            .map_err(storage)?
            .to_string_lossy()
            .replace('\\', "/");
        let mut seen = HashSet::from([source.clone()]);
        let mut attachment_bytes = 0u64;
        for event in Parser::new_ext(&text, Options::all()) {
            let url = match event {
                Event::Start(Tag::Image { dest_url, .. })
                | Event::Start(Tag::Link { dest_url, .. }) => dest_url,
                _ => continue,
            };
            if url.is_empty() || url.starts_with('#') || url.starts_with("//") || url.contains(':')
            {
                continue;
            }
            let raw = url.split(['#', '?']).next().unwrap_or_default();
            let Ok(decoded) = percent_encoding::percent_decode_str(raw).decode_utf8() else {
                plan.issues
                    .push(format!("{}：附件编码无效 {url}", book.title));
                continue;
            };
            let relative = decoded.replace('\\', "/");
            if relative.starts_with('/')
                || relative.contains(':')
                || relative.chars().any(char::is_control)
            {
                plan.issues
                    .push(format!("{}：附件路径无效 {url}", book.title));
                continue;
            }
            let path = source
                .parent()
                .ok_or_else(|| storage("Markdown 目录无效"))?
                .join(relative);
            let checked = (|| -> Result<_> {
                ensure_regular_path(&path)?;
                let path = fs::canonicalize(path).map_err(storage)?;
                if !path.starts_with(&scope) || !path.is_file() {
                    return Err(storage("附件超出选定范围或不是常规文件"));
                }
                if fs::metadata(&path).map_err(storage)?.len() > 32 * 1024 * 1024 {
                    return Err(storage("单个离线附件超过 32 MiB"));
                }
                let (bytes, sha256) = fingerprint(&path)?;
                let original_name = path
                    .strip_prefix(&scope)
                    .map_err(storage)?
                    .to_string_lossy()
                    .replace('\\', "/");
                Ok((
                    path,
                    PlannedResource {
                        id: Id::new_v4(),
                        source: Path::new("").to_owned(),
                        original_name,
                        bytes,
                        sha256,
                    },
                ))
            })();
            match checked {
                Ok((path, mut resource)) => {
                    if seen.insert(path.clone()) {
                        if attachment_bytes.saturating_add(resource.bytes) > crate::ARCHIVE_BYTES {
                            plan.issues
                                .push(format!("{}：离线附件总量超过 512 MiB", book.title));
                            continue;
                        }
                        attachment_bytes += resource.bytes;
                        consumed.insert(path.clone());
                        resource.source = path;
                        book.resources.push(resource);
                    }
                }
                Err(e) => plan
                    .issues
                    .push(format!("{}：附件 {url} 无法导入：{e}", book.title)),
            }
        }
    }
    // An image used as an attachment is not also made into a comic book.
    for book in &mut plan.books {
        if book.format == Format::Comic {
            book.resources.retain(|r| !consumed.contains(&r.source));
        }
    }
    plan.books.retain(|b| !b.resources.is_empty());
    Ok(())
}
