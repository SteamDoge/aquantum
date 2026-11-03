// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
//! Checked portable snapshots and isolated restore roots. Active bytes are never
//! overwritten by restore; the client selects a fully validated recovered copy.
use crate::maintenance::{copy_checked, save_new_json};
use crate::{
    LocalBlobs, SqliteRepository, ensure_regular_path, fingerprint, safe_relative, storage,
};
use aq_application::{
    Repository, Result,
    backup::{
        BACKUP_ENTRIES, BACKUP_LIMIT, BackupEntry, BackupManifest, valid_backup_name,
        validate_device_preferences,
    },
};
use aq_domain::{Catalog, Id};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, HashSet},
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};
use zip::{ZipArchive, ZipWriter, write::SimpleFileOptions};

const SMALL_JSON: u64 = 128 * 1024 * 1024;
const EXTRA_DIRS: &[&str] = &[
    "library/objects",
    "library/resource-pins",
    "library/retired-resource-pins",
    "library/maintenance-tasks",
    "library/discarded-task-receipts",
    "import-staging",
    "modules",
    "restoration-origins",
    "device-preference-history",
];

#[derive(Clone, Serialize, Deserialize)]
pub struct BackupPlan {
    pub manifest: BackupManifest,
    pub catalog: Catalog,
    pub device_preferences: serde_json::Value,
    #[serde(default)]
    pub migration_snapshots: Vec<aq_application::backup::MigrationSnapshot>,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct BackupProgress {
    pub version: u32,
    pub task: Id,
    pub kind: String,
    pub phase: String,
    pub completed: usize,
    pub total: usize,
    pub bytes: u64,
    pub result: Option<serde_json::Value>,
    pub error: Option<String>,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct RestoreRequest {
    pub version: u32,
    pub task: Id,
    pub source: PathBuf,
    pub bytes: u64,
    pub sha256: String,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct RecoveredLibrary {
    pub version: u32,
    pub task: Id,
    pub root: PathBuf,
    pub library: Id,
    pub books: usize,
    pub notes: usize,
    pub source_revision: u64,
    pub device_preferences: serde_json::Value,
    pub missing_external_sources: usize,
}
fn hash(data: &[u8]) -> String {
    format!("{:x}", Sha256::digest(data))
}
fn now() -> Result<u128> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(storage)?
        .as_nanos())
}
fn read_json<T: serde::de::DeserializeOwned>(path: &Path, limit: u64) -> Result<T> {
    ensure_regular_path(path)?;
    let file = File::open(path).map_err(storage)?;
    if file.metadata().map_err(storage)?.len() > limit {
        return Err(storage("记录超过读取限额"));
    }
    serde_json::from_reader(file.take(limit + 1)).map_err(storage)
}
fn collect_task_files(
    directory: &Path,
    files: &mut usize,
    bytes: &mut u64,
    directories: &mut Vec<PathBuf>,
) -> Result<()> {
    ensure_regular_path(directory)?;
    for entry in fs::read_dir(directory).map_err(storage)? {
        let path = entry.map_err(storage)?.path();
        ensure_regular_path(&path)?;
        let metadata = fs::symlink_metadata(&path).map_err(storage)?;
        if metadata.is_dir() {
            directories.push(path.clone());
            collect_task_files(&path, files, bytes, directories)?;
        } else if metadata.is_file() && path.file_name().is_some_and(|n| n != ".records.lock") {
            *files = files.saturating_add(1);
            *bytes = bytes.saturating_add(metadata.len());
            fs::remove_file(&path).map_err(storage)?;
        }
    }
    Ok(())
}

fn collect_files(
    root: &Path,
    path: &Path,
    entries: &mut Vec<BackupEntry>,
    depth: usize,
) -> Result<()> {
    if depth > 64 {
        return Err(storage("备份目录超过 64 层"));
    }
    ensure_regular_path(path)?;
    if path.is_file() {
        if path.file_name().is_some_and(|n| n == ".records.lock") {
            return Ok(());
        }
        let relative = path
            .strip_prefix(root)
            .map_err(storage)?
            .to_string_lossy()
            .replace('\\', "/");
        let name = format!("app/{relative}");
        safe_relative(&name)?;
        if !valid_backup_name(&name) {
            return Err(storage("不允许的备份范围"));
        }
        let (bytes, sha256) = fingerprint(path)?;
        entries.push(BackupEntry {
            name,
            bytes,
            sha256,
        });
        if entries.len() > BACKUP_ENTRIES {
            return Err(storage("备份文件数超过上限"));
        }
    } else if path.is_dir() {
        for entry in fs::read_dir(path).map_err(storage)? {
            collect_files(root, &entry.map_err(storage)?.path(), entries, depth + 1)?;
        }
    } else {
        return Err(storage("备份只接受普通文件和目录"));
    }
    Ok(())
}
impl LocalBlobs {
    fn backup_root(&self) -> Result<&Path> {
        self.root.parent().ok_or_else(|| storage("应用根目录缺失"))
    }
    fn job_dir(&self, kind: &str, task: Id) -> PathBuf {
        self.root
            .join(format!("{kind}-tasks"))
            .join(task.to_string())
    }
    fn checkpoint(&self, kind: &str, task: Id) -> Result<()> {
        let canceled = self.job_dir(kind, task).join("cancel.json");
        if canceled.exists() {
            ensure_regular_path(&canceled)?;
            return Err(aq_application::Error::Unsupported(
                "任务已暂停，完整暂存与失败残留保留，可继续".into(),
            ));
        }
        Ok(())
    }
    fn progress(
        &self,
        kind: &str,
        task: Id,
        phase: &str,
        counts: (usize, usize, u64),
        result: Option<serde_json::Value>,
        error: Option<String>,
    ) -> Result<()> {
        let (completed, total, bytes) = counts;
        let value = BackupProgress {
            version: 1,
            task,
            kind: kind.into(),
            phase: phase.into(),
            completed,
            total,
            bytes,
            result,
            error,
        };
        save_new_json(
            &self.job_dir(kind, task),
            &format!("state-{:040}-{}.json", now()?, Id::new_v4()),
            &value,
        )
    }
    pub fn task_progress(&self, kind: &str, task: Id) -> Result<BackupProgress> {
        if !matches!(kind, "backup" | "restore") {
            return Err(storage("任务类别无效"));
        }
        let directory = self.job_dir(kind, task);
        ensure_regular_path(&directory)?;
        let mut paths = fs::read_dir(&directory)
            .map_err(storage)?
            .collect::<std::io::Result<Vec<_>>>()
            .map_err(storage)?;
        paths.retain(|e| {
            e.file_name().to_string_lossy().starts_with("state-")
                && e.path().extension().is_some_and(|x| x == "json")
        });
        paths.sort_by_key(|e| e.file_name());
        let path = paths
            .last()
            .ok_or_else(|| storage("任务尚未写入状态"))?
            .path();
        read_json(&path, SMALL_JSON)
    }
    pub fn cancel_backup_task(&self, kind: &str, task: Id) -> Result<()> {
        if !matches!(kind, "backup" | "restore") {
            return Err(storage("任务类别无效"));
        }
        let directory = self.job_dir(kind, task);
        ensure_regular_path(&directory)?;
        if !directory.join("cancel.json").exists() {
            save_new_json(
                &directory,
                "cancel.json",
                &serde_json::json!({"version":1,"task":task,"kind":kind}),
            )?;
        }
        Ok(())
    }
    pub fn resume_backup_task(&self, kind: &str, task: Id) -> Result<()> {
        if self.task_discarded(kind, task)? {
            return Err(storage("任务已放弃，不能继续"));
        }
        if !matches!(kind, "backup" | "restore") {
            return Err(storage("任务类别无效"));
        }
        let directory = self.job_dir(kind, task);
        ensure_regular_path(&directory)?;
        let cancel = directory.join("cancel.json");
        if cancel.exists() {
            ensure_regular_path(&cancel)?;
            fs::rename(
                cancel,
                directory.join(format!("previous-cancel-{}.json", Id::new_v4())),
            )
            .map_err(storage)?;
        }
        Ok(())
    }
    /// Give up a task the user no longer wants, and only that task.
    ///
    /// This is never automatic and never bulk: one recorded task id at a time.
    /// It deletes the task's own staging and any half-built copy it left in the
    /// private area, then appends a discard receipt. A finished task and an
    /// already published result are refused by identity, so a destination that
    /// was successfully written can never be removed by giving up the task that
    /// wrote it.
    pub fn discard_backup_task(&self, kind: &str, task: Id) -> Result<()> {
        let _guard = self.maintenance_guard()?;
        if !matches!(kind, "backup" | "restore") {
            return Err(storage("任务类别无效"));
        }
        let directory = self.job_dir(kind, task);
        if self.discard_finished(kind, task) {
            return Ok(());
        }
        let already_discarding = self.task_discarded(kind, task)?;
        if !directory.exists() && !already_discarding {
            return Err(storage("任务不存在"));
        }
        // A task whose latest state says completed has a published result that
        // this operation must not touch.
        if !already_discarding
            && self
                .task_progress(kind, task)
                .is_ok_and(|p| p.phase == "completed" || p.result.is_some())
        {
            return Err(storage("已完成的任务不能放弃，请直接管理已发布的文件"));
        }
        if kind == "restore" {
            let published = self
                .backup_root()?
                .join("recovered-libraries")
                .join(task.to_string());
            if published.exists() {
                return Err(storage("该恢复任务已产出独立副本，目录保留"));
            }
        }
        // Only this task's own regular files are removed. Private record metadata
        // (the `.records.lock` every save leaves behind) is not a backup entry and
        // is skipped instead of being rejected or swept.
        let receipts = self.root.join("discarded-task-receipts");
        if !already_discarding {
            save_new_json(
                &receipts,
                &format!("{kind}-{task}.json"),
                &serde_json::json!({"version":1,"task":task,"kind":kind}),
            )?;
        }
        let mut files = 0usize;
        let mut bytes = 0u64;
        let mut directories: Vec<PathBuf> = vec![];
        if directory.exists() {
            collect_task_files(&directory, &mut files, &mut bytes, &mut directories)?;
        }
        directories.sort_by_key(|p| std::cmp::Reverse(p.components().count()));
        for path in directories {
            if path != directory {
                let _ = fs::remove_dir(&path);
            }
        }
        let lock = directory.join(".records.lock");
        if lock.exists() {
            ensure_regular_path(&lock)?;
            fs::remove_file(&lock).map_err(storage)?;
        }
        let _ = fs::remove_dir(&directory);
        // The receipt is written beside the task folder rather than inside it, so
        // it cannot be mistaken for leftover staging and stays readable after the
        // give-up is recorded.
        save_new_json(
            &receipts,
            &format!("{kind}-{task}.completed.json"),
            &serde_json::json!({"version":1,"task":task,"kind":kind,"files":files,"bytes":bytes}),
        )?;
        Ok(())
    }
    pub fn task_discarded(&self, kind: &str, task: Id) -> Result<bool> {
        if !matches!(kind, "backup" | "restore") {
            return Err(storage("任务类别无效"));
        }
        let path = self
            .root
            .join("discarded-task-receipts")
            .join(format!("{kind}-{task}.json"));
        if !path.exists() {
            return Ok(false);
        }
        let receipt: serde_json::Value = read_json(&path, SMALL_JSON)?;
        if receipt["version"] != 1 || receipt["kind"] != kind || receipt["task"] != task.to_string()
        {
            return Err(storage("放弃任务回执身份无效"));
        }
        Ok(true)
    }
    pub fn discard_finished(&self, kind: &str, task: Id) -> bool {
        self.root
            .join("discarded-task-receipts")
            .join(format!("{kind}-{task}.completed.json"))
            .is_file()
    }
    pub fn discarded_tasks(&self) -> Result<Vec<(String, Id, bool)>> {
        let root = self.root.join("discarded-task-receipts");
        if !root.exists() {
            return Ok(vec![]);
        }
        let mut result = vec![];
        for entry in fs::read_dir(root).map_err(storage)? {
            let entry = entry.map_err(storage)?;
            let name = entry.file_name().to_string_lossy().into_owned();
            if name.ends_with(".completed.json") {
                continue;
            }
            for kind in ["backup", "restore"] {
                if let Some(id) = name
                    .strip_prefix(&format!("{kind}-"))
                    .and_then(|s| s.strip_suffix(".json"))
                    .and_then(|s| s.parse::<Id>().ok())
                    && self.task_discarded(kind, id)?
                {
                    result.push((kind.into(), id, self.discard_finished(kind, id)));
                }
            }
        }
        Ok(result)
    }
    pub fn prepare_backup(
        &self,
        catalog: &Catalog,
        preferences: serde_json::Value,
    ) -> Result<BackupPlan> {
        let _guard = self.maintenance_guard()?;
        catalog.validate_integrity()?;
        validate_device_preferences(&preferences)?;
        let root = self.backup_root()?;
        let migration_snapshots = SqliteRepository::open(&self.root)?.migration_snapshots()?;
        let mut entries = vec![];
        for directory in EXTRA_DIRS {
            let path = root.join(directory);
            if path.exists() {
                collect_files(root, &path, &mut entries, 0)?;
            }
        }
        // Backup staging belongs to the source library and is not portable.
        // Do not export its resource leases without the corresponding local job:
        // otherwise a restored copy could protect orphan bytes forever.
        let mut portable = Vec::with_capacity(entries.len());
        for entry in entries {
            if let Some(relative) = entry.name.strip_prefix("app/library/resource-pins/")
                && relative.ends_with(".json")
            {
                let value: serde_json::Value =
                    read_json(&self.root.join("resource-pins").join(relative), SMALL_JSON)?;
                let task = value["task"]
                    .as_str()
                    .and_then(|s| s.parse::<Id>().ok())
                    .ok_or_else(|| storage("资源保护记录身份无效"))?;
                if self.job_dir("backup", task).exists() || self.task_discarded("backup", task)? {
                    continue;
                }
            }
            portable.push(entry);
        }
        let mut entries = portable;
        for (name, data) in [
            (
                "catalog.json",
                serde_json::to_vec_pretty(catalog).map_err(storage)?,
            ),
            (
                "device-preferences.json",
                serde_json::to_vec_pretty(&preferences).map_err(storage)?,
            ),
        ] {
            entries.push(BackupEntry {
                name: name.into(),
                bytes: data.len() as u64,
                sha256: hash(&data),
            });
        }
        let migrations = serde_json::to_vec_pretty(&migration_snapshots).map_err(storage)?;
        entries.push(BackupEntry {
            name: "migration-backups.json".into(),
            bytes: migrations.len() as u64,
            sha256: hash(&migrations),
        });
        entries.sort_by(|a, b| a.name.cmp(&b.name));
        let manifest = BackupManifest {
            format: "aquantum-library-backup".into(),
            version: 1,
            backup: Id::new_v4(),
            library: catalog.id,
            catalog_revision: catalog.revision,
            source_root: root.to_string_lossy().to_string(),
            created_at: (now()? / 1_000_000_000) as u64,
            entries,
        };
        let total = manifest.validate()?;
        let objects: HashMap<_, _> = manifest
            .entries
            .iter()
            .map(|e| (e.name.as_str(), e))
            .collect();
        for r in catalog.retained_resources() {
            let name = format!("app/library/objects/{}", r.id);
            let entry = objects
                .get(name.as_str())
                .ok_or_else(|| storage("正文或历史资源缺失，不能报告完整备份"))?;
            if entry.bytes != r.bytes || entry.sha256 != r.sha256 {
                return Err(storage("正文或历史资源校验失败，不能报告完整备份"));
            }
        }
        let pinned: Vec<Id> = manifest
            .entries
            .iter()
            .filter_map(|e| e.name.strip_prefix("app/library/objects/"))
            .filter_map(|key| key.strip_suffix(".part").unwrap_or(key).parse().ok())
            .collect();
        self.pin_resources(manifest.backup, &pinned)?;
        let plan = BackupPlan {
            manifest,
            catalog: catalog.clone(),
            device_preferences: preferences,
            migration_snapshots,
        };
        save_new_json(
            &self.job_dir("backup", plan.manifest.backup),
            "plan.json",
            &plan,
        )?;
        self.progress(
            "backup",
            plan.manifest.backup,
            "ready",
            (0, plan.manifest.entries.len(), total),
            None,
            None,
        )?;
        Ok(plan)
    }
    pub fn backup_plan(&self, task: Id) -> Result<BackupPlan> {
        let plan: BackupPlan =
            read_json(&self.job_dir("backup", task).join("plan.json"), SMALL_JSON)?;
        plan.manifest.validate()?;
        if plan.manifest.backup != task {
            return Err(storage("备份任务身份错误"));
        }
        Ok(plan)
    }
    pub fn run_backup(&self, task: Id, destination: &Path) -> Result<serde_json::Value> {
        let _guard = self.maintenance_guard()?;
        if self.task_discarded("backup", task)? {
            return Err(storage("任务已放弃，不能继续"));
        }
        let plan = self.backup_plan(task)?;
        let total = plan.manifest.validate()?;
        let count = plan.manifest.entries.len();
        let directory = self.job_dir("backup", task);
        let result = (|| -> Result<serde_json::Value> {
            self.checkpoint("backup", task)?;
            let destination = std::path::absolute(destination).map_err(storage)?;
            let parent = destination
                .parent()
                .ok_or_else(|| storage("备份目标目录无效"))?;
            ensure_regular_path(parent)?;
            if fs::canonicalize(parent)
                .map_err(storage)?
                .starts_with(self.backup_root()?)
            {
                return Err(storage("请选择应用私有目录之外的备份位置"));
            }
            if destination.exists() {
                return Err(storage("备份目标已存在，不覆盖"));
            }
            let staged = directory.join("staged");
            fs::create_dir_all(&staged).map_err(storage)?;
            ensure_regular_path(&staged)?;
            let available = fs2::available_space(&self.root).map_err(storage)?;
            if available < total.saturating_mul(2).saturating_add(8 * 1024 * 1024) {
                return Err(storage(
                    "本地可用空间不足以暂存并校验备份，请先手动管理空间",
                ));
            }
            if fs2::available_space(parent).map_err(storage)?
                < total.saturating_add(8 * 1024 * 1024)
            {
                return Err(storage("目标目录可用空间不足"));
            }
            let mut progress_at = std::time::Instant::now();
            for (index, entry) in plan.manifest.entries.iter().enumerate() {
                self.checkpoint("backup", task)?;
                if entry.name.starts_with("app/library/objects/") {
                    continue;
                }
                let file = staged.join(format!("{index:08}.bin"));
                if file.exists() {
                    if fingerprint(&file)? != (entry.bytes, entry.sha256.clone()) {
                        return Err(storage(
                            "已有完整暂存与备份计划不一致，请创建新任务；原暂存保留",
                        ));
                    }
                } else {
                    let temporary = staged.join(format!("{}.part", Id::new_v4()));
                    let mut output = OpenOptions::new()
                        .write(true)
                        .create_new(true)
                        .open(&temporary)
                        .map_err(storage)?;
                    let actual = if entry.name == "catalog.json" {
                        let data = serde_json::to_vec_pretty(&plan.catalog).map_err(storage)?;
                        output.write_all(&data).map_err(storage)?;
                        (data.len() as u64, hash(&data))
                    } else if entry.name == "migration-backups.json" {
                        let data = serde_json::to_vec_pretty(&plan.migration_snapshots)
                            .map_err(storage)?;
                        output.write_all(&data).map_err(storage)?;
                        (data.len() as u64, hash(&data))
                    } else if entry.name == "device-preferences.json" {
                        let data =
                            serde_json::to_vec_pretty(&plan.device_preferences).map_err(storage)?;
                        output.write_all(&data).map_err(storage)?;
                        (data.len() as u64, hash(&data))
                    } else {
                        let source = self.backup_root()?.join(
                            entry
                                .name
                                .strip_prefix("app/")
                                .ok_or_else(|| storage("备份源无效"))?,
                        );
                        ensure_regular_path(&source)?;
                        copy_checked(
                            &mut File::open(source).map_err(storage)?,
                            &mut output,
                            entry.bytes,
                            &mut || self.checkpoint("backup", task),
                        )?
                    };
                    output.sync_all().map_err(storage)?;
                    drop(output);
                    if actual != (entry.bytes, entry.sha256.clone()) {
                        return Err(storage("备份期间源文件发生变化，未发布备份；请重新预览"));
                    }
                    fs::rename(temporary, file).map_err(storage)?;
                }
                if index + 1 == count
                    || progress_at.elapsed() >= std::time::Duration::from_millis(500)
                {
                    self.progress(
                        "backup",
                        task,
                        "staging",
                        (index + 1, count, total),
                        None,
                        None,
                    )?;
                    progress_at = std::time::Instant::now();
                }
            }
            let temporary = directory.join(format!("archive-{}.part", Id::new_v4()));
            let mut writer = ZipWriter::new(
                OpenOptions::new()
                    .read(true)
                    .write(true)
                    .create_new(true)
                    .open(&temporary)
                    .map_err(storage)?,
            );
            writer
                .start_file("manifest.json", SimpleFileOptions::default())
                .map_err(storage)?;
            writer
                .write_all(&serde_json::to_vec_pretty(&plan.manifest).map_err(storage)?)
                .map_err(storage)?;
            let mut progress_at = std::time::Instant::now();
            for (index, entry) in plan.manifest.entries.iter().enumerate() {
                self.checkpoint("backup", task)?;
                writer
                    .start_file(
                        &entry.name,
                        SimpleFileOptions::default()
                            .compression_method(zip::CompressionMethod::Stored)
                            .large_file(entry.bytes >= u32::MAX as u64),
                    )
                    .map_err(storage)?;
                let source = if entry.name.starts_with("app/library/objects/") {
                    self.backup_root()?
                        .join(entry.name.strip_prefix("app/").unwrap())
                } else {
                    staged.join(format!("{index:08}.bin"))
                };
                ensure_regular_path(&source)?;
                let actual = copy_checked(
                    &mut File::open(source).map_err(storage)?,
                    &mut writer,
                    entry.bytes,
                    &mut || self.checkpoint("backup", task),
                )?;
                if actual != (entry.bytes, entry.sha256.clone()) {
                    return Err(storage("备份暂存校验失败，未发布"));
                }
                if index + 1 == count
                    || progress_at.elapsed() >= std::time::Duration::from_millis(500)
                {
                    self.progress(
                        "backup",
                        task,
                        "packing",
                        (index + 1, count, total),
                        None,
                        None,
                    )?;
                    progress_at = std::time::Instant::now();
                }
            }
            let output = writer.finish().map_err(storage)?;
            output.sync_all().map_err(storage)?;
            drop(output);
            let checked = inspect_backup(&temporary)?;
            if checked.backup != task {
                return Err(storage("备份复核身份不一致"));
            }
            let mut verify =
                ZipArchive::new(File::open(&temporary).map_err(storage)?).map_err(storage)?;
            for index in 0..verify.len() {
                self.checkpoint("backup", task)?;
                let mut entry = verify.by_index(index).map_err(storage)?;
                let limit = entry.size();
                copy_checked(&mut entry, &mut std::io::sink(), limit, &mut || {
                    self.checkpoint("backup", task)
                })?;
            }
            drop(verify);
            crate::archives::publish_no_replace(&temporary, &destination)?;
            let result = serde_json::json!({"task":task,"destination":destination,"files":count,"bytes":total,"temporary_retained":fs::remove_file(&temporary).is_err()});
            self.progress(
                "backup",
                task,
                "completed",
                (count, count, total),
                Some(result.clone()),
                None,
            )?;
            Ok(result)
        })();
        if let Err(e) = &result {
            let _ = self.progress(
                "backup",
                task,
                "stopped",
                (0, count, total),
                None,
                Some(e.to_string()),
            );
        }
        result
    }
    pub fn prepare_restore(&self, source: &Path) -> Result<RestoreRequest> {
        ensure_regular_path(source)?;
        let source = fs::canonicalize(source).map_err(storage)?;
        inspect_backup(&source)?;
        let (bytes, sha256) = fingerprint(&source)?;
        let request = RestoreRequest {
            version: 1,
            task: Id::new_v4(),
            source,
            bytes,
            sha256,
        };
        save_new_json(
            &self.job_dir("restore", request.task),
            "request.json",
            &request,
        )?;
        self.progress("restore", request.task, "ready", (0, 1, bytes), None, None)?;
        Ok(request)
    }
    pub fn run_restore(&self, task: Id) -> Result<RecoveredLibrary> {
        let _guard = self.maintenance_guard()?;
        if self.task_discarded("restore", task)? {
            return Err(storage("任务已放弃，不能继续"));
        }
        let request: RestoreRequest = read_json(
            &self.job_dir("restore", task).join("request.json"),
            SMALL_JSON,
        )?;
        if request.version != 1 || request.task != task {
            return Err(storage("恢复任务身份错误"));
        }
        let recovered_parent = self.backup_root()?.join("recovered-libraries");
        fs::create_dir_all(&recovered_parent).map_err(storage)?;
        ensure_regular_path(&recovered_parent)?;
        let destination = recovered_parent.join(task.to_string());
        if destination.exists() {
            let value: RecoveredLibrary =
                read_json(&destination.join("recovery.json"), SMALL_JSON)?;
            if value.version != 1
                || value.task != task
                || value.root != destination
                || SqliteRepository::open(&destination.join("library"))?
                    .load()?
                    .id
                    != value.library
            {
                return Err(storage("既有恢复副本身份不一致，原目录保留"));
            }
            return Ok(value);
        }
        let result = (|| -> Result<RecoveredLibrary> {
            self.checkpoint("restore", task)?;
            if fingerprint(&request.source)? != (request.bytes, request.sha256.clone()) {
                return Err(storage("备份文件在确认后改变，请重新选择"));
            }
            let manifest = inspect_backup(&request.source)?;
            let total = manifest.validate()?;
            if fs2::available_space(&recovered_parent).map_err(storage)?
                < total.saturating_add(16 * 1024 * 1024)
            {
                return Err(storage("本地空间不足以恢复独立副本，现有资料库保留"));
            }
            let output = self
                .job_dir("restore", task)
                .join(format!("attempt-{}", Id::new_v4()));
            crate::archives::unpack_archive_checked(
                &request.source,
                &output,
                BACKUP_LIMIT + SMALL_JSON,
                BACKUP_ENTRIES + 1,
                || self.checkpoint("restore", task),
            )?;
            let mut progress_at = std::time::Instant::now();
            for (index, entry) in manifest.entries.iter().enumerate() {
                self.checkpoint("restore", task)?;
                if fingerprint(&output.join(safe_relative(&entry.name)?))?
                    != (entry.bytes, entry.sha256.clone())
                {
                    return Err(storage("恢复文件校验失败，现有资料库保留"));
                }
                if index + 1 == manifest.entries.len()
                    || progress_at.elapsed() >= std::time::Duration::from_millis(500)
                {
                    self.progress(
                        "restore",
                        task,
                        "checking",
                        (index + 1, manifest.entries.len(), total),
                        None,
                        None,
                    )?;
                    progress_at = std::time::Instant::now();
                }
            }
            let raw: serde_json::Value = read_json(&output.join("catalog.json"), SMALL_JSON)?;
            let mut catalog: Catalog = serde_json::from_value(raw.clone()).map_err(storage)?;
            crate::repository::migrate_catalog(&mut catalog, aq_domain::DATA_VERSION)?;
            catalog.validate_integrity()?;
            if catalog.id != manifest.library || catalog.revision != manifest.catalog_revision {
                return Err(storage("备份清单与目录身份不一致"));
            }
            let preferences: serde_json::Value =
                read_json(&output.join("device-preferences.json"), 2 * 1024 * 1024)?;
            validate_device_preferences(&preferences)?;
            let app = output.join("app");
            fs::create_dir_all(app.join("library")).map_err(storage)?;
            let by_name: HashMap<_, _> = manifest
                .entries
                .iter()
                .map(|e| (e.name.as_str(), e))
                .collect();
            for resource in catalog.retained_resources() {
                let name = format!("app/library/objects/{}", resource.id);
                let entry = by_name
                    .get(name.as_str())
                    .ok_or_else(|| storage("备份缺少正文或历史资源"))?;
                if entry.sha256 != resource.sha256 || entry.bytes != resource.bytes {
                    return Err(storage("备份资源与目录校验值不匹配"));
                }
            }
            let completed: HashSet<_> = catalog.imports.iter().map(|i| i.task).collect();
            let missing = rebase_import_plans(
                &app,
                &PathBuf::from(&manifest.source_root),
                &destination,
                &completed,
            )?;
            let mut repository = SqliteRepository::open(&app.join("library"))?;
            catalog.revision = 1;
            repository.save(0, &catalog)?;
            if output.join("migration-backups.json").exists() {
                let snapshots: Vec<aq_application::backup::MigrationSnapshot> =
                    read_json(&output.join("migration-backups.json"), SMALL_JSON)?;
                repository.retain_migration_snapshots(&snapshots)?;
            }
            drop(repository);
            save_new_json(
                &app.join("restoration-origins"),
                &format!("restore-{}.json", task),
                &serde_json::json!({"manifest":manifest,"original_catalog":raw}),
            )?;
            let result = RecoveredLibrary {
                version: 1,
                task,
                root: destination.clone(),
                library: catalog.id,
                books: catalog.books.len(),
                notes: catalog.notes.len(),
                source_revision: manifest.catalog_revision,
                device_preferences: preferences,
                missing_external_sources: missing,
            };
            save_new_json(&app, "recovery.json", &result)?;
            fs::rename(&app, &destination).map_err(storage)?;
            self.progress(
                "restore",
                task,
                "completed",
                (manifest.entries.len(), manifest.entries.len(), total),
                Some(serde_json::to_value(&result).map_err(storage)?),
                None,
            )?;
            Ok(result)
        })();
        if let Err(e) = &result {
            let _ = self.progress(
                "restore",
                task,
                "stopped",
                (0, 1, request.bytes),
                None,
                Some(e.to_string()),
            );
        }
        result
    }
}

pub fn inspect_backup(source: &Path) -> Result<BackupManifest> {
    ensure_regular_path(source)?;
    if fs::metadata(source).map_err(storage)?.len() > BACKUP_LIMIT + SMALL_JSON {
        return Err(storage("备份文件超过限额"));
    }
    let mut archive = ZipArchive::new(File::open(source).map_err(storage)?).map_err(storage)?;
    if archive.len() > BACKUP_ENTRIES + 1 {
        return Err(storage("备份条目超过上限"));
    }
    let manifest: BackupManifest = {
        let file = archive.by_name("manifest.json").map_err(storage)?;
        if file.size() > SMALL_JSON {
            return Err(storage("备份清单过大"));
        }
        serde_json::from_reader(file.take(SMALL_JSON + 1)).map_err(storage)?
    };
    manifest.validate()?;
    let expected: HashMap<_, _> = manifest
        .entries
        .iter()
        .map(|e| (e.name.as_str(), e.bytes))
        .collect();
    let mut names = HashSet::new();
    for index in 0..archive.len() {
        let entry = archive.by_index(index).map_err(storage)?;
        safe_relative(entry.name())?;
        if entry.is_dir()
            || entry.enclosed_name().is_none()
            || entry
                .unix_mode()
                .is_some_and(|m| m & 0o170000 != 0 && m & 0o170000 != 0o100000)
            || !names.insert(entry.name().to_lowercase())
        {
            return Err(storage("备份包含目录项、重复路径、链接或特殊文件"));
        }
        if entry.name() != "manifest.json" && expected.get(entry.name()) != Some(&entry.size()) {
            return Err(storage("备份文件列表或大小与清单不一致"));
        }
    }
    if archive.len() != expected.len() + 1 {
        return Err(storage("备份缺少文件"));
    }
    Ok(manifest)
}
fn rebase_import_plans(
    app: &Path,
    old_root: &Path,
    new_root: &Path,
    completed: &HashSet<Id>,
) -> Result<usize> {
    let directory = app.join("import-staging");
    if !directory.exists() {
        return Ok(0);
    }
    let mut missing = 0;
    for entry in fs::read_dir(&directory).map_err(storage)? {
        let entry = entry.map_err(storage)?;
        if !entry.file_type().map_err(storage)?.is_dir() {
            continue;
        }
        let path = entry.path().join("plan.json");
        if !path.exists() {
            continue;
        }
        let mut plan: aq_application::ImportPlan = read_json(&path, SMALL_JSON)?;
        if completed.contains(&plan.task) {
            continue;
        }
        let mut task_missing = 0;
        for resource in plan.books.iter_mut().flat_map(|b| &mut b.resources) {
            if let Ok(relative) = resource.source.strip_prefix(old_root)
                && relative.starts_with("import-staging")
                && crate::safe_relative(&relative.to_string_lossy()).is_ok()
                && app.join(relative).is_file()
            {
                let staged = fs::canonicalize(app.join(relative)).map_err(storage)?;
                if !staged
                    .starts_with(fs::canonicalize(app.join("import-staging")).map_err(storage)?)
                {
                    return Err(storage("恢复计划来源越出暂存目录"));
                }
                ensure_regular_path(&staged)?;
                resource.source = new_root.join(relative);
            } else {
                missing += 1;
                task_missing += 1;
            }
        }
        let before = entry
            .path()
            .join(format!("before-restore-plan-{}.json", Id::new_v4()));
        fs::rename(&path, before).map_err(storage)?;
        save_new_json(&entry.path(), "plan.json", &plan)?;
        if task_missing > 0
            && !entry
                .path()
                .join("external-sources-require-selection.json")
                .exists()
        {
            save_new_json(
                &entry.path(),
                "external-sources-require-selection.json",
                &serde_json::json!({"version":1,"reason":"外部来源未包含在备份中；需要重新选择后才能继续"}),
            )?;
        }
    }
    Ok(missing)
}

#[cfg(test)]
mod recovery_path_tests {
    use super::*;
    use aq_application::Repository;
    #[test]
    fn restored_import_plans_cannot_rebase_parent_segments_outside_staging() {
        let temp = tempfile::tempdir().unwrap();
        let app = temp.path().join("app");
        let task = app.join("import-staging/task");
        fs::create_dir_all(&task).unwrap();
        let outside = app.join("outside.txt");
        fs::write(&outside, b"must not become a staged source").unwrap();
        let library = app.join("library");
        let c = crate::SqliteRepository::open(&library)
            .unwrap()
            .load()
            .unwrap();
        let mut plan = crate::plan_import(&c, &library, &outside, c.inbox).unwrap();
        let old_root = temp.path().join("old-root");
        plan.books[0].resources[0].source = old_root.join("import-staging/../outside.txt");
        fs::write(task.join("plan.json"), serde_json::to_vec(&plan).unwrap()).unwrap();
        let new_root = temp.path().join("recovered");
        assert_eq!(
            rebase_import_plans(&app, &old_root, &new_root, &HashSet::new()).unwrap(),
            1
        );
        assert!(
            task.join("external-sources-require-selection.json")
                .exists()
        );
        let rebased: aq_application::ImportPlan =
            read_json(&task.join("plan.json"), SMALL_JSON).unwrap();
        assert!(!rebased.books[0].resources[0].source.starts_with(&new_root));
    }
}
