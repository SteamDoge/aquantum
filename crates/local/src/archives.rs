// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
//! Bounded archive I/O. Never extract links, traverse paths, or overwrite files.
use crate::{ensure_regular_path, storage};
use aq_application::{Result, pages::selected_pages};
use aq_domain::{Catalog, Id};
use std::{
    collections::HashSet,
    fs::{self, File, OpenOptions},
    io::Write,
    path::{Component, Path, PathBuf},
};
use zip::{ZipArchive, ZipWriter, write::SimpleFileOptions};

pub const ARCHIVE_BYTES: u64 = 512 * 1024 * 1024;
pub const ARCHIVE_FILES: usize = 10_000;

pub fn read_preview_resource(resource: &aq_application::PlannedResource) -> Result<Vec<u8>> {
    use sha2::{Digest, Sha256};
    ensure_regular_path(&resource.source)?;
    if resource.bytes > 32 * 1024 * 1024 {
        return Err(storage("单张预览超过 32 MiB"));
    }
    let data = fs::read(&resource.source).map_err(storage)?;
    if data.len() as u64 != resource.bytes
        || format!("{:x}", Sha256::digest(&data)) != resource.sha256
    {
        return Err(storage("源文件在预览后改变，请重建导入计划"));
    }
    Ok(data)
}

pub fn safe_relative(name: &str) -> Result<PathBuf> {
    let normalized = name.replace('\\', "/");
    let path = PathBuf::from(&normalized);
    if name.is_empty()
        || name.contains(':')
        || name.chars().any(char::is_control)
        || normalized.starts_with('/')
        || path
            .components()
            .any(|c| !matches!(c, Component::Normal(_)))
        || normalized.split('/').any(|part| {
            let part = part.to_ascii_uppercase();
            let stem = part.split('.').next().unwrap_or_default();
            part.ends_with(['.', ' '])
                || part.is_empty()
                || part == "."
                || part == ".."
                || matches!(stem, "CON" | "PRN" | "AUX" | "NUL" | "CONIN$" | "CONOUT$")
                || stem
                    .strip_prefix("COM")
                    .or_else(|| stem.strip_prefix("LPT"))
                    .is_some_and(|n| {
                        matches!(
                            n,
                            "1" | "2" | "3" | "4" | "5" | "6" | "7" | "8" | "9" | "¹" | "²" | "³"
                        )
                    })
        })
    {
        return Err(storage("文件名含不安全路径、设备名或控制字符"));
    }
    Ok(path)
}

/// Destination must be a new task-owned directory. Failures are retained.
pub fn unpack_archive(source: &Path, destination: &Path) -> Result<()> {
    unpack_archive_checked(source, destination, ARCHIVE_BYTES, ARCHIVE_FILES, || Ok(()))
}

pub(crate) fn unpack_archive_checked(
    source: &Path,
    destination: &Path,
    maximum_bytes: u64,
    maximum_files: usize,
    mut checkpoint: impl FnMut() -> Result<()>,
) -> Result<()> {
    ensure_regular_path(source)?;
    if fs::metadata(source).map_err(storage)?.len() > maximum_bytes {
        return Err(storage("压缩包超过所选任务大小上限"));
    }
    let mut archive = ZipArchive::new(File::open(source).map_err(storage)?).map_err(storage)?;
    if archive.len() > maximum_files {
        return Err(storage("压缩包条目数超过所选任务上限"));
    }
    // Inspect every entry before writing any untrusted path.
    let mut names = HashSet::new();
    let mut total = 0u64;
    for i in 0..archive.len() {
        checkpoint()?;
        let item = archive.by_index(i).map_err(storage)?;
        let name = item.name().trim_end_matches('/');
        safe_relative(name)?;
        if item.enclosed_name().is_none()
            || item
                .unix_mode()
                .is_some_and(|m| m & 0o170000 != 0 && !matches!(m & 0o170000, 0o100000 | 0o040000))
        {
            return Err(storage("压缩包包含链接、特殊文件或越界路径"));
        }
        if !names.insert(name.replace('\\', "/").to_lowercase()) {
            return Err(storage("压缩包有重复或大小写冲突的路径"));
        }
        total = total
            .checked_add(item.size())
            .ok_or_else(|| storage("压缩包大小溢出"))?;
        if total > maximum_bytes {
            return Err(storage("解压总量超过所选任务上限"));
        }
    }
    fs::create_dir(destination).map_err(storage)?;
    ensure_regular_path(destination)?;
    for i in 0..archive.len() {
        checkpoint()?;
        let mut item = archive.by_index(i).map_err(storage)?;
        let relative = safe_relative(item.name().trim_end_matches('/'))?;
        let target = destination.join(relative);
        if item.is_dir() {
            fs::create_dir_all(&target).map_err(storage)?;
            continue;
        }
        fs::create_dir_all(target.parent().ok_or_else(|| storage("无效目录"))?).map_err(storage)?;
        ensure_regular_path(target.parent().unwrap())?;
        let mut output = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&target)
            .map_err(storage)?;
        let declared = item.size();
        let (copied, _) =
            crate::maintenance::copy_checked(&mut item, &mut output, declared, &mut checkpoint)?;
        if copied != declared {
            return Err(storage("压缩包条目大小不匹配"));
        }
        output.sync_all().map_err(storage)?;
    }
    Ok(())
}

