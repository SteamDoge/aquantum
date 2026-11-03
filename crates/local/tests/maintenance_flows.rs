// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
use aq_application::{BlobStore, Reader};
use aq_domain::{Id, Location};
use aq_local::{LocalBlobs, SqliteRepository, plan_import};
use std::fs;

fn fixture() -> (tempfile::TempDir, Reader<SqliteRepository, LocalBlobs>, Id) {
    let temp = tempfile::tempdir().unwrap();
    let app = temp.path().join("app");
    let source = temp.path().join("source");
    fs::create_dir(&source).unwrap();
    fs::write(source.join("book.txt"), "first\n\nsecond").unwrap();
    let mut reader = Reader {
        repository: SqliteRepository::open(&app.join("library")).unwrap(),
        blobs: LocalBlobs::open(&app.join("library")).unwrap(),
    };
    let c = reader.catalog().unwrap();
    let plan = plan_import(&c, &reader.blobs.root, &source, c.inbox).unwrap();
    let done = reader.import(&plan, false).unwrap();
    (temp, reader, done.books[0])
}

#[test]
fn discarding_a_backup_is_locked_terminal_and_releases_abandoned_resource_pins() {
    let (temp, reader, _) = fixture();
    let catalog = reader.catalog().unwrap();
    let orphan = Id::new_v4();
    fs::write(
        reader.blobs.root.join("objects").join(orphan.to_string()),
        b"orphan",
    )
    .unwrap();
    let plan = reader
        .blobs
        .prepare_backup(&catalog, serde_json::json!({}))
        .unwrap();
    assert!(
        reader
            .blobs
            .pinned_resources(&catalog)
            .unwrap()
            .contains(&orphan)
    );
    let lease = reader.blobs.begin_import(Id::new_v4(), &[]).unwrap();
    assert!(
        reader
            .blobs
            .discard_backup_task("backup", plan.manifest.backup)
            .is_err()
    );
    drop(lease);
    reader
        .blobs
        .discard_backup_task("backup", plan.manifest.backup)
        .unwrap();
    reader
        .blobs
        .discard_backup_task("backup", plan.manifest.backup)
        .unwrap();
    assert!(
        !reader
            .blobs
            .pinned_resources(&catalog)
            .unwrap()
            .contains(&orphan)
    );
    assert!(
        reader
            .blobs
            .resume_backup_task("backup", plan.manifest.backup)
            .is_err()
    );
    assert!(
        reader
            .blobs
            .run_backup(
                plan.manifest.backup,
                &temp.path().join("must-not-exist.aqb")
            )
            .is_err()
    );
    assert_eq!(
        reader.blobs.cleanup_preview(&catalog).unwrap().items.len(),
        1
    );
}

#[test]
fn interrupted_discard_and_backup_restore_do_not_resurrect_local_resource_leases() {
    let (temp, reader, _) = fixture();
    let catalog = reader.catalog().unwrap();
    let orphan = Id::new_v4();
    fs::write(
        reader.blobs.root.join("objects").join(orphan.to_string()),
        b"orphan",
    )
    .unwrap();
    let first = reader
        .blobs
        .prepare_backup(&catalog, serde_json::json!({}))
        .unwrap()
        .manifest
        .backup;
    let receipts = reader.blobs.root.join("discarded-task-receipts");
    fs::create_dir_all(&receipts).unwrap();
    fs::write(
        receipts.join(format!("backup-{first}.json")),
        serde_json::to_vec(&serde_json::json!({"version":1,"task":first,"kind":"backup"})).unwrap(),
    )
    .unwrap();
    fs::rename(
        reader
            .blobs
            .root
            .join("backup-tasks")
            .join(first.to_string()),
        temp.path().join("kept-private-staging"),
    )
    .unwrap();
    reader.blobs.discard_backup_task("backup", first).unwrap();
    assert!(reader.blobs.discard_finished("backup", first));
    let completed = reader
        .blobs
        .prepare_backup(&catalog, serde_json::json!({}))
        .unwrap()
        .manifest
        .backup;
    reader
        .blobs
        .run_backup(completed, &temp.path().join("first.aqb"))
        .unwrap();
    let portable = reader
        .blobs
        .prepare_backup(&catalog, serde_json::json!({}))
        .unwrap();
    assert!(
        !portable
            .manifest
            .entries
            .iter()
            .any(|e| e.name.starts_with("app/library/resource-pins/")
                && (e.name.contains(&first.to_string())
                    || e.name.contains(&completed.to_string())))
    );
    assert!(
        portable
            .manifest
            .entries
            .iter()
            .any(|e| e.name.contains("discarded-task-receipts/"))
    );
    let path = temp.path().join("portable.aqb");
    reader
        .blobs
        .run_backup(portable.manifest.backup, &path)
        .unwrap();
    let restore = reader.blobs.prepare_restore(&path).unwrap();
    let result = reader.blobs.run_restore(restore.task).unwrap();
    let root = result.root;
    let restored = LocalBlobs::open(&root.join("library")).unwrap();
    let restored_catalog = SqliteRepository::open(&root.join("library")).unwrap();
    use aq_application::Repository;
    assert!(
        !restored
            .pinned_resources(&restored_catalog.load().unwrap())
            .unwrap()
            .contains(&orphan)
    );
    assert!(restored.discard_finished("backup", first));
}

