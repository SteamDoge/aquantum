// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
//! SQLite, immutable local blobs and filesystem import planning.
mod archives;
mod backups;
mod blobs;
mod maintenance;
mod markdown;
mod planning;
mod publication;
mod repository;

pub use archives::*;
pub use backups::*;
pub use blobs::*;
pub use maintenance::*;
pub use markdown::suppress_attachment_comics;
pub use planning::*;
pub use repository::*;

pub(crate) fn storage(error: impl std::fmt::Display) -> aq_application::Error {
    aq_application::Error::Storage(error.to_string())
}

/// Reject symlinks and Windows junction/reparse points on import paths.
/// This checks current ancestors, not root containment or hostile concurrent replacement.
pub(crate) fn ensure_regular_path(path: &std::path::Path) -> aq_application::Result<()> {
    let absolute = std::path::absolute(path).map_err(storage)?;
    for ancestor in absolute.ancestors() {
        let metadata = std::fs::symlink_metadata(ancestor).map_err(storage)?;
        let linked = metadata.file_type().is_symlink();
        #[cfg(windows)]
        let linked = {
            use std::os::windows::fs::MetadataExt;
            linked || metadata.file_attributes() & 0x400 != 0
        };
        if linked {
            return Err(storage(format!(
                "不导入符号链接或重解析点：{}",
                ancestor.display()
            )));
        }
    }
    Ok(())
}
