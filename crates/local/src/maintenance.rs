// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
//! Reference-aware, explicitly requested maintenance. No background eviction.
use crate::{LocalBlobs, ensure_regular_path, fingerprint, storage};
pub use aq_application::maintenance::{CleanupItem, CleanupPlan};
use aq_application::maintenance::{protected_resources, validate_cleanup};
use aq_application::{Error, Result};
use aq_domain::{Catalog, Id};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    fs::{self, File, OpenOptions},
    io::Write,
    path::Path,
};

pub(crate) fn copy_checked(
    input: &mut impl std::io::Read,
    output: &mut impl Write,
    limit: u64,
    checkpoint: &mut impl FnMut() -> Result<()>,
) -> Result<(u64, String)> {
    use sha2::{Digest, Sha256};
    let mut bytes = 0u64;
    let mut hasher = Sha256::new();
    let mut buffer = [0u8; 65536];
    loop {
        checkpoint()?;
        let n = input.read(&mut buffer).map_err(storage)?;
        if n == 0 {
            break;
        }
        bytes = bytes
            .checked_add(n as u64)
            .ok_or_else(|| storage("文件大小溢出"))?;
        if bytes > limit {
            return Err(storage("文件超过确认大小"));
        }
        hasher.update(&buffer[..n]);
        output.write_all(&buffer[..n]).map_err(storage)?;
    }
    Ok((bytes, format!("{:x}", hasher.finalize())))
}

pub struct MaintenanceGuard {
    _file: File,
}
pub fn available_storage(path: &Path) -> Result<u64> {
    ensure_regular_path(path)?;
    fs2::available_space(path).map_err(storage)
}
impl aq_application::ResourceLease for MaintenanceGuard {}

#[derive(Serialize, Deserialize)]
pub struct ResourcePin {
    pub version: u32,
    pub task: Id,
    pub resources: Vec<Id>,
}

#[derive(Clone, Serialize, Deserialize)]
pub struct CleanupConsent {
    pub version: u32,
    pub task: Id,
    pub library: Id,
    pub actor: Id,
    pub keys: Vec<String>,
}

pub(crate) fn save_new_json<T: Serialize>(directory: &Path, name: &str, value: &T) -> Result<()> {
    save_private_record(
        &directory.join(name),
        &serde_json::to_vec_pretty(value).map_err(storage)?,
    )
}

/// Publish a complete private record. Interrupted writes keep a .pending suffix
/// and cannot shadow a previously published plan, receipt, or staged source.
pub fn save_private_record(path: &Path, data: &[u8]) -> Result<()> {
    let directory = path.parent().ok_or_else(|| storage("记录目录无效"))?;
    let existing = directory
        .ancestors()
        .find(|ancestor| ancestor.exists())
        .ok_or_else(|| storage("记录目录没有有效父路径"))?;
    ensure_regular_path(existing)?;
    fs::create_dir_all(directory).map_err(storage)?;
    ensure_regular_path(directory)?;
    // Serialize the final existence check and rename, including on Unix where
    // rename alone would replace an existing destination. The empty lock is
    // retained as private metadata; it is never a completion receipt.
    let lock_path = directory.join(".records.lock");
    if lock_path.exists() {
        ensure_regular_path(&lock_path)?;
    }
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(lock_path)
        .map_err(storage)?;
    lock.lock().map_err(storage)?;
    match fs::symlink_metadata(path) {
        Ok(_) => return Err(storage("记录已存在，不覆盖")),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => return Err(storage(e)),
    }
    let temporary = directory.join(format!("{}.pending", Id::new_v4()));
    let mut output = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)
        .map_err(storage)?;
    output.write_all(data).map_err(storage)?;
    output.sync_all().map_err(storage)?;
    drop(output);
    let destination = path;
    // Names are task-generated UUIDs in private directories; publish only a
    // complete JSON record. Interrupted .pending files are retained, not parsed.
    crate::publication::move_new(&temporary, destination).map_err(storage)
}

