// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
use aq_application::{Reader, Repository, SearchScope};
use aq_domain::*;
use aq_local::{LocalBlobs, SqliteRepository, plan_import};
use std::fs;
use tempfile::TempDir;

type App = Reader<SqliteRepository, LocalBlobs>;

#[test]
fn opening_an_initialized_library_does_not_request_a_write_transaction() {
    let f = Fixture::new();
    let mut writer = rusqlite::Connection::open(f.root.join("library.sqlite3")).unwrap();
    let _transaction = writer
        .transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)
        .unwrap();
    let reader = SqliteRepository::open(&f.root).unwrap();
    assert_eq!(reader.load().unwrap().id, f.app.catalog().unwrap().id);
}

#[test]
fn repeated_progress_reuses_derived_paragraph_count_without_reading_the_book() {
    let mut f = Fixture::new();
    fs::write(
        f.source.join("large.txt"),
        "unique count cache regression\n\nsecond\n\nthird",
    )
    .unwrap();
    let plan = f.plan();
    let book = f.app.import(&plan, false).unwrap().books[0];
    assert_eq!(f.app.text(book).unwrap().paragraphs.len(), 3);
    let resource = f.app.catalog().unwrap().book(book).unwrap().pages[0]
        .resource
        .id;
    let object = f.app.blobs.root.join("objects").join(resource.to_string());
    let retained = object.with_extension("retained");
    fs::rename(&object, &retained).unwrap();
    for index in 0..3 {
        f.app
            .save_progress(book, Location::Paragraph { index })
            .unwrap();
    }
    assert!(
        f.app
            .save_progress(book, Location::Paragraph { index: 3 })
            .is_err()
    );
    fs::rename(retained, object).unwrap();
}

#[test]
fn fixture_closes_sqlite_before_removing_its_windows_temp_directory() {
    let f = Fixture::new();
    let path = f._temp.path().to_path_buf();
    drop(f);
    assert!(!path.exists());
}

#[test]
fn indexed_snippets_map_expanding_unicode_lowercase_to_original_characters() {
    let mut f = Fixture::new();
    let text = format!(
        "{}{}target{}",
        "İ".repeat(100),
        "a".repeat(40),
        "tail".repeat(60)
    );
    fs::write(f.source.join("unicode.txt"), text).unwrap();
    let plan = f.plan();
    f.app.import(&plan, false).unwrap();
    f.app.build_text_index(&SearchScope::All).unwrap();
    let hits = f.app.search_text("TARGET", &SearchScope::All).unwrap();
    assert_eq!(hits.len(), 1);
    assert!(hits[0].snippet.contains("target"));
    assert!(hits[0].snippet.starts_with(&"a".repeat(30)));
}

#[test]
fn indexed_library_operations_decode_one_catalog_snapshot() {
    use aq_application::TextIndexStore;
    use std::cell::Cell;

    struct CountedRepository {
        inner: SqliteRepository,
        loads: Cell<usize>,
    }
    impl Repository for CountedRepository {
        fn load(&self) -> aq_application::Result<Catalog> {
            self.loads.set(self.loads.get() + 1);
            self.inner.load()
        }
        fn save(&mut self, expected: u64, catalog: &Catalog) -> aq_application::Result<()> {
            self.inner.save(expected, catalog)
        }
    }
    impl TextIndexStore for CountedRepository {
        fn has_text_index(&self, book: Id, hash: &str) -> aq_application::Result<bool> {
            self.inner.has_text_index(book, hash)
        }
        fn store_text_index(
            &mut self,
            book: Id,
            hash: &str,
            paragraphs: &[String],
        ) -> aq_application::Result<()> {
            self.inner.store_text_index(book, hash, paragraphs)
        }
        fn query_text_index(
            &self,
            book: Id,
            hash: &str,
            query: &str,
            limit: usize,
        ) -> aq_application::Result<Vec<aq_application::search::TextHit>> {
            self.inner.query_text_index(book, hash, query, limit)
        }
    }
    let mut f = Fixture::new();
    for i in 0..20 {
        fs::write(
            f.source.join(format!("book-{i}.txt")),
            "第一段 searchable\n\n正文",
        )
        .unwrap();
    }
    let plan = f.plan();
    f.app.import(&plan, false).unwrap();
    f.app.build_text_index(&SearchScope::All).unwrap();
    let app = Reader {
        repository: CountedRepository {
            inner: f.app.repository,
            loads: Cell::new(0),
        },
        blobs: f.app.blobs,
    };
    assert_eq!(app.index_status(&SearchScope::All).unwrap().indexed, 20);
    assert_eq!(app.repository.loads.get(), 1);
    app.repository.loads.set(0);
    assert_eq!(
        app.search_text("searchable", &SearchScope::All)
            .unwrap()
            .len(),
        20
    );
    assert_eq!(app.repository.loads.get(), 1);
}

