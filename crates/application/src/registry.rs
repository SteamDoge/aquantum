// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
//! Reader surfaces contributed by formats, behind one interface.
//!
//! The client asks "which surfaces does this book offer?" and gets ids plus a
//! uniform case conversion. Adding a format therefore never means editing a
//! suffix switch in the shell: a format either registers here or it is not
//! offered at all. Formats with no reader surface (or no core support yet) stay
//! unknown on purpose, so nothing claims a capability this build cannot honour.

use aq_domain::{Book, Format};

/// One surface a client can execute against a book.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Surface {
    /// Paragraph text produced by the core (TXT and the Markdown fallback).
    Text,
    /// Markdown structure with source ranges and node identities.
    Markdown,
    /// Real pages whose pixels come from an external engine (PDF).
    FixedPage,
    /// Image pages owned by the core (comic archives and image books).
    ImagePage,
    /// One document laid out by the bundled browser engine (EPUB/MOBI/AZW3/FB2).
    Document,
}

impl Surface {
    pub const ALL: [Self; 5] = [
        Self::Text,
        Self::Markdown,
        Self::FixedPage,
        Self::ImagePage,
        Self::Document,
    ];

    pub fn id(self) -> &'static str {
        match self {
            Self::Text => "text",
            Self::Markdown => "markdown",
            Self::FixedPage => "fixed_page",
            Self::ImagePage => "image_page",
            Self::Document => "document",
        }
    }

    pub fn parse(id: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|surface| surface.id() == id)
    }

    /// The unit a position index counts, so the shell never guesses from bytes.
    pub fn unit(self) -> &'static str {
        match self {
            Self::Text | Self::Markdown => "paragraph",
            Self::FixedPage | Self::ImagePage => "page",
            // A document is addressed by a character anchor, not by an ordinal.
            Self::Document => "anchor",
        }
    }

    /// Surfaces whose bytes the core decodes, so a text encoding can apply.
    pub fn decodes_bytes(self) -> bool {
        matches!(self, Self::Text | Self::Markdown)
    }
}

/// A format that can contribute reader surfaces.
pub trait FormatProvider: Send + Sync {
    /// Stable identifier, independent of display language and file suffix.
    fn id(&self) -> &'static str;
    /// Every surface this format can offer, in presentation order.
    fn surfaces(&self) -> &'static [Surface];
}

struct Text;
impl FormatProvider for Text {
    fn id(&self) -> &'static str {
        "txt"
    }
    fn surfaces(&self) -> &'static [Surface] {
        &[Surface::Text]
    }
}

struct MarkdownFormat;
impl FormatProvider for MarkdownFormat {
    fn id(&self) -> &'static str {
        "markdown"
    }
    fn surfaces(&self) -> &'static [Surface] {
        &[Surface::Markdown, Surface::Text]
    }
}

struct Pdf;
impl FormatProvider for Pdf {
    fn id(&self) -> &'static str {
        "pdf"
    }
    fn surfaces(&self) -> &'static [Surface] {
        &[Surface::FixedPage]
    }
}

struct Comic;
impl FormatProvider for Comic {
    fn id(&self) -> &'static str {
        "comic"
    }
    fn surfaces(&self) -> &'static [Surface] {
        &[Surface::ImagePage]
    }
}

/// Publications opened by the bundled foliate-js engine. One provider covers
/// all four suffixes because the surface, the anchor format and the client
/// renderer are identical; the file suffix only selects the engine's parser.
struct DocumentFormat;
impl FormatProvider for DocumentFormat {
    fn id(&self) -> &'static str {
        "document"
    }
    fn surfaces(&self) -> &'static [Surface] {
        &[Surface::Document]
    }
}

/// Formats this build can actually read. A provider appears here only with a
/// working core path, never as a placeholder for a future format.
pub fn providers() -> &'static [&'static dyn FormatProvider] {
    &[&Text, &MarkdownFormat, &Pdf, &Comic, &DocumentFormat]
}

/// The provider for a stored book, or `None` when no surface is implemented.
pub fn provider_for(book: &Book) -> Option<&'static dyn FormatProvider> {
    let id = match book.format {
        Format::Txt => "txt",
        Format::Markdown => "markdown",
        Format::Pdf => "pdf",
        Format::Comic => "comic",
        Format::Epub | Format::Mobi | Format::Azw3 | Format::Fb2 => "document",
    };
    providers().iter().copied().find(|p| p.id() == id)
}

