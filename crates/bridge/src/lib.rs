// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
//! Narrow JSON C ABI for Flutter. UI never writes SQLite or source resources.
mod book_metadata;
mod import_tasks;
mod maintenance;
mod plugin;
mod session;
use aq_domain::{CropInsets, Gap, Id, ReadingDirection};
use serde::Deserialize;
use serde_json::{Value, json};
use std::{
    ffi::{CStr, CString, c_char},
    path::PathBuf,
};

#[derive(Deserialize)]
struct Request {
    root: PathBuf,
    method: String,
    #[serde(default)]
    args: Value,
}

fn call(input: &str) -> Result<Value, String> {
    let envelope: Value = serde_json::from_str(input).map_err(|e| e.to_string())?;
    if envelope["method"] == "plugin_runtime" {
        return plugin::invoke(&envelope["args"]);
    }
    let request: Request = serde_json::from_value(envelope).map_err(|e| e.to_string())?;
    if !request.root.is_absolute() {
        return Err("资料库路径必须是应用私有目录的绝对路径".into());
    }
    let mut s = session::Session::open(&request.root)?;
    let a = request.args;
    if let Some(result) = s.maintenance_operation(&request.method, &a) {
        return result;
    }
    let id = |key: &str| -> Result<Id, String> {
        a.get(key)
            .and_then(Value::as_str)
            .ok_or_else(|| format!("缺少 {key}"))?
            .parse::<Id>()
            .map_err(|e| e.to_string())
    };
    let text = |key: &str| -> Result<String, String> {
        a.get(key)
            .and_then(Value::as_str)
            .map(str::to_owned)
            .ok_or_else(|| format!("缺少 {key}"))
    };
    let index = || -> Result<usize, String> {
        a.get("index")
            .and_then(Value::as_u64)
            .and_then(|n| usize::try_from(n).ok())
            .ok_or("位置序号无效".into())
    };
    let scope = |value: Option<&Value>| -> Result<aq_application::SearchScope, String> {
        aq_application::SearchScope::parse(value).map_err(|e| e.to_string())
    };
    match request.method.as_str() {
        "update_book_metadata" => s.update_book_metadata(a),
        "book_cover" => s.book_cover(id("book")?),
        "document_interactions" => Ok(json!(
            s.reader
                .document_interactions(id("book")?)
                .map_err(|e| e.to_string())?
        )),
        "set_document_interaction" => {
            let mut value = a;
            value["actor"] = json!(s.reader.catalog().map_err(|e| e.to_string())?.actor);
            Ok(json!(
                s.reader
                    .set_document_interaction(
                        serde_json::from_value(value).map_err(|e| e.to_string())?
                    )
                    .map_err(|e| e.to_string())?
            ))
        }
        "document_path" => {
            let c = s.reader.catalog().map_err(|e| e.to_string())?;
            let b = c.book(id("book")?).map_err(|e| e.to_string())?;
            if b.format != aq_domain::Format::Pdf {
                return Err("此端口仅允许 PDF 内部资源".into());
            }
            let page = b.pages.first().ok_or("正文资源缺失")?;
            Ok(
                json!({"path":s.reader.blobs.resource_path(page.resource.id).map_err(|e|e.to_string())?,"resource":page.resource.id,"revision":b.revision}),
            )
        }
        "bind_pdf_pages" => Ok(json!(
            s.reader
                .bind_pdf_pages(
                    id("book")?,
                    id("resource")?,
                    a.get("revision")
                        .and_then(Value::as_u64)
                        .ok_or("缺少版本")?,
                    a.get("count")
                        .and_then(Value::as_u64)
                        .and_then(|n| usize::try_from(n).ok())
                        .ok_or("无效页数")?
                )
                .map_err(|e| e.to_string())?
        )),
        "preview_import" => Ok(json!(
            s.preview_import(serde_json::from_value(a).map_err(|e| e.to_string())?)?
        )),
        "import_plan" => s.import_preview_value(id("task")?),
        "save_import_draft" => {
            s.save_import_draft(&serde_json::from_value(a).map_err(|e| e.to_string())?)?;
            Ok(Value::Null)
        }
        "import_tasks" => Ok(json!(s.import_tasks()?)),
        "preview_image" => {
            use base64::{Engine, engine::general_purpose::STANDARD};
            let plan = s.import_plan(id("task")?)?;
            let resource_id = id("resource")?;
            let resource = plan
                .books
                .iter()
                .filter(|b| b.format == aq_domain::Format::Comic)
                .flat_map(|b| &b.resources)
                .find(|r| r.id == resource_id)
                .ok_or("预览页面不存在")?;
            Ok(json!(STANDARD.encode(
                aq_local::read_preview_resource(resource).map_err(|e| e.to_string())?
            )))
        }
        "commit_import" => Ok(json!(
            s.commit_import(serde_json::from_value(a).map_err(|e| e.to_string())?)?
        )),
        "reorder_pages" => {
            let order: Vec<Id> = serde_json::from_value(a.get("pages").cloned().ok_or("缺少页序")?)
                .map_err(|e| e.to_string())?;
            s.reader
                .reorder_pages(
                    id("book")?,
                    a.get("revision")
                        .and_then(Value::as_u64)
                        .ok_or("缺少版本")?,
                    &order,
                )
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "reverse_pages" => {
            let pages: Vec<Id> =
                serde_json::from_value(a.get("pages").cloned().ok_or("缺少所选页")?)
                    .map_err(|e| e.to_string())?;
            let c = s.reader.catalog().map_err(|e| e.to_string())?;
            if Some(c.book(id("book")?).map_err(|e| e.to_string())?.revision)
                != a.get("revision").and_then(Value::as_u64)
            {
                return Err("书籍已更新，请刷新".into());
            }
            s.reader
                .reverse_pages(id("book")?, &pages)
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "move_pages" => {
            let pages: Vec<Id> =
                serde_json::from_value(a.get("pages").cloned().ok_or("缺少所选页")?)
                    .map_err(|e| e.to_string())?;
            let before: Option<Id> =
                serde_json::from_value(a.get("before").cloned().unwrap_or(Value::Null))
                    .map_err(|e| e.to_string())?;
            s.reader
                .move_pages(
                    id("book")?,
                    a.get("revision")
                        .and_then(Value::as_u64)
                        .ok_or("缺少版本")?,
                    &pages,
                    before,
                )
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "export_pages" => {
            let pages: Vec<Id> =
                serde_json::from_value(a.get("pages").cloned().ok_or("缺少所选页")?)
                    .map_err(|e| e.to_string())?;
            let revision = a
                .get("revision")
                .and_then(Value::as_u64)
                .ok_or("缺少版本")?;
            let book = id("book")?;
            let bytes = aq_local::export_pages(
                &s.reader.blobs,
                &s.reader.catalog().map_err(|e| e.to_string())?,
                book,
                revision,
                &pages,
                &PathBuf::from(text("destination")?),
            )
            .map_err(|e| e.to_string())?;
            let cut = if a.get("cut").and_then(Value::as_bool) == Some(true) {
                match s.reader.cut_exported_pages(book, revision, &pages) {
                    Ok(()) => json!({"applied":true}),
                    Err(e) => json!({"applied":false,"reason":e.to_string()}),
                }
            } else {
                json!({"applied":false})
            };
            Ok(json!({"bytes":bytes,"destination":text("destination")?,"cut":cut}))
        }
        "undo_book_change" => {
            s.reader
                .undo_book_change(id("operation")?)
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "snapshot" => serde_json::to_value(s.snapshot()?).map_err(|e| e.to_string()),
        // Formats are a core contribution, not a client suffix table: the shape
        // here is the same one capabilities_for() produces for a stored book.
        "formats" => {
            let providers = aq_application::registry::providers()
                .iter()
                .map(|p| json!({"id": p.id(), "surfaces": p.surfaces()}))
                .collect::<Vec<_>>();
            let surfaces = aq_application::registry::Surface::ALL
                .iter()
                .map(|surface| {
                    json!({
                        "id": surface.id(),
                        "unit": surface.unit(),
                        "encoding": surface.decodes_bytes(),
                    })
                })
                .collect::<Vec<_>>();
            Ok(json!({"providers": providers, "surfaces": surfaces}))
        }
        "index_status" => Ok(json!(
            s.reader
                .index_status(&scope(a.get("scope"))?)
                .map_err(|e| e.to_string())?
        )),
        "build_index" => Ok(json!(
            s.reader
                .build_text_index(&scope(a.get("scope"))?)
                .map_err(|e| e.to_string())?
        )),
        "search_text" => Ok(json!(
            s.reader
                .search_text(&text("query")?, &scope(a.get("scope"))?)
                .map_err(|e| e.to_string())?
        )),
        "move_books" => {
            let ids: Vec<Id> =
                serde_json::from_value(a.get("books").cloned().ok_or("缺少文件列表")?)
                    .map_err(|e| e.to_string())?;
            s.reader
                .move_books(&ids, id("target")?)
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "rename_project" => {
            s.reader
                .rename_project(id("project")?, &text("name")?)
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "color_project" => {
            let color = a
                .get("color")
                .and_then(Value::as_u64)
                .and_then(|n| u8::try_from(n).ok())
                .ok_or("颜色无效")?;
            s.reader
                .color_project(id("project")?, color)
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "move_project" => {
            s.reader
                .move_project(id("project")?, id("target")?)
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "delete_project" => {
            s.reader
                .delete_empty_project(id("project")?)
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "manage_book" => Ok(json!(
            s.reader
                .manage_book(
                    id("book")?,
                    &text("action")?,
                    a.get("name").and_then(Value::as_str),
                    a.get("target")
                        .and_then(Value::as_str)
                        .map(str::parse)
                        .transpose()
                        .map_err(|_| "目标项目无效")?
                )
                .map_err(|e| e.to_string())?
        )),
        "reading_checkpoint" => {
            s.reader
                .checkpoint_reading(serde_json::from_value(a).map_err(|e| e.to_string())?)
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "create_project" => Ok(json!(
            s.reader
                .create_project(id("parent")?, &text("name")?)
                .map_err(|e| e.to_string())?
        )),
        "import_files" => Ok(json!(
            s.ingest(
                serde_json::from_value(a.get("files").cloned().ok_or("缺少文件")?)
                    .map_err(|e| e.to_string())?,
                id("target")?
            )?
        )),
        "read_text" => Ok(json!(
            s.reader.text(id("book")?).map_err(|e| e.to_string())?
        )),
        "read_image" => Ok(json!(s.image(id("book")?, id("page")?)?)),
        "read_attachment" => {
            use aq_application::BlobStore;
            use base64::{Engine, engine::general_purpose::STANDARD};
            let c = s.reader.catalog().map_err(|e| e.to_string())?;
            let b = c.book(id("book")?).map_err(|e| e.to_string())?;
            if b.format != aq_domain::Format::Markdown {
                return Err("此书没有 Markdown 附件".into());
            }
            let resource = id("resource")?;
            let page = b
                .pages
                .iter()
                .skip(1)
                .find(|p| p.resource.id == resource)
                .ok_or("附件不属于这份文档")?;
            Ok(json!(
                STANDARD.encode(
                    s.reader
                        .blobs
                        .read(page.resource.id, 32 * 1024 * 1024)
                        .map_err(|e| e.to_string())?
                )
            ))
        }
        "save_progress" => {
            if let Some(value) = a.get("content_progress") {
                let progress = value
                    .as_u64()
                    .filter(|v| *v <= 10000)
                    .ok_or("内容进度超出范围")? as u32;
                s.measured_progress(id("book")?, index()?, progress)?;
            } else {
                s.progress(id("book")?, index()?)?;
            }
            Ok(Value::Null)
        }
        // Document books cannot report an ordinal that survives relayout, so the
        // engine supplies its own character anchor plus a recomputable hint.
        "save_progress_at" => {
            s.progress_at(
                id("book")?,
                text("anchor")?,
                a.get("progress")
                    .and_then(Value::as_u64)
                    .map(|v| v.min(u32::MAX as u64) as u32),
            )?;
            Ok(Value::Null)
        }
        "add_note" => {
            let book = id("book")?;
            let markdown = text("text")?;
            match a.get("anchor").and_then(Value::as_str) {
                Some(anchor) => Ok(json!(
                    s.note_at(
                        book,
                        anchor.to_owned(),
                        a.get("progress")
                            .and_then(Value::as_u64)
                            .map(|v| v.min(u32::MAX as u64) as u32),
                        markdown,
                    )?
                )),
                None => Ok(json!(s.note(book, index()?, markdown)?)),
            }
        }
        "document_resource" => Ok(json!(
            s.reader
                .document_resource(id("book")?)
                .map_err(|e| e.to_string())?
        )),
        "notes_markdown" => Ok(json!(
            s.reader
                .notes_markdown(id("book")?)
                .map_err(|e| e.to_string())?
        )),
        "set_gap" => {
            let gap = a
                .get("seamless")
                .and_then(Value::as_bool)
                .map(|value| if value { Gap::Seamless } else { Gap::Gapped });
            s.reader
                .set_book_gap(id("book")?, gap)
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "effective_gap" => Ok(json!(
            s.reader
                .catalog()
                .map_err(|e| e.to_string())?
                .effective_gap(id("book")?)
                .map_err(|e| e.to_string())?
        )),
        "effective_direction" => Ok(json!(
            s.reader
                .catalog()
                .map_err(|e| e.to_string())?
                .effective_direction(id("book")?)
                .map_err(|e| e.to_string())?
        )),
        "set_project_direction" => {
            s.reader
                .set_project_direction_for_format(
                    id("project")?,
                    direction(a.get("direction"))?,
                    fixed_format(a.get("format"))?,
                )
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "set_book_direction" => {
            s.reader
                .set_book_direction(id("book")?, direction(a.get("direction"))?)
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "resolve_book_direction" => {
            s.reader
                .resolve_book_direction(
                    id("book")?,
                    a.get("inherit").and_then(Value::as_bool) == Some(true),
                    a.get("direction").and_then(Value::as_str),
                )
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "set_project_crop" => {
            s.reader
                .set_project_crop_for_format(
                    id("project")?,
                    crop(&a),
                    fixed_format(a.get("format"))?,
                )
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "effective_crop" => {
            let catalog = s.reader.catalog().map_err(|e| e.to_string())?;
            let book = id("book")?;
            let page = catalog
                .effective_crop(book, id("page")?)
                .map_err(|e| e.to_string())?;
            let source = catalog
                .effective_crop_source(book)
                .map_err(|e| e.to_string())?;
            Ok(json!({
                "left": page.left,
                "top": page.top,
                "right": page.right,
                "bottom": page.bottom,
                "source": source,
                "description": match source {
                    Some(id) if id == book => "本文件自定义".to_string(),
                    Some(id) => format!(
                        "项目默认（继承自：{}）",
                        catalog.project(id).map(|p| p.name.clone()).unwrap_or_default()
                    ),
                    None => "默认（未裁边）".to_string(),
                },
            }))
        }
        // Whole-book crop values so every page of a long series can be rendered
        // without a round trip per page.
        "book_crops" => {
            let catalog = s.reader.catalog().map_err(|e| e.to_string())?;
            let book = catalog.book(id("book")?).map_err(|e| e.to_string())?;
            let mut values = serde_json::Map::new();
            for page in &book.pages {
                let insets = catalog
                    .effective_crop(book.id, page.id)
                    .map_err(|e| e.to_string())?;
                values.insert(
                    page.id.to_string(),
                    json!({
                        "left": insets.left,
                        "top": insets.top,
                        "right": insets.right,
                        "bottom": insets.bottom,
                    }),
                );
            }
            Ok(Value::Object(values))
        }
        "set_book_crop" => {
            s.reader
                .set_book_crop(id("book")?, crop(&a))
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "set_page_crop" => {
            s.reader
                .set_page_crop(id("book")?, id("page")?, crop(&a))
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "text_encoding" => Ok(json!(
            s.reader
                .text_encoding(id("book")?)
                .map_err(|e| e.to_string())?
        )),
        "set_text_encoding" => {
            let chosen = a.get("encoding").and_then(Value::as_str);
            s.reader
                .set_text_encoding(id("book")?, chosen)
                .map_err(|e| e.to_string())?;
            Ok(Value::Null)
        }
        "notes" => Ok(json!(
            s.reader.notes(id("book")?).map_err(|e| e.to_string())?
        )),
        _ => Err("未知应用操作".into()),
    }
}

/// `null` restores inheritance; an object names one of the three directions.
fn fixed_format(value: Option<&Value>) -> Result<aq_domain::Format, String> {
    match value {
        None => Ok(aq_domain::Format::Comic),
        Some(Value::String(name)) if name == "Comic" => Ok(aq_domain::Format::Comic),
        Some(Value::String(name)) if name == "Pdf" => Ok(aq_domain::Format::Pdf),
        _ => Err("格式必须为 Comic 或 Pdf".into()),
    }
}

fn direction(value: Option<&Value>) -> Result<Option<ReadingDirection>, String> {
    let Some(value) = value.filter(|v| !v.is_null()) else {
        return Ok(None);
    };
    let name = value
        .as_str()
        .or_else(|| value.get("value").and_then(Value::as_str))
        .ok_or("缺少阅读方向")?;
    let parsed = ReadingDirection::parse(name).ok_or_else(|| format!("未知阅读方向：{name}"))?;
    Ok(Some(parsed))
}

/// A crop request; every edge defaults to 0 so a reset is just `{}`.
fn crop(a: &Value) -> CropInsets {
    let edge = |key: &str| -> f32 {
        a.get(key)
            .and_then(Value::as_f64)
            .map(|v| v as f32)
            .unwrap_or(0.0)
    };
    CropInsets {
        left: edge("left"),
        top: edge("top"),
        right: edge("right"),
        bottom: edge("bottom"),
    }
}

fn response(input: &str) -> String {
    let result = std::panic::catch_unwind(|| call(input));
    match result {
        Ok(Ok(data)) => json!({"ok":true,"data":data}).to_string(),
        Ok(Err(error)) => json!({"ok":false,"error":error}).to_string(),
        Err(_) => json!({"ok":false,"error":"本地操作异常中断，当前操作未报告成功"}).to_string(),
    }
}

/// # Safety
/// `input` must point to a live, NUL-terminated UTF-8 string for this call.
/// The returned allocation must be released once with `aq_free_json`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aq_invoke_json(input: *const c_char) -> *mut c_char {
    let output = if input.is_null() {
        json!({"ok":false,"error":"输入为空"}).to_string()
    } else {
        match unsafe { CStr::from_ptr(input) }.to_str() {
            Ok(value) => response(value),
            Err(_) => json!({"ok":false,"error":"输入不是 UTF-8"}).to_string(),
        }
    };
    CString::new(output)
        .expect("JSON cannot contain raw NUL")
        .into_raw()
}

/// # Safety
/// `pointer` must be null or an outstanding allocation returned by `aq_invoke_json`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn aq_free_json(pointer: *mut c_char) {
    if !pointer.is_null() {
        drop(unsafe { CString::from_raw(pointer) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ffi_envelope_and_memory_contract_handle_valid_and_invalid_requests() {
        let root = tempfile::tempdir().unwrap();
        let input =
            CString::new(json!({"root":root.path(),"method":"snapshot"}).to_string()).unwrap();
        unsafe {
            let pointer = aq_invoke_json(input.as_ptr());
            let value: Value =
                serde_json::from_str(CStr::from_ptr(pointer).to_str().unwrap()).unwrap();
            assert_eq!(value["ok"], true);
            assert!(value["data"]["catalog"]["inbox"].is_string());
            aq_free_json(pointer);
            let null = aq_invoke_json(std::ptr::null());
            assert!(CStr::from_ptr(null).to_str().unwrap().contains("false"));
            aq_free_json(null);
        }
        assert!(response("not json").contains("false"));
    }
    /// Every stored task must be listed with the same control fields, and a
    /// cancelled backup is reported as awaiting an explicit continue rather than
    /// as a silently resumable or failed task.
    #[test]
    fn storage_tasks_report_one_shape_for_every_kind() {
        let root = tempfile::tempdir().unwrap();
        let mut session = crate::session::Session::open(root.path()).unwrap();
        let tasks = session
            .maintenance_operation("storage_tasks", &json!({}))
            .expect("storage_tasks is a maintenance method")
            .unwrap();
        assert!(tasks.as_array().unwrap().is_empty());

        let catalog = session.reader.catalog().unwrap();
        let plan = session
            .reader
            .blobs
            .prepare_backup(&catalog, json!({}))
            .unwrap();
        let backup = plan.manifest.backup;
        session
            .maintenance_operation("task_cancel", &json!({"kind":"backup","task":backup}))
            .unwrap()
            .unwrap();

        let tasks = session
            .maintenance_operation("storage_tasks", &json!({}))
            .unwrap()
            .unwrap();
        let backup_task = tasks
            .as_array()
            .unwrap()
            .iter()
            .find(|t| t["kind"] == "backup")
            .expect("the cancelled backup is still listed");
        assert_eq!(backup_task["task"], json!(backup));
        assert_eq!(backup_task["phase"], "cancelled");
        assert_eq!(backup_task["restart"], "resume");
        assert_eq!(backup_task["cancellable"], true);
        // A cancelled task has no published result yet, so it can still be given up.
        assert_eq!(backup_task["discardable"], true);

        session
            .maintenance_operation("task_resume", &json!({"kind":"backup","task":backup}))
            .unwrap()
            .unwrap();
        let resumed = session
            .maintenance_operation("storage_tasks", &json!({}))
            .unwrap()
            .unwrap();
        let backup_task = resumed
            .as_array()
            .unwrap()
            .iter()
            .find(|t| t["kind"] == "backup")
            .expect("the resumed backup is still listed");
        assert_ne!(backup_task["phase"], "cancelled");
        assert_eq!(backup_task["discardable"], true);
    }
    /// Giving up one unfinished task removes only that task's own staging and
    /// keeps a receipt; a published result can never be removed this way.
    #[test]
    fn discarding_one_unfinished_task_leaves_published_files_alone() {
        let root = tempfile::tempdir().unwrap();
        let mut session = crate::session::Session::open(root.path()).unwrap();
        let catalog = session.reader.catalog().unwrap();
        let backup = session
            .reader
            .blobs
            .prepare_backup(&catalog, json!({}))
            .unwrap()
            .manifest
            .backup;
        let other = session
            .reader
            .blobs
            .prepare_backup(&catalog, json!({}))
            .unwrap()
            .manifest
            .backup;
        // The destination must live outside the application's private area, so
        // the published archive goes to a sibling temporary directory.
        let outside = tempfile::tempdir().unwrap();
        let published = outside.path().join("published.zip");
        session
            .maintenance_operation(
                "backup_run",
                &json!({"task":other,"destination":published.clone()}),
            )
            .unwrap()
            .unwrap();
        assert!(published.exists());
        // A half-finished run leaves staging behind, as an interrupted task does.
        // The recorded plan is what the give-up must remove, and its own records
        // stay inside this task, so nothing outside it is ever swept.
        let job = session
            .library
            .join("backup-tasks")
            .join(backup.to_string());
        let staged = job.join("staged");
        std::fs::create_dir_all(&staged).unwrap();
        std::fs::write(staged.join("00000000.bin"), b"partial").unwrap();
        assert!(job.join("plan.json").exists());

        session
            .maintenance_operation("task_discard", &json!({"kind":"backup","task":backup}))
            .unwrap()
            .unwrap();
        assert!(!staged.join("00000000.bin").exists());
        assert!(!job.join("plan.json").exists());
        // The give-up leaves one receipt beside the task folder and no residue.
        let receipt = session
            .library
            .join("discarded-task-receipts")
            .join(format!("backup-{backup}.json"));
        assert!(receipt.is_file());
        let listed = session
            .maintenance_operation("storage_tasks", &json!({}))
            .unwrap()
            .unwrap();
        assert!(
            listed
                .as_array()
                .unwrap()
                .iter()
                .any(|t| t["task"] == json!(backup)
                    && t["phase"] == "discarded"
                    && t["restart"] == "none"),
            "a given-up task retains a terminal receipt without a resume action"
        );
        // The other task and its published archive are untouched.
        assert!(published.exists());
        assert_eq!(
            session
                .reader
                .blobs
                .task_progress("backup", other)
                .unwrap()
                .phase,
            "completed"
        );
        let err = session
            .maintenance_operation("task_discard", &json!({"kind":"backup","task":other}))
            .expect("task_discard is a maintenance method")
            .expect_err("a finished task cannot be given up");
        assert!(err.contains("已完成"), "{err}");
        assert!(published.exists());
    }
}