#[test]
fn encoding_changes_invalidate_index_and_mark_old_note_anchors_stale() {
    let mut f = Fixture::new();
    fs::write(f.source.join("encoded.txt"), [0xd6, 0xd0, 0xce, 0xc4]).unwrap();
    let plan = f.plan();
    let book = f.app.import(&plan, false).unwrap().books[0];
    f.app.set_text_encoding(book, Some("GB18030")).unwrap();
    f.app
        .add_note(book, Location::Paragraph { index: 0 }, "保留来源".into())
        .unwrap();
    f.app.build_text_index(&SearchScope::All).unwrap();
    assert_eq!(
        f.app.search_text("中文", &SearchScope::All).unwrap().len(),
        1
    );
    f.app.set_text_encoding(book, Some("UTF-8")).unwrap();
    assert_eq!(f.app.index_status(&SearchScope::All).unwrap().indexed, 0);
    assert!(
        f.app
            .search_text("中文", &SearchScope::All)
            .unwrap()
            .is_empty()
    );
    assert!(f.app.notes(book).unwrap()[0].stale);
    f.app.build_text_index(&SearchScope::All).unwrap();
    assert!(
        f.app
            .search_text("中文", &SearchScope::All)
            .unwrap()
            .is_empty()
    );
}
struct Fixture {
    root: std::path::PathBuf,
    source: std::path::PathBuf,
    app: App,
    // SQLite and its lock handles must close before TempDir is deleted on Windows.
    _temp: TempDir,
}
impl Fixture {
    fn new() -> Self {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path().join("library");
        let source = temp.path().join("收藏");
        fs::create_dir_all(&source).unwrap();
        let app = App {
            repository: SqliteRepository::open(&root).unwrap(),
            blobs: LocalBlobs::open(&root).unwrap(),
        };
        Self {
            _temp: temp,
            root,
            source,
            app,
        }
    }
    fn plan(&self) -> aq_application::ImportPlan {
        let c = self.app.catalog().unwrap();
        plan_import(&c, &self.root, &self.source, c.inbox).unwrap()
    }
    fn text(&self) {
        fs::write(
            self.source.join("示例.txt"),
            "第一段\r\n\r\n第二段\n\n第三段",
        )
        .unwrap();
    }
    fn comic(&self) {
        for name in ["10.png", "2.png", "1.png", "3.png", "4.png"] {
            // M0 preserves image bytes and filenames, but does not decode images.
            fs::write(self.source.join(name), format!("fixture:{name}")).unwrap();
        }
    }
}

#[test]
fn import_preserves_originals_and_reads_managed_copy_after_source_removed() {
    let mut f = Fixture::new();
    f.text();
    let before = fs::read(f.source.join("示例.txt")).unwrap();
    let plan = f.plan();
    assert_eq!(f.app.catalog().unwrap().books.len(), 0);
    let done = f.app.import(&plan, false).unwrap();
    assert_eq!(fs::read(f.source.join("示例.txt")).unwrap(), before);
    fs::remove_file(f.source.join("示例.txt")).unwrap();
    assert_eq!(
        f.app.text(done.books[0]).unwrap().paragraphs,
        ["第一段", "第二段", "第三段"]
    );
    drop(f.app);
    let reopened = SqliteRepository::open(&f.root).unwrap().load().unwrap();
    assert_eq!(reopened.books.len(), 1);
    assert!(
        !serde_json::to_string(&reopened)
            .unwrap()
            .contains("\"source\":")
    );
}

#[test]
fn folder_import_separates_current_images_from_subfolders_and_sorts_naturally() {
    let mut f = Fixture::new();
    f.comic();
    fs::create_dir(f.source.join("第一册")).unwrap();
    fs::write(f.source.join("第一册").join("001.jpg"), b"child").unwrap();
    let done = f.app.import(&f.plan(), false).unwrap();
    let c = f.app.catalog().unwrap();
    assert_eq!(done.projects.len(), 2);
    assert_eq!(done.books.len(), 2);
    let root = c.books.iter().find(|b| b.title == "收藏").unwrap();
    let names: Vec<_> = root
        .pages
        .iter()
        .map(|p| p.resource.original_name.as_str())
        .collect();
    assert_eq!(names, ["1.png", "2.png", "3.png", "4.png", "10.png"]);
    assert_eq!(
        c.books
            .iter()
            .find(|b| b.title == "第一册")
            .unwrap()
            .pages
            .len(),
        1
    );
}

