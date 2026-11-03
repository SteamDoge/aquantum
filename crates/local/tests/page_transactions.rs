// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
use aq_application::{AppendPlacement, Reader};
use aq_domain::{Id, Location};
use aq_local::{
    LocalBlobs, SqliteRepository, export_pages, plan_import, safe_relative, unpack_archive,
};
use std::{fs, io::Write};
use zip::{ZipArchive, ZipWriter, write::SimpleFileOptions};

fn fixture() -> (tempfile::TempDir, Reader<SqliteRepository, LocalBlobs>, Id) {
    let temp = tempfile::tempdir().unwrap();
    let library = temp.path().join("library");
    let source = temp.path().join("original");
    fs::create_dir(&source).unwrap();
    for i in 1..=5 {
        fs::write(source.join(format!("{i}.png")), format!("source-{i}")).unwrap();
    }
    let mut reader = Reader {
        repository: SqliteRepository::open(&library).unwrap(),
        blobs: LocalBlobs::open(&library).unwrap(),
    };
    let c = reader.catalog().unwrap();
    let plan = plan_import(&c, &library, &source, c.inbox).unwrap();
    let done = reader.import(&plan, false).unwrap();
    (temp, reader, done.books[0])
}

#[test]
fn reorder_move_and_append_preserve_ids_and_reject_stale_or_lossy_edits() {
    let (temp, mut reader, book) = fixture();
    let c = reader.catalog().unwrap();
    let original = c.book(book).unwrap().clone();
    let ids: Vec<_> = original.pages.iter().map(|p| p.id).collect();
    assert!(reader.reorder_pages(book, 1, &ids[..4]).is_err());
    assert!(reader.reorder_pages(book, 1, &[ids[0]; 5]).is_err());
    reader
        .move_pages(book, 1, &[ids[1], ids[3]], Some(ids[0]))
        .unwrap();
    assert_eq!(
        reader
            .catalog()
            .unwrap()
            .book(book)
            .unwrap()
            .pages
            .iter()
            .map(|p| p.id)
            .collect::<Vec<_>>(),
        [ids[1], ids[3], ids[0], ids[2], ids[4]]
    );
    assert!(reader.reorder_pages(book, 1, &ids).is_err());
    let op = reader.catalog().unwrap().operations.last().unwrap().id;
    reader.undo_book_change(op).unwrap();
    assert_eq!(
        reader
            .catalog()
            .unwrap()
            .book(book)
            .unwrap()
            .pages
            .iter()
            .map(|p| p.id)
            .collect::<Vec<_>>(),
        ids
    );
    let added = temp.path().join("6.png");
    fs::write(&added, b"new-page").unwrap();
    let current = reader.catalog().unwrap();
    let plan = plan_import(&current, &reader.blobs.root, &added, c.inbox).unwrap();
    let placement = AppendPlacement {
        book,
        revision: 3,
        before: Some(ids[0]),
    };
    let done = reader
        .import_with_placement(&plan, false, Some(&placement))
        .unwrap();
    assert_eq!(done.books, [book]);
    assert_eq!(reader.catalog().unwrap().book(book).unwrap().pages.len(), 6);
    // Restart/replay is idempotent even when the append's expected version is old.
    let mut reopened = Reader {
        repository: SqliteRepository::open(&reader.blobs.root).unwrap(),
        blobs: LocalBlobs::open(&reader.blobs.root).unwrap(),
    };
    reopened
        .import_with_placement(&plan, false, Some(&placement))
        .unwrap();
    assert_eq!(
        reopened.catalog().unwrap().book(book).unwrap().pages.len(),
        6
    );
    assert_eq!(fs::read(&added).unwrap(), b"new-page");
}

#[test]
fn checked_export_never_overwrites_and_cut_is_reversible_and_anchor_safe() {
    let (temp, mut reader, book) = fixture();
    let c = reader.catalog().unwrap();
    let ids: Vec<_> = c.book(book).unwrap().pages.iter().map(|p| p.id).collect();
    let output = temp.path().join("pages.cbz");
    export_pages(&reader.blobs, &c, book, 1, &[ids[3], ids[1]], &output).unwrap();
    let bytes = fs::read(&output).unwrap();
    let mut archive = ZipArchive::new(fs::File::open(&output).unwrap()).unwrap();
    assert_eq!(archive.len(), 3);
    assert_eq!(archive.by_index(0).unwrap().name(), "000001.png");
    assert!(archive.by_name("aq-export.json").is_ok());
    assert!(export_pages(&reader.blobs, &c, book, 1, &[ids[0]], &output).is_err());
    assert_eq!(fs::read(&output).unwrap(), bytes);
    reader
        .cut_exported_pages(book, 1, &[ids[1], ids[3]])
        .unwrap();
    assert_eq!(reader.catalog().unwrap().book(book).unwrap().pages.len(), 3);
    let op = reader.catalog().unwrap().operations.last().unwrap().id;
    reader.undo_book_change(op).unwrap();
    assert_eq!(reader.catalog().unwrap().book(book).unwrap().pages.len(), 5);
    reader
        .add_note(
            book,
            Location::Page { page: ids[1] },
            "keep my anchor".into(),
        )
        .unwrap();
    assert!(reader.cut_exported_pages(book, 3, &[ids[1]]).is_err());
    assert_eq!(reader.catalog().unwrap().book(book).unwrap().pages.len(), 5);
    // Missing/corrupt source must not publish a destination or change metadata.
    fs::write(
        reader
            .blobs
            .root
            .join("objects")
            .join(c.book(book).unwrap().pages[0].resource.id.to_string()),
        b"corrupt",
    )
    .unwrap();
    let failed = temp.path().join("failed.cbz");
    assert!(
        export_pages(
            &reader.blobs,
            &reader.catalog().unwrap(),
            book,
            3,
            &[ids[0]],
            &failed
        )
        .is_err()
    );
    assert!(!failed.exists());
    assert_eq!(reader.catalog().unwrap().book(book).unwrap().pages.len(), 5);
}

