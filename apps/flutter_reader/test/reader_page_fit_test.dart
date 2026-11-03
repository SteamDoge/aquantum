// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aquantum_reader/screens/reader_screen.dart';
import 'reader_landscape_test.dart' show LongTextApi;
import 'reader_shell_test.dart' show book;
import 'package:flutter_test/flutter_test.dart';
import 'package:aquantum_reader/reader/text_pagination.dart';
import 'package:aquantum_reader/reader/reader_page_overview.dart';
import 'package:aquantum_reader/design/widgets.dart';
import 'reader_p01_test.dart' show LayoutSwapAdapter;

void main() {
  testWidgets('keyboard overlay preserves the measured reading canvas', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    addTearDown(tester.view.resetViewPadding);
    addTearDown(tester.view.resetPadding);
    SharedPreferences.setMockInitialValues({});
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
    final page = find.byType(ReaderTextPageView).first;
    final originalSize = tester.getSize(page);
    final originalLayout = tester.widget<ReaderTextPageView>(page).layout;
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    tester.view.padding = const FakeViewPadding(top: 24);
    await tester.pumpAndSettle();
    expect(tester.getSize(page), originalSize);
    expect(
      tester.widget<ReaderTextPageView>(page).layout,
      same(originalLayout),
    );
    expect(tester.takeException(), isNull);
    tester.view.resetViewInsets();
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    await tester.pumpAndSettle();
    expect(tester.getSize(page), originalSize);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('article night mode does not recolor light application chrome', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'reader-ui.v2.test-Txt': '{"version":1,"theme":"navy"}',
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.light(),
        home: ReaderScreen(
          api: LongTextApi(),
          book: book('Txt'),
          initialPosition: 0,
        ),
      ),
    );
    for (var i = 0; i < 80; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      if (find.byType(PagedTextReader).evaluate().isNotEmpty) break;
    }
    await tester.pumpAndSettle();
    final toolbarIcon = tester.element(find.byIcon(Icons.format_list_bulleted));
    expect(IconTheme.of(toolbarIcon).color, isNot(Colors.white));
    final page = find.byType(ReaderTextPageView).first;
    final canvas = tester.widget<ColoredBox>(
      find.descendant(of: page, matching: find.byType(ColoredBox)).first,
    );
    expect(canvas.color, const Color(0xff1c2833));
    expect(Theme.of(toolbarIcon).brightness, Brightness.light);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'whitespace page across source paragraphs is retained without an empty visual page',
    (tester) async {
      final paragraphs = [
        '${List.filled(60, '文').join()}\n　　',
        '第二章 新页\n${List.filled(80, '后文').join()}',
      ];
      final layout = TextPagination.layout(
        paragraphs: paragraphs,
        viewport: const Size(359, 278),
        style: const TextStyle(fontSize: 23, height: 1.9, letterSpacing: .3),
        scaler: TextScaler.noScaling,
        direction: TextDirection.ltr,
        margin: 28,
        paragraphGap: 24,
        chapterStarts: const [(1, 0)],
      );
      expect(
        layout.pages.every(
          (p) => p.fragments.any((f) => f.text.trim().isNotEmpty),
        ),
        isTrue,
      );
      for (var p = 0; p < paragraphs.length; p++) {
        expect(
          [
            for (final page in layout.pages)
              for (final f in page.fragments)
                if (f.paragraph == p) f.text,
          ].join(),
          paragraphs[p],
        );
      }
      for (var i = 0; i < layout.pages.length; i++) {
        await tester.pumpWidget(
          MaterialApp(
            home: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 359,
                height: 278,
                child: ReaderTextPageView(
                  key: ValueKey(i),
                  layout: layout,
                  index: i,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(SelectableText), findsWidgets);
      }
    },
  );

  test('chapter indentation cannot become a blank page after a full page', () {
    final before = '${List.filled(60, '文').join()}\n　　';
    final text = '$before第二章 新页\n${List.filled(70, '后文').join()}';
    final layout = TextPagination.layout(
      paragraphs: [text],
      viewport: const Size(359, 278),
      style: const TextStyle(fontSize: 23, height: 1.9, letterSpacing: .3),
      scaler: TextScaler.noScaling,
      direction: TextDirection.ltr,
      margin: 28,
      paragraphGap: 24,
      chapterStarts: [(0, before.length)],
    );
    expect(
      layout.pages.every(
        (p) => p.fragments.any((f) => f.text.trim().isNotEmpty),
      ),
      isTrue,
    );
    expect(
      layout.pages[layout.pageFor(0, before.length)].anchor.text.trimLeft(),
      startsWith('第二章 新页'),
    );
    expect(
      [
        for (final page in layout.pages)
          for (final f in page.fragments) f.text,
      ].join(),
      text,
    );
  });

  testWidgets(
    'per-book night palette leaves light toolbar and system icons readable',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'reader-ui.v2.test-Txt': '{"version":1,"theme":"navy"}',
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: ReaderScreen(
            api: LongTextApi(),
            book: book('Txt'),
            initialPosition: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final icon = tester.element(find.byIcon(Icons.format_list_bulleted));
      expect(IconTheme.of(icon).color!.computeLuminance(), lessThan(.5));
      expect(
        Theme.of(icon).scaffoldBackgroundColor.computeLuminance(),
        greaterThan(.5),
      );
      final overlays = tester.widgetList<AnnotatedRegion<SystemUiOverlayStyle>>(
        find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
      );
      expect(
        overlays.any((o) => o.value.statusBarIconBrightness == Brightness.dark),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final dark in [false, true]) {
    testWidgets('overview keeps four soft paper edges at 1dp dark=$dark', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: dark ? Brightness.dark : Brightness.light,
          ),
          home: SizedBox.expand(
            child: ReaderPageOverview(
              adapter: LayoutSwapAdapter(3, 0, []),
              pageSize: const Size(393, 852),
              onActivate: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final paper = find.byKey(const ValueKey('reader-overview-page-0'));
      expect(tester.getSize(paper), const Size(393, 852));
      final box = tester.widget<DecoratedBox>(
        find.descendant(of: paper, matching: find.byType(DecoratedBox)).first,
      );
      expect(box.position, DecorationPosition.foreground);
      final border = (box.decoration as BoxDecoration).border! as Border;
      expect(border.left, border.right);
      expect(border.top, border.left);
      expect(border.bottom, border.left);
      final background = Theme.of(
        tester.element(paper),
      ).scaffoldBackgroundColor;
      expect(border.left.color, readerPaperEdge(background));
      expect(border.left.color, isNot(dark ? Colors.white : Colors.black));
      final scale = tester.getRect(paper).width / 393;
      expect(border.left.width * scale, closeTo(1, .01));
      expect(border.top.width * scale, closeTo(1, .01));
      expect(border.bottom.width * scale, closeTo(1, .01));
    });
  }

  for (final width in [359.0, 393.0]) {
    for (final scale in [1.0, 1.8]) {
      testWidgets(
        'all page glyphs fit width=$width scale=$scale without vertical scroll',
        (tester) async {
          final size = Size(width, 1000);
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final paragraphs = [
            List.filled(
              70,
              '　　进了寺门，诸葛天申道：“且到我们下处坐坐。”杜慎卿道：“也好。”一同来到下院。\n',
            ).join(),
            List.filled(500, '正文').join(),
          ];
          final layout = TextPagination.layout(
            paragraphs: paragraphs,
            viewport: size,
            style: const TextStyle(
              fontSize: 23,
              height: 1.9,
              letterSpacing: .3,
            ),
            scaler: TextScaler.linear(scale),
            direction: TextDirection.ltr,
            margin: 28,
            paragraphGap: 24,
          );
          for (var p = 0; p < paragraphs.length; p++) {
            expect(
              [
                for (final page in layout.pages)
                  for (final f in page.fragments)
                    if (f.paragraph == p) f.text,
              ].join(),
              paragraphs[p],
            );
          }
          for (var i = 0; i < layout.pages.length; i++) {
            await tester.pumpWidget(
              MaterialApp(
                home: ReaderTextPageView(
                  key: ValueKey(i),
                  layout: layout,
                  index: i,
                ),
              ),
            );
            await tester.pumpAndSettle();
            expect(find.byType(SingleChildScrollView), findsNothing);
            final last = tester.getRect(find.byType(SelectableText).last);
            expect(
              last.bottom,
              lessThanOrEqualTo(size.height - layout.padding.bottom + .1),
              reason: 'page $i',
            );
            for (final scroll in tester.stateList<ScrollableState>(
              find.byType(Scrollable),
            )) {
              expect(
                scroll.position.maxScrollExtent,
                0,
                reason: 'page $i must not scroll inside',
              );
            }
            expect(tester.takeException(), isNull);
          }
        },
      );
    }
  }
  test(
    'chapter anchors inside a single paragraph begin new pages with exact source continuity',
    () async {
      final before = '${List.filled(73, '上一章正文。').join()}\n';
      final chapter = '第三十回 愛少俊訪友神樂觀 逞風流高會莫愁湖\n';
      final text = before + chapter + List.filled(150, '后续正文。').join();
      final layout = await TextPagination.layoutAsync(
        paragraphs: [text],
        viewport: const Size(393, 1000),
        style: const TextStyle(fontSize: 23, height: 1.9),
        scaler: TextScaler.noScaling,
        direction: TextDirection.ltr,
        margin: 28,
        paragraphGap: 24,
        chapterStarts: [(0, before.length)],
        onPreview: (preview) {
          final page = preview.pages[preview.pageFor(0, before.length)];
          expect(page.anchor.start, before.length);
        },
      );
      final page = layout.pages[layout.pageFor(0, before.length)];
      expect(page.anchor.start, before.length);
      expect(page.anchor.text, startsWith(chapter));
      expect(
        [
          for (final page in layout.pages)
            for (final f in page.fragments) f.text,
        ].join(),
        text,
      );
    },
  );
}