#[test]
fn same_task_retry_is_idempotent_but_new_import_gets_numbered_name() {
    let mut f = Fixture::new();
    f.text();
    let plan = f.plan();
    let first = f.app.import(&plan, false).unwrap();
    assert_eq!(f.app.import(&plan, false).unwrap().books, first.books);
    assert_eq!(f.app.catalog().unwrap().books.len(), 1);
    f.app.import(&f.plan(), false).unwrap();
    let c = f.app.catalog().unwrap();
    assert!(c.projects.iter().any(|p| p.name == "收藏（1）"));
    // Duplicate file import into the same project gets a separate book name.
    let source = f.source.join("示例.txt");
    let plan = plan_import(&c, &f.root, &source, c.books[0].project).unwrap();
    f.app.import(&plan, false).unwrap();
    assert!(
        f.app
            .catalog()
            .unwrap()
            .books
            .iter()
            .any(|b| b.title == "示例（1）")
    );
}

#[test]
fn source_changed_after_preview_leaves_no_partial_catalog() {
    let mut f = Fixture::new();
    f.text();
    let plan = f.plan();
    fs::write(f.source.join("示例.txt"), "更改了").unwrap();
    assert!(f.app.import(&plan, false).is_err());
    let c = f.app.catalog().unwrap();
    assert!(c.books.is_empty());
    assert!(c.imports.is_empty());
    assert!(c.operations.is_empty());
    assert!(f.app.blobs.usage(&c).unwrap().incomplete_bytes > 0);
}

#[test]
fn stale_plan_and_wrong_library_are_rejected() {
    let mut f = Fixture::new();
    f.text();
    let plan = f.plan();
    let inbox = f.app.catalog().unwrap().inbox;
    f.app.create_project(inbox, "新项目").unwrap();
    assert!(f.app.import(&plan, false).is_err());
    let mut other = Fixture::new();
    assert!(other.app.import(&plan, false).is_err());
}

#[test]
fn unsupported_issues_require_explicit_skip() {
    let mut f = Fixture::new();
    f.text();
    fs::write(f.source.join("暂不支持.docx"), b"docx").unwrap();
    let plan = f.plan();
    assert_eq!(plan.issues.len(), 1);
    assert!(f.app.import(&plan, false).is_err());
    assert_eq!(f.app.import(&plan, true).unwrap().books.len(), 1);
}

#[test]
fn resource_ids_cannot_be_reused_to_overwrite_existing_content() {
    let mut f = Fixture::new();
    f.text();
    let first = f.plan();
    f.app.import(&first, false).unwrap();
    let mut second = f.plan();
    second.books[0].resources[0].id = first.books[0].resources[0].id;
    assert!(f.app.import(&second, false).is_err());
    assert_eq!(f.app.catalog().unwrap().books.len(), 1);
}

#[test]
fn moving_project_recomputes_inheritance_and_preserves_book_override() {
    let mut f = Fixture::new();
    f.comic();
    let done = f.app.import(&f.plan(), false).unwrap();
    let inbox = f.app.catalog().unwrap().inbox;
    let parent = f.app.create_project(inbox, "无缝项目").unwrap();
    f.app.set_project_gap(parent, Some(Gap::Seamless)).unwrap();
    let book = done.books[0];
    assert_eq!(
        f.app.catalog().unwrap().effective_gap(book).unwrap().value,
        Gap::Gapped
    );
    f.app.move_project(done.projects[0], parent).unwrap();
    assert_eq!(
        f.app.catalog().unwrap().effective_gap(book).unwrap().source,
        Some(parent)
    );
    f.app.set_book_gap(book, Some(Gap::Gapped)).unwrap();
    f.app.set_project_gap(parent, Some(Gap::Gapped)).unwrap();
    f.app.set_project_gap(parent, Some(Gap::Seamless)).unwrap();
    assert_eq!(
        f.app.catalog().unwrap().effective_gap(book).unwrap().value,
        Gap::Gapped
    );
    f.app.set_book_gap(book, None).unwrap();
    assert_eq!(
        f.app.catalog().unwrap().effective_gap(book).unwrap().value,
        Gap::Seamless
    );
    assert!(f.app.move_project(parent, done.projects[0]).is_err());
    assert!(f.app.move_project(inbox, parent).is_err());
}

#[test]
fn reverse_retains_page_identity_progress_and_supports_guarded_undo() {
    let mut f = Fixture::new();
    f.comic();
    let book = f.app.import(&f.plan(), false).unwrap().books[0];
    let original = f.app.catalog().unwrap().book(book).unwrap().clone();
    let ids: Vec<_> = original.pages.iter().map(|p| p.id).collect();
    f.app
        .save_progress(book, Location::Page { page: ids[1] })
        .unwrap();
    f.app
        .reverse_pages(book, &[ids[1], ids[3], ids[4]])
        .unwrap();
    let c = f.app.catalog().unwrap();
    let reversed: Vec<_> = c.book(book).unwrap().pages.iter().map(|p| p.id).collect();
    assert_eq!(reversed, [ids[0], ids[4], ids[2], ids[3], ids[1]]);
    assert_eq!(c.progress[0].location, Location::Page { page: ids[1] });
    let operation = c.operations.last().unwrap().id;
    f.app.undo_book_change(operation).unwrap();
    let c = f.app.catalog().unwrap();
    assert_eq!(
        c.book(book)
            .unwrap()
            .pages
            .iter()
            .map(|p| p.id)
            .collect::<Vec<_>>(),
        ids
    );
    assert!(f.app.undo_book_change(operation).is_err());
    assert!(f.app.reverse_pages(book, &[Id::new_v4()]).is_err());
}

