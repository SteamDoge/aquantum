// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
use crate::storage;
use aq_application::{Error, Repository, Result};
use aq_domain::Catalog;
use rusqlite::{Connection, TransactionBehavior, params};
use std::{path::Path, time::Duration};

pub struct SqliteRepository {
    connection: Connection,
}

/// v1→v2 and v2→v3 add defaulted fields; opening and restoring share this policy.
pub(crate) fn migrate_catalog(catalog: &mut Catalog, target: u32) -> Result<()> {
    if catalog.schema_version == 0
        || catalog.schema_version > target
        || target > aq_domain::DATA_VERSION
    {
        return Err(storage("目录版本不兼容，未迁移"));
    }
    while catalog.schema_version < target {
        match catalog.schema_version {
            1 | 2 => catalog.schema_version += 1,
            _ => return Err(storage("目录版本没有已定义的迁移路径")),
        }
    }
    Ok(())
}

impl SqliteRepository {
    pub fn migration_snapshots(&self) -> Result<Vec<aq_application::backup::MigrationSnapshot>> {
        let exists:bool=self.connection.query_row("SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='migration_backups')",[],|r|r.get(0)).map_err(storage)?;
        if !exists {
            return Ok(vec![]);
        }
        let mut statement = self
            .connection
            .prepare("SELECT version,payload FROM migration_backups ORDER BY version")
            .map_err(storage)?;
        statement
            .query_map([], |r| {
                Ok(aq_application::backup::MigrationSnapshot {
                    version: r.get(0)?,
                    payload: r.get(1)?,
                })
            })
            .map_err(storage)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(storage)
    }
    pub fn retain_migration_snapshots(
        &mut self,
        snapshots: &[aq_application::backup::MigrationSnapshot],
    ) -> Result<()> {
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(storage)?;
        tx.execute_batch("CREATE TABLE IF NOT EXISTS migration_backups(version INTEGER PRIMARY KEY, payload TEXT NOT NULL);").map_err(storage)?;
        for snapshot in snapshots {
            let value: serde_json::Value =
                serde_json::from_str(&snapshot.payload).map_err(storage)?;
            if snapshot.version == 0
                || snapshot.version > aq_domain::DATA_VERSION
                || value.get("schema_version").and_then(|v| v.as_u64())
                    != Some(snapshot.version as u64)
            {
                return Err(storage("迁移原始快照版本无效"));
            }
            tx.execute(
                "INSERT INTO migration_backups VALUES(?1,?2)",
                params![snapshot.version, snapshot.payload],
            )
            .map_err(storage)?;
        }
        tx.commit().map_err(storage)
    }
    pub fn open(root: &Path) -> Result<Self> {
        std::fs::create_dir_all(root).map_err(storage)?;
        crate::ensure_regular_path(&std::path::absolute(root).map_err(storage)?)?;
        let db_path = root.join("library.sqlite3");
        if db_path.exists() {
            crate::ensure_regular_path(&db_path)?;
        }
        let mut connection = Connection::open(db_path).map_err(storage)?;
        connection
            .busy_timeout(Duration::from_secs(5))
            .map_err(storage)?;
        connection
            .pragma_update(None, "foreign_keys", true)
            .map_err(storage)?;
        // A normal request opens an already initialized library. Avoid taking a
        // write lock and running DDL merely to service that read/write request.
        let current: u32 = connection
            .pragma_query_value(None, "user_version", |r| r.get(0))
            .map_err(storage)?;
        if current == aq_domain::DATA_VERSION {
            let indexes: u32 = connection.query_row(
                "SELECT count(*) FROM sqlite_master WHERE type='table' AND name IN ('text_index','text_index_versions')",
                [], |r| r.get(0)).map_err(storage)?;
            if indexes == 2 {
                let repo = Self { connection };
                repo.load()?;
                return Ok(repo);
            }
        }
        // Serialize first-open migration and initial catalog creation too.
        let tx = connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(storage)?;
        let version: u32 = tx
            .pragma_query_value(None, "user_version", |r| r.get(0))
            .map_err(storage)?;
        if version > aq_domain::DATA_VERSION {
            return Err(Error::Unsupported(format!(
                "数据库版本 {version} 高于本程序"
            )));
        }
        if version == 0 {
            tx.execute_batch("CREATE TABLE catalog (singleton INTEGER PRIMARY KEY CHECK(singleton=1), revision INTEGER NOT NULL, payload TEXT NOT NULL); PRAGMA user_version=3;").map_err(storage)?;
            let c = Catalog::default();
            tx.execute(
                "INSERT INTO catalog VALUES(1,0,?1)",
                [serde_json::to_string(&c).map_err(storage)?],
            )
            .map_err(storage)?;
        }
        if version == 1 {
            let (revision, payload): (i64, String) = tx
                .query_row(
                    "SELECT revision,payload FROM catalog WHERE singleton=1",
                    [],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .map_err(storage)?;
            let mut catalog: Catalog = serde_json::from_str(&payload).map_err(storage)?;
            if catalog.schema_version != 1
                || i64::try_from(catalog.revision).map_err(storage)? != revision
            {
                return Err(storage("旧目录版本无效，迁移未提交"));
            }
            migrate_catalog(&mut catalog, 2)?;
            // A durable, immutable pre-migration payload stays inside the same DB.
            tx.execute_batch("CREATE TABLE IF NOT EXISTS migration_backups(version INTEGER PRIMARY KEY, payload TEXT NOT NULL);").map_err(storage)?;
            tx.execute(
                "INSERT OR IGNORE INTO migration_backups VALUES(1,?1)",
                [&payload],
            )
            .map_err(storage)?;
            tx.execute(
                "UPDATE catalog SET payload=?1 WHERE singleton=1",
                [serde_json::to_string(&catalog).map_err(storage)?],
            )
            .map_err(storage)?;
            tx.pragma_update(None, "user_version", 2).map_err(storage)?;
        }
        if version == 1 || version == 2 {
            let (revision, payload): (i64, String) = tx
                .query_row(
                    "SELECT revision,payload FROM catalog WHERE singleton=1",
                    [],
                    |r| Ok((r.get(0)?, r.get(1)?)),
                )
                .map_err(storage)?;
            let mut catalog: Catalog = serde_json::from_str(&payload).map_err(storage)?;
            if catalog.schema_version != 2
                || i64::try_from(catalog.revision).map_err(storage)? != revision
            {
                return Err(storage("v2 目录版本不一致，未迁移"));
            }
            tx.execute_batch("CREATE TABLE IF NOT EXISTS migration_backups(version INTEGER PRIMARY KEY, payload TEXT NOT NULL);").map_err(storage)?;
            tx.execute(
                "INSERT OR IGNORE INTO migration_backups VALUES(2,?1)",
                [&payload],
            )
            .map_err(storage)?;
            migrate_catalog(&mut catalog, aq_domain::DATA_VERSION)?;
            tx.execute(
                "UPDATE catalog SET payload=?1 WHERE singleton=1",
                [serde_json::to_string(&catalog).map_err(storage)?],
            )
            .map_err(storage)?;
            tx.pragma_update(None, "user_version", 3).map_err(storage)?;
        }
        tx.commit().map_err(storage)?;
        connection.execute_batch("CREATE TABLE IF NOT EXISTS text_index_versions(book TEXT NOT NULL, hash TEXT NOT NULL, PRIMARY KEY(book,hash)); CREATE TABLE IF NOT EXISTS text_index(book TEXT NOT NULL, hash TEXT NOT NULL, paragraph INTEGER NOT NULL, body TEXT NOT NULL, folded TEXT NOT NULL, PRIMARY KEY(book,hash,paragraph));").map_err(storage)?;
        let repo = Self { connection };
        repo.load()?;
        Ok(repo)
    }
}

impl aq_application::TextIndexStore for SqliteRepository {
    fn has_text_index(&self, book: aq_domain::Id, hash: &str) -> Result<bool> {
        self.connection
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM text_index_versions WHERE book=?1 AND hash=?2)",
                params![book.to_string(), hash],
                |r| r.get(0),
            )
            .map_err(storage)
    }
    fn store_text_index(
        &mut self,
        book: aq_domain::Id,
        hash: &str,
        paragraphs: &[String],
    ) -> Result<()> {
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(storage)?;
        {
            let mut insert = tx
                .prepare("INSERT OR IGNORE INTO text_index VALUES(?1,?2,?3,?4,?5)")
                .map_err(storage)?;
            let book_id = book.to_string();
            for (index, body) in paragraphs.iter().enumerate() {
                insert
                    .execute(params![
                        book_id,
                        hash,
                        index as i64,
                        body,
                        body.to_lowercase()
                    ])
                    .map_err(storage)?;
            }
        }
        tx.execute(
            "INSERT OR IGNORE INTO text_index_versions VALUES(?1,?2)",
            params![book.to_string(), hash],
        )
        .map_err(storage)?;
        tx.commit().map_err(storage)
    }
    fn query_text_index(
        &self,
        book: aq_domain::Id,
        hash: &str,
        query: &str,
        limit: usize,
    ) -> Result<Vec<aq_application::search::TextHit>> {
        let mut statement = self.connection.prepare("SELECT paragraph,body,instr(folded,?3) FROM text_index WHERE book=?1 AND hash=?2 AND instr(folded,?3)>0 ORDER BY paragraph LIMIT ?4").map_err(storage)?;
        let rows = statement
            .query_map(params![book.to_string(), hash, query, limit as i64], |r| {
                Ok((
                    r.get::<_, i64>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, u32>(2)?,
                ))
            })
            .map_err(storage)?;
        let mut output = vec![];
        for row in rows {
            let (paragraph, body, folded_position) = row.map_err(storage)?;
            let mut folded_chars = 0;
            let offset = body
                .chars()
                .position(|ch| {
                    folded_chars += ch.to_lowercase().count();
                    folded_chars >= folded_position as usize
                })
                .unwrap_or(0)
                .saturating_sub(30);
            output.push(aq_application::search::TextHit {
                book,
                paragraph: usize::try_from(paragraph).map_err(storage)?,
                snippet: body.chars().skip(offset).take(160).collect(),
            });
        }
        Ok(output)
    }
}

