// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
//! Portable backup format and validation. Filesystem work stays behind local I/O.
use crate::{Error, Result};
use aq_domain::Id;
use serde::{Deserialize, Serialize};

pub const BACKUP_LIMIT: u64 = 64 * 1024 * 1024 * 1024;
pub const BACKUP_ENTRIES: usize = 1_000_000;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BackupEntry {
    pub name: String,
    pub bytes: u64,
    pub sha256: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct BackupManifest {
    pub format: String,
    pub version: u32,
    pub backup: Id,
    pub library: Id,
    pub catalog_revision: u64,
    pub source_root: String,
    pub created_at: u64,
    pub entries: Vec<BackupEntry>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct MigrationSnapshot {
    pub version: u32,
    pub payload: String,
}
pub fn valid_backup_name(name: &str) -> bool {
    name == "catalog.json"
        || name == "migration-backups.json"
        || name == "device-preferences.json"
        || [
            "app/library/objects/",
            "app/library/resource-pins/",
            "app/library/retired-resource-pins/",
            "app/library/maintenance-tasks/",
            "app/library/discarded-task-receipts/",
            "app/import-staging/",
            "app/modules/",
            "app/restoration-origins/",
            "app/device-preference-history/",
        ]
        .iter()
        .any(|prefix| name.starts_with(prefix))
}
impl BackupManifest {
    pub fn validate(&self) -> Result<u64> {
        if self.format != "aquantum-library-backup"
            || self.version != 1
            || self.entries.len() > BACKUP_ENTRIES
        {
            return Err(Error::Unsupported("备份格式、版本或条目数不受支持".into()));
        }
        let mut names = std::collections::HashSet::new();
        let mut total = 0u64;
        for entry in &self.entries {
            if !valid_backup_name(&entry.name)
                || !names.insert(entry.name.to_lowercase())
                || entry.sha256.len() != 64
                || !entry.sha256.bytes().all(|b| b.is_ascii_hexdigit())
            {
                return Err(Error::Unsupported(
                    "备份条目名称、重复项或校验信息无效".into(),
                ));
            }
            total = total
                .checked_add(entry.bytes)
                .ok_or_else(|| Error::Unsupported("备份大小溢出".into()))?;
        }
        if total > BACKUP_LIMIT
            || !names.contains("catalog.json")
            || !names.contains("device-preferences.json")
        {
            return Err(Error::Unsupported("备份超过 64 GiB 或缺少目录/设置".into()));
        }
        Ok(total)
    }
}
pub fn validate_device_preferences(value: &serde_json::Value) -> Result<()> {
    let map = value
        .as_object()
        .ok_or_else(|| Error::Unsupported("设备设置必须是键值对象".into()))?;
    if serde_json::to_vec(value)
        .map_err(|e| Error::Storage(e.to_string()))?
        .len()
        > 2 * 1024 * 1024
    {
        return Err(Error::Unsupported("设备设置超过 2 MiB".into()));
    }
    for (key, value) in map {
        if key.is_empty()
            || key.len() > 240
            || key.chars().any(char::is_control)
            || !(value.is_string()
                || value.is_boolean()
                || value.is_number()
                || value
                    .as_array()
                    .is_some_and(|a| a.iter().all(|v| v.is_string())))
        {
            return Err(Error::Unsupported("设备设置类型或名称无效".into()));
        }
    }
    Ok(())
}