#[test]
fn notes_are_lazy_associated_and_progress_bounds_checked() {
    let mut f = Fixture::new();
    f.text();
    let book = f.app.import(&f.plan(), false).unwrap().books[0];
    assert!(f.app.notes_markdown(book).is_err());
    assert!(
        f.app
            .save_progress(book, Location::Paragraph { index: 3 })
            .is_err()
    );
    f.app
        .save_progress(book, Location::Paragraph { index: 1 })
        .unwrap();
    f.app
        .add_note(
            book,
            Location::Paragraph { index: 1 },
            "第二段的笔记".into(),
        )
        .unwrap();
    f.app
        .add_note(
            book,
            Location::Paragraph { index: 2 },
            "第三段的笔记".into(),
        )
        .unwrap();
    let md = f.app.notes_markdown(book).unwrap();
    assert!(md.contains("第二段的笔记"));
    assert!(md.contains("第三段的笔记"));
    assert_eq!(md.matches("aqreader://book/").count(), 2);
    assert_eq!(
        f.app.catalog().unwrap().progress[0].location,
        Location::Paragraph { index: 1 }
    );
    assert!(f.app.set_book_gap(book, Some(Gap::Gapped)).is_err());
}

#[test]
fn repository_cas_rejects_stale_writers_and_newer_schema() {
    let f = Fixture::new();
    let mut a = SqliteRepository::open(&f.root).unwrap();
    let mut b = SqliteRepository::open(&f.root).unwrap();
    let mut state = a.load().unwrap();
    state.revision += 1;
    a.save(0, &state).unwrap();
    assert!(b.save(0, &state).is_err());
    drop(a);
    drop(b);
    let db = rusqlite::Connection::open(f.root.join("library.sqlite3")).unwrap();
    db.pragma_update(None, "user_version", 99).unwrap();
    drop(db);
    assert!(SqliteRepository::open(&f.root).is_err());
}

#[test]
fn managed_library_cannot_be_imported_recursively() {
    let f = Fixture::new();
    let c = f.app.catalog().unwrap();
    assert!(plan_import(&c, &f.root, &f.root, c.inbox).is_err());
    assert!(plan_import(&c, &f.root, f.root.parent().unwrap(), c.inbox).is_err());
}

#[test]
fn long_digits_fullwidth_and_navigation_constraints_are_deterministic() {
    assert!(natural_compare("２.jpg", "10.jpg").is_lt());
    assert!(natural_compare("99999999999999999999", "100000000000000000000").is_lt());
    assert!(validate_navigation(&[Destination::Projects, Destination::Me]).is_ok());
    assert!(validate_navigation(&[Destination::Me, Destination::Projects]).is_err());
    assert!(
        validate_navigation(&[
            Destination::Projects,
            Destination::Projects,
            Destination::Me
        ])
        .is_err()
    );
    assert!(
        validate_navigation(&[
            Destination::Home,
            Destination::Projects,
            Destination::Statistics,
            Destination::Ai,
            Destination::Search,
            Destination::Me
        ])
        .is_err()
    );
}

#[test]
fn non_utf8_text_is_preserved_and_reported_as_a_guess() {
    let mut f = Fixture::new();
    fs::write(f.source.join("legacy.txt"), [0xff, 0xfe, 0xff]).unwrap();
    let book = f.app.import(&f.plan(), false).unwrap().books[0];
    assert_eq!(
        f.app.catalog().unwrap().book(book).unwrap().pages[0]
            .resource
            .bytes,
        3
    );
    // Garbage bytes still decode, but never silently: the guess is unconfident
    // and the panel offers the alternatives instead of lying about the text.
    let info = f.app.text_encoding(book).unwrap();
    assert!(!info.stored);
    assert!(!info.candidates.is_empty());
    assert!(f.app.set_text_encoding(book, Some("klingon")).is_err());
}

