// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
use aq_application::{BlobStore, Reader};
use aq_domain::{BookMetadata, Id};
use aq_local::{LocalBlobs, SqliteRepository, plan_import};
use std::fs;

#[test]
fn confirmed_metadata_and_covers_survive_reopen_copy_undo_and_remain_protected() {
    let temp = tempfile::tempdir().unwrap();
    let root = temp.path().join("app/library");
    let source = temp.path().join("original.txt");
    fs::write(&source, "原件正文\n\n第二段").unwrap();
    let mut app = Reader {
        repository: SqliteRepository::open(&root).unwrap(),
        blobs: LocalBlobs::open(&root).unwrap(),
    };
    let c = app.catalog().unwrap();
    let plan = plan_import(&c, &root, &source, c.inbox).unwrap();
    let id = app.import(&plan, false).unwrap().books[0];
    let cover = temp.path().join("cover.png");
    fs::write(&cover, b"cover-original").unwrap();
    let c = app.catalog().unwrap();
    let cover_plan = plan_import(&c, &root, &cover, c.inbox).unwrap();
    let planned = &cover_plan.books[0].resources[0];
    let original = c.book(id).unwrap().clone();
    let metadata = BookMetadata {
        author: "作者".into(),
        provider: "Open Library".into(),
        source_id: "/books/OL1M".into(),
        ..Default::default()
    };
    let changed = app
        .update_book_metadata(
            id,
            original.revision,
            "确认书名",
            metadata,
            Some(planned),
            false,
        )
        .unwrap();
    assert_eq!(
        changed.pages[0].resource.sha256,
        original.pages[0].resource.sha256
    );
    assert_eq!(fs::read_to_string(&source).unwrap(), "原件正文\n\n第二段");
    assert!(
        app.update_book_metadata(
            id,
            original.revision,
            "过期修改",
            Default::default(),
            None,
            true
        )
        .is_err()
    );
    let copy_id = app.manage_book(id, "copy", None, None).unwrap();
    assert_eq!(
        app.catalog()
            .unwrap()
            .book(copy_id)
            .unwrap()
            .metadata
            .cover
            .as_ref()
            .unwrap()
            .id,
        planned.id
    );
    drop(app);
    let mut app = Reader {
        repository: SqliteRepository::open(&root).unwrap(),
        blobs: LocalBlobs::open(&root).unwrap(),
    };
    assert_eq!(
        app.catalog().unwrap().book(id).unwrap().metadata.author,
        "作者"
    );
    let cleared = app
        .update_book_metadata(
            id,
            changed.revision,
            "确认书名",
            Default::default(),
            None,
            true,
        )
        .unwrap();
    assert!(cleared.metadata.cover.is_none());
    let c = app.catalog().unwrap();
    let op = c.operations.last().unwrap().id;
    assert!(c.retained_resources().any(|r| r.id == planned.id));
    c.validate_integrity().unwrap();
    app.undo_book_change(op).unwrap();
    let c = app.catalog().unwrap();
    assert_eq!(
        c.book(id).unwrap().metadata.cover.as_ref().unwrap().id,
        planned.id
    );
    assert_eq!(app.blobs.read(planned.id, 100).unwrap(), b"cover-original");
    let backup = app
        .blobs
        .prepare_backup(&c, serde_json::json!({"appearance.palette.v1":"folio"}))
        .unwrap();
    let destination = temp.path().join("metadata-backup.aqb");
    app.blobs
        .run_backup(backup.manifest.backup, &destination)
        .unwrap();
    let restore = app.blobs.prepare_restore(&destination).unwrap();
    let restored = app.blobs.run_restore(restore.task).unwrap();
    let restored_root = restored.root.join("library");
    let restored_app = Reader {
        repository: SqliteRepository::open(&restored_root).unwrap(),
        blobs: LocalBlobs::open(&restored_root).unwrap(),
    };
    let recovered = restored_app.catalog().unwrap();
    assert_eq!(recovered.book(id).unwrap().metadata.author, "作者");
    assert_eq!(
        restored_app.blobs.read(planned.id, 100).unwrap(),
        b"cover-original"
    );
    assert_eq!(
        restored.device_preferences["appearance.palette.v1"],
        "folio"
    );
    assert_ne!(copy_id, Id::nil());
}

#[test]
fn legacy_books_default_to_empty_metadata_without_touching_resources() {
    let value = serde_json::json!({"id":Id::new_v4(),"project":Id::new_v4(),"title":"旧书","format":"Txt","revision":1,"gap":null,"pages":[],"archived":false});
    let book: aq_domain::Book = serde_json::from_value(value).unwrap();
    assert!(book.metadata.cover.is_none());
    assert!(book.metadata.author.is_empty());
}