#[test]
fn private_records_publish_one_complete_winner_without_overwriting() {
    let temp = tempfile::tempdir().unwrap();
    let path = temp.path().join("task/confirmed.json");
    let threads: Vec<_> = (0..8)
        .map(|index| {
            let path = path.clone();
            std::thread::spawn(move || {
                let bytes = vec![index; 4096];
                aq_local::save_private_record(&path, &bytes).map(|_| bytes)
            })
        })
        .collect();
    let winners: Vec<_> = threads
        .into_iter()
        .filter_map(|t| t.join().unwrap().ok())
        .collect();
    assert_eq!(winners.len(), 1);
    assert_eq!(fs::read(path).unwrap(), winners[0]);
}

#[test]
fn manual_cleanup_protects_content_history_and_live_or_recoverable_imports() {
    let (_temp, reader, _book) = fixture();
    let c = reader.catalog().unwrap();
    let orphan = Id::new_v4();
    fs::write(
        reader.blobs.root.join("objects").join(orphan.to_string()),
        b"orphan",
    )
    .unwrap();
    let task = Id::new_v4();
    let lease = reader.blobs.begin_import(task, &[orphan]).unwrap();
    assert!(reader.blobs.cleanup_preview(&c).is_err());
    drop(lease);
    assert!(reader.blobs.cleanup_preview(&c).unwrap().items.is_empty());
    reader.blobs.release_import_pins(task).unwrap();
    let plan = reader.blobs.cleanup_preview(&c).unwrap();
    assert_eq!(plan.items.len(), 1);
    assert_eq!(plan.items[0].key, orphan.to_string());
    reader
        .blobs
        .confirm_cleanup(&c, plan.task, &[orphan.to_string()])
        .unwrap();
    reader
        .blobs
        .cleanup_item(&c, plan.task, &orphan.to_string())
        .unwrap();
    reader
        .blobs
        .cleanup_item(&c, plan.task, &orphan.to_string())
        .unwrap();
    assert!(
        !reader
            .blobs
            .root
            .join("objects")
            .join(orphan.to_string())
            .exists()
    );
    for r in c.retained_resources() {
        assert!(
            reader
                .blobs
                .root
                .join("objects")
                .join(r.id.to_string())
                .exists()
        );
    }
}

