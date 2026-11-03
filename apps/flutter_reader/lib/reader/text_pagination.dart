// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'text_chunks.dart';
import 'reader_page_effect.dart';

class TextPageFragment {
  final int paragraph, start, end;
  final String text;
  final double gapAfter;

  /// Keep source offsets without painting a whitespace-only visual page.
  final bool sourceOnly;
  const TextPageFragment(
    this.paragraph,
    this.start,
    this.end,
    this.text,
    this.gapAfter, {
    this.sourceOnly = false,
  });
  // A line break at a page boundary belongs to the source anchor, but must not
  // create a second, empty visual line at the bottom of that page.
  String get displayText => text.endsWith('\n')
      ? text.substring(0, text.length - (text.endsWith('\r\n') ? 2 : 1))
      : text;
}

class ReaderTextPage {
  final List<TextPageFragment> fragments;

  /// Room at the foot of this page kept free for the shell's controller.
  final double reserved;
  ReaderTextPage(List<TextPageFragment> input, {this.reserved = 0})
    : fragments = List.unmodifiable(input);
  TextPageFragment get anchor =>
      fragments.firstWhere((f) => !f.sourceOnly, orElse: () => fragments.first);
}

class TextPagination {
  // RenderEditable reserves a 1dp caret gap plus SelectableText's 2dp cursor,
  // even for read-only text. Preview and measurement must use that same width.
  static const selectionGutter = 3.0;
  final bool complete;
  final Size viewport;
  final EdgeInsets padding;
  final TextStyle style;
  final TextScaler scaler;
  final TextDirection direction;
  final Color? backgroundColor;
  final List<ReaderTextPage> pages;

  TextPagination._(
    this.viewport,
    this.padding,
    this.style,
    this.scaler,
    this.direction,
    this.backgroundColor,
    this.pages, {
    this.complete = true,
  });

  /// Measure real glyph lines with Flutter's renderer. Split only at measured
  /// line boundaries; an arbitrarily long paragraph may occupy several pages.
  factory TextPagination.layout({
    required List<String> paragraphs,
    required Size viewport,
    required TextStyle style,
    required TextScaler scaler,
    required TextDirection direction,
    required double margin,
    required double paragraphGap,
    double reserved = 0,
    Iterable<(int, int)> chapterStarts = const [],
    Color? backgroundColor,
  }) => _layoutSteps(
    paragraphs: paragraphs,
    viewport: viewport,
    style: style,
    scaler: scaler,
    direction: direction,
    margin: margin,
    paragraphGap: paragraphGap,
    reserved: reserved,
    chapterStarts: chapterStarts,
    backgroundColor: backgroundColor,
  ).last!;

