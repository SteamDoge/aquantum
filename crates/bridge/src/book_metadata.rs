// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
//! Confirmed book information travels through the same transactional catalog
//! and immutable resource store as imports; failed staging is retained.
use crate::session::Session;
use aq_application::BlobStore;
use aq_domain::{BookMetadata, Id};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{fs::OpenOptions, io::Write};

#[derive(Deserialize)]
struct Update {
    book: Id,
    revision: u64,
    title: String,
    metadata: BookMetadata,
    #[serde(default)]
    cover_data: Option<String>,
    #[serde(default)]
    clear_cover: bool,
}
impl Session {
    pub fn update_book_metadata(&mut self, args: Value) -> Result<Value, String> {
        let update: Update = serde_json::from_value(args).map_err(|e| e.to_string())?;
        // Refuse stale requests before retaining a staged image.
        if self
            .reader
            .catalog()
            .map_err(|e| e.to_string())?
            .book(update.book)
            .map_err(|e| e.to_string())?
            .revision
            != update.revision
        {
            return Err("书籍已变化，请重新打开信息页".into());
        }
        let staged = if let Some(encoded) = update.cover_data {
            if encoded.len() > 12 * 1024 * 1024 {
                return Err("封面超过8MiB".into());
            }
            let bytes = STANDARD.decode(encoded).map_err(|_| "封面编码无效")?;
            if bytes.is_empty() || bytes.len() > 8 * 1024 * 1024 {
                return Err("封面超过8MiB或为空".into());
            }
            let extension = if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
                "png"
            } else if bytes.starts_with(b"\xff\xd8\xff") {
                "jpg"
            } else if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
                "webp"
            } else {
                return Err("封面仅支持PNG、JPEG和WebP图片".into());
            };
            let path = self
                .staging
                .join(format!("cover-{}.{}", Id::new_v4(), extension));
            let mut file = OpenOptions::new()
                .create_new(true)
                .write(true)
                .open(&path)
                .map_err(|e| e.to_string())?;
            file.write_all(&bytes).map_err(|e| e.to_string())?;
            file.sync_all().map_err(|e| e.to_string())?;
            drop(file);
            let catalog = self.reader.catalog().map_err(|e| e.to_string())?;
            let plan =
                aq_local::plan_import(&catalog, &self.reader.blobs.root, &path, catalog.inbox)
                    .map_err(|e| e.to_string())?;
            let resource = plan
                .books
                .first()
                .and_then(|b| b.resources.first())
                .ok_or("封面预览失败")?
                .clone();
            Some((path, resource))
        } else {
            None
        };
        let book = self
            .reader
            .update_book_metadata(
                update.book,
                update.revision,
                &update.title,
                update.metadata,
                staged.as_ref().map(|(_, r)| r),
                update.clear_cover,
            )
            .map_err(|e| e.to_string())?;
        // Staged bytes are technical transaction input. Once published and
        // catalogued they are redundant; errors never discard staged input.
        if let Some((path, resource)) = staged {
            // Catalog + history now protect these bytes. Failure to retire a
            // publication pin merely retains redundant protection, never
            // misreports the already-committed metadata as an unsuccessful save.
            let _ = self.reader.blobs.release_import_pins(resource.id);
            let _ = std::fs::remove_file(path);
        }
        Ok(json!(book))
    }
    pub fn book_cover(&self, book: Id) -> Result<Value, String> {
        let catalog = self.reader.catalog().map_err(|e| e.to_string())?;
        let Some(cover) = &catalog
            .book(book)
            .map_err(|e| e.to_string())?
            .metadata
            .cover
        else {
            return Ok(Value::Null);
        };
        Ok(json!(
            STANDARD.encode(
                self.reader
                    .blobs
                    .read(cover.id, 8 * 1024 * 1024)
                    .map_err(|e| e.to_string())?
            )
        ))
    }
}