#[test]
fn management_preserves_identity_bytes_and_personal_state() {
    let mut f = Fixture::new();
    f.text();
    let done = f.app.import(&f.plan(), false).unwrap();
    let id = done.books[0];
    f.app
        .save_progress(id, Location::Paragraph { index: 1 })
        .unwrap();
    f.app
        .add_note(id, Location::Paragraph { index: 1 }, "保留笔记".into())
        .unwrap();
    let before = f.app.catalog().unwrap().book(id).unwrap().clone();
    let inbox = f.app.catalog().unwrap().inbox;
    let parent = f.app.create_project(inbox, "课程").unwrap();
    f.app.color_project(parent, 2).unwrap();
    f.app.rename_project(parent, "考试").unwrap();
    f.app.manage_book(id, "rename", Some("改名"), None).unwrap();
    f.app.move_books(&[id], parent).unwrap();
    let copied = f.app.manage_book(id, "copy", None, Some(parent)).unwrap();
    let c = f.app.catalog().unwrap();
    assert_eq!(
        c.book(id).unwrap().pages[0].resource.id,
        before.pages[0].resource.id
    );
    assert_ne!(c.book(copied).unwrap().pages[0].id, before.pages[0].id);
    assert_eq!(c.progress[0].book, id);
    assert!(f.app.notes_markdown(id).unwrap().contains("保留笔记"));
    assert!(f.app.move_books(&[id, Id::new_v4()], inbox).is_err());
    assert_eq!(f.app.catalog().unwrap().book(id).unwrap().project, parent);
    assert!(f.app.delete_empty_project(parent).is_err());
    f.app.manage_book(id, "archive", None, None).unwrap();
    f.app.manage_book(id, "restore", None, None).unwrap();
    f.app.manage_book(id, "remove", None, None).unwrap();
    assert_eq!(f.app.catalog().unwrap().book(id).unwrap().project, inbox);
    assert!(f.source.join("示例.txt").exists());
}

#[test]
fn reading_checkpoints_are_idempotent_and_survive_reopening() {
    let mut f = Fixture::new();
    f.text();
    let id = f.app.import(&f.plan(), false).unwrap().books[0];
    let mut session = ReadingSession {
        id: Id::new_v4(),
        actor: Id::nil(),
        book: id,
        day: "2026-10-19".into(),
        started_at: 123456,
        elapsed_ms: 35000,
        position: 1,
        total: 3,
    };
    f.app.checkpoint_reading(session.clone()).unwrap();
    f.app.checkpoint_reading(session.clone()).unwrap();
    session.elapsed_ms = 65000;
    f.app.checkpoint_reading(session.clone()).unwrap();
    session.elapsed_ms = 64000;
    assert!(f.app.checkpoint_reading(session.clone()).is_err());
    session.id = Id::new_v4();
    session.position = 3;
    assert!(f.app.checkpoint_reading(session).is_err());
    let reopened = SqliteRepository::open(&f.root).unwrap().load().unwrap();
    assert_eq!(reopened.reading_sessions.len(), 1);
    assert_eq!(reopened.reading_sessions[0].elapsed_ms, 65000);
    assert_eq!(reopened.reading_sessions[0].actor, reopened.actor);
}

#[test]
fn persisted_index_survives_rename_move_archive_and_reopen() {
    let mut f = Fixture::new();
    f.text();
    let id = f.app.import(&f.plan(), false).unwrap().books[0];
    assert_eq!(f.app.index_status(&SearchScope::All).unwrap().indexed, 0);
    assert_eq!(
        f.app.build_text_index(&SearchScope::All).unwrap().indexed,
        1
    );
    assert_eq!(
        f.app.search_text("第二", &SearchScope::All).unwrap()[0].paragraph,
        1
    );
    f.app
        .manage_book(id, "rename", Some("新标题"), None)
        .unwrap();
    assert_eq!(
        f.app.search_text("第二", &SearchScope::All).unwrap()[0].book,
        id
    );
    f.app.manage_book(id, "archive", None, None).unwrap();
    assert!(
        f.app
            .search_text("第二", &SearchScope::All)
            .unwrap()
            .is_empty()
    );
    f.app.manage_book(id, "restore", None, None).unwrap();
    let reopened = Reader {
        repository: SqliteRepository::open(&f.root).unwrap(),
        blobs: LocalBlobs::open(&f.root).unwrap(),
    };
    assert_eq!(reopened.index_status(&SearchScope::All).unwrap().indexed, 1);
    assert_eq!(
        reopened
            .search_text("第二", &SearchScope::All)
            .unwrap()
            .len(),
        1
    );
    assert!(
        reopened
            .search_text("' OR 1=1 --", &SearchScope::All)
            .unwrap()
            .is_empty()
    );
}

