// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
//! Manual maintenance policy shared by local adapters, UI and future connectors.
use crate::{Error, Result};
use aq_domain::{Catalog, Id};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CleanupItem {
    pub key: String,
    pub category: String,
    pub bytes: u64,
    pub sha256: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct CleanupPlan {
    pub version: u32,
    pub task: Id,
    pub library: Id,
    pub base_revision: u64,
    pub protected_resources: usize,
    pub items: Vec<CleanupItem>,
}
pub fn protected_resources(catalog: &Catalog, pins: impl IntoIterator<Item = Id>) -> HashSet<Id> {
    let mut ids: HashSet<_> = catalog.retained_resources().map(|r| r.id).collect();
    ids.extend(pins);
    ids
}
pub fn validate_cleanup(
    catalog: &Catalog,
    plan: &CleanupPlan,
    item: &CleanupItem,
    pins: impl IntoIterator<Item = Id>,
) -> Result<Id> {
    if plan.version != 1 || plan.library != catalog.id || plan.base_revision != catalog.revision {
        return Err(Error::Conflict(
            "预览后资料库发生变化，请重新预览清理范围".into(),
        ));
    }
    let stem = match item.category.as_str() {
        "unreferenced" => item.key.as_str(),
        "incomplete" => item
            .key
            .strip_suffix(".part")
            .ok_or_else(|| Error::Unsupported("清理类别与名称不匹配".into()))?,
        _ => return Err(Error::Unsupported("不能清理该数据类别".into())),
    };
    let id = stem
        .parse::<Id>()
        .map_err(|_| Error::Unsupported("清理键不是受管资源身份".into()))?;
    if protected_resources(catalog, pins).contains(&id) {
        return Err(Error::Unsupported(
            "资源仍被内容、历史或恢复任务引用，已保留".into(),
        ));
    }
    Ok(id)
}