  static Future<TextPagination> layoutAsync({
    required List<String> paragraphs,
    required Size viewport,
    required TextStyle style,
    required TextScaler scaler,
    required TextDirection direction,
    required double margin,
    required double paragraphGap,
    double reserved = 0,
    Iterable<(int, int)> chapterStarts = const [],
    Color? backgroundColor,
    bool Function()? cancelled,
    int anchorParagraph = 0,
    int anchorOffset = 0,
    ValueChanged<TextPagination>? onPreview,
  }) async {
    // Measure only a bounded source window first, including deep saved anchors.
    // Whole-book page numbers are published only by the complete layout below.
    if (onPreview != null && paragraphs.isNotEmpty) {
      await Future<void>.delayed(Duration.zero);
      if (cancelled?.call() ?? false) throw StateError('Pagination cancelled');
      final chunks = TextChunks.of(paragraphs);
      final target = chunks.chunks.indexWhere(
        (c) => c.paragraph == anchorParagraph && c.end >= anchorOffset,
      );
      final first = math.max(0, target - 1);
      final end = math.min(chunks.chunks.length, first + 4);
      final blocks = <String>[];
      final sources = <(int, int)>[];
      for (var i = first; i < end; i++) {
        final chunk = chunks.chunks[i];
        if (sources.isNotEmpty && sources.last.$1 == chunk.paragraph) {
          blocks[blocks.length - 1] += chunks.text(i);
        } else {
          blocks.add(chunks.text(i));
          sources.add((chunk.paragraph, chunk.start));
        }
      }
      final local = TextPagination.layout(
        chapterStarts: [
          for (var i = 0; i < sources.length; i++)
            for (final start in chapterStarts)
              if (start.$1 == sources[i].$1 &&
                  start.$2 >= sources[i].$2 &&
                  start.$2 < sources[i].$2 + blocks[i].length)
                (i, start.$2 - sources[i].$2),
        ],
        paragraphs: blocks,
        viewport: viewport,
        style: style,
        scaler: scaler,
        direction: direction,
        margin: margin,
        paragraphGap: paragraphGap,
        reserved: reserved,
        backgroundColor: backgroundColor,
      );
      onPreview(
        TextPagination._(
          viewport,
          local.padding,
          local.style,
          scaler,
          direction,
          backgroundColor,
          [
            for (final page in local.pages)
              ReaderTextPage([
                for (final f in page.fragments)
                  TextPageFragment(
                    sources[f.paragraph].$1,
                    sources[f.paragraph].$2 + f.start,
                    sources[f.paragraph].$2 + f.end,
                    f.text,
                    f.gapAfter,
                    sourceOnly: f.sourceOnly,
                  ),
              ]),
          ],
          complete: false,
        ),
      );
      // Give Flutter a frame to show the current source before background work.
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    for (final result in _layoutSteps(
      paragraphs: paragraphs,
      viewport: viewport,
      style: style,
      scaler: scaler,
      direction: direction,
      margin: margin,
      paragraphGap: paragraphGap,
      reserved: reserved,
      backgroundColor: backgroundColor,
      chapterStarts: chapterStarts,
    )) {
      if (cancelled?.call() ?? false) throw StateError('Pagination cancelled');
      if (result != null) return result;
      await Future<void>.delayed(Duration.zero);
    }
    throw StateError('Missing pagination result');
  }

  static Iterable<TextPagination?> _layoutSteps({
    required List<String> paragraphs,
    required Size viewport,
    required TextStyle style,
    required TextScaler scaler,
    required TextDirection direction,
    required double margin,
    required double paragraphGap,
    double reserved = 0,
    Iterable<(int, int)> chapterStarts = const [],
    Color? backgroundColor,
  }) sync* {
    style = style.copyWith(
      inherit: false,
      fontSize: style.fontSize ?? 20,
      textBaseline: style.textBaseline ?? TextBaseline.alphabetic,
    );
    final strut = StrutStyle.fromTextStyle(style);
    const heightBehavior = TextHeightBehavior();
    final horizontal = math.min(
      margin,
      math.max(0.0, (viewport.width - 80) / 2),
    );
    // The reader shell keeps its one bottom controller over every format, so
    // the last line of a page has to stop above it rather than hide under it.
    final padding = EdgeInsets.fromLTRB(
      horizontal,
      24,
      horizontal,
      24 + reserved,
    );
    final width = math.max(
      1.0,
      viewport.width - padding.horizontal - selectionGutter,
    );
    final height = math.max(1.0, viewport.height - padding.vertical);

    /// The pixel size of an inline range, used only when line metrics cannot
    /// name a boundary (a substituted glyph such as a CJK full stop reports an
    /// empty box on an empty glyph run).
    Size boxOf(TextPainter painter, int start, int end) {
      if (end <= start) return Size.zero;
      final boxes = painter.getBoxesForSelection(
        TextSelection(baseOffset: start, extentOffset: end),
      );
      return boxes.isEmpty ? Size.zero : boxes.first.toRect().size;
    }

    final pages = <ReaderTextPage>[];
    var fragments = <TextPageFragment>[];
    var used = 0.0;
    void finish() {
      if (fragments.isEmpty) return;
      // Blank source ranges can span paragraphs; preserve their bytes and
      // offsets on a neighbouring page without adding height to that page.
      if (fragments.every((f) => f.text.trim().isEmpty)) {
        final retained = [
          for (final f in fragments)
            TextPageFragment(
              f.paragraph,
              f.start,
              f.end,
              f.text,
              f.gapAfter,
              sourceOnly: true,
            ),
        ];
        if (pages.isEmpty) {
          fragments = retained;
          used = 0;
          return;
        }
        final previous = pages.removeLast();
        pages.add(
          ReaderTextPage([
            ...previous.fragments,
            ...retained,
          ], reserved: reserved),
        );
      } else {
        pages.add(ReaderTextPage(fragments, reserved: reserved));
      }
      fragments = [];
      used = 0;
    }

    final chunks = TextChunks.of(paragraphs);
    final breaks = chapterStarts.toSet();
    final breaksByParagraph = <int, List<int>>{};
    for (final (paragraph, offset) in breaks) {
      (breaksByParagraph[paragraph] ??= []).add(offset);
    }
    for (final offsets in breaksByParagraph.values) {
      offsets.sort();
    }
    final runs = <TextChunk>[];
    for (final chunk in chunks.chunks) {
      final offsets =
          (breaksByParagraph[chunk.paragraph] ?? const <int>[])
              .where((offset) => offset > chunk.start && offset < chunk.end)
              .toList()
            ..sort();
      var start = chunk.start;
      for (final end in [...offsets, chunk.end]) {
        runs.add(TextChunk(chunk.paragraph, start, end));
        start = end;
      }
    }
    for (var run = 0; run < runs.length; run++) {
      yield null;
      final chunk = runs[run];
      final paragraph = chunk.paragraph;
      if (breaks.contains((chunk.paragraph, chunk.start))) finish();
      final text = paragraphs[chunk.paragraph].substring(
        chunk.start,
        chunk.end,
      );
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: direction,
        textScaler: scaler,
        strutStyle: strut,
        textHeightBehavior: heightBehavior,
      )..layout(maxWidth: width);
      final lines = painter.computeLineMetrics();

      /// Where line [n] starts. A boundary that describes no pixels would emit
      /// an empty fragment, and a page whose fragment paints nothing measures
      /// zero tall and would land on the same page as the next one.
      int lineStart(int n) {
        if (n <= 0) return 0;
        if (n >= lines.length) return text.length;
        final hinted = painter
            .getLineBoundary(
              painter.getPositionForOffset(
                Offset(
                  0,
                  lines[n].baseline - lines[n].ascent + lines[n].height / 2,
                ),
              ),
            )
            .start;
        // A boundary is usable only when the glyph starting there paints.
        final firstBox = painter.getBoxesForSelection(
          TextSelection(baseOffset: hinted, extentOffset: hinted + 1),
        );
        if (firstBox.isNotEmpty && firstBox.first.toRect().height > 0) {
          return hinted;
        }
        // The reported boundary runs no glyph, so search forward for the first
        // offset that does start a painted line.
        for (var offset = hinted; offset < text.length; offset++) {
          final height = boxOf(painter, offset, offset + 1).height;
          if (height > 0) return offset;
        }
        return text.length;
      }

      final starts = <int>[
        for (var n = 0; n <= lines.length; n++) lineStart(n),
      ];
      var line = 0;
      // A chunk may end at a source newline. Its final empty metric is not a
      // second displayed line; the newline is retained in the source range.
      final count = text.endsWith('\n') && lines.length > 1
          ? lines.length - 1
          : lines.length;
      final exact = TextPainter(
        textDirection: direction,
        textScaler: scaler,
        strutStyle: strut,
        textHeightBehavior: heightBehavior,
      );
      double measured(int first, int last) {
        final candidate = TextPageFragment(
          paragraph,
          0,
          0,
          text.substring(
            starts[first],
            last == count ? text.length : starts[last],
          ),
          0,
        );
        exact.text = TextSpan(text: candidate.displayText, style: style);
        exact.layout(maxWidth: width);
        final result = exact.height;
        return result;
      }

      while (line < count) {
        var low = line + 1, high = count, best = line;
        while (low <= high) {
          final middle = (low + high) ~/ 2;
          if (used + measured(line, middle) <= height + .01) {
            best = middle;
            low = middle + 1;
          } else {
            high = middle - 1;
          }
        }
        if (best == line && fragments.any((f) => !f.sourceOnly)) {
          finish();
          continue;
        }
        if (best == line) best = line + 1;
        final end = best == count ? text.length : starts[best];
        final fragmentHeight = measured(line, best);
        final gap = best == count && chunk.end == paragraphs[paragraph].length
            ? paragraphGap
            : 0.0;
        if (end > starts[line]) {
          fragments.add(
            TextPageFragment(
              paragraph,
              chunk.start + starts[line],
              chunk.start + end,
              text.substring(starts[line], end),
              gap,
            ),
          );
        }
        used += fragmentHeight + gap;
        line = best;
        if (line < count) finish();
      }
      painter.dispose();
      exact.dispose();
    }
    finish();
    if (pages.isEmpty && fragments.isNotEmpty) {
      pages.add(ReaderTextPage(fragments, reserved: reserved));
    }
    yield TextPagination._(
      viewport,
      padding,
      style,
      scaler,
      direction,
      backgroundColor,
      List.unmodifiable(pages),
    );
  }

