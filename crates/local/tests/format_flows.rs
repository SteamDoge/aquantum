// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
use aq_application::{Reader, Repository};
use aq_domain::{DocumentInteraction, Id};
use aq_local::{LocalBlobs, SqliteRepository, plan_import};
use std::fs;

#[test]
fn malformed_markdown_url_is_a_skippable_issue_and_large_attachments_are_bounded() {
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("selected");
    fs::create_dir(&source).unwrap();
    fs::write(
        source.join("index.md"),
        "![bad](a%FF.png)\n\n[large](huge.bin)",
    )
    .unwrap();
    let huge = fs::File::create(source.join("huge.bin")).unwrap();
    huge.set_len(33 * 1024 * 1024).unwrap();
    drop(huge);
    let library = temp.path().join("library");
    let c = SqliteRepository::open(&library).unwrap().load().unwrap();
    let plan = plan_import(&c, &library, &source, c.inbox).unwrap();
    assert!(plan.issues.iter().any(|issue| issue.contains("编码无效")));
    assert!(plan.issues.iter().any(|issue| issue.contains("32 MiB")));
    assert_eq!(plan.books[0].resources.len(), 1);
}

#[test]
fn markdown_attachments_are_offline_managed_dependencies_not_duplicate_comics() {
    let temp = tempfile::tempdir().unwrap();
    let folder = temp.path().join("selected");
    let library = temp.path().join("library");
    fs::create_dir_all(folder.join("assets")).unwrap();
    fs::write(folder.join("assets/图 1.png"), b"image-original").unwrap();
    let text = "# Heading\n\n![first](assets/图%201.png)\n\n![again][same]\n\n[same]: assets/图%201.png\n\n![remote](https://invalid.example/test.png)\n\n- [ ] task\n";
    fs::write(folder.join("index.md"), text).unwrap();
    let mut app = Reader {
        repository: SqliteRepository::open(&library).unwrap(),
        blobs: LocalBlobs::open(&library).unwrap(),
    };
    let c = app.catalog().unwrap();
    let plan = plan_import(&c, &library, &folder, c.inbox).unwrap();
    assert!(plan.issues.is_empty(), "{:?}", plan.issues);
    assert_eq!(plan.books.len(), 1);
    assert_eq!(plan.books[0].resources.len(), 2);
    assert_eq!(plan.books[0].resources[1].original_name, "assets/图 1.png");
    let done = app.import(&plan, false).unwrap();
    let book = done.books[0];
    let source = app.catalog().unwrap().book(book).unwrap().pages[0]
        .resource
        .id;
    let change = DocumentInteraction {
        book,
        actor: Id::nil(),
        source,
        node: "block:4:semantic-hash:task:0.0".into(),
        kind: "task".into(),
        value: true,
        revision: 0,
    };
    let saved = app.set_document_interaction(change.clone()).unwrap();
    assert_ne!(saved.actor, Id::nil());
    assert_eq!(saved.revision, 1);
    assert!(app.set_document_interaction(change).is_err());
    let mut stale = saved.clone();
    stale.source = Id::new_v4();
    assert!(app.set_document_interaction(stale).is_err());
    assert_eq!(fs::read_to_string(folder.join("index.md")).unwrap(), text);
    assert_eq!(app.text(book).unwrap().source, text);
    drop(app);
    let reopened = Reader {
        repository: SqliteRepository::open(&library).unwrap(),
        blobs: LocalBlobs::open(&library).unwrap(),
    };
    assert!(reopened.document_interactions(book).unwrap()[0].value);
    assert_eq!(
        reopened.catalog().unwrap().book(book).unwrap().pages.len(),
        2
    );
}

#[test]
fn missing_or_out_of_scope_markdown_dependencies_require_explicit_skip() {
    let temp = tempfile::tempdir().unwrap();
    let folder = temp.path().join("selected");
    let library = temp.path().join("library");
    fs::create_dir(&folder).unwrap();
    fs::write(temp.path().join("private.png"), b"outside").unwrap();
    fs::write(
        folder.join("index.md"),
        "![outside](../private.png)\n\n![missing](missing.png)",
    )
    .unwrap();
    let mut app = Reader {
        repository: SqliteRepository::open(&library).unwrap(),
        blobs: LocalBlobs::open(&library).unwrap(),
    };
    let c = app.catalog().unwrap();
    let plan = plan_import(&c, &library, &folder, c.inbox).unwrap();
    assert_eq!(plan.issues.len(), 2);
    assert!(app.import(&plan, false).is_err());
    let done = app.import(&plan, true).unwrap();
    assert_eq!(
        app.catalog()
            .unwrap()
            .book(done.books[0])
            .unwrap()
            .pages
            .len(),
        1
    );
    assert_eq!(
        fs::read(temp.path().join("private.png")).unwrap(),
        b"outside"
    );
}

#[test]
fn v2_catalog_migration_preserves_exact_payload_and_interaction_defaults() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("library");
    let original = SqliteRepository::open(&root).unwrap().load().unwrap();
    let mut old = serde_json::to_value(original).unwrap();
    old["schema_version"] = 2.into();
    old.as_object_mut().unwrap().remove("document_interactions");
    let payload = serde_json::to_string_pretty(&old).unwrap();
    let db = rusqlite::Connection::open(root.join("library.sqlite3")).unwrap();
    db.execute("UPDATE catalog SET payload=?1", [&payload])
        .unwrap();
    db.pragma_update(None, "user_version", 2).unwrap();
    drop(db);
    let current = SqliteRepository::open(&root).unwrap().load().unwrap();
    assert_eq!(current.schema_version, 3);
    assert!(current.document_interactions.is_empty());
    let db = rusqlite::Connection::open(root.join("library.sqlite3")).unwrap();
    let backup: String = db
        .query_row(
            "SELECT payload FROM migration_backups WHERE version=2",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(backup, payload);
}
