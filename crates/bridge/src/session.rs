// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
//! Filesystem work behind the native command boundary; independent of any UI.
use aq_application::{BlobStore, Reader};
use aq_domain::{Catalog, CompletedImport, Format, Id, Location};
use aq_local::{LocalBlobs, SqliteRepository, StorageUsage, plan_import};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
};

pub type AppReader = Reader<SqliteRepository, LocalBlobs>;
pub const IMPORT_LIMIT: usize = 32 * 1024 * 1024;

pub struct Session {
    pub reader: AppReader,
    pub library: PathBuf,
    pub staging: PathBuf,
}

#[derive(Serialize)]
pub struct Snapshot {
    pub catalog: Catalog,
    pub book_capabilities:
        std::collections::HashMap<Id, aq_application::registry::BookCapabilities>,
    pub storage: StorageUsage,
    pub staging_bytes: u64,
    pub version: &'static str,
    pub display_version: &'static str,
}

#[derive(Deserialize)]
pub struct IncomingFile {
    pub name: String,
    pub data: String,
}

impl Session {
    pub fn open(root: &Path) -> Result<Self, String> {
        fs::create_dir_all(root).map_err(error)?;
        let root = fs::canonicalize(root).map_err(error)?;
        let library = root.join("library");
        let staging = root.join("import-staging");
        let reader = Reader {
            repository: SqliteRepository::open(&library).map_err(error)?,
            blobs: LocalBlobs::open(&library).map_err(error)?,
        };
        fs::create_dir_all(&staging).map_err(error)?;
        Ok(Self {
            reader,
            library,
            staging,
        })
    }
    pub fn snapshot(&self) -> Result<Snapshot, String> {
        let catalog = self.reader.catalog().map_err(error)?;
        let storage = self.reader.blobs.usage(&catalog).map_err(error)?;
        Ok(Snapshot {
            book_capabilities: catalog
                .books
                .iter()
                .map(|book| (book.id, aq_application::registry::capabilities_for(book)))
                .collect(),
            catalog,
            storage,
            staging_bytes: directory_bytes(&self.staging)?,
            version: env!("CARGO_PKG_VERSION"),
            display_version: include_str!("../../../VERSION").trim(),
        })
    }
    pub fn ingest(
        &mut self,
        files: Vec<IncomingFile>,
        target: Id,
    ) -> Result<CompletedImport, String> {
        if files.is_empty() || files.len() > 512 {
            return Err("每次请选择 1–512 个文件".into());
        }
        let catalog = self.reader.catalog().map_err(error)?;
        catalog.project(target).map_err(error)?;
        let task = self.staging.join(Id::new_v4().to_string());
        fs::create_dir(&task).map_err(error)?;
        let mut paths = vec![];
        let mut names = std::collections::HashSet::new();
        let mut bytes = 0;
        for file in files {
            let name = aq_local::safe_relative(&file.name).map_err(error)?;
            if !names.insert(name.to_string_lossy().replace('\\', "/").to_lowercase()) {
                return Err("所选文件包含大小写冲突的路径".into());
            }
            if file.data.len() > IMPORT_LIMIT * 4 / 3 + 4 {
                return Err("单次导入内容超过 32 MiB，请分批选择".into());
            }
            let decoded = STANDARD.decode(file.data).map_err(error)?;
            bytes += decoded.len();
            if bytes > IMPORT_LIMIT {
                return Err("单次导入内容超过 32 MiB，请分批选择".into());
            }
            let path = task.join(name);
            fs::create_dir_all(path.parent().ok_or("文件目录无效")?).map_err(error)?;
            let mut output = fs::OpenOptions::new()
                .create_new(true)
                .write(true)
                .open(&path)
                .map_err(error)?;
            output.write_all(&decoded).map_err(error)?;
            output.sync_all().map_err(error)?;
            paths.push(path);
        }
        paths
            .sort_by(|a, b| aq_domain::natural_compare(&a.to_string_lossy(), &b.to_string_lossy()));
        let has_folders = paths.iter().any(|p| p.parent() != Some(task.as_path()));
        let plan = if has_folders {
            plan_import(&catalog, &self.library, &task, target).map_err(error)?
        } else {
            let mut combined =
                plan_import(&catalog, &self.library, &paths[0], target).map_err(error)?;
            let first_books = std::mem::take(&mut combined.books);
            let mut books = vec![];
            let mut images = vec![];
            for (index, path) in paths.iter().enumerate() {
                let item_books = if index == 0 {
                    first_books.clone()
                } else {
                    let item = plan_import(&catalog, &self.library, path, target).map_err(error)?;
                    combined.issues.extend(item.issues);
                    item.books
                };
                for book in item_books {
                    if book.format == Format::Comic {
                        images.extend(book.resources);
                    } else {
                        books.push(book);
                    }
                }
            }
            if !images.is_empty() {
                books.push(aq_application::PlannedBook {
                    id: Id::new_v4(),
                    project: target,
                    title: images[0]
                        .original_name
                        .rsplit_once('.')
                        .map(|(s, _)| s)
                        .unwrap_or("图片集")
                        .to_string(),
                    format: Format::Comic,
                    resources: images,
                });
            }
            combined.books = books;
            combined
        };
        let result = self.reader.import(&plan, false).map_err(error)?;
        // End only this successful staging transaction. Failed imports remain visible.
        for path in &paths {
            let _ = fs::remove_file(path);
        }
        remove_empty_directories(&task);
        Ok(result)
    }
    pub fn image(&self, book: Id, page: Id) -> Result<String, String> {
        let c = self.reader.catalog().map_err(error)?;
        let book = c.book(book).map_err(error)?;
        if book.format != Format::Comic {
            return Err("此内容不包含漫画页面".into());
        }
        let p = book
            .pages
            .iter()
            .find(|p| p.id == page)
            .ok_or("页面不存在")?;
        let data = self
            .reader
            .blobs
            .read(p.resource.id, 32 * 1024 * 1024)
            .map_err(error)?;
        let extension = p
            .resource
            .original_name
            .rsplit('.')
            .next()
            .unwrap_or("")
            .to_lowercase();
        let mime = match extension.as_str() {
            "jpg" | "jpeg" => "image/jpeg",
            "png" => "image/png",
            "webp" => "image/webp",
            "gif" => "image/gif",
            _ => return Err("图片格式不受支持".into()),
        };
        Ok(format!("data:{mime};base64,{}", STANDARD.encode(data)))
    }
    pub fn progress(&mut self, book: Id, index: usize) -> Result<(), String> {
        let c = self.reader.catalog().map_err(error)?;
        let b = c.book(book).map_err(error)?;
        let location = location_of(b, index, None)?;
        self.reader.save_progress(book, location).map_err(error)
    }
    pub fn measured_progress(
        &mut self,
        book: Id,
        index: usize,
        content_progress: u32,
    ) -> Result<(), String> {
        let c = self.reader.catalog().map_err(error)?;
        let b = c.book(book).map_err(error)?;
        if !matches!(b.format, Format::Txt | Format::Markdown) {
            return Err("只有文字格式使用内容进度".into());
        }
        let location = location_of(b, index, None)?;
        self.reader
            .save_progress_measured(book, location, Some(content_progress))
            .map_err(error)
    }
    /// Document books report a character anchor instead of an ordinal, so the
    /// position survives font, window and layout changes.
    pub fn progress_at(
        &mut self,
        book: Id,
        anchor: String,
        progress: Option<u32>,
    ) -> Result<(), String> {
        let c = self.reader.catalog().map_err(error)?;
        let b = c.book(book).map_err(error)?;
        if !b.format.is_document() {
            return Err("此格式不使用文字锚点".into());
        }
        self.reader
            .save_progress(book, Location::Document { anchor, progress })
            .map_err(error)
    }
    pub fn note(&mut self, book: Id, index: usize, markdown: String) -> Result<Id, String> {
        let c = self.reader.catalog().map_err(error)?;
        let b = c.book(book).map_err(error)?;
        let location = location_of(b, index, None)?;
        self.reader
            .add_note(book, location, markdown)
            .map_err(error)
    }
    pub fn note_at(
        &mut self,
        book: Id,
        anchor: String,
        progress: Option<u32>,
        markdown: String,
    ) -> Result<Id, String> {
        let c = self.reader.catalog().map_err(error)?;
        let b = c.book(book).map_err(error)?;
        if !b.format.is_document() {
            return Err("此格式不使用文字锚点".into());
        }
        self.reader
            .add_note(book, Location::Document { anchor, progress }, markdown)
            .map_err(error)
    }
}