#[test]
fn cleanup_rejects_stale_or_changed_items_and_resumes_after_delete_before_receipt() {
    let (_temp, mut reader, _book) = fixture();
    let id = Id::new_v4();
    let key = format!("{id}.part");
    let path = reader.blobs.root.join("objects").join(&key);
    fs::write(&path, b"partial").unwrap();
    let c = reader.catalog().unwrap();
    let plan = reader.blobs.cleanup_preview(&c).unwrap();
    reader.create_project(c.inbox, "after preview").unwrap();
    assert!(
        reader
            .blobs
            .cleanup_item(&reader.catalog().unwrap(), plan.task, &key)
            .is_err()
    );
    let current = reader.catalog().unwrap();
    let plan = reader.blobs.cleanup_preview(&current).unwrap();
    reader
        .blobs
        .confirm_cleanup(&current, plan.task, std::slice::from_ref(&key))
        .unwrap();
    fs::write(&path, b"changed").unwrap();
    assert!(
        reader
            .blobs
            .cleanup_item(&current, plan.task, &key)
            .is_err()
    );
    let plan = reader.blobs.cleanup_preview(&current).unwrap();
    reader
        .blobs
        .confirm_cleanup(&current, plan.task, std::slice::from_ref(&key))
        .unwrap();
    let dir = reader
        .blobs
        .root
        .join("maintenance-tasks")
        .join(plan.task.to_string());
    fs::write(
        dir.join(format!("intent-{key}.json")),
        serde_json::to_vec(&plan.items[0]).unwrap(),
    )
    .unwrap();
    fs::remove_file(&path).unwrap();
    reader
        .blobs
        .cleanup_item(&current, plan.task, &key)
        .unwrap();
    assert!(dir.join(format!("done-{key}.json")).exists());
    assert!(
        reader
            .blobs
            .cleanup_item(&current, plan.task, "../../outside")
            .is_err()
    );
}

#[test]
fn checked_backup_restores_an_independent_library_and_preserves_current_and_originals() {
    let (temp, mut reader, book) = fixture();
    reader
        .save_progress(book, Location::Paragraph { index: 1 })
        .unwrap();
    reader
        .add_note(
            book,
            Location::Paragraph { index: 1 },
            "associated note".into(),
        )
        .unwrap();
    let catalog = reader.catalog().unwrap();
    let preferences = serde_json::json!({"theme":"dark","reader-font-size":24.0,"reader-bookmarks.v1.book":"saved"});
    let mut original_v1 = serde_json::to_value(&catalog).unwrap();
    original_v1["schema_version"] = serde_json::json!(1);
    let original_json = serde_json::to_string_pretty(&original_v1).unwrap();
    reader
        .repository
        .retain_migration_snapshots(&[aq_application::backup::MigrationSnapshot {
            version: 1,
            payload: original_json.clone(),
        }])
        .unwrap();
    let app = reader.blobs.root.parent().unwrap().to_path_buf();
    fs::create_dir_all(app.join("modules/packages/example")).unwrap();
    fs::write(
        app.join("modules/packages/example/package.zip"),
        b"preserved module bytes",
    )
    .unwrap();
    let plan = reader
        .blobs
        .prepare_backup(&catalog, preferences.clone())
        .unwrap();
    let destination = temp.path().join("library.aqb");
    reader
        .blobs
        .run_backup(plan.manifest.backup, &destination)
        .unwrap();
    let exported = fs::read(&destination).unwrap();
    assert!(
        reader
            .blobs
            .run_backup(plan.manifest.backup, &destination)
            .is_err()
    );
    assert_eq!(fs::read(&destination).unwrap(), exported);
    reader
        .manage_book(book, "rename", Some("after backup"), None)
        .unwrap();
    let request = reader.blobs.prepare_restore(&destination).unwrap();
    let recovered = reader.blobs.run_restore(request.task).unwrap();
    assert_ne!(recovered.root, app);
    assert_eq!(recovered.device_preferences, preferences);
    assert_eq!(
        reader.catalog().unwrap().book(book).unwrap().title,
        "after backup"
    );
    let restored = Reader {
        repository: SqliteRepository::open(&recovered.root.join("library")).unwrap(),
        blobs: LocalBlobs::open(&recovered.root.join("library")).unwrap(),
    };
    assert_eq!(restored.catalog().unwrap().id, catalog.id);
    let retained = restored.repository.migration_snapshots().unwrap();
    assert_eq!(retained.len(), 1);
    assert_eq!(retained[0].payload, original_json);
    assert_eq!(
        restored.catalog().unwrap().book(book).unwrap().title,
        "book"
    );
    assert_eq!(restored.text(book).unwrap().paragraphs, ["first", "second"]);
    assert!(
        restored
            .notes_markdown(book)
            .unwrap()
            .contains("associated note")
    );
    assert_eq!(
        restored.catalog().unwrap().progress[0].location,
        Location::Paragraph { index: 1 }
    );
    assert_eq!(
        fs::read(recovered.root.join("modules/packages/example/package.zip")).unwrap(),
        b"preserved module bytes"
    );
    assert_eq!(
        reader.blobs.run_restore(request.task).unwrap().root,
        recovered.root
    );
    assert_eq!(fs::read(destination).unwrap(), exported);
}

