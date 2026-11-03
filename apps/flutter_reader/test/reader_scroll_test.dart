// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';

import 'package:aquantum_reader/reader/continuous_progress.dart';
import 'package:aquantum_reader/reader/reader_contract.dart';
import 'package:aquantum_reader/reader/reader_scrollbar.dart';
import 'package:aquantum_reader/reader/reader_shell.dart';
import 'package:aquantum_reader/reader/text_pagination.dart';
import 'package:aquantum_reader/screens/reader_screen.dart';
import 'package:aquantum_reader/widgets/reader_settings.dart';
import 'package:aquantum_reader/widgets/text_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'library_test.dart' show TestApi;
import 'reader_shell_test.dart' show book;

/// A book whose paragraphs differ wildly in length, so progress by paragraph
/// count and progress by content length disagree.
class UnevenTextApi extends TestApi {
  static final paragraphs = [
    for (var i = 0; i < 40; i++)
      i == 5 ? List.filled(400, '很长的一段文字，用来检查段内位置。').join() : '第 $i 段，短。',
  ];
  @override
  Future<dynamic> call(String method, [Map<String, dynamic> args = const {}]) =>
      method == 'read_text'
      ? Future.value({'paragraphs': paragraphs})
      : super.call(method, args);
}

Future<void> openScrolling(WidgetTester tester, TestApi api) async {
  SharedPreferences.setMockInitialValues({});
  await (ReaderPreferences()..textPaged = false).save(bookId: 'test-Txt');
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: ReaderScreen(api: api, book: book('Txt'), initialPosition: 0),
    ),
  );
  await tester.pumpAndSettle();
}

ReaderScrollMetrics metricsOf(WidgetTester tester) =>
    tester.widget<ReaderShell>(find.byType(ReaderShell)).scroll!.metrics.value;

double thumbOpacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(
      find.descendant(
        of: find.byType(ReaderScrollbar),
        matching: find.byType(AnimatedOpacity),
      ),
    )
    .opacity;