impl Repository for SqliteRepository {
    fn load(&self) -> Result<Catalog> {
        let (revision, json): (i64, String) = self
            .connection
            .query_row(
                "SELECT revision,payload FROM catalog WHERE singleton=1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .map_err(storage)?;
        let c: Catalog = serde_json::from_str(&json).map_err(storage)?;
        c.validate_version()?;
        if i64::try_from(c.revision).map_err(storage)? != revision {
            return Err(storage("目录版本与事务版本不一致"));
        }
        Ok(c)
    }
    fn save(&mut self, expected: u64, c: &Catalog) -> Result<()> {
        c.validate_version()?;
        if Some(c.revision) != expected.checked_add(1) {
            return Err(storage("保存必须递增一次目录版本"));
        }
        let tx = self
            .connection
            .transaction_with_behavior(TransactionBehavior::Immediate)
            .map_err(storage)?;
        let rows = tx
            .execute(
                "UPDATE catalog SET revision=?1,payload=?2 WHERE singleton=1 AND revision=?3",
                params![
                    i64::try_from(c.revision).map_err(storage)?,
                    serde_json::to_string(c).map_err(storage)?,
                    i64::try_from(expected).map_err(storage)?
                ],
            )
            .map_err(storage)?;
        if rows != 1 {
            return Err(Error::Conflict("其他进程已修改资料库".into()));
        }
        tx.commit().map_err(storage)
    }
}