#[test]
fn canceled_backup_can_resume_and_corruption_never_switches_or_changes_current_catalog() {
    let (temp, reader, _book) = fixture();
    let catalog = reader.catalog().unwrap();
    let plan = reader
        .blobs
        .prepare_backup(&catalog, serde_json::json!({}))
        .unwrap();
    let destination = temp.path().join("canceled.aqb");
    reader
        .blobs
        .cancel_backup_task("backup", plan.manifest.backup)
        .unwrap();
    assert!(
        reader
            .blobs
            .run_backup(plan.manifest.backup, &destination)
            .is_err()
    );
    assert!(!destination.exists());
    reader
        .blobs
        .resume_backup_task("backup", plan.manifest.backup)
        .unwrap();
    reader
        .blobs
        .run_backup(plan.manifest.backup, &destination)
        .unwrap();
    let request = reader.blobs.prepare_restore(&destination).unwrap();
    fs::write(&destination, b"corrupt").unwrap();
    assert!(reader.blobs.run_restore(request.task).is_err());
    assert_eq!(reader.catalog().unwrap().revision, catalog.revision);
    assert_eq!(reader.catalog().unwrap().books.len(), catalog.books.len());
}

#[test]
fn restore_rejects_extra_paths_and_forged_resource_bytes_without_publishing_a_library() {
    use std::io::{Read, Write};
    let (temp, reader, _book) = fixture();
    let catalog = reader.catalog().unwrap();
    let plan = reader
        .blobs
        .prepare_backup(&catalog, serde_json::json!({}))
        .unwrap();
    let source = temp.path().join("valid.aqb");
    reader
        .blobs
        .run_backup(plan.manifest.backup, &source)
        .unwrap();
    for extra in [
        Some("../escape.txt"),
        Some("app/modules/unlisted.txt"),
        None,
    ] {
        let path = temp.path().join(format!("bad-{}.aqb", Id::new_v4()));
        let mut input = zip::ZipArchive::new(fs::File::open(&source).unwrap()).unwrap();
        let mut output = zip::ZipWriter::new(fs::File::create(&path).unwrap());
        for index in 0..input.len() {
            let mut entry = input.by_index(index).unwrap();
            let mut bytes = vec![];
            entry.read_to_end(&mut bytes).unwrap();
            if extra.is_none() && entry.name().starts_with("app/library/objects/") {
                bytes[0] ^= 1;
            }
            output
                .start_file(entry.name(), zip::write::SimpleFileOptions::default())
                .unwrap();
            output.write_all(&bytes).unwrap();
        }
        if let Some(name) = extra {
            output
                .start_file(name, zip::write::SimpleFileOptions::default())
                .unwrap();
            output.write_all(b"unexpected").unwrap();
        }
        output.finish().unwrap();
        if extra.is_some() {
            assert!(reader.blobs.prepare_restore(&path).is_err());
        } else {
            let request = reader.blobs.prepare_restore(&path).unwrap();
            assert!(reader.blobs.run_restore(request.task).is_err());
            assert!(
                !reader
                    .blobs
                    .root
                    .parent()
                    .unwrap()
                    .join("recovered-libraries")
                    .join(request.task.to_string())
                    .exists()
            );
        }
        assert_eq!(reader.catalog().unwrap().revision, catalog.revision);
        assert_eq!(
            reader.text(catalog.books[0].id).unwrap().paragraphs,
            ["first", "second"]
        );
    }
    assert!(!temp.path().join("escape.txt").exists());
}
