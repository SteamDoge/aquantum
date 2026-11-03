// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
use crate::{PlannedResource, Result};
use aq_domain::{Catalog, Id, Resource};

/// Atomically persist metadata and operation history using an expected revision.
pub trait Repository {
    fn load(&self) -> Result<Catalog>;
    fn save(&mut self, expected_revision: u64, catalog: &Catalog) -> Result<()>;
}

/// Immutable resources; failed transactions may retain unreferenced blobs.
/// No automatic cleanup is part of this interface.
pub trait BlobStore {
    /// Serialize publication against manual maintenance and durably pin resources
    /// before copying. The lease remains live through the catalog transaction.
    fn begin_import(&self, task: Id, resources: &[Id]) -> Result<Box<dyn ResourceLease>>;
    fn put(&self, source: &PlannedResource) -> Result<Resource>;
    fn read(&self, id: Id, max_bytes: u64) -> Result<Vec<u8>>;
    /// Absolute path of the verified managed copy, for read-only format engines
    /// that need random access without loading the whole resource into memory.
    fn resource_path(&self, id: Id) -> Result<std::path::PathBuf>;
}

pub trait ResourceLease {}

pub trait TextIndexStore {
    fn has_text_index(&self, book: Id, hash: &str) -> Result<bool>;
    fn store_text_index(&mut self, book: Id, hash: &str, paragraphs: &[String]) -> Result<()>;
    fn query_text_index(
        &self,
        book: Id,
        hash: &str,
        query: &str,
        limit: usize,
    ) -> Result<Vec<crate::search::TextHit>>;
}