#[test]
fn zip_rejects_traversal_case_collisions_links_and_retains_original_archive() {
    for path in [
        "../x",
        "a/../../x",
        "C:/x",
        "/x",
        "a\\..\\x",
        "NUL.txt",
        "name.",
        "CONIN$",
        "CONOUT$.txt",
        "COM¹.txt",
        "LPT³",
    ] {
        assert!(safe_relative(path).is_err(), "{path}");
    }
    for names in [["ok.txt", "../escape.txt"], ["a.txt", "A.TXT"]] {
        let temp = tempfile::tempdir().unwrap();
        let source = temp.path().join("bad.zip");
        let mut zip = ZipWriter::new(fs::File::create(&source).unwrap());
        for name in names {
            zip.start_file(name, SimpleFileOptions::default()).unwrap();
            zip.write_all(b"data").unwrap();
        }
        zip.finish().unwrap();
        let before = fs::read(&source).unwrap();
        let output = temp.path().join("unpacked");
        assert!(unpack_archive(&source, &output).is_err());
        assert!(!output.exists());
        assert_eq!(fs::read(source).unwrap(), before);
    }
    let temp = tempfile::tempdir().unwrap();
    let source = temp.path().join("link.zip");
    let mut zip = ZipWriter::new(fs::File::create(&source).unwrap());
    zip.add_symlink("link", "../out", SimpleFileOptions::default())
        .unwrap();
    zip.finish().unwrap();
    assert!(unpack_archive(&source, &temp.path().join("out")).is_err());
}

#[test]
fn cropped_pages_are_retained_and_library_can_still_be_backed_up() {
    let (_temp, mut reader, book) = fixture();
    let page = reader.catalog().unwrap().book(book).unwrap().pages[1].id;
    let crop = aq_domain::CropInsets {
        left: 0.1,
        ..Default::default()
    };
    reader.set_page_crop(book, page, crop).unwrap();
    assert!(reader.cut_exported_pages(book, 1, &[page]).is_err());
    let catalog = reader.catalog().unwrap();
    catalog.validate_integrity().unwrap();
    assert_eq!(catalog.crop[&book][&page], crop);
    reader
        .blobs
        .prepare_backup(&catalog, serde_json::json!({}))
        .unwrap();
}

#[test]
fn undo_rejects_a_deleted_project_and_resolves_restored_name_collisions() {
    let (_temp, mut reader, book) = fixture();
    let c = reader.catalog().unwrap();
    let old = reader.create_project(c.inbox, "old").unwrap();
    let target = reader.create_project(c.inbox, "target").unwrap();
    reader.move_books(&[book], old).unwrap();
    reader.move_books(&[book], target).unwrap();
    let operation = reader.catalog().unwrap().operations.last().unwrap().id;
    reader.delete_empty_project(old).unwrap();
    assert!(reader.undo_book_change(operation).is_err());
    reader.catalog().unwrap().validate_integrity().unwrap();

    reader
        .manage_book(book, "rename", Some("old title"), None)
        .unwrap();
    reader
        .manage_book(book, "rename", Some("new title"), None)
        .unwrap();
    let operation = reader.catalog().unwrap().operations.last().unwrap().id;
    let copy = reader.manage_book(book, "copy", None, None).unwrap();
    reader
        .manage_book(copy, "rename", Some("old title"), None)
        .unwrap();
    reader.undo_book_change(operation).unwrap();
    let c = reader.catalog().unwrap();
    assert_ne!(c.book(book).unwrap().title, c.book(copy).unwrap().title);
    c.validate_integrity().unwrap();
}

#[test]
fn undo_append_cannot_remove_pages_with_personal_references() {
    for kind in ["note", "progress", "crop"] {
        let (temp, mut reader, book) = fixture();
        let added = temp.path().join("extra.png");
        fs::write(&added, b"extra-page").unwrap();
        let c = reader.catalog().unwrap();
        let plan = plan_import(&c, &reader.blobs.root, &added, c.inbox).unwrap();
        reader
            .import_with_placement(
                &plan,
                false,
                Some(&AppendPlacement {
                    book,
                    revision: 1,
                    before: None,
                }),
            )
            .unwrap();
        let c = reader.catalog().unwrap();
        let operation = c.operations.last().unwrap().id;
        let page = c.book(book).unwrap().pages.last().unwrap().id;
        match kind {
            "note" => {
                reader
                    .add_note(book, Location::Page { page }, "keep".into())
                    .unwrap();
            }
            "progress" => reader.save_progress(book, Location::Page { page }).unwrap(),
            _ => reader
                .set_page_crop(
                    book,
                    page,
                    aq_domain::CropInsets {
                        left: 0.1,
                        ..Default::default()
                    },
                )
                .unwrap(),
        }
        assert!(reader.undo_book_change(operation).is_err(), "{kind}");
        let c = reader.catalog().unwrap();
        assert_eq!(c.book(book).unwrap().pages.len(), 6);
        c.validate_integrity().unwrap();
    }
}
