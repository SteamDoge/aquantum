// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
//! Use cases depend on ports. UI/CLI and future connectors call these operations.
pub mod backup;
pub mod formats;
pub mod importing;
pub mod maintenance;
pub mod management;
pub mod pages;
pub mod ports;
pub mod reading;
pub mod registry;
pub mod search;
pub mod service;
pub mod statistics;
pub mod textcodec;

pub use importing::*;
pub use ports::*;
pub use reading::*;
pub use search::*;
pub use service::*;
pub use textcodec::*;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error(transparent)]
    Domain(#[from] aq_domain::Error),
    #[error("存储错误：{0}")]
    Storage(String),
    #[error("版本冲突：{0}；请刷新后重试")]
    Conflict(String),
    #[error("暂不支持：{0}")]
    Unsupported(String),
}
pub type Result<T> = std::result::Result<T, Error>;