  /// Lays text out inside the area this renderer actually controls, keeping
  /// [takenByReadout] free at the foot for the shell's one shared controller.
  /// Page space still comes only from measured lines, so a short page stays
  /// short instead of turning every paragraph into a page of its own.
  factory TextPagination.forReader({
    required List<String> paragraphs,
    required Size viewport,
    required TextStyle style,
    required TextScaler scaler,
    required TextDirection direction,
    required double margin,
    required double paragraphGap,
    double takenByReadout = 0,
    Iterable<(int, int)> chapterStarts = const [],
    Color? backgroundColor,
  }) => TextPagination.layout(
    paragraphs: paragraphs,
    viewport: viewport,
    style: style,
    scaler: scaler,
    direction: direction,
    margin: margin,
    paragraphGap: paragraphGap,
    reserved: takenByReadout,
    chapterStarts: chapterStarts,
    backgroundColor: backgroundColor,
  );

  bool covers(int paragraph, int offset) => pages.any(
    (page) => page.fragments.any(
      (f) => f.paragraph == paragraph && offset >= f.start && offset <= f.end,
    ),
  );

  /// First page holding each paragraph, so a lookup starts at the right page
  /// instead of scanning the whole book; lookups run on every reader build.
  late final List<int> _firstPage = () {
    var last = -1;
    for (final page in pages) {
      for (final f in page.fragments) {
        if (f.paragraph > last) last = f.paragraph;
      }
    }
    final first = List<int>.filled(last + 1, -1);
    for (var i = 0; i < pages.length; i++) {
      for (final f in pages[i].fragments) {
        if (first[f.paragraph] < 0) first[f.paragraph] = i;
      }
    }
    return first;
  }();

