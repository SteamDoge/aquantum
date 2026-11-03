// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import '../reader/reader_contract.dart';
import '../reader/reader_renderers.dart';
import 'markdown_document.dart';

class MarkdownReaderAdapter extends TextReaderAdapter
    implements OutlineReaderAdapter {
  final MarkdownDocument document;
  MarkdownReaderAdapter({
    required super.book,
    required super.position,
    required super.status,
    required super.content,
    required super.onGo,
    required super.locked,
    required super.paragraphs,
    required this.document,
  });
  @override
  ReaderCapabilities get capabilities => const ReaderCapabilities(
    search: true,
    navigationLabel: '文档标题',
    settings: {
      ReaderSetting.fontSize,
      ReaderSetting.fontFamily,
      ReaderSetting.lineHeight,
      ReaderSetting.paragraphGap,
      ReaderSetting.margin,
      ReaderSetting.theme,
      // Markdown can be paged from its own paragraph text, so offering the
      // page count is not an empty switch even when it opens in one scroll.
      ReaderSetting.textPaging,
    },
  );

  /// A page layout names its own pages, so the core's block outline would send
  /// the reader to a paragraph the paged view cannot address. Only the
  /// scrolling view, which can reach a block directly, uses it.
  @override
  List<ReaderLocation> get outline => paged
      ? const []
      : [
          for (final block in document.blocks)
            if (block.level > 0)
              ReaderLocation(
                'paragraph:$textSource:${block.paragraph}',
                block.label,
                block.paragraph,
              ),
        ];
}