impl LocalBlobs {
    pub fn maintenance_guard(&self) -> Result<MaintenanceGuard> {
        ensure_regular_path(&self.root)?;
        let path = self.root.join("resource-operations.lock");
        if path.exists() {
            ensure_regular_path(&path)?;
        }
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(path)
            .map_err(storage)?;
        file.try_lock()
            .map_err(|e| Error::Conflict(format!("其他导入或存储维护正在进行：{e}")))?;
        Ok(MaintenanceGuard { _file: file })
    }
    pub(crate) fn pin_resources(&self, task: Id, resources: &[Id]) -> Result<()> {
        save_new_json(
            &self.root.join("resource-pins"),
            &format!("{}-{}.json", task, Id::new_v4()),
            &ResourcePin {
                version: 1,
                task,
                resources: resources.to_vec(),
            },
        )
    }
    pub fn pinned_resources(&self, catalog: &Catalog) -> Result<HashSet<Id>> {
        let directory = self.root.join("resource-pins");
        if !directory.exists() {
            return Ok(HashSet::new());
        }
        ensure_regular_path(&directory)?;
        let completed: HashSet<_> = catalog.imports.iter().map(|i| i.task).collect();
        let mut ids = HashSet::new();
        for entry in fs::read_dir(directory).map_err(storage)? {
            let entry = entry.map_err(storage)?;
            ensure_regular_path(&entry.path())?;
            if entry.path().extension().is_none_or(|e| e != "json") {
                continue;
            }
            let pin: ResourcePin =
                serde_json::from_slice(&fs::read(entry.path()).map_err(storage)?)
                    .map_err(storage)?;
            if pin.version != 1 {
                return Err(storage("资源保护记录版本未知，停止清理"));
            }
            if completed.contains(&pin.task) || self.task_discarded("backup", pin.task)? {
                continue;
            }
            let completed_backup = self
                .task_progress("backup", pin.task)
                .ok()
                .is_some_and(|s| s.phase == "completed");
            if !completed_backup {
                ids.extend(pin.resources);
            }
        }
        Ok(ids)
    }
    /// Explicitly discard an idle import's recovery pins; keep an audit copy.
    pub fn release_import_pins(&self, task: Id) -> Result<()> {
        let _guard = self.maintenance_guard()?;
        let directory = self.root.join("resource-pins");
        if !directory.exists() {
            return Ok(());
        }
        let retired = self.root.join("retired-resource-pins");
        fs::create_dir_all(&retired).map_err(storage)?;
        ensure_regular_path(&retired)?;
        for entry in fs::read_dir(&directory).map_err(storage)? {
            let entry = entry.map_err(storage)?;
            ensure_regular_path(&entry.path())?;
            if entry.path().extension().is_none_or(|e| e != "json") {
                continue;
            }
            let pin: ResourcePin =
                serde_json::from_slice(&fs::read(entry.path()).map_err(storage)?)
                    .map_err(storage)?;
            if pin.task == task {
                fs::rename(
                    entry.path(),
                    retired.join(format!("{}-{}.json", task, Id::new_v4())),
                )
                .map_err(storage)?;
            }
        }
        Ok(())
    }
}