/// Page books address a stable page id, text books a paragraph index, and
/// document books an engine anchor (supplied separately, never an ordinal).
fn location_of(
    b: &aq_domain::Book,
    index: usize,
    anchor: Option<String>,
) -> Result<Location, String> {
    if b.format.is_fixed_page() {
        return Ok(Location::Page {
            page: b.pages.get(index).ok_or("页面不存在")?.id,
        });
    }
    if b.format.is_document() {
        let anchor = anchor.ok_or("文档位置需要文字锚点")?;
        return Ok(Location::Document {
            anchor,
            progress: None,
        });
    }
    Ok(Location::Paragraph { index })
}

fn error(e: impl std::fmt::Display) -> String {
    e.to_string()
}
fn directory_bytes(path: &Path) -> Result<u64, String> {
    let mut sum = 0;
    for e in fs::read_dir(path).map_err(error)? {
        let e = e.map_err(error)?;
        let kind = e.file_type().map_err(error)?;
        if kind.is_file() {
            sum += e.metadata().map_err(error)?.len();
        } else if kind.is_dir() {
            sum += directory_bytes(&e.path())?;
        }
    }
    Ok(sum)
}
fn remove_empty_directories(path: &Path) {
    if let Ok(entries) = fs::read_dir(path) {
        for entry in entries.flatten() {
            if entry.file_type().is_ok_and(|t| t.is_dir()) {
                remove_empty_directories(&entry.path());
            }
        }
    }
    let _ = fs::remove_dir(path);
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn desktop_and_mobile_payloads_use_the_shared_import_and_resume_rules() {
        let root = tempfile::tempdir().unwrap();
        let mut session = Session::open(root.path()).unwrap();
        let inbox = session.snapshot().unwrap().catalog.inbox;
        let done = session
            .ingest(
                vec![IncomingFile {
                    name: "随笔.txt".into(),
                    data: STANDARD.encode("第一段\n\n第二段"),
                }],
                inbox,
            )
            .unwrap();
        let book = done.books[0];
        session.progress(book, 1).unwrap();
        session.note(book, 1, "记录".into()).unwrap();
        assert_eq!(session.snapshot().unwrap().staging_bytes, 0);
        drop(session);
        let session = Session::open(root.path()).unwrap();
        assert_eq!(session.reader.text(book).unwrap().paragraphs.len(), 2);
        assert_eq!(
            session.snapshot().unwrap().catalog.progress[0].location,
            Location::Paragraph { index: 1 }
        );
        assert!(
            session
                .reader
                .notes_markdown(book)
                .unwrap()
                .contains("记录")
        );
    }
    #[test]
    fn multiple_images_keep_the_first_page_and_validate_platform_names() {
        let root = tempfile::tempdir().unwrap();
        let mut session = Session::open(root.path()).unwrap();
        let inbox = session.snapshot().unwrap().catalog.inbox;
        let result = session
            .ingest(
                vec![
                    IncomingFile {
                        name: "a.png".into(),
                        data: STANDARD.encode(b"a"),
                    },
                    IncomingFile {
                        name: "b.png".into(),
                        data: STANDARD.encode(b"b"),
                    },
                ],
                inbox,
            )
            .unwrap();
        let c = session.reader.catalog().unwrap();
        let book = c.book(result.books[0]).unwrap();
        assert_eq!(book.pages.len(), 2);
        assert_eq!(book.pages[0].resource.original_name, "a.png");
        for name in ["CON.txt", "NUL", "a.", "a ", "CONIN$", "a/./x"] {
            assert!(
                session
                    .ingest(
                        vec![IncomingFile {
                            name: name.into(),
                            data: STANDARD.encode(b"x")
                        }],
                        inbox
                    )
                    .is_err(),
                "{name}"
            );
        }
    }
    #[test]
    fn traversal_and_overwrite_names_are_rejected() {
        for name in [
            "../x.txt",
            "/x.txt",
            "C:/x.txt",
            "a/../../x",
            "a\\..\\x",
            "",
        ] {
            assert!(aq_local::safe_relative(name).is_err(), "{name}");
        }
        assert!(aq_local::safe_relative("小说/第一章.txt").is_ok());
    }
}
