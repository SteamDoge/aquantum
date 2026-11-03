// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
//! Core identity registration for fixed-layout engines. No native PDF handles here.
use crate::{BlobStore, Reader, Repository, Result};
use aq_domain::{Format, Id, Page};

impl<R: Repository, B: BlobStore> Reader<R, B> {
    pub fn document_interactions(&self, book: Id) -> Result<Vec<aq_domain::DocumentInteraction>> {
        let c = self.catalog()?;
        c.book(book)?;
        Ok(c.document_interactions
            .into_iter()
            .filter(|s| s.book == book && s.actor == c.actor)
            .collect())
    }
    pub fn set_document_interaction(
        &mut self,
        state: aq_domain::DocumentInteraction,
    ) -> Result<aq_domain::DocumentInteraction> {
        let mut c = self.catalog()?;
        let book = c.book(state.book)?;
        self.ensure_owned(&c, book.project)?;
        if book.format != Format::Markdown
            || book
                .pages
                .first()
                .is_none_or(|p| p.resource.id != state.source)
            || state.node.len() > 240
            || state.node.is_empty()
            || state.node.chars().any(char::is_control)
            || !matches!(state.kind.as_str(), "task" | "fold")
        {
            return Err(aq_domain::Error::Invalid("交互节点、格式或正文版本无效".into()).into());
        }
        let previous = c.document_interactions.iter().position(|s| {
            s.book == state.book
                && s.actor == c.actor
                && s.source == state.source
                && s.node == state.node
                && s.kind == state.kind
        });
        let revision = previous
            .map(|i| c.document_interactions[i].revision)
            .unwrap_or(0);
        if state.revision != revision {
            return Err(crate::Error::Conflict(
                "个人交互状态已更新，请重新读取".into(),
            ));
        }
        let expected = c.revision;
        let state = aq_domain::DocumentInteraction {
            actor: c.actor,
            revision: revision + 1,
            ..state
        };
        if let Some(i) = previous {
            c.document_interactions[i] = state.clone();
        } else {
            c.document_interactions.push(state.clone());
        }
        c.revision += 1;
        self.repository.save(expected, &c)?;
        Ok(state)
    }
    pub fn bind_pdf_pages(
        &mut self,
        book: Id,
        resource: Id,
        revision: u64,
        count: usize,
    ) -> Result<aq_domain::Book> {
        let c = self.catalog()?;
        let before = c.book(book)?;
        self.ensure_owned(&c, before.project)?;
        if before.format != Format::Pdf
            || before.pages.is_empty()
            || before.pages[0].resource.id != resource
            || count == 0
            || count > 100_000
        {
            return Err(aq_domain::Error::Invalid("PDF 页面或资源身份无效".into()).into());
        }
        if before.pages.len() == count {
            return Ok(before.clone());
        }
        if before.pages.len() != 1 || before.revision != revision {
            return Err(crate::Error::Conflict(
                "固定页面已绑定，不能覆盖原有定位".into(),
            ));
        }
        self.change_book(book, "bind_pdf_pages", |b| {
            let source = b.pages[0].resource.clone();
            for _ in 1..count {
                b.pages.push(Page {
                    id: Id::new_v4(),
                    resource: source.clone(),
                });
            }
            b.revision += 1;
            Ok(())
        })?;
        Ok(self.catalog()?.book(book)?.clone())
    }
}