/// Surfaces for a book; empty means the client must not open a reader.
pub fn surfaces_for(book: &Book) -> &'static [Surface] {
    provider_for(book).map_or(&[], |provider| provider.surfaces())
}

/// Capabilities a client switches UI on, so it branches on data, not suffixes.
#[derive(Clone, Debug, Eq, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct BookCapabilities {
    pub format: String,
    pub surfaces: Vec<Surface>,
    /// Unit counted by the position index, from the first offered surface.
    pub unit: String,
    /// Whether this book can be read with a different text encoding.
    pub encoding: bool,
    /// Whether pages are real fixed frames with engine-provided pixels.
    pub fixed_pages: bool,
    /// Whether images can be cropped and turned without touching the original.
    pub image_pages: bool,
}

pub fn capabilities_for(book: &Book) -> BookCapabilities {
    let surfaces = surfaces_for(book).to_vec();
    BookCapabilities {
        format: provider_for(book).map_or(String::new(), |p| p.id().to_owned()),
        unit: surfaces
            .first()
            .map_or_else(|| "paragraph".to_owned(), |s| s.unit().to_owned()),
        encoding: surfaces.iter().any(|s| s.decodes_bytes()),
        fixed_pages: surfaces.contains(&Surface::FixedPage),
        image_pages: surfaces.contains(&Surface::ImagePage),
        surfaces,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use aq_domain::Id;

    fn book(format: Format) -> Book {
        Book {
            metadata: Default::default(),
            id: Id::new_v4(),
            project: Id::new_v4(),
            title: "样本".into(),
            format,
            revision: 1,
            gap: None,
            direction: None,
            pages: vec![],
            archived: false,
        }
    }

    const STORED: [Format; 8] = [
        Format::Txt,
        Format::Markdown,
        Format::Pdf,
        Format::Comic,
        Format::Epub,
        Format::Mobi,
        Format::Azw3,
        Format::Fb2,
    ];

    #[test]
    fn every_stored_format_offers_a_surface() {
        for format in STORED {
            let caps = capabilities_for(&book(format));
            assert!(!caps.surfaces.is_empty(), "{format:?} must offer a surface");
            assert!(!caps.format.is_empty(), "{format:?} must name its provider");
        }
    }

    #[test]
    fn surface_ids_round_trip_and_never_repeat() {
        let mut seen = vec![];
        for surface in Surface::ALL {
            assert_eq!(Surface::parse(surface.id()), Some(surface));
            assert!(!seen.contains(&surface.id()), "duplicate id");
            seen.push(surface.id());
        }
        assert_eq!(Surface::parse("epub"), None);
        assert_eq!(Surface::parse("azw3"), None);
    }

    #[test]
    fn capabilities_follow_the_surfaces_not_the_suffix() {
        let comic = capabilities_for(&book(Format::Comic));
        assert_eq!(comic.unit, "page");
        assert!(comic.image_pages && !comic.fixed_pages && !comic.encoding);

        let pdf = capabilities_for(&book(Format::Pdf));
        assert_eq!(pdf.unit, "page");
        assert!(pdf.fixed_pages && !pdf.image_pages && !pdf.encoding);

        let text = capabilities_for(&book(Format::Txt));
        assert_eq!(text.unit, "paragraph");
        assert!(text.encoding && !text.fixed_pages && !text.image_pages);

        // Markdown keeps its structured surface first and can still fall back to
        // plain text, so a client asks for the surface it can render.
        let markdown = capabilities_for(&book(Format::Markdown));
        assert_eq!(markdown.surfaces[0], Surface::Markdown);
        assert!(markdown.surfaces.contains(&Surface::Text));

        // A document is anchored, never paged by the core and never re-decoded
        // by the core, so the shell must not offer page or encoding switches.
        for format in [Format::Epub, Format::Mobi, Format::Azw3, Format::Fb2] {
            let document = capabilities_for(&book(format));
            assert_eq!(document.unit, "anchor");
            assert_eq!(document.surfaces, vec![Surface::Document]);
            assert!(!document.fixed_pages && !document.image_pages && !document.encoding);
        }
    }

    #[test]
    fn providers_are_unique_and_cover_every_stored_format() {
        let ids: Vec<_> = providers().iter().map(|p| p.id()).collect();
        assert_eq!(ids.len(), 5);
        let mut unique = ids.clone();
        unique.sort_unstable();
        unique.dedup();
        assert_eq!(unique.len(), ids.len(), "provider ids must be unique");
        for format in STORED {
            assert!(
                provider_for(&book(format)).is_some(),
                "{format:?} has no provider"
            );
        }
    }
}
