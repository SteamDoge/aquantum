// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
//! Idempotent checkpoints; UI supplies only foreground monotonic elapsed time.
use crate::{BlobStore, Reader, Repository};
use aq_domain::ReadingSession;

impl<R: Repository, B: BlobStore> Reader<R, B> {
    pub fn checkpoint_reading(&mut self, mut session: ReadingSession) -> crate::Result<()> {
        let mut c = self.catalog()?;
        let book = c.book(session.book)?;
        self.ensure_owned(&c, book.project)?;
        let parts: Vec<_> = session.day.split('-').collect();
        let valid_day = parts.len() == 3
            && parts[0].len() == 4
            && parts[1].len() == 2
            && parts[2].len() == 2
            && parts.iter().all(|p| p.bytes().all(|b| b.is_ascii_digit()))
            && (1..=12).contains(&parts[1].parse::<u32>().unwrap_or(0))
            && valid_date(&parts);
        let previous = c.reading_sessions.iter().find(|s| s.id == session.id);
        let total = if book.format.is_fixed_page() {
            book.pages.len()
        } else if let Some(previous) = previous {
            // Imported resources are immutable, so a validated session's total
            // remains valid across rename/move/checkpoints.
            previous.total
        } else if book.format.is_document() {
            // The engine owns pagination and reports the total it measured; the
            // same session reuses that value on every later checkpoint.
            session.total
        } else {
            self.paragraph_count(&c, book.id)?
        };
        if book.archived
            || !valid_day
            || session.total != total
            || session.total == 0
            || session.position >= session.total
            || session.elapsed_ms > 86_400_000
        {
            return Err(aq_domain::Error::Invalid("阅读会话日期、位置或时长无效".into()).into());
        }
        session.actor = c.actor;
        let expected = c.revision;
        if let Some(old) = c.reading_sessions.iter_mut().find(|s| s.id == session.id) {
            if old.actor != session.actor
                || old.book != session.book
                || old.day != session.day
                || old.started_at != session.started_at
                || session.elapsed_ms < old.elapsed_ms
            {
                return Err(aq_domain::Error::Invalid("会话身份冲突或时长倒退".into()).into());
            }
            *old = session;
        } else {
            c.reading_sessions.push(session);
        }
        c.revision += 1;
        self.repository.save(expected, &c)
    }
}

fn valid_date(parts: &[&str]) -> bool {
    let year = parts[0].parse::<u32>().unwrap_or(0);
    let month = parts[1].parse::<usize>().unwrap_or(0);
    let day = parts[2].parse::<u32>().unwrap_or(0);
    let leap = year.is_multiple_of(4) && (!year.is_multiple_of(100) || year.is_multiple_of(400));
    let days = [
        0,
        31,
        if leap { 29 } else { 28 },
        31,
        30,
        31,
        30,
        31,
        31,
        30,
        31,
        30,
        31,
    ];
    year > 0 && days.get(month).is_some_and(|max| day > 0 && day <= *max)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reading_dates_use_the_gregorian_calendar() {
        for day in [
            "2026-02-31",
            "2026-02-29",
            "2100-02-29",
            "0000-01-01",
            "2026-04-31",
        ] {
            assert!(!valid_date(&day.split('-').collect::<Vec<_>>()));
        }
        for day in ["2024-02-29", "2000-02-29", "2026-11-02"] {
            assert!(valid_date(&day.split('-').collect::<Vec<_>>()));
        }
    }
}
