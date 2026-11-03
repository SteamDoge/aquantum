// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import '../data/models.dart';
import 'reader_contract.dart';
import 'text_pagination.dart';

abstract class SessionReaderAdapter implements ReaderAdapter {
  final Book book;
  @override
  final int position;
  @override
  final String status;
  final WidgetBuilder content;
  final ValueChanged<int> onGo;
  final bool Function() locked;
  SessionReaderAdapter({
    required this.book,
    required this.position,
    required this.status,
    required this.content,
    required this.onGo,
    required this.locked,
  });
  @override
  String get documentId => book.id;
  @override
  String get title => book.title;

  /// Horizontal turns unless an image book resolves TopToBottom.
  @override
  bool get verticalTurn => false;

  /// Only paged renderers show the bottom controller by default; a continuous
  /// renderer such as the PDF viewer overrides this to keep page navigation.
  @override
  bool get pageProgress => paged;
  @override
  bool get interactionLocked => locked();
  @override
  Widget buildContent(BuildContext context) => content(context);
  @override
  void goTo(int index) {
    if (index >= 0 && index < count) onGo(index);
  }
}

class TextReaderAdapter extends SessionReaderAdapter
    implements OutlineReaderAdapter, LocationReaderAdapter {
  final List<String> paragraphs;
  final int currentOffset;
  final void Function(int paragraph, int offset)? onGoToText;

  /// Outline from the core; empty means the text carries no headings, in which
  /// case the navigation panel falls back to numbered paragraphs.
  @override
  final List<ReaderLocation> outline;
  TextReaderAdapter({
    required super.book,
    required super.position,
    required super.status,
    required super.content,
    required super.onGo,
    required super.locked,
    required this.paragraphs,
    this.currentOffset = 0,
    this.onGoToText,
    List<ReaderOutlineEntry> entries = const [],
  }) : outline = [
         for (final e in entries)
           if (e.index >= 0 && e.index < paragraphs.length)
             ReaderLocation(
               e.offset > 0
                   ? 'text:${_sourceOf(book)}:${e.index}:${e.offset}'
                   : 'paragraph:${_sourceOf(book)}:${e.index}',
               e.title,
               e.index,
             ),
       ];

  /// The identity of the text bytes, shared by outline ids and `location`.
  static String _sourceOf(Book book) => book.pages.isEmpty
      ? '${book.revision}'
      : (book.pages.first['resource']['id'] as String? ?? '${book.revision}');
  @override
  int get count => paragraphs.length;
  @override
  String get unit => '段';
  @override
  bool get paged => false;
  @override
  bool get rightToLeft => false;
  @override
  ReaderCapabilities get capabilities => ReaderCapabilities(
    search: true,
    encoding: true,
    navigationLabel: outline.isEmpty ? '内容导航（段落）' : '目录',
    settings: {
      ReaderSetting.fontSize,
      ReaderSetting.fontFamily,
      ReaderSetting.fontWeight,
      ReaderSetting.lineHeight,
      ReaderSetting.paragraphGap,
      ReaderSetting.margin,
      ReaderSetting.theme,
      ReaderSetting.textPaging,
    },
  );
  String get textSource => _sourceOf(book);
  @override
  ReaderLocation location(int index) => ReaderLocation(
    index == position && currentOffset > 0
        ? 'text:$textSource:$index:$currentOffset'
        : 'paragraph:$textSource:$index',
    paragraphs[index]
        .trim()
        .replaceAll('\n', ' ')
        .characters
        .take(140)
        .toString(),
    index,
  );
  @override
  int? resolveLocation(String id) {
    final prefix = 'paragraph:$textSource:';
    final textPrefix = 'text:$textSource:';
    final index = id.startsWith(textPrefix)
        ? int.tryParse(id.substring(textPrefix.length).split(':').first)
        : id.startsWith(prefix)
        ? int.tryParse(id.substring(prefix.length))
        : null;
    return index != null && index >= 0 && index < count ? index : null;
  }

  @override
  Widget? buildThumbnail(BuildContext context, int index) => null;
  @override
  Future<void> goToLocation(ReaderLocation location) async {
    final paragraph = resolveLocation(location.id);
    if (paragraph == null) return;
    final offset = location.id.startsWith('text:$textSource:')
        ? (int.tryParse(location.id.split(':').last) ?? 0).clamp(
            0,
            paragraphs[paragraph].length,
          )
        : 0;
    if (onGoToText != null) {
      onGoToText!(paragraph, offset);
    } else {
      goTo(paragraph);
    }
  }

  @override
  Future<List<ReaderSearchHit>> search(String query) async {
    final needle = query.toLowerCase();
    if (needle.isEmpty) return [];
    final results = <ReaderSearchHit>[];
    for (var i = 0; i < paragraphs.length && results.length < 100; i++) {
      final offset = paragraphs[i].toLowerCase().indexOf(needle);
      if (offset < 0) continue;
      final start = (offset - 40).clamp(0, paragraphs[i].length);
      final end = (offset + query.length + 100).clamp(
        start,
        paragraphs[i].length,
      );
      results.add(
        ReaderSearchHit(
          ReaderLocation('text:$textSource:$i:$offset', location(i).label, i),
          paragraphs[i].substring(start, end),
        ),
      );
    }
    return results;
  }
}

