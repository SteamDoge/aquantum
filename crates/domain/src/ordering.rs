// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
use std::cmp::Ordering;

/// Version 1: deterministic Unicode ordering with ASCII/full-width digit runs.
/// Chinese pinyin collation is deliberately deferred until a shared table is selected.
pub fn natural_compare(left: &str, right: &str) -> Ordering {
    fn normalized(s: &str) -> Vec<char> {
        s.trim_start()
            .chars()
            .map(|c| match c {
                '\u{ff01}'..='\u{ff5e}' => char::from_u32(c as u32 - 0xfee0).unwrap(),
                '\u{3000}' => ' ',
                _ => c,
            })
            .flat_map(char::to_lowercase)
            .collect()
    }
    let (a, b) = (normalized(left), normalized(right));
    let (mut i, mut j) = (0, 0);
    while i < a.len() && j < b.len() {
        let order = if a[i].is_ascii_digit() && b[j].is_ascii_digit() {
            let (start_a, start_b) = (i, j);
            while i < a.len() && a[i].is_ascii_digit() {
                i += 1;
            }
            while j < b.len() && b[j].is_ascii_digit() {
                j += 1;
            }
            let aa = &a[start_a..i];
            let bb = &b[start_b..j];
            let aa = &aa[aa.iter().take_while(|c| **c == '0').count()..];
            let bb = &bb[bb.iter().take_while(|c| **c == '0').count()..];
            aa.len().cmp(&bb.len()).then_with(|| aa.cmp(bb))
        } else {
            let cmp = a[i].cmp(&b[j]);
            i += 1;
            j += 1;
            cmp
        };
        if order != Ordering::Equal {
            return order;
        }
    }
    (a.len() - i)
        .cmp(&(b.len() - j))
        .then_with(|| left.cmp(right))
}
