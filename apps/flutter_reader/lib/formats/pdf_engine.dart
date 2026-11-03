// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import 'dart:ui' as ui;
import 'package:pdfrx/pdfrx.dart';
import '../data/models.dart';
import '../reader/reader_contract.dart';

/// PDFium owns its native worker. This session bounds auxiliary search/thumbnail
/// work and invalidates results on close; pixels never cross the JSON bridge.
class PdfEngineSession {
  final PdfDocument document;
  final Book book;
  bool closed = false;
  int generation = 0;
  Future<void> _pending = Future.value();
  int queued = 0;
  final Map<int, List<PdfRect>> highlights = {};
  PdfEngineSession(this.document, this.book);
  Future<T> serial<T>(Future<T> Function() action) {
    if (closed || queued >= 64) {
      return Future.error(StateError('PDF 任务队列已关闭或繁忙，请稍后重试'));
    }
    queued++;
    final result = _pending.then((_) {
      if (closed) throw StateError('PDF 会话已关闭');
      return action();
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result.whenComplete(() => queued--);
  }

  Future<List<ReaderSearchHit>> search(String query) async {
    final current = ++generation;
    highlights.clear();
    if (query.trim().isEmpty) return [];
    if (query.length > 200) throw const FormatException('搜索词最多 200 字符。');
    final pattern = RegExp(RegExp.escape(query), caseSensitive: false);
    final hits = <ReaderSearchHit>[];
    // One page per worker turn, yielding to visible-page work between pages.
    for (var i = 0; i < document.pages.length && hits.length < 100; i++) {
      if (closed || current != generation) return [];
      await serial(() async {
        if (!document.pages[i].isLoaded) {
          await document.reloadPages(pageNumbersToReload: [i + 1]);
        }
        final page = await document.pages[i].ensureLoaded();
        final text = await page.loadText();
        if (text == null || closed || current != generation) return;
        for (final match in pattern.allMatches(text.fullText)) {
          final rect = text.charRects.boundingRect(
            start: match.start,
            end: match.end,
          );
          (highlights[i] ??= []).add(rect);
          final start = (match.start - 45).clamp(0, text.fullText.length);
          final end = (match.end + 100).clamp(start, text.fullText.length);
          hits.add(
            ReaderSearchHit(
              ReaderLocation('page:${book.pages[i]['id']}', '第 ${i + 1} 页', i),
              text.fullText.substring(start, end),
            ),
          );
          if (hits.length == 100) break;
        }
      });
      await Future<void>.delayed(Duration.zero);
    }
    return hits;
  }

  Future<ui.Image?> region(
    int index,
    Map<String, dynamic> crop,
    double targetWidth,
  ) => serial(() async {
    if (!document.pages[index].isLoaded) {
      await document.reloadPages(pageNumbersToReload: [index + 1]);
    }
    final page = await document.pages[index].ensureLoaded();
    double inset(String name) => (crop[name] as num?)?.toDouble() ?? 0;
    final visibleWidth = 1 - inset('left') - inset('right');
    final visibleHeight = 1 - inset('top') - inset('bottom');
    // Limit native allocation even for extreme page dimensions and 10% crops.
    var scale = targetWidth.clamp(128, 2048) / (page.width * visibleWidth);
    final height = page.height * visibleHeight * scale;
    if (height > 4096) scale *= 4096 / height;
    final fullWidth = page.width * scale, fullHeight = page.height * scale;
    final pixels = await page.render(
      x: (inset('left') * fullWidth).round(),
      y: (inset('top') * fullHeight).round(),
      width: (fullWidth * visibleWidth).round().clamp(1, 2048),
      height: (fullHeight * visibleHeight).round().clamp(1, 4096),
      fullWidth: fullWidth,
      fullHeight: fullHeight,
    );
    if (pixels == null) return null;
    try {
      return await pixels.createImage();
    } finally {
      pixels.dispose();
    }
  });

  Future<ui.Image?> thumbnail(int index) => serial(() async {
    if (!document.pages[index].isLoaded) {
      await document.reloadPages(pageNumbersToReload: [index + 1]);
    }
    final page = await document.pages[index].ensureLoaded();
    final pixels = await page.render(
      fullWidth: 128,
      fullHeight: page.height / page.width * 128,
    );
    if (pixels == null) return null;
    try {
      return await pixels.createImage();
    } finally {
      pixels.dispose();
    }
  });
  void paint(ui.Canvas canvas, ui.Rect pageRect, PdfPage page) {
    for (final rect in highlights[page.pageNumber - 1] ?? <PdfRect>[]) {
      canvas.drawRect(
        rect
            .toRect(page: page, scaledPageSize: pageRect.size)
            .translate(pageRect.left, pageRect.top),
        ui.Paint()..color = const ui.Color(0x70FFCC00),
      );
    }
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    generation++;
    await _pending;
    await document.dispose();
  }
}
