// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
//! Durable import plans. Clients may edit labels and identity lists, never paths.
use crate::session::{IncomingFile, Session};
use aq_application::{AppendPlacement, ImportPlan};
use aq_domain::{CompletedImport, Format, Id};
use aq_local::{ARCHIVE_BYTES, plan_import, safe_relative, unpack_archive};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde::{Deserialize, Serialize};
use std::{collections::HashSet, fs, path::PathBuf};

#[derive(Deserialize)]
pub struct ImportSelection {
    pub target: Id,
    #[serde(default)]
    pub paths: Vec<PathBuf>,
    #[serde(default)]
    pub files: Vec<IncomingFile>,
}

#[cfg(test)]
mod tests {
    use super::*;
    fn edits(plan: &ImportPlan) -> CommitImport {
        CommitImport {
            task: plan.task,
            base_revision: plan.base_revision,
            target: plan.target,
            books: plan
                .books
                .iter()
                .map(|b| BookEdit {
                    id: b.id,
                    title: b.title.clone(),
                    project: b.project,
                    resources: b.resources.iter().map(|r| r.id).collect(),
                })
                .collect(),
            projects: plan
                .projects
                .iter()
                .map(|p| ProjectEdit {
                    id: p.id,
                    name: p.name.clone(),
                })
                .collect(),
            skip_issues: false,
            append: None,
        }
    }
    #[test]
    fn saved_preview_edits_survive_restart_and_commit_once_without_forged_resources() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("app");
        let source = temp.path().join("original.txt");
        fs::write(&source, "first\n\nsecond").unwrap();
        let session = Session::open(&root).unwrap();
        let inbox = session.reader.catalog().unwrap().inbox;
        let plan = session
            .preview_import(ImportSelection {
                target: inbox,
                paths: vec![source.clone()],
                files: vec![],
            })
            .unwrap();
        assert!(session.reader.catalog().unwrap().books.is_empty());
        let mut change = edits(&plan);
        change.books[0].title = "edited title".into();
        session.save_import_draft(&change).unwrap();
        drop(session);
        let mut session = Session::open(&root).unwrap();
        assert_eq!(
            session.import_plan(plan.task).unwrap().books[0].title,
            "edited title"
        );
        let mut forged = change.clone();
        forged.books[0].resources[0] = Id::new_v4();
        assert!(session.commit_import(forged).is_err());
        assert!(session.reader.catalog().unwrap().books.is_empty());
        let done = session.commit_import(change.clone()).unwrap();
        assert_eq!(
            session
                .reader
                .catalog()
                .unwrap()
                .book(done.books[0])
                .unwrap()
                .title,
            "edited title"
        );
        session.commit_import(change).unwrap();
        assert_eq!(session.reader.catalog().unwrap().books.len(), 1);
        assert_eq!(session.import_tasks().unwrap()[0].status, "completed");
        assert_eq!(fs::read_to_string(source).unwrap(), "first\n\nsecond");
    }
    #[test]
    fn changed_source_and_stale_preview_never_partially_commit() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("app");
        let source = temp.path().join("original.txt");
        fs::write(&source, "original").unwrap();
        let mut session = Session::open(&root).unwrap();
        let inbox = session.reader.catalog().unwrap().inbox;
        let plan = session
            .preview_import(ImportSelection {
                target: inbox,
                paths: vec![source.clone()],
                files: vec![],
            })
            .unwrap();
        session.reader.create_project(inbox, "new project").unwrap();
        assert!(session.commit_import(edits(&plan)).is_err());
        let refreshed = session.import_plan(plan.task).unwrap();
        assert!(refreshed.base_revision > plan.base_revision);
        fs::write(&source, "changed").unwrap();
        assert!(session.commit_import(edits(&refreshed)).is_err());
        assert!(session.reader.catalog().unwrap().books.is_empty());
        assert_eq!(session.import_tasks().unwrap()[0].status, "pending");
    }
}
#[derive(Clone, Serialize, Deserialize)]
pub struct BookEdit {
    pub id: Id,
    pub title: String,
    pub project: Id,
    pub resources: Vec<Id>,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct ProjectEdit {
    pub id: Id,
    pub name: String,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct CommitImport {
    pub task: Id,
    pub base_revision: u64,
    pub target: Id,
    pub books: Vec<BookEdit>,
    pub projects: Vec<ProjectEdit>,
    #[serde(default)]
    pub skip_issues: bool,
    pub append: Option<AppendPlacement>,
}
#[derive(Serialize)]
pub struct ImportTask {
    pub task: Id,
    pub status: &'static str,
    pub books: usize,
    pub issues: usize,
    pub error: Option<String>,
}
fn error(e: impl std::fmt::Display) -> String {
    e.to_string()
}
fn write_new(path: &std::path::Path, data: &[u8]) -> Result<(), String> {
    aq_local::save_private_record(path, data).map_err(error)
}
impl Session {
    fn task_path(&self, task: Id) -> PathBuf {
        self.staging.join(task.to_string())
    }
    fn original_plan(&self, task: Id) -> Result<ImportPlan, String> {
        let mut plan: ImportPlan = serde_json::from_slice(
            &fs::read(self.task_path(task).join("plan.json")).map_err(error)?,
        )
        .map_err(error)?;
        let catalog = self.reader.catalog().map_err(error)?;
        if plan.task != task || plan.library != catalog.id {
            return Err("任务身份或资料库不匹配".into());
        }
        // Reopening a preview explicitly refreshes the catalog version. Immutable
        // original paths/hashes remain server-owned and are checked at execution.
        plan.base_revision = catalog.revision;
        Ok(plan)
    }
    fn draft(&self, task: Id) -> Result<Option<CommitImport>, String> {
        let mut paths: Vec<_> = fs::read_dir(self.task_path(task))
            .map_err(error)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(error)?
            .into_iter()
            .filter(|e| e.file_name().to_string_lossy().starts_with("draft-"))
            .collect();
        paths.sort_by_key(|e| e.file_name());
        paths
            .last()
            .map(|e| serde_json::from_slice(&fs::read(e.path()).map_err(error)?).map_err(error))
            .transpose()
    }
    pub fn import_plan(&self, task: Id) -> Result<ImportPlan, String> {
        let original = self.original_plan(task)?;
        let mut plan = match self.draft(task)? {
            Some(edits) => Self::edit_plan(original, &edits)?,
            None => original,
        };
        plan.base_revision = self.reader.catalog().map_err(error)?.revision;
        Ok(plan)
    }
    pub fn import_preview_value(&self, task: Id) -> Result<serde_json::Value, String> {
        let mut value = serde_json::to_value(self.import_plan(task)?).map_err(error)?;
        if let Some(draft) = self.draft(task)? {
            value["_append"] = serde_json::to_value(draft.append).map_err(error)?;
            value["_skip_issues"] = draft.skip_issues.into();
        }
        Ok(value)
    }
    pub fn save_import_draft(&self, edits: &CommitImport) -> Result<(), String> {
        Self::edit_plan(self.original_plan(edits.task)?, edits)?;
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(error)?
            .as_nanos();
        let file = self
            .task_path(edits.task)
            .join(format!("draft-{nanos:040}-{}.json", Id::new_v4()));
        write_new(&file, &serde_json::to_vec_pretty(edits).map_err(error)?)
    }
    pub fn import_tasks(&self) -> Result<Vec<ImportTask>, String> {
        let c = self.reader.catalog().map_err(error)?;
        let mut tasks = vec![];
        for entry in fs::read_dir(&self.staging).map_err(error)? {
            let entry = entry.map_err(error)?;
            if !entry.file_type().map_err(error)?.is_dir() {
                continue;
            }
            let Ok(task) = entry.file_name().to_string_lossy().parse::<Id>() else {
                continue;
            };
            if !entry.path().join("plan.json").is_file() {
                continue;
            }
            let plan = match self.import_plan(task) {
                Ok(plan) => plan,
                Err(error) => {
                    tasks.push(ImportTask {
                        task,
                        status: "error",
                        books: 0,
                        issues: 1,
                        error: Some(error),
                    });
                    continue;
                }
            };
            tasks.push(ImportTask {
                task,
                status: if entry.path().join("discarded.json").exists() {
                    "discarded"
                } else if c.imports.iter().any(|i| i.task == task) {
                    "completed"
                } else {
                    "pending"
                },
                books: plan.books.len(),
                issues: plan.issues.len(),
                error: None,
            });
        }
        tasks.sort_by_key(|t| t.task);
        Ok(tasks)
    }
    pub fn preview_import(&self, selection: ImportSelection) -> Result<ImportPlan, String> {
        let catalog = self.reader.catalog().map_err(error)?;
        catalog.project(selection.target).map_err(error)?;
        if selection.paths.is_empty() == selection.files.is_empty() {
            return Err("请选择路径或文件流中的一种来源".into());
        }
        if selection.paths.len() + selection.files.len() > 10_000 {
            return Err("一次最多选择 10000 个文件".into());
        }
        let task = Id::new_v4();
        let directory = self.task_path(task);
        fs::create_dir(&directory).map_err(error)?;
        let mut sources = selection.paths;
        if !selection.files.is_empty() {
            let input = directory.join("input");
            fs::create_dir(&input).map_err(error)?;
            let mut total = 0usize;
            for file in selection.files {
                let relative = safe_relative(&file.name).map_err(error)?;
                if file.data.len() > crate::session::IMPORT_LIMIT * 4 / 3 + 4 {
                    return Err("流式选择单次超过 32 MiB，请使用文件路径或分批".into());
                }
                let data = STANDARD.decode(file.data).map_err(error)?;
                total += data.len();
                if total > crate::session::IMPORT_LIMIT {
                    return Err("文件流单次超过 32 MiB".into());
                }
                let path = input.join(relative);
                fs::create_dir_all(path.parent().ok_or("无效目录")?).map_err(error)?;
                write_new(&path, &data)?;
                sources.push(path);
            }
        }
        sources
            .sort_by(|a, b| aq_domain::natural_compare(&a.to_string_lossy(), &b.to_string_lossy()));
        let mut plan = ImportPlan {
            version: 1,
            task,
            library: catalog.id,
            base_revision: catalog.revision,
            target: selection.target,
            projects: vec![],
            books: vec![],
            issues: vec![],
        };
        let mut images = vec![];
        let mut total = 0u64;
        for (i, source) in sources.iter().enumerate() {
            let ext = source
                .extension()
                .and_then(|s| s.to_str())
                .unwrap_or_default()
                .to_lowercase();
            let archive = matches!(ext.as_str(), "zip" | "cbz");
            let item = if archive {
                let output = directory.join(format!("archive-{i}"));
                unpack_archive(source, &output).map_err(error)?;
                let mut item = plan_import(&catalog, &self.library, &output, selection.target)
                    .map_err(error)?;
                let name = source
                    .file_stem()
                    .unwrap_or_default()
                    .to_string_lossy()
                    .to_string();
                if let Some(root) = item.projects.first_mut() {
                    root.name = name.clone();
                }
                for book in &mut item.books {
                    if book.title == format!("archive-{i}") {
                        book.title = name.clone();
                    }
                }
                item
            } else {
                plan_import(&catalog, &self.library, source, selection.target).map_err(error)?
            };
            plan.issues.extend(item.issues);
            plan.projects.extend(item.projects);
            for book in item.books {
                total = total
                    .checked_add(book.resources.iter().map(|r| r.bytes).sum::<u64>())
                    .ok_or("大小溢出")?;
                if total > ARCHIVE_BYTES {
                    return Err("单任务超过 512 MiB，请分批导入".into());
                }
                if !source.is_dir() && !archive && book.format == Format::Comic {
                    images.extend(book.resources);
                } else {
                    plan.books.push(book);
                }
            }
        }
        if !images.is_empty() {
            let title = images[0]
                .original_name
                .rsplit_once('.')
                .map(|(name, _)| name)
                .unwrap_or("图片集")
                .to_string();
            plan.books.push(aq_application::PlannedBook {
                id: Id::new_v4(),
                project: selection.target,
                title,
                format: Format::Comic,
                resources: images,
            });
        }
        aq_local::suppress_attachment_comics(&mut plan);
        if plan.books.is_empty() {
            return Err(format!("没有可导入内容：{}", plan.issues.join("；")));
        }
        let count: usize = plan.books.iter().map(|b| b.resources.len()).sum();
        if count > 10_000 {
            return Err("任务资源超过 10000 个".into());
        }
        write_new(
            &directory.join("plan.json"),
            &serde_json::to_vec_pretty(&plan).map_err(error)?,
        )?;
        Ok(plan)
    }
    pub fn commit_import(&mut self, edits: CommitImport) -> Result<CompletedImport, String> {
        let c = self.reader.catalog().map_err(error)?;
        if let Some(done) = c.imports.iter().find(|i| i.task == edits.task) {
            return Ok(done.clone());
        }
        if self
            .task_path(edits.task)
            .join("external-sources-require-selection.json")
            .exists()
        {
            return Err(
                "恢复的任务包含未备份的外部来源，请重新选择文件创建导入预览；原计划保留。".into(),
            );
        }
        if self.task_path(edits.task).join("discarded.json").exists() {
            return Err("此导入任务已由用户放弃，请重新选择文件建立预览；原计划保留。".into());
        }
        self.save_import_draft(&edits)?;
        let mut plan = Self::edit_plan(self.original_plan(edits.task)?, &edits)?;
        plan.books.retain(|b| !b.resources.is_empty());
        let attempt = self
            .task_path(plan.task)
            .join(format!("attempt-{}.json", Id::new_v4()));
        write_new(&attempt, &serde_json::to_vec_pretty(&plan).map_err(error)?)?;
        self.reader
            .import_with_placement(&plan, edits.skip_issues, edits.append.as_ref())
            .map_err(error)
    }
    fn edit_plan(mut plan: ImportPlan, edits: &CommitImport) -> Result<ImportPlan, String> {
        plan.base_revision = edits.base_revision;
        // Every planned item stays represented; exclusions are explicit empty
        // resource lists. Resources can only be permuted/subselected, never forged.
        if edits.books.len() != plan.books.len() || edits.projects.len() != plan.projects.len() {
            return Err("编辑条目不完整，请重新预览".into());
        }
        let mut seen = HashSet::new();
        for edit in &edits.projects {
            if !seen.insert(edit.id) {
                return Err("项目重复".into());
            }
            let project = plan
                .projects
                .iter_mut()
                .find(|p| p.id == edit.id)
                .ok_or("项目已失效")?;
            project.name = aq_domain::valid_name(&edit.name).map_err(error)?;
            if project.parent == plan.target {
                project.parent = edits.target;
            }
        }
        seen.clear();
        for edit in &edits.books {
            if !seen.insert(edit.id) {
                return Err("文件重复".into());
            }
            let book = plan
                .books
                .iter_mut()
                .find(|b| b.id == edit.id)
                .ok_or("文件已失效")?;
            book.title = aq_domain::valid_name(&edit.title).map_err(error)?;
            book.project = edit.project;
            let mut resources = std::collections::HashMap::new();
            for r in std::mem::take(&mut book.resources) {
                resources.insert(r.id, r);
            }
            book.resources = edit
                .resources
                .iter()
                .map(|id| resources.remove(id).ok_or("预览页重复或已失效"))
                .collect::<Result<_, _>>()?;
        }
        plan.target = edits.target;
        Ok(plan)
    }
}
