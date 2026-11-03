// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
//! Complete-file publication without replacement. Failed staging stays inspectable.
#[cfg(any(test, not(any(windows, target_os = "linux", target_os = "android"))))]
use std::fs;
use std::{io, path::Path};

/// Move a complete same-filesystem file without ever replacing a destination.
pub(crate) fn move_new(source: &Path, destination: &Path) -> io::Result<()> {
    #[cfg(windows)]
    {
        use std::os::windows::ffi::OsStrExt;
        #[link(name = "kernel32")]
        unsafe extern "system" {
            fn MoveFileExW(source: *const u16, destination: *const u16, flags: u32) -> i32;
        }
        let source: Vec<_> = std::path::absolute(source)?
            .as_os_str()
            .encode_wide()
            .chain([0])
            .collect();
        let destination: Vec<_> = std::path::absolute(destination)?
            .as_os_str()
            .encode_wide()
            .chain([0])
            .collect();
        if source[..source.len() - 1].contains(&0)
            || destination[..destination.len() - 1].contains(&0)
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "NUL in file path",
            ));
        }
        // SAFETY: both buffers are live, NUL-terminated UTF-16. Flags=0 forbids replacement and cross-volume copying.
        if unsafe { MoveFileExW(source.as_ptr(), destination.as_ptr(), 0) } != 0 {
            return Ok(());
        }
        Err(io::Error::last_os_error())
    }
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        use std::{ffi::CString, os::unix::ffi::OsStrExt};
        let source = CString::new(source.as_os_str().as_bytes())?;
        let destination = CString::new(destination.as_os_str().as_bytes())?;
        // SAFETY: syscall receives two live C strings, AT_FDCWD directories and the documented no-replace flag.
        let result = unsafe {
            libc::syscall(
                libc::SYS_renameat2,
                libc::AT_FDCWD,
                source.as_ptr(),
                libc::AT_FDCWD,
                destination.as_ptr(),
                libc::RENAME_NOREPLACE,
            )
        };
        if result == 0 {
            return Ok(());
        }
        Err(io::Error::last_os_error())
    }
    #[cfg(not(any(windows, target_os = "linux", target_os = "android")))]
    {
        fs::hard_link(source, destination)?;
        // A published destination is success even if its temporary link is retained.
        let _ = fs::remove_file(source);
        Ok(())
    }
}

/// Copy across volumes into a sibling part, then publish atomically in that volume.
pub(crate) fn copy_new(source: &Path, destination: &Path) -> aq_application::Result<()> {
    use crate::{ensure_regular_path, fingerprint, maintenance::copy_checked, storage};
    use std::fs::{File, OpenOptions};
    ensure_regular_path(source)?;
    let parent = destination
        .parent()
        .ok_or_else(|| storage("发布目录无效"))?;
    ensure_regular_path(parent)?;
    let part = parent.join(format!(".aq-publish-{}.part", aq_domain::Id::new_v4()));
    let expected = fingerprint(source)?;
    let mut input = File::open(source).map_err(storage)?;
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&part)
        .map_err(storage)?;
    let actual = copy_checked(&mut input, &mut output, expected.0, &mut || Ok(()))?;
    output.sync_all().map_err(storage)?;
    drop(output);
    if actual != expected {
        return Err(storage(format!(
            "发布副本校验失败，残留保留：{}",
            part.display()
        )));
    }
    move_new(&part, destination)
        .map_err(|e| storage(format!("未发布完整副本：{e}；残留保留：{}", part.display())))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn publication_never_overwrites_and_copy_publishes_complete_bytes() {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("source.part");
        let destination = temp.path().join("published");
        fs::write(&source, b"complete").unwrap();
        fs::write(&destination, b"existing").unwrap();
        assert!(move_new(&source, &destination).is_err());
        assert_eq!(fs::read(&destination).unwrap(), b"existing");
        assert_eq!(fs::read(&source).unwrap(), b"complete");
        let copied = temp.path().join("copied");
        copy_new(&source, &copied).unwrap();
        assert_eq!(fs::read(&copied).unwrap(), b"complete");
        assert!(source.exists());
    }
}
