// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aquantum_reader/reader/reader_contract.dart';
import 'package:aquantum_reader/reader/reader_renderers.dart';
import 'package:aquantum_reader/reader/text_pagination.dart';
import 'package:aquantum_reader/reader/reader_panels.dart';
import 'package:aquantum_reader/screens/reader_screen.dart';
import 'reader_shell_test.dart' show book;
import 'reader_landscape_test.dart' show LongTextApi;

void main() {
  testWidgets(
    'chapter navigation uses chapter titles and their measured pages',
    (tester) async {
      final paragraphs = [
        '第一章 风起',
        List.filled(500, '正文不是章节名称。').join(),
        '第二章 归途',
        List.filled(500, '更多正文。').join(),
      ];
      final layout = TextPagination.layout(
        paragraphs: paragraphs,
        viewport: const Size(375, 1100),
        style: const TextStyle(fontSize: 20, height: 1.9),
        scaler: TextScaler.noScaling,
        direction: TextDirection.ltr,
        margin: 28,
        paragraphGap: 24,
      );
      final adapter = PagedTextReaderAdapter(
        book: book('Txt'),
        position: 0,
        status: '',
        content: (_) => const SizedBox(),
        onGo: (_) {},
        locked: () => false,
        layout: layout,
        paragraphs: paragraphs,
        entries: const [
          ReaderOutlineEntry(0, '第一章 风起', 1),
          ReaderOutlineEntry(2, '第二章 归途', 1),
        ],
        rightToLeft: false,
        animatePageTurns: false,
      );
      expect(adapter.outline.length, 2);
      expect(adapter.outline[1].index, layout.pageFor(2));
      expect(adapter.location(1).label, contains('第一章 风起'));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReaderNavigationPanel(adapter: adapter, onSelect: (_) {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final tile = tester.widget<ListTile>(
        find.byKey(const ValueKey('reader-navigation-item-1')),
      );
      expect((tile.leading as Text).data, '第 ${layout.pageFor(2) + 1} 页');
      expect((tile.title as Text).data, '第二章 归途');
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final height in [1000.0, 1250.0]) {
    testWidgets('tall phone $height uses full immersive pagination height', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = Size(375, height);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderScreen(
            api: LongTextApi(),
            book: book('Txt'),
            initialPosition: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final layout = tester
          .widget<PagedTextReader>(find.byType(PagedTextReader))
          .layout;
      expect(layout.padding.bottom, 24);
      expect(layout.pages.first.reserved, 0);
      await tester.pumpWidget(
        MaterialApp(home: ReaderTextPageView(layout: layout, index: 0)),
      );
      await tester.pumpAndSettle();
      final bottom = tester.getRect(find.byType(SelectableText).last).bottom;
      expect(height - bottom, lessThan(24 + 20 * 1.9 + 2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }
}