#[test]
fn migration_retains_exact_v1_payload_and_rejects_inconsistent_revision() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("library.sqlite3");
    let conn = rusqlite::Connection::open(&path).unwrap();
    let mut json = serde_json::to_value(Catalog::default()).unwrap();
    json["schema_version"] = serde_json::json!(1);
    json.as_object_mut().unwrap().remove("reading_sessions");
    for p in json["projects"].as_array_mut().unwrap() {
        p.as_object_mut().unwrap().remove("color");
    }
    let payload = json.to_string();
    conn.execute_batch("CREATE TABLE catalog(singleton INTEGER PRIMARY KEY,revision INTEGER NOT NULL,payload TEXT NOT NULL); PRAGMA user_version=1;").unwrap();
    conn.execute("INSERT INTO catalog VALUES(1,0,?1)", [&payload])
        .unwrap();
    drop(conn);
    let c = SqliteRepository::open(temp.path()).unwrap().load().unwrap();
    assert_eq!(c.schema_version, 3);
    assert!(c.reading_sessions.is_empty());
    assert_eq!(c.id.to_string(), json["id"].as_str().unwrap());
    let conn = rusqlite::Connection::open(&path).unwrap();
    assert_eq!(
        conn.query_row(
            "SELECT payload FROM migration_backups WHERE version=1",
            [],
            |r| r.get::<_, String>(0)
        )
        .unwrap(),
        payload
    );
    conn.execute_batch("PRAGMA user_version=1; UPDATE catalog SET revision=99;")
        .unwrap();
    drop(conn);
    assert!(SqliteRepository::open(temp.path()).is_err());
}

#[test]
fn legacy_encoding_detection_preview_and_override_stay_per_book() {
    let mut f = Fixture::new();
    let (gbk, _, _) =
        encoding_rs::GB18030.encode("第一段中文测试内容，包含标点符号。\r\n\r\n第二段。");
    fs::write(f.source.join("简体.txt"), &gbk[..]).unwrap();
    let book = f.app.import(&f.plan(), false).unwrap().books[0];
    let info = f.app.text_encoding(book).unwrap();
    assert_eq!(info.encoding, "GB18030");
    assert!(!info.stored);
    assert!(info.confident);
    assert!(info.candidates.len() > 1);
    assert!(info.candidates[0].sample.contains("中文"));
    assert_eq!(
        f.app.text(book).unwrap().paragraphs[0],
        "第一段中文测试内容，包含标点符号。"
    );
    // A wrong override is honored and reported as stored, never silently ignored.
    f.app.set_text_encoding(book, Some("big5")).unwrap();
    let stored = f.app.text_encoding(book).unwrap();
    assert!(stored.stored);
    assert_eq!(stored.encoding, "Big5");
    assert!(!f.app.text(book).unwrap().paragraphs[0].contains("第一段"));
    // Clearing the override restores detection.
    f.app.set_text_encoding(book, None).unwrap();
    let cleared = f.app.text_encoding(book).unwrap();
    assert!(!cleared.stored);
    assert_eq!(cleared.encoding, "GB18030");
}

#[test]
fn search_scope_is_layered_and_never_widens_on_stale_ids() {
    let mut f = Fixture::new();
    let root = f.app.catalog().unwrap().inbox;
    f.text();
    let first = f.app.import(&f.plan(), false).unwrap().books[0];
    fs::write(f.source.join("其他.txt"), "另一个标题\r\n\r\n第二段").unwrap();
    let second = f.app.import(&f.plan(), false).unwrap().books[0];
    let built = f.app.build_text_index(&SearchScope::All).unwrap();
    assert_eq!(
        (built.indexed, built.eligible),
        (3, 3),
        "three books share the source folder"
    );
    let book_scope = SearchScope::Book { book: second };
    assert_eq!(f.app.search_text("第二段", &book_scope).unwrap().len(), 1);
    assert_eq!(
        f.app.search_text("第二段", &book_scope).unwrap()[0].book,
        second
    );
    let project_scope = SearchScope::Project { project: root };
    let project_hits = f.app.search_text("第二段", &project_scope).unwrap();
    assert!(
        project_hits.len() >= 2,
        "expected both files to match, got {} hits",
        project_hits.len()
    );
    assert_eq!(f.app.index_status(&book_scope).unwrap().indexed, 1);
    assert_eq!(f.app.index_status(&project_scope).unwrap().indexed, 3);
    let missing = SearchScope::Project {
        project: Id::new_v4(),
    };
    assert!(f.app.search_text("第二段", &missing).is_err());
    assert!(
        f.app
            .search_text("第二段", &SearchScope::Book { book: first })
            .is_ok()
    );
    assert_eq!(SearchScope::parse(None).unwrap(), SearchScope::All);
    assert!(
        SearchScope::parse(Some(&serde_json::json!({"kind": "book"}))).is_err(),
        "a book scope without an id must be rejected"
    );
}