class ComicReaderAdapter extends SessionReaderAdapter
    implements PagedReaderAdapter {
  final bool continuous;
  @override
  final bool rightToLeft;
  @override
  final bool verticalTurn;
  final Widget Function(BuildContext, int) thumbnail;
  final Widget Function(BuildContext, int, bool)? pageBuilder;
  @override
  final bool animatePageTurns;
  ComicReaderAdapter({
    required super.book,
    required super.position,
    required super.status,
    required super.content,
    required super.onGo,
    required super.locked,
    required this.continuous,
    required this.rightToLeft,
    this.verticalTurn = false,
    required this.thumbnail,
    this.pageBuilder,
    this.animatePageTurns = true,
  });
  @override
  int get count => book.pages.length;
  @override
  String get unit => '页';
  @override
  bool get paged => !continuous;
  @override
  ReaderCapabilities get capabilities => ReaderCapabilities(
    navigationLabel: '页面导航',
    searchExplanation: '当前图片阅读器尚未接入 OCR 文字检索插件。',
    settings: {
      ReaderSetting.theme,
      if (!continuous) ReaderSetting.animation,
      ReaderSetting.continuous,
      if (!continuous) ReaderSetting.fit,
      if (!continuous) ReaderSetting.direction,
      ReaderSetting.imageGap,
      ReaderSetting.rotation,
    },
  );
  @override
  ReaderLocation location(int index) => ReaderLocation(
    'page:${book.pages[index]['id']}',
    '第 ${index + 1} 页',
    index,
  );
  @override
  int? resolveLocation(String id) {
    final index = book.pages.indexWhere((p) => 'page:${p['id']}' == id);
    return index < 0 ? null : index;
  }

  @override
  Widget? buildThumbnail(BuildContext context, int index) =>
      thumbnail(context, index);
  @override
  Future<List<ReaderSearchHit>> search(String query) async => [];
  @override
  Widget? buildPage(BuildContext context, int index, {required bool preview}) =>
      pageBuilder?.call(context, index, preview) ?? thumbnail(context, index);
}