void main() {
  test('whole-book progress follows content length, not item count', () {
    final progress = WeightedProgress([10, 90, 100]);
    expect(progress.fractionAt(1, 0), .05);
    expect(progress.fractionAt(1, .5), closeTo(.275, 1e-9));
    expect(progress.fractionAt(2, 1), 1);
    // 40% of the book is inside the long middle item, not "item 1 of 3".
    final (item, within) = progress.locate(.4);
    expect(item, 1);
    expect(within, closeTo(70 / 90, 1e-9));
    expect(progress.locate(.5), (2, 0.0));
    expect(progress.locate(0), (0, 0.0));
    expect(progress.locate(1).$1, 2);
  });

  test('thumb follows the share on screen within a minimum and a maximum', () {
    const track = 600.0;
    // A long book: the share on screen is tiny, the thumb keeps its minimum.
    expect(ReaderScrollbar.thumbExtent(track, .001), ReaderScrollbar.minThumb);
    // In between it is proportional, as in a browser.
    expect(ReaderScrollbar.thumbExtent(track, .2), 120);
    // A short book never fills the track.
    expect(
      ReaderScrollbar.thumbExtent(track, .9),
      track * ReaderScrollbar.maxThumbShare,
    );
    // Unknown share: the minimum.
    expect(ReaderScrollbar.thumbExtent(track, null), ReaderScrollbar.minThumb);
    // A screen can only start at 1 - viewport, which is the bottom of travel.
    expect(
      ReaderScrollbar.travelOf(const ReaderScrollMetrics(.75, .25)),
      closeTo(1, 1e-9),
    );
    expect(ReaderScrollbar.fractionOf(1, .25), .75);
  });

  testWidgets('scrolling text stops anywhere, never snaps, and has no '
      'bottom controller', (tester) async {
    await openScrolling(tester, UnevenTextApi());
    expect(find.byType(TextReader), findsOneWidget);
    expect(find.byType(Slider), findsNothing, reason: 'no bottom controller');
    expect(find.byType(ReaderScrollbar), findsOneWidget);
    // The scrollbar stays out of the way until the text moves.
    expect(thumbOpacity(tester), 0);
    final title = find.descendant(
      of: find.byType(TextReader),
      matching: find.text('统一阅读器'),
    );
    final before = tester.getTopLeft(title).dy;
    await tester.drag(find.byType(TextReader), const Offset(0, -137));
    await tester.pumpAndSettle();
    final moved = before - tester.getTopLeft(title).dy;
    // Wherever the finger let go — not a paragraph start, not a screen.
    expect(moved, greaterThan(100));
    expect(moved, lessThan(140));
    await tester.pump();
    expect(thumbOpacity(tester), 1, reason: 'scrolling shows the scrollbar');
    await tester.pump(ReaderScrollbar.visibleFor + const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(thumbOpacity(tester), 0, reason: 'it fades once scrolling stops');
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('a tap on scrolling text never jumps it', (tester) async {
    final api = UnevenTextApi();
    await openScrolling(tester, api);
    final title = find.descendant(
      of: find.byType(TextReader),
      matching: find.text('统一阅读器'),
    );
    final before = tester.getTopLeft(title).dy;
    for (final point in const [Offset(20, 400), Offset(380, 400)]) {
      await tester.tapAt(point);
      await tester.pumpAndSettle();
      await tester.tapAt(point);
      await tester.pumpAndSettle();
    }
    expect(tester.getTopLeft(title).dy, before);
    expect(api.position, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('the scrollbar spans the whole book by content length', (
    tester,
  ) async {
    final api = UnevenTextApi();
    await openScrolling(tester, api);
    final weights = UnevenTextApi.paragraphs.map(TextReader.weightOf);
    final progress = WeightedProgress(weights);
    // Half the book by length is deep inside the one long paragraph, though
    // by count it would be paragraph 20.
    tester
        .widget<ReaderShell>(find.byType(ReaderShell))
        .scroll!
        .seek(progress.fractionAt(5, .5));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    final metrics = metricsOf(tester);
    expect(metrics.fraction, closeTo(progress.fractionAt(5, .5), .02));
    expect(api.position, 5, reason: 'the reached paragraph is saved');
    final prefs = await SharedPreferences.getInstance();
    final anchor = jsonDecode(
      prefs.getString('reader-text-anchor.v1.test-Txt')!,
    );
    expect(anchor['paragraph'], 5);
    // The place inside the long paragraph is kept, not its first line.
    expect(
      anchor['offset'] / UnevenTextApi.paragraphs[5].length,
      closeTo(.5, .05),
    );
    // Dragging the thumb to the bottom reaches the end of the book.
    final bar = tester.getRect(find.byType(ReaderScrollbar));
    final gesture = await tester.startGesture(bar.center);
    await tester.pump();
    await gesture.moveTo(Offset(bar.center.dx, bar.bottom + 50));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    final end = metricsOf(tester);
    expect(end.fraction + (end.viewport ?? 0), closeTo(1, .02));
    expect(
      tester
          .widgetList<ScrollablePositionedList>(
            find.byType(ScrollablePositionedList),
          )
          .length,
      1,
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('switching to pages lands on the page holding the place read '
      'inside a long paragraph', (tester) async {
    final api = UnevenTextApi();
    await openScrolling(tester, api);
    final progress = WeightedProgress(
      UnevenTextApi.paragraphs.map(TextReader.weightOf),
    );
    tester
        .widget<ReaderShell>(find.byType(ReaderShell))
        .scroll!
        .seek(progress.fractionAt(5, .6));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    // Open the settings and switch to left/right paging.
    await tester.tapAt(const Offset(200, 400));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('阅读设置'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('左右翻页'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('左右翻页'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭面板'));
    await tester.pumpAndSettle();
    final paged = tester.widget<PagedTextReader>(
      find.byType(PagedTextReader, skipOffstage: false),
    );
    final shell = tester.widget<ReaderShell>(find.byType(ReaderShell));
    final first = paged.layout.pageFor(5);
    final last = paged.layout.pages.lastIndexWhere(
      (p) => p.fragments.any((f) => f.paragraph == 5),
    );
    expect(last, greaterThan(first + 2), reason: 'the paragraph spans pages');
    // Not the paragraph's first page: the page with the words being read.
    expect(shell.adapter.position, greaterThan(first));
    expect(shell.adapter.position, lessThanOrEqualTo(last));
    expect(shell.scroll, isNull, reason: 'paging has no scrollbar');
    expect(find.byType(ReaderScrollbar), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
