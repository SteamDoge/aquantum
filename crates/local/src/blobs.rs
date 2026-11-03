// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
use crate::{ensure_regular_path, storage};
use aq_application::{BlobStore, Error, PlannedResource, Result};
use aq_domain::{Catalog, Id, Resource};
use serde::Serialize;
use sha2::{Digest, Sha256};
use std::{
    collections::HashSet,
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
};

pub struct LocalBlobs {
    pub root: PathBuf,
}

#[derive(Debug, Serialize)]
pub struct StorageUsage {
    pub original_bytes: u64,
    pub retained_unreferenced_bytes: u64,
    pub incomplete_bytes: u64,
    pub database_bytes: u64,
    pub referenced_resources: usize,
    pub cleanup_policy: &'static str,
}

impl LocalBlobs {
    pub fn open(root: &Path) -> Result<Self> {
        fs::create_dir_all(root.join("objects")).map_err(storage)?;
        ensure_regular_path(&std::path::absolute(root.join("objects")).map_err(storage)?)?;
        Ok(Self {
            root: fs::canonicalize(root).map_err(storage)?,
        })
    }
    fn path(&self, id: Id) -> PathBuf {
        self.root.join("objects").join(id.to_string())
    }
    /// Read-only format engines receive only a verified managed-object path.
    pub fn resource_path(&self, id: Id) -> Result<PathBuf> {
        let path = self.path(id);
        ensure_regular_path(&path)?;
        if !path.is_file() {
            return Err(storage("受管资源不是常规文件"));
        }
        Ok(path)
    }
    pub fn usage(&self, catalog: &Catalog) -> Result<StorageUsage> {
        let refs: HashSet<_> = catalog
            .retained_resources()
            .map(|r| r.id.to_string())
            .collect();
        let mut usage = StorageUsage {
            original_bytes: 0,
            retained_unreferenced_bytes: 0,
            incomplete_bytes: 0,
            database_bytes: fs::metadata(self.root.join("library.sqlite3"))
                .map_err(storage)?
                .len(),
            referenced_resources: refs.len(),
            cleanup_policy: "M0 只读统计，未提供删除；无任何自动清理",
        };
        for entry in fs::read_dir(self.root.join("objects")).map_err(storage)? {
            let entry = entry.map_err(storage)?;
            ensure_regular_path(&entry.path())?;
            if !entry.file_type().map_err(storage)?.is_file() {
                continue;
            }
            let bytes = entry.metadata().map_err(storage)?.len();
            let name = entry.file_name().to_string_lossy().to_string();
            if refs.contains(&name) {
                usage.original_bytes += bytes;
            } else if name.ends_with(".part") {
                usage.incomplete_bytes += bytes;
            } else {
                usage.retained_unreferenced_bytes += bytes;
            }
        }
        Ok(usage)
    }
}

pub(crate) fn fingerprint(path: &Path) -> Result<(u64, String)> {
    ensure_regular_path(path)?;
    if !path.is_file() {
        return Err(storage(format!("不是常规文件：{}", path.display())));
    }
    let mut file = File::open(path).map_err(storage)?;
    hash_reader(&mut file)
}

fn hash_reader(reader: &mut impl Read) -> Result<(u64, String)> {
    let mut hasher = Sha256::new();
    let mut bytes = 0;
    let mut buffer = [0u8; 65536];
    loop {
        let n = reader.read(&mut buffer).map_err(storage)?;
        if n == 0 {
            break;
        }
        hasher.update(&buffer[..n]);
        bytes += n as u64;
    }
    Ok((bytes, format!("{:x}", hasher.finalize())))
}

impl BlobStore for LocalBlobs {
    fn begin_import(
        &self,
        task: Id,
        resources: &[Id],
    ) -> Result<Box<dyn aq_application::ResourceLease>> {
        let guard = self.maintenance_guard()?;
        self.pin_resources(task, resources)?;
        Ok(Box::new(guard))
    }
    fn put(&self, source: &PlannedResource) -> Result<Resource> {
        // Revalidate paths and stream bytes; never trust preview metadata alone.
        ensure_regular_path(&source.source)?;
        if !source.source.is_file() {
            return Err(storage("源文件已失效"));
        }
        let output = self.path(source.id);
        if output.exists() {
            let actual = fingerprint(&output)?;
            if actual != (source.bytes, source.sha256.clone()) {
                return Err(Error::Conflict("同身份资源的校验值不同".into()));
            }
        } else {
            let part = self
                .root
                .join("objects")
                .join(format!("{}.part", Id::new_v4()));
            let mut out = OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&part)
                .map_err(storage)?;
            let mut input = File::open(&source.source).map_err(storage)?;
            let mut hasher = Sha256::new();
            let mut bytes = 0;
            let mut buffer = [0u8; 65536];
            loop {
                let n = input.read(&mut buffer).map_err(storage)?;
                if n == 0 {
                    break;
                }
                out.write_all(&buffer[..n]).map_err(storage)?;
                hasher.update(&buffer[..n]);
                bytes += n as u64;
            }
            out.sync_all().map_err(storage)?;
            drop(out);
            if bytes != source.bytes || format!("{:x}", hasher.finalize()) != source.sha256 {
                return Err(Error::Conflict(
                    "源文件在预览后已变化；临时副本保留在存储统计中".into(),
                ));
            }
            // Publish the complete sibling part; interruption never occupies the final ID.
            if let Err(e) = crate::publication::move_new(&part, &output) {
                if output.exists() && fingerprint(&output)? == (source.bytes, source.sha256.clone())
                {
                    let _ = fs::remove_file(&part);
                } else {
                    return Err(storage(format!("发布资源失败：{e}；临时副本保留")));
                }
            }
        }
        Ok(Resource {
            id: source.id,
            sha256: source.sha256.clone(),
            bytes: source.bytes,
            original_name: source.original_name.clone(),
        })
    }
    fn read(&self, id: Id, max_bytes: u64) -> Result<Vec<u8>> {
        let path = self.path(id);
        ensure_regular_path(&path)?;
        let file = File::open(path).map_err(storage)?;
        if file.metadata().map_err(storage)?.len() > max_bytes {
            return Err(Error::Unsupported(format!(
                "文本读取上限为 {max_bytes} 字节"
            )));
        }
        let mut bytes = vec![];
        file.take(max_bytes + 1)
            .read_to_end(&mut bytes)
            .map_err(storage)?;
        if bytes.len() as u64 > max_bytes {
            return Err(Error::Unsupported("资源超出读取上限".into()));
        }
        Ok(bytes)
    }
    fn resource_path(&self, id: Id) -> Result<PathBuf> {
        LocalBlobs::resource_path(self, id)
    }
}

#[cfg(test)]
mod publication_tests {
    use super::*;
    #[test]
    fn exclusive_publication_is_idempotent_and_never_overwrites_an_existing_resource() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source.txt");
        fs::write(&source, b"complete").unwrap();
        let (bytes, sha256) = fingerprint(&source).unwrap();
        let store = LocalBlobs::open(&temp.path().join("library")).unwrap();
        let planned = PlannedResource {
            id: Id::new_v4(),
            source,
            original_name: "source.txt".into(),
            bytes,
            sha256,
        };
        store.put(&planned).unwrap();
        store.put(&planned).unwrap();
        assert_eq!(fs::read(store.path(planned.id)).unwrap(), b"complete");
        fs::write(store.path(planned.id), b"existing").unwrap();
        assert!(store.put(&planned).is_err());
        assert_eq!(fs::read(store.path(planned.id)).unwrap(), b"existing");
    }
}