  /// The page showing character [offset] of [paragraph]. An offset past the
  /// paragraph's last fragment resolves to its last page; a paragraph that
  /// paints nothing resolves to the page of the next paragraph that does.
  int pageFor(int paragraph, [int offset = 0]) {
    if (pages.isEmpty || paragraph < 0) return 0;
    if (paragraph >= _firstPage.length) return pages.length - 1;
    final start = _firstPage[paragraph];
    if (start < 0) {
      for (var next = paragraph + 1; next < _firstPage.length; next++) {
        if (_firstPage[next] >= 0) return _firstPage[next];
      }
      return pages.length - 1;
    }
    var lastMatch = start;
    for (var i = start; i < pages.length; i++) {
      var holds = false;
      for (final f in pages[i].fragments) {
        if (f.paragraph != paragraph) continue;
        holds = true;
        lastMatch = i;
        if (offset >= f.start &&
            (offset < f.end || (offset == f.end && f.start == f.end))) {
          return i;
        }
      }
      // Fragments of one paragraph sit on consecutive pages.
      if (!holds) break;
    }
    return lastMatch;
  }
}

class ReaderTextPageView extends StatelessWidget {
  final TextPagination layout;
  final int index;
  final bool preview;
  final EditableTextContextMenuBuilder? contextMenuBuilder;
  final ValueChanged<bool>? onSelectionActive;
  const ReaderTextPageView({
    super.key,
    required this.layout,
    required this.index,
    this.preview = false,
    this.contextMenuBuilder,
    this.onSelectionActive,
  });
  @override
  Widget build(BuildContext context) {
    final fragments = layout.pages[index].fragments
        .where((f) => !f.sourceOnly)
        .toList();
    final paper = ColoredBox(
      color:
          layout.backgroundColor ?? Theme.of(context).scaffoldBackgroundColor,
      child: Padding(
        padding: layout.padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final fragment in fragments)
              Padding(
                padding: EdgeInsets.only(
                  bottom: identical(fragment, fragments.last)
                      ? 0
                      : fragment.gapAfter,
                ),
                child: preview
                    ? Padding(
                        padding: const EdgeInsets.only(
                          right: TextPagination.selectionGutter,
                        ),
                        child: Text(
                          fragment.displayText,
                          style: layout.style,
                          textScaler: layout.scaler,
                          textDirection: layout.direction,
                          strutStyle: StrutStyle.fromTextStyle(layout.style),
                          textHeightBehavior: const TextHeightBehavior(),
                        ),
                      )
                    : SelectableText(
                        cursorWidth: 2,
                        fragment.displayText,
                        style: layout.style,
                        textScaler: layout.scaler,
                        textDirection: layout.direction,
                        strutStyle: StrutStyle.fromTextStyle(layout.style),
                        textHeightBehavior: const TextHeightBehavior(),
                        contextMenuBuilder: contextMenuBuilder,
                        onSelectionChanged: (selection, _) =>
                            onSelectionActive?.call(!selection.isCollapsed),
                      ),
              ),
          ],
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.hasBoundedWidth &&
            constraints.hasBoundedHeight &&
            ((constraints.maxWidth - layout.viewport.width).abs() > .1 ||
                (constraints.maxHeight - layout.viewport.height).abs() > .1)) {
          return FittedBox(
            fit: BoxFit.contain,
            child: SizedBox(
              width: layout.viewport.width,
              height: layout.viewport.height,
              child: paper,
            ),
          );
        }
        return paper;
      },
    );
  }
}