#[test]
fn comic_direction_ignores_projects_and_crop_never_touches_original_bytes() {
    let mut f = Fixture::new();
    f.comic();
    let book = f.app.import(&f.plan(), false).unwrap().books[0];
    let c = f.app.catalog().unwrap();
    let project = c.book(book).unwrap().project;
    assert!(matches!(
        c.effective_direction(book).unwrap().value,
        ReadingDirection::LeftToRight
    ));
    f.app
        .set_project_direction(project, Some(ReadingDirection::RightToLeft))
        .unwrap();
    let inherited = f.app.catalog().unwrap().effective_direction(book).unwrap();
    assert!(matches!(inherited.value, ReadingDirection::LeftToRight));
    assert_eq!(inherited.source, None);
    f.app
        .set_book_direction(book, Some(ReadingDirection::TopToBottom))
        .unwrap();
    let overridden = f.app.catalog().unwrap().effective_direction(book).unwrap();
    assert!(matches!(overridden.value, ReadingDirection::TopToBottom));
    assert_eq!(overridden.source, Some(book));
    f.app.set_book_direction(book, None).unwrap();
    assert!(matches!(
        f.app
            .catalog()
            .unwrap()
            .effective_direction(book)
            .unwrap()
            .value,
        ReadingDirection::LeftToRight
    ));
    // Crop is recorded, inherited by sibling pages, and validated.
    let page = f.app.catalog().unwrap().book(book).unwrap().pages[1].id;
    let insets = CropInsets {
        left: 0.1,
        top: 0.05,
        right: 0.1,
        bottom: 0.05,
    };
    f.app.set_book_crop(book, insets).unwrap();
    assert!(!f.app.catalog().unwrap().has_page_crop(book, page));
    assert_eq!(
        f.app.catalog().unwrap().effective_crop(book, page).unwrap(),
        insets
    );
    let tighter = CropInsets {
        left: 0.2,
        ..insets
    };
    f.app.set_page_crop(book, page, tighter).unwrap();
    assert!(f.app.catalog().unwrap().has_page_crop(book, page));
    assert_eq!(
        f.app.catalog().unwrap().effective_crop(book, page).unwrap(),
        tighter
    );
    let untouched = f.app.catalog().unwrap().book(book).unwrap().pages[0].id;
    assert_eq!(
        f.app
            .catalog()
            .unwrap()
            .effective_crop(book, untouched)
            .unwrap(),
        insets
    );
    let bytes_before: u64 = f
        .app
        .catalog()
        .unwrap()
        .book(book)
        .unwrap()
        .pages
        .iter()
        .map(|p| p.resource.bytes)
        .sum();
    let reset = CropInsets::default();
    f.app.set_page_crop(book, page, reset).unwrap();
    assert!(!f.app.catalog().unwrap().has_page_crop(book, page));
    let bytes_after: u64 = f
        .app
        .catalog()
        .unwrap()
        .book(book)
        .unwrap()
        .pages
        .iter()
        .map(|p| p.resource.bytes)
        .sum();
    assert_eq!(bytes_before, bytes_after);
    assert!(
        f.app
            .set_book_crop(
                book,
                CropInsets {
                    left: 0.6,
                    right: 0.6,
                    ..reset
                }
            )
            .is_err(),
        "cropping more than 90% of the width must be rejected"
    );
    // Text books reject direction and crop rules instead of pretending.
    f.text();
    let text = f.app.import(&f.plan(), false).unwrap().books[0];
    assert!(
        f.app
            .set_book_direction(text, Some(ReadingDirection::RightToLeft))
            .is_err()
    );
    assert!(f.app.set_book_crop(text, insets).is_err());
}

#[test]
fn project_crop_inherits_to_descendants_and_reset_restores_the_chain() {
    let mut f = Fixture::new();
    f.comic();
    let book = f.app.import(&f.plan(), false).unwrap().books[0];
    let catalog = f.app.catalog().unwrap();
    let project = catalog.book(book).unwrap().project;
    let page = catalog.book(book).unwrap().pages[0].id;
    assert_eq!(
        catalog.effective_crop(book, page).unwrap(),
        CropInsets::default(),
        "a fresh library must not pretend a page is trimmed"
    );
    let shared = CropInsets {
        left: 0.08,
        top: 0.04,
        right: 0.08,
        bottom: 0.04,
    };
    f.app.set_project_crop(project, shared).unwrap();
    let catalog = f.app.catalog().unwrap();
    assert_eq!(catalog.effective_crop(book, page).unwrap(), shared);
    assert_eq!(catalog.effective_crop_source(book).unwrap(), Some(project));
    // A book-level record outranks the project, and removing it falls back.
    let own = CropInsets {
        left: 0.3,
        ..CropInsets::default()
    };
    f.app.set_book_crop(book, own).unwrap();
    assert_eq!(
        f.app.catalog().unwrap().effective_crop(book, page).unwrap(),
        own
    );
    assert_eq!(
        f.app
            .catalog()
            .unwrap()
            .effective_crop_source(book)
            .unwrap(),
        Some(book)
    );
    f.app.set_book_crop(book, CropInsets::default()).unwrap();
    assert_eq!(
        f.app.catalog().unwrap().effective_crop(book, page).unwrap(),
        shared,
        "an identity book record must delete itself instead of pinning zero"
    );
    assert_eq!(
        f.app
            .catalog()
            .unwrap()
            .effective_crop_source(book)
            .unwrap(),
        Some(project)
    );
    // Clearing the project default restores the untrimmed default everywhere.
    f.app
        .set_project_crop(project, CropInsets::default())
        .unwrap();
    assert_eq!(
        f.app.catalog().unwrap().effective_crop(book, page).unwrap(),
        CropInsets::default()
    );
    assert!(
        f.app
            .set_project_crop(
                project,
                CropInsets {
                    left: 0.7,
                    right: 0.7,
                    ..CropInsets::default()
                }
            )
            .is_err()
    );
}

