// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
use crate::{Error, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashSet;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Destination {
    Home,
    Projects,
    Statistics,
    Ai,
    Me,
    Search,
    Recent,
    Notifications,
    Operations,
    Modules,
}

pub fn validate_navigation(items: &[Destination]) -> Result<()> {
    if !(1..=5).contains(&items.len())
        || items.last() != Some(&Destination::Me)
        || items.iter().collect::<HashSet<_>>().len() != items.len()
    {
        return Err(Error::Invalid(
            "移动导航须有 1–5 个不同快捷入口，我的不可移除且固定最右".into(),
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shortcuts_may_hide_projects_but_not_me() {
        assert!(validate_navigation(&[Destination::Me]).is_ok());
        assert!(validate_navigation(&[Destination::Modules, Destination::Me]).is_ok());
        assert!(validate_navigation(&[Destination::Projects]).is_err());
        assert!(validate_navigation(&[Destination::Me, Destination::Projects]).is_err());
        assert!(
            validate_navigation(&[Destination::Modules, Destination::Modules, Destination::Me])
                .is_err()
        );
        assert!(validate_navigation(&[]).is_err());
    }
}