/// Publish a checked CBZ/ZIP without overwriting any existing destination.
/// Catalog changes (cut) are a subsequent optimistic application transaction.
pub fn export_pages(
    blobs: &crate::LocalBlobs,
    catalog: &Catalog,
    book: Id,
    revision: u64,
    ids: &[Id],
    destination: &Path,
) -> Result<u64> {
    let b = catalog.book(book)?;
    if b.revision != revision {
        return Err(aq_application::Error::Conflict("书籍已改变，请刷新".into()));
    }
    let pages = selected_pages(b, ids)?;
    let extension = destination
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or_default()
        .to_lowercase();
    if !matches!(extension.as_str(), "zip" | "cbz") {
        return Err(storage("当前页面导出支持 CBZ 或 ZIP"));
    }
    let destination = std::path::absolute(destination).map_err(storage)?;
    let parent = destination
        .parent()
        .ok_or_else(|| storage("导出目录无效"))?;
    ensure_regular_path(parent)?;
    let parent = fs::canonicalize(parent).map_err(storage)?;
    // Export is external: never publish into managed data or its parents.
    if parent.starts_with(&blobs.root) {
        return Err(storage("不能导出到受管资料库内部"));
    }
    if destination.exists() {
        return Err(storage("目标已存在，请另选名称；不会覆盖"));
    }
    let temporary = parent.join(format!(".aq-export-{}.part", Id::new_v4()));
    let result = (|| -> Result<u64> {
        let mut writer = ZipWriter::new(
            OpenOptions::new()
                .read(true)
                .write(true)
                .create_new(true)
                .open(&temporary)
                .map_err(storage)?,
        );
        let mut total = 0u64;
        for (i, page) in pages.iter().enumerate() {
            total = total
                .checked_add(page.resource.bytes)
                .ok_or_else(|| storage("导出大小溢出"))?;
            if total > ARCHIVE_BYTES {
                return Err(storage("单次导出超过 512 MiB，请分批选择"));
            }
            let ext = page
                .resource
                .original_name
                .rsplit('.')
                .next()
                .unwrap_or_default()
                .to_ascii_lowercase();
            if !matches!(ext.as_str(), "jpg" | "jpeg" | "png" | "gif" | "webp") {
                return Err(storage("页面扩展名无效"));
            }
            writer
                .start_file(
                    format!("{:06}.{ext}", i + 1),
                    SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored),
                )
                .map_err(storage)?;
            let mut input = File::open(blobs.resource_path(page.resource.id)?).map_err(storage)?;
            let actual = crate::maintenance::copy_checked(
                &mut input,
                &mut writer,
                page.resource.bytes,
                &mut || Ok(()),
            )?;
            if actual != (page.resource.bytes, page.resource.sha256.clone()) {
                return Err(storage("受管资源校验失败，源页面保留"));
            }
        }
        // Keep source identity, stable-page mapping and annotations with the export.
        let notes: Vec<_> = catalog
            .notes
            .iter()
            .filter(|n| {
                n.book == book
                    && matches!(n.location, aq_domain::Location::Page {page} if ids.contains(&page))
            })
            .collect();
        writer
            .start_file("aq-export.json", SimpleFileOptions::default())
            .map_err(storage)?;
        writer.write_all(&serde_json::to_vec_pretty(&serde_json::json!({"version":1,"library":catalog.id,"book":book,"revision":revision,"pages":pages,"notes":notes})).map_err(storage)?).map_err(storage)?;
        let output = writer.finish().map_err(storage)?;
        output.sync_all().map_err(storage)?;
        drop(output);
        let mut verify =
            ZipArchive::new(File::open(&temporary).map_err(storage)?).map_err(storage)?;
        for i in 0..verify.len() {
            std::io::copy(
                &mut verify.by_index(i).map_err(storage)?,
                &mut std::io::sink(),
            )
            .map_err(storage)?;
        }
        drop(verify);
        // A hard link provides create-new publication, including a destination race.
        publish_no_replace(&temporary, &destination)?;
        let _ = fs::remove_file(&temporary);
        Ok(total)
    })();
    result.map_err(|e| storage(format!("{e}；未完成导出保留在 {}", temporary.display())))
}

pub(crate) fn publish_no_replace(source: &Path, destination: &Path) -> Result<()> {
    ensure_regular_path(source)?;
    ensure_regular_path(
        destination
            .parent()
            .ok_or_else(|| storage("发布目录无效"))?,
    )?;
    match fs::hard_link(source, destination) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            Err(storage("目标已存在，不覆盖"))
        }
        Err(_) => crate::publication::copy_new(source, destination),
    }
}