impl LocalBlobs {
    pub fn cleanup_preview(&self, catalog: &Catalog) -> Result<CleanupPlan> {
        let _guard = self.maintenance_guard()?;
        let references = protected_resources(catalog, self.pinned_resources(catalog)?);
        let mut plan = CleanupPlan {
            version: 1,
            task: Id::new_v4(),
            library: catalog.id,
            base_revision: catalog.revision,
            protected_resources: references.len(),
            items: vec![],
        };
        for entry in fs::read_dir(self.root.join("objects")).map_err(storage)? {
            let entry = entry.map_err(storage)?;
            ensure_regular_path(&entry.path())?;
            if !entry.file_type().map_err(storage)?.is_file() {
                continue;
            }
            let name = entry.file_name().to_string_lossy().to_string();
            let (id, category) = if let Ok(id) = name.parse::<Id>() {
                (id, "unreferenced")
            } else if let Some(stem) = name.strip_suffix(".part") {
                let Ok(id) = stem.parse::<Id>() else {
                    continue;
                };
                (id, "incomplete")
            } else {
                continue;
            };
            if references.contains(&id) {
                continue;
            }
            let (bytes, sha256) = fingerprint(&entry.path())?;
            plan.items.push(CleanupItem {
                key: name,
                category: category.into(),
                bytes,
                sha256,
            });
        }
        plan.items.sort_by(|a, b| a.key.cmp(&b.key));
        save_new_json(
            &self
                .root
                .join("maintenance-tasks")
                .join(plan.task.to_string()),
            "plan.json",
            &plan,
        )?;
        Ok(plan)
    }
    pub fn cleanup_plan(&self, task: Id) -> Result<CleanupPlan> {
        let path = self
            .root
            .join("maintenance-tasks")
            .join(task.to_string())
            .join("plan.json");
        ensure_regular_path(&path)?;
        let plan: CleanupPlan =
            serde_json::from_slice(&fs::read(path).map_err(storage)?).map_err(storage)?;
        if plan.version != 1 || plan.task != task {
            return Err(storage("清理计划版本或身份错误"));
        }
        Ok(plan)
    }
    pub fn confirm_cleanup(&self, catalog: &Catalog, task: Id, keys: &[String]) -> Result<()> {
        let _guard = self.maintenance_guard()?;
        let plan = self.cleanup_plan(task)?;
        if keys.is_empty() || keys.iter().collect::<HashSet<_>>().len() != keys.len() {
            return Err(storage("确认清理范围不能为空或重复"));
        }
        let pins = self.pinned_resources(catalog)?;
        for key in keys {
            let item = plan
                .items
                .iter()
                .find(|i| &i.key == key)
                .ok_or_else(|| storage("确认范围超出预览计划"))?;
            validate_cleanup(catalog, &plan, item, pins.iter().copied())?;
        }
        let directory = self.root.join("maintenance-tasks").join(task.to_string());
        let path = directory.join("confirmed.json");
        if path.exists() {
            let prior: CleanupConsent =
                serde_json::from_slice(&fs::read(&path).map_err(storage)?).map_err(storage)?;
            if prior.version == 1
                && prior.task == task
                && prior.library == catalog.id
                && prior.actor == catalog.actor
                && prior.keys == keys
            {
                return Ok(());
            }
            return Err(storage("此计划已有不同确认范围，请重新预览"));
        }
        save_new_json(
            &directory,
            "confirmed.json",
            &CleanupConsent {
                version: 1,
                task,
                library: catalog.id,
                actor: catalog.actor,
                keys: keys.to_vec(),
            },
        )
    }
    pub fn cleanup_state(&self, task: Id) -> Result<serde_json::Value> {
        let plan = self.cleanup_plan(task)?;
        let directory = self.root.join("maintenance-tasks").join(task.to_string());
        let mut completed = vec![];
        for item in &plan.items {
            let _: Id = item
                .key
                .strip_suffix(".part")
                .unwrap_or(&item.key)
                .parse()
                .map_err(storage)?;
            let file = directory.join(format!("done-{}.json", item.key));
            if file.exists() {
                ensure_regular_path(&file)?;
                let receipt: CleanupItem =
                    serde_json::from_slice(&fs::read(file).map_err(storage)?).map_err(storage)?;
                if receipt.key != item.key
                    || receipt.sha256 != item.sha256
                    || receipt.bytes != item.bytes
                {
                    return Err(storage("完成回执与清理计划不一致"));
                }
                completed.push(item.key.clone());
            }
        }
        let consent = directory.join("confirmed.json");
        let confirmed: Option<CleanupConsent> = if consent.exists() {
            ensure_regular_path(&consent)?;
            Some(serde_json::from_slice(&fs::read(consent).map_err(storage)?).map_err(storage)?)
        } else {
            None
        };
        Ok(serde_json::json!({"plan":plan,"completed":completed,"confirmed":confirmed}))
    }
    /// One item per client step: cancel, foreground reading, and recovery remain
    /// possible between files. A changed catalog requires a fresh explicit plan.
    pub fn cleanup_item(&self, catalog: &Catalog, task: Id, key: &str) -> Result<CleanupItem> {
        let _guard = self.maintenance_guard()?;
        let plan = self.cleanup_plan(task)?;
        let item = plan
            .items
            .iter()
            .find(|i| i.key == key)
            .ok_or_else(|| storage("项目不属于已确认清理计划"))?;
        let consent_path = self
            .root
            .join("maintenance-tasks")
            .join(task.to_string())
            .join("confirmed.json");
        ensure_regular_path(&consent_path)?;
        let consent: CleanupConsent =
            serde_json::from_slice(&fs::read(consent_path).map_err(storage)?).map_err(storage)?;
        if consent.version != 1
            || consent.task != task
            || consent.library != catalog.id
            || consent.actor != catalog.actor
            || !consent.keys.iter().any(|k| k == key)
        {
            return Err(storage("该文件未包含在用户确认的清理范围中"));
        }
        validate_cleanup(catalog, &plan, item, self.pinned_resources(catalog)?)?;
        let completed = self
            .root
            .join("maintenance-tasks")
            .join(task.to_string())
            .join(format!("done-{key}.json"));
        if completed.exists() {
            ensure_regular_path(&completed)?;
            return Ok(item.clone());
        }
        let path = self.root.join("objects").join(key);
        let task_dir = completed.parent().unwrap();
        let intent = task_dir.join(format!("intent-{key}.json"));
        if !path.exists() && intent.exists() {
            ensure_regular_path(&intent)?;
            let previous: CleanupItem =
                serde_json::from_slice(&fs::read(&intent).map_err(storage)?).map_err(storage)?;
            if previous.key != item.key
                || previous.bytes != item.bytes
                || previous.sha256 != item.sha256
            {
                return Err(storage("中断回执与确认计划不一致，停止恢复"));
            }
            save_new_json(
                task_dir,
                completed.file_name().unwrap().to_str().unwrap(),
                item,
            )?;
            return Ok(item.clone());
        }
        ensure_regular_path(&path)?;
        if fingerprint(&path)? != (item.bytes, item.sha256.clone()) {
            return Err(Error::Conflict("待清理文件已改变，请重新预览".into()));
        }
        if !intent.exists() {
            save_new_json(
                task_dir,
                intent.file_name().unwrap().to_str().unwrap(),
                item,
            )?;
        }
        fs::remove_file(&path).map_err(storage)?;
        save_new_json(
            task_dir,
            completed.file_name().unwrap().to_str().unwrap(),
            item,
        )?;
        Ok(item.clone())
    }
}
