// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
//! Platform-independent identities, library rules and reading state.
pub mod catalog;
pub mod model;
pub mod navigation;
pub mod ordering;
pub mod settings;
pub mod validation;

pub use catalog::*;
pub use model::*;
pub use navigation::*;
pub use ordering::*;
pub use settings::*;
