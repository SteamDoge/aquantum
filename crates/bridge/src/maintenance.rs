// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
//! Storage JSON adaptation. Policies remain in application/local.
use crate::session::Session;
use aq_domain::Id;
use serde_json::{Value, json};
use std::{fs, path::PathBuf};
fn error(e: impl std::fmt::Display) -> String {
    e.to_string()
}
fn id(args: &Value, name: &str) -> Result<Id, String> {
    args.get(name)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("缺少 {name}"))?
        .parse()
        .map_err(error)
}
fn text(args: &Value, name: &str) -> Result<String, String> {
    args.get(name)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| format!("缺少 {name}"))
}

impl Session {
    pub fn maintenance_operation(
        &mut self,
        method: &str,
        args: &Value,
    ) -> Option<Result<Value, String>> {
        if !matches!(
            method,
            "storage_overview"
                | "cleanup_preview"
                | "cleanup_state"
                | "cleanup_confirm"
                | "cleanup_step"
                | "backup_prepare"
                | "backup_run"
                | "restore_prepare"
                | "restore_run"
                | "task_status"
                | "task_cancel"
                | "task_resume"
                | "storage_tasks"
                | "task_discard"
                | "discard_import_task"
        ) {
            return None;
        }
        Some((|| -> Result<Value, String> {
            match method {
                "storage_overview" => self.storage_overview(),
                "cleanup_preview" => Ok(json!(
                    self.reader
                        .blobs
                        .cleanup_preview(&self.reader.catalog().map_err(error)?)
                        .map_err(error)?
                )),
                "cleanup_state" => self
                    .reader
                    .blobs
                    .cleanup_state(id(args, "task")?)
                    .map_err(error),
                "cleanup_confirm" => {
                    let keys: Vec<String> =
                        serde_json::from_value(args.get("keys").cloned().ok_or("缺少确认范围")?)
                            .map_err(error)?;
                    self.reader
                        .blobs
                        .confirm_cleanup(
                            &self.reader.catalog().map_err(error)?,
                            id(args, "task")?,
                            &keys,
                        )
                        .map_err(error)?;
                    Ok(Value::Null)
                }
                "cleanup_step" => Ok(json!(
                    self.reader
                        .blobs
                        .cleanup_item(
                            &self.reader.catalog().map_err(error)?,
                            id(args, "task")?,
                            &text(args, "key")?
                        )
                        .map_err(error)?
                )),
                "backup_prepare" => {
                    let preferences = args
                        .get("device_preferences")
                        .cloned()
                        .ok_or("缺少设备设置快照")?;
                    let plan = self
                        .reader
                        .blobs
                        .prepare_backup(&self.reader.catalog().map_err(error)?, preferences)
                        .map_err(error)?;
                    Ok(
                        json!({"task":plan.manifest.backup,"files":plan.manifest.entries.len(),"bytes":plan.manifest.validate().map_err(error)?,"created_at":plan.manifest.created_at,"library":plan.manifest.library}),
                    )
                }
                "backup_run" => self
                    .reader
                    .blobs
                    .run_backup(
                        id(args, "task")?,
                        &PathBuf::from(text(args, "destination")?),
                    )
                    .map_err(error),
                "restore_prepare" => Ok(json!(
                    self.reader
                        .blobs
                        .prepare_restore(&PathBuf::from(text(args, "source")?))
                        .map_err(error)?
                )),
                "restore_run" => Ok(json!(
                    self.reader
                        .blobs
                        .run_restore(id(args, "task")?)
                        .map_err(error)?
                )),
                "task_status" => Ok(json!(
                    self.reader
                        .blobs
                        .task_progress(&text(args, "kind")?, id(args, "task")?)
                        .map_err(error)?
                )),
                "task_cancel" => {
                    self.reader
                        .blobs
                        .cancel_backup_task(&text(args, "kind")?, id(args, "task")?)
                        .map_err(error)?;
                    Ok(Value::Null)
                }
                "task_resume" => {
                    self.reader
                        .blobs
                        .resume_backup_task(&text(args, "kind")?, id(args, "task")?)
                        .map_err(error)?;
                    Ok(Value::Null)
                }
                "task_discard" => {
                    self.reader
                        .blobs
                        .discard_backup_task(&text(args, "kind")?, id(args, "task")?)
                        .map_err(error)?;
                    Ok(Value::Null)
                }
                "storage_tasks" => self.storage_tasks(),
                "discard_import_task" => {
                    let task = id(args, "task")?;
                    let path = self.staging.join(task.to_string());
                    self.import_plan(task)?;
                    self.reader.blobs.release_import_pins(task).map_err(error)?;
                    if !path.join("discarded.json").exists() {
                        let mut file = fs::OpenOptions::new()
                            .write(true)
                            .create_new(true)
                            .open(path.join("discarded.json"))
                            .map_err(error)?;
                        use std::io::Write;
                        file.write_all(serde_json::to_string(&json!({"version":1,"task":task,"reason":"用户明确放弃恢复；原计划和暂存保留"})).map_err(error)?.as_bytes()).map_err(error)?;
                        file.sync_all().map_err(error)?;
                    }
                    Ok(Value::Null)
                }
                _ => unreachable!(),
            }
        })())
    }
    fn storage_overview(&self) -> Result<Value, String> {
        let c = self.reader.catalog().map_err(error)?;
        let pins = self.reader.blobs.pinned_resources(&c).map_err(error)?;
        let mut books = vec![];
        for book in &c.books {
            let mut unique = std::collections::HashSet::new();
            let bytes: u64 = book
                .pages
                .iter()
                .filter(|p| unique.insert(p.resource.id))
                .map(|p| p.resource.bytes)
                .sum();
            books.push(json!({"book":book.id,"project":book.project,"title":book.title,"archived":book.archived,"bytes":bytes,"resources":unique.len()}));
        }
        let mut projects = vec![];
        for project in &c.projects {
            let mut unique = std::collections::HashMap::new();
            let mut book_count = 0;
            for book in &c.books {
                let mut next = Some(book.project);
                let mut visited = std::collections::HashSet::new();
                let mut includes = false;
                while let Some(node) = next {
                    if !visited.insert(node) {
                        break;
                    }
                    if node == project.id {
                        includes = true;
                        break;
                    }
                    next = c.project(node).map_err(error)?.parent;
                }
                if includes {
                    book_count += 1;
                    for page in &book.pages {
                        unique
                            .entry(page.resource.id)
                            .or_insert(page.resource.bytes);
                    }
                }
            }
            projects.push(json!({"project":project.id,"name":project.name,"books":book_count,"resources":unique.len(),"bytes":unique.values().sum::<u64>()}));
        }
        Ok(
            json!({"usage":self.reader.blobs.usage(&c).map_err(error)?,"available_bytes":aq_local::available_storage(&self.library).map_err(error)?,"pinned_resources":pins.len(),"books":books,"projects":projects}),
        )
    }
    /// One list for every stored task. Import, cleanup, backup and restore all
    /// report the same fields so the client needs no per-kind rules.
    fn storage_tasks(&self) -> Result<Value, String> {
        let mut tasks = vec![];
        for item in self.import_tasks()? {
            let restart = if item.status == "completed" {
                "none"
            } else {
                "reopen_preview"
            };
            // Only a task that is neither abandoned nor finished can be given up; giving it up never deletes its plan or staging.
            let discardable = matches!(item.status, "pending" | "error");
            tasks.push(json!({"task":item.task,"kind":"import","phase":item.status,"completed":if item.status=="completed"{item.books}else{0},"total":item.books,"error":item.error,"cancellable":false,"discardable":discardable,
                "restart":restart}));
        }
        let cleanup_keys = |state: &Value| {
            state["confirmed"]["keys"]
                .as_array()
                .map(Vec::len)
                .unwrap_or(0)
        };
        for entry in self.task_directories("maintenance-tasks")? {
            let (_, task) = entry;
            let mut value = match self.reader.blobs.cleanup_state(task) {
                Ok(state) => {
                    let total = cleanup_keys(&state);
                    let completed = state["completed"].as_array().map(Vec::len).unwrap_or(0);
                    let phase = if state["confirmed"].is_null() {
                        "ready"
                    } else if completed == total {
                        "completed"
                    } else {
                        "pending"
                    };
                    json!({"task":task,"phase":phase,"completed":completed,"total":total,"cancellable":false,"discardable":false,
                        "restart":"continue_steps"})
                }
                Err(e) => {
                    json!({"task":task,"phase":"error","error":e.to_string(),"cancellable":false,
                        "discardable":false,"restart":"none"})
                }
            };
            value["kind"] = "cleanup".into();
            tasks.push(value);
        }
        for (directory, kind) in [("backup-tasks", "backup"), ("restore-tasks", "restore")] {
            for (cancelled, task) in self.task_directories(directory)? {
                if self
                    .reader
                    .blobs
                    .task_discarded(kind, task)
                    .map_err(error)?
                {
                    continue;
                }
                // A cancelled task is not resume-on-its-own: the client must ask
                // again before anything continues, so it is a distinct phase.
                let mut value = match self.reader.blobs.task_progress(kind, task) {
                    Ok(progress) => {
                        let mut value = json!(progress);
                        if cancelled && value["phase"] != "completed" {
                            value["phase"] = "cancelled".into();
                        }
                        // Giving up is offered for exactly the tasks that have no
                        // published result yet, and it is still an explicit request.
                        let finished = value["phase"] == "completed";
                        value["cancellable"] = json!(!finished);
                        value["discardable"] = json!(!finished);
                        value["restart"] = if finished { "none" } else { "resume" }.into();
                        value
                    }
                    Err(e) => {
                        json!({"task":task,"phase":if cancelled{"cancelled"}else{"error"},"error":e.to_string(),
                            "cancellable":cancelled,"discardable":true,"restart":"resume"})
                    }
                };
                value["kind"] = kind.into();
                tasks.push(value);
            }
        }
        for (kind, task, finished) in self.reader.blobs.discarded_tasks().map_err(error)? {
            tasks.push(json!({"task":task,"kind":kind,"phase":if finished{"discarded"}else{"discarding"},"completed":0,"total":0,"cancellable":false,"discardable":!finished,"restart":"none"}));
        }
        Ok(json!(tasks))
    }
    /// Task directories of one kind, each flagged with a still-present cancel
    /// request. Names that are not task ids are skipped instead of failing the
    /// list, and a missing root simply means no such task ever started.
    ///
    /// Every row of `storage_tasks` carries the same control fields so the client
    /// needs no per-kind branching: `cancellable` (a running task can be asked to
    /// stop), `discardable` (an abandoned task can be given up, keeping plan and
    /// staging), `restart` (how continuing works) and `phase`.
    fn task_directories(&self, directory: &str) -> Result<Vec<(bool, Id)>, String> {
        let root = self.library.join(directory);
        if !root.exists() {
            return Ok(vec![]);
        }
        let mut tasks = vec![];
        for entry in fs::read_dir(root).map_err(error)? {
            let entry = entry.map_err(error)?;
            if !entry.file_type().map_err(error)?.is_dir() {
                continue;
            }
            let Ok(task) = entry.file_name().to_string_lossy().parse::<Id>() else {
                continue;
            };
            tasks.push((entry.path().join("cancel.json").exists(), task));
        }
        Ok(tasks)
    }
}