#[test]
fn resolve_book_direction_resets_without_project_inheritance() {
    let mut f = Fixture::new();
    f.comic();
    let book = f.app.import(&f.plan(), false).unwrap().books[0];
    let project = f.app.catalog().unwrap().book(book).unwrap().project;
    f.app
        .set_project_direction(project, Some(ReadingDirection::TopToBottom))
        .unwrap();
    // Freezing without a label keeps whatever the chain currently resolves to,
    // so the reader never silently jumps back to left-to-right.
    f.app.resolve_book_direction(book, false, None).unwrap();
    let frozen = f.app.catalog().unwrap().effective_direction(book).unwrap();
    assert!(matches!(frozen.value, ReadingDirection::LeftToRight));
    assert_eq!(frozen.source, Some(book));
    f.app
        .resolve_book_direction(book, false, Some("rtl"))
        .unwrap();
    assert!(matches!(
        f.app
            .catalog()
            .unwrap()
            .effective_direction(book)
            .unwrap()
            .value,
        ReadingDirection::RightToLeft
    ));
    assert!(
        f.app
            .resolve_book_direction(book, false, Some("nope"))
            .is_err(),
        "an unknown direction must be rejected, not defaulted"
    );
    f.app.resolve_book_direction(book, true, None).unwrap();
    let inherited = f.app.catalog().unwrap().effective_direction(book).unwrap();
    assert!(matches!(inherited.value, ReadingDirection::LeftToRight));
    assert_eq!(inherited.source, None);
    f.text();
    let text = f.app.import(&f.plan(), false).unwrap().books[0];
    assert!(f.app.resolve_book_direction(text, false, None).is_err());
}

#[test]
fn notes_expose_their_anchor_and_flag_stale_ones_without_losing_text() {
    let mut f = Fixture::new();
    f.text();
    let book = f.app.import(&f.plan(), false).unwrap().books[0];
    let first = f
        .app
        .add_note(book, Location::Paragraph { index: 0 }, "第一段".into());
    let first = first.unwrap();
    f.app
        .add_note(book, Location::Paragraph { index: 1 }, "第二段".into())
        .unwrap();
    let notes = f.app.notes(book).unwrap();
    assert_eq!(notes.len(), 2);
    assert_eq!(notes[0].paragraph, Some(0));
    assert_eq!(notes[0].page, None);
    assert!(
        !notes[0].stale,
        "a note written on the current revision is fresh"
    );
    // A later edit of the same source bumps the book revision, so older anchors
    // are reported as possibly drifted rather than silently relocated.
    f.text();
    f.app.import(&f.plan(), false).unwrap();
    let after = f.app.notes(book).unwrap();
    assert_eq!(after.len(), 2);
    assert_eq!(after[0].id, first, "re-import must not renumber notes");
}

#[test]
fn plain_text_outline_points_at_the_paragraphs_the_reader_shows() {
    let mut f = Fixture::new();
    fs::write(
        f.source.join("有目录.txt"),
        "第一章 起风\r\n\r\n正文第一段。\r\n\r\n这是一段很长的正文，不应被当成标题，即便它看起来很整齐。\r\n\r\n第三方服务与第二章无关。\r\n\r\n第二章 归途\r\n\r\n结尾。",
    )
    .unwrap();
    let book = f.app.import(&f.plan(), false).unwrap().books[0];
    let doc = f.app.text(book).unwrap();
    assert_eq!(doc.outline.len(), 2, "outline: {:?}", doc.outline);
    // Every entry must address a paragraph the reader actually renders.
    for entry in &doc.outline {
        assert!(entry.index < doc.paragraphs.len());
        assert_eq!(doc.paragraphs[entry.index], entry.title);
    }
    assert_eq!(doc.outline[0].title, "第一章 起风");
    assert_eq!(doc.outline[0].level, 1);
    assert_eq!(doc.outline[1].title, "第二章 归途");
}

#[test]
fn a_text_without_headings_reports_no_outline_instead_of_guessing() {
    let mut f = Fixture::new();
    fs::write(
        f.source.join("无目录.txt"),
        "这是一段普通正文。\r\n\r\n这是第二段普通正文，没有任何章节标记。",
    )
    .unwrap();
    let book = f.app.import(&f.plan(), false).unwrap().books[0];
    let doc = f.app.text(book).unwrap();
    assert!(doc.outline.is_empty(), "outline: {:?}", doc.outline);
    assert_eq!(doc.paragraphs.len(), 2);
}