class PagedTextController {
  _PagedTextReaderState? _state;
  bool get attached => _state != null;

  /// The settled page the view shows, or null before it has a viewport.
  int? get page {
    final pages = _state?.pages;
    if (pages == null || !pages.hasClients) return null;
    return pages.page?.round();
  }

  void goTo(int page, {required bool animate}) =>
      _state?.goTo(page, animate: animate);
}

class PagedTextReader extends StatefulWidget {
  final String effect;
  final TextPagination layout;
  final PagedTextController controller;
  final int initialPage;
  final bool rightToLeft;
  final ValueChanged<int> onPage;
  final EditableTextContextMenuBuilder? contextMenuBuilder;
  final ValueChanged<bool>? onSelectionActive;
  const PagedTextReader({
    super.key,
    required this.layout,
    this.effect = 'slide',
    required this.controller,
    required this.initialPage,
    required this.onPage,
    this.rightToLeft = false,
    this.contextMenuBuilder,
    this.onSelectionActive,
  });
  @override
  State<PagedTextReader> createState() => _PagedTextReaderState();
}

class _PagedTextReaderState extends State<PagedTextReader> {
  late PageController pages = PageController(initialPage: widget.initialPage);
  @override
  void initState() {
    super.initState();
    widget.controller._state = this;
  }

  @override
  void dispose() {
    if (identical(widget.controller._state, this)) {
      widget.controller._state = null;
    }
    pages.dispose();
    super.dispose();
  }

  void goTo(int page, {required bool animate}) {
    if (!pages.hasClients) return;
    if (!animate || MediaQuery.disableAnimationsOf(context)) {
      pages.jumpToPage(page);
    } else {
      pages.animateToPage(
        page,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => PageView.builder(
      controller: pages,
      reverse: widget.rightToLeft,
      itemCount: widget.layout.pages.length,
      onPageChanged: widget.onPage,
      itemBuilder: (context, index) => AnimatedBuilder(
        animation: pages,
        child: ReaderTextPageView(
          layout: widget.layout,
          index: index,
          contextMenuBuilder: widget.contextMenuBuilder,
          onSelectionActive: widget.onSelectionActive,
        ),
        builder: (context, child) {
          if (widget.effect == 'slide' ||
              MediaQuery.disableAnimationsOf(context)) {
            return child!;
          }
          final delta =
              index -
              (pages.hasClients && pages.position.hasContentDimensions
                  ? pages.page ?? widget.initialPage.toDouble()
                  : widget.initialPage.toDouble());
          return ReaderPageEffect(
            effect: widget.effect,
            delta: delta,
            width: constraints.maxWidth,
            rightToLeft: widget.rightToLeft,
            child: child!,
          );
        },
      ),
    ),
  );
}