class PagedTextReaderAdapter extends SessionReaderAdapter
    implements MeasuredPagedReaderAdapter, OutlineReaderAdapter {
  final TextPagination layout;
  final List<String> paragraphs;
  final List<ReaderOutlineEntry> entries;
  @override
  final bool rightToLeft, animatePageTurns;
  PagedTextReaderAdapter({
    required super.book,
    required super.position,
    required super.status,
    required super.content,
    required super.onGo,
    required super.locked,
    required this.layout,
    required this.paragraphs,
    this.entries = const [],
    required this.rightToLeft,
    required this.animatePageTurns,
  });
  String get textSource => book.pages.isEmpty
      ? '${book.revision}'
      : book.pages.first['resource']['id'] as String? ?? '${book.revision}';
  @override
  int get count => layout.pages.length;
  @override
  Size get pageCanvasSize => layout.viewport;

  /// A page can only be reached by its page, so the chrome outline names pages
  /// instead of the core's paragraph outline, which a page view cannot address.
  @override
  late final List<ReaderLocation> outline = [
    for (final entry in entries)
      if (entry.index >= 0 &&
          entry.index < paragraphs.length &&
          (layout.complete || layout.covers(entry.index, entry.offset)))
        ReaderLocation(
          'text:$textSource:${entry.index}:${entry.offset}',
          entry.title,
          layout.pageFor(entry.index, entry.offset),
        ),
  ];
  String chapterAt(int paragraph, int offset) {
    ReaderOutlineEntry? current;
    for (final entry in entries) {
      if ((entry.index < paragraph ||
              (entry.index == paragraph && entry.offset <= offset)) &&
          (current == null ||
              entry.index > current.index ||
              (entry.index == current.index &&
                  entry.offset >= current.offset))) {
        current = entry;
      }
    }
    return current?.title ?? (entries.isEmpty ? '未识别章节标题' : '正文');
  }

  @override
  String get unit => layout.complete ? '页' : '附近页（全书分页中）';
  @override
  bool get paged => true;
  @override
  ReaderCapabilities get capabilities => const ReaderCapabilities(
    search: true,
    navigationLabel: '内容导航（分页）',
    settings: {
      ReaderSetting.fontSize,
      ReaderSetting.fontFamily,
      ReaderSetting.fontWeight,
      ReaderSetting.lineHeight,
      ReaderSetting.paragraphGap,
      ReaderSetting.margin,
      ReaderSetting.theme,
      ReaderSetting.textPaging,
      ReaderSetting.direction,
      ReaderSetting.animation,
      ReaderSetting.turnEffect,
    },
  );
  @override
  ReaderLocation location(int index) {
    final anchor = layout.pages[index].anchor;
    return ReaderLocation(
      'text:$textSource:${anchor.paragraph}:${anchor.start}',
      '第 ${index + 1} 页 · ${chapterAt(anchor.paragraph, anchor.start)}',
      index,
    );
  }

  @override
  int? resolveLocation(String id) {
    final textPrefix = 'text:$textSource:';
    final paragraphPrefix = 'paragraph:$textSource:';
    final parts = id.startsWith(textPrefix)
        ? id.substring(textPrefix.length).split(':')
        : id.startsWith(paragraphPrefix)
        ? [id.substring(paragraphPrefix.length), '0']
        : <String>[];
    if (parts.length != 2) return null;
    final paragraph = int.tryParse(parts[0]), offset = int.tryParse(parts[1]);
    if (paragraph == null ||
        offset == null ||
        paragraph < 0 ||
        paragraph >= paragraphs.length ||
        offset < 0 ||
        offset > paragraphs[paragraph].length) {
      return null;
    }
    return layout.pageFor(paragraph, offset);
  }

  @override
  Widget? buildPage(BuildContext context, int index, {required bool preview}) =>
      ReaderTextPageView(layout: layout, index: index, preview: true);
  @override
  Widget? buildThumbnail(BuildContext context, int index) => FittedBox(
    child: SizedBox(
      width: layout.viewport.width,
      height: layout.viewport.height,
      child: buildPage(context, index, preview: true),
    ),
  );
  @override
  Future<List<ReaderSearchHit>> search(String query) async {
    if (query.isEmpty) return [];
    final results = <ReaderSearchHit>[];
    for (var i = 0; i < paragraphs.length && results.length < 100; i++) {
      final offset = paragraphs[i].toLowerCase().indexOf(query.toLowerCase());
      if (offset >= 0) {
        results.add(
          ReaderSearchHit(
            location(layout.pageFor(i, offset)),
            paragraphs[i].substring(
              (offset - 40).clamp(0, paragraphs[i].length),
              (offset + query.length + 100).clamp(0, paragraphs[i].length),
            ),
          ),
        );
      }
    }
    return results;
  }
}
