// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/data/models.dart';
import 'package:aquantum_reader/screens/reader_screen.dart';
import 'package:aquantum_reader/reader/text_pagination.dart';
import 'package:aquantum_reader/reader/reader_contract.dart';
import 'package:aquantum_reader/reader/reader_shell.dart';
import 'package:aquantum_reader/reader/reader_panels.dart';
import 'package:aquantum_reader/widgets/article_settings_panel.dart';
import 'qa_storage.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'reference TXT imports and compact Aa settings stay independent from reading mode',
    (tester) async {
      await configureQaStorage();
      await Directory(
        Platform.environment['AQ_SCREENSHOT_DIR']!,
      ).create(recursive: true);
      final sample = File(Platform.environment['AQ_ARTICLE_SAMPLE']!);
      final original = await sample.readAsBytes();
      final api = RustReaderApi(
        '${Platform.environment['AQ_TEST_SUPPORT']}/article-library',
      );
      final snapshot = await api.call('snapshot');
      await api.call('import_files', {
        'target': snapshot['catalog']['inbox'],
        'files': [
          {'name': '儒林外史.txt', 'data': base64Encode(original)},
        ],
      });
      final library = LibrarySnapshot(
        Map<String, dynamic>.from(await api.call('snapshot')),
      );
      final book = library.books.single;
      final key = GlobalKey();
      Future<void> settle() async {
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 10),
        );
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle(
          const Duration(milliseconds: 100),
          EnginePhase.sendSemanticsUpdate,
          const Duration(seconds: 10),
        );
      }

      Future<void> shot(String name) async {
        debugPrint('REFERENCE_CAPTURE $name');
        final target =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final picture = await target
              .toImage(pixelRatio: 1.5)
              .timeout(const Duration(seconds: 10));
          final data = await picture
              .toByteData(format: ui.ImageByteFormat.png)
              .timeout(const Duration(seconds: 10));
          await File(
            '${Platform.environment['AQ_SCREENSHOT_DIR']}/$name.png',
          ).writeAsBytes(data!.buffer.asUint8List());
          picture.dispose();
        });
      }

      await tester.pumpWidget(
        MaterialApp(
          home: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 390,
              height: 1000,
              child: RepaintBoundary(
                key: key,
                child: MaterialApp(
                  home: ReaderScreen(api: api, book: book, initialPosition: 0),
                ),
              ),
            ),
          ),
        ),
      );
      for (
        var i = 0;
        i < 1200 &&
            find
                .byType(PagedTextReader, skipOffstage: false)
                .evaluate()
                .isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      if (find
          .byType(PagedTextReader, skipOffstage: false)
          .evaluate()
          .isEmpty) {
        await shot('opening-diagnostic');
        debugPrint(
          'OPEN_DIAGNOSTIC: ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data?.substring(0, (t.data!.length).clamp(0, 200)))}',
        );
      }
      expect(find.byType(PagedTextReader, skipOffstage: false), findsOneWidget);
      for (var i = 0; i < 2000; i++) {
        final current = tester.widget<PagedTextReader>(
          find.byType(PagedTextReader, skipOffstage: false),
        );
        if (current.layout.complete) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await settle();
      final layout = tester
          .widget<PagedTextReader>(
            find.byType(PagedTextReader, skipOffstage: false),
          )
          .layout;
      expect(layout.pages.length, greaterThan(100));
      expect(layout.padding.bottom, 24);
      await tester.tapAt(const Offset(195, 250));
      await settle();
      await shot('reading');
      await tester.tapAt(const Offset(195, 60));
      await settle();
      await tester.tap(find.byTooltip('目录与内容导航'));
      await settle();
      final nav = tester.widget<ReaderNavigationPanel>(
        find.byType(ReaderNavigationPanel),
      );
      final outline = (nav.adapter as dynamic).outline as List;
      expect(outline.length, greaterThanOrEqualTo(40));
      expect(outline.first.label, contains('第一回'));
      await shot('chapters');
      for (final entry in outline) {
        final page = layout.pages[entry.index as int];
        expect(
          page.anchor.text.trimLeft(),
          startsWith(entry.label as String),
          reason: 'every detected chapter starts at page top',
        );
      }
      await tester.tap(find.byTooltip('关闭面板'));
      await settle();
      await tester.tap(find.byTooltip('阅读设置'));
      await settle();
      expect(find.byType(ArticleSettingsPanel), findsOneWidget);
      await shot('aa');
      await tester.ensureVisible(find.text('间距设置'));
      await tester.tap(find.text('间距设置'));
      await settle();
      expect(find.text('行间距'), findsOneWidget);
      await shot('spacing');
      await tester.tap(find.byTooltip('返回阅读设置'));
      await settle();
      await tester.ensureVisible(find.text('覆盖翻页'));
      await tester.tap(find.text('覆盖翻页'));
      await settle();
      await tester.tap(find.byTooltip('关闭面板'));
      await settle();
      await tester.tapAt(const Offset(195, 250));
      await settle();
      final paged = tester.widget<PagedTextReader>(
        find.byType(PagedTextReader, skipOffstage: false),
      );
      expect(paged.effect, 'cover');
      expect(
        tester.widget<ReaderShell>(find.byType(ReaderShell)).adapter.paged,
        isTrue,
      );
      await tester.drag(
        find.byType(PagedTextReader, skipOffstage: false),
        const Offset(-650, 0),
      );
      await settle();
      expect(paged.controller.page, greaterThan(0));
      expect(tester.takeException(), isNull);
      // Reflow in the deep part of the real book while the overview is visible.
      paged.controller.goTo(
        (layout.pages.length * .65).round(),
        animate: false,
      );
      await settle();
      final rawText = await api.call('read_text', {'book': book.id});
      final sourceParagraphs = rawText['paragraphs'] as List;
      final sourceChapters = ReaderOutlineEntry.parse(rawText['outline']);
      expect(sourceChapters.length, greaterThanOrEqualTo(40));
      final phoneLayout = TextPagination.layout(
        paragraphs: sourceParagraphs.cast<String>(),
        viewport: const Size(1080 / 2.75, 2201 / 2.75),
        style: layout.style.copyWith(fontSize: 25),
        scaler: TextScaler.noScaling,
        direction: TextDirection.ltr,
        margin: 28,
        paragraphGap: 24,
        chapterStarts: [
          for (final entry in sourceChapters) (entry.index, entry.offset),
        ],
      );
      expect(
        phoneLayout.pages.every(
          (p) => p.fragments.any((f) => f.text.trim().isNotEmpty),
        ),
        isTrue,
        reason:
            'the actual TXT at Android font 25 must have no whitespace-only pages',
      );
      debugPrint('REAL_TXT_FONT25_NO_BLANK_PAGES ${phoneLayout.pages.length}');
      int sourceAtTop() {
        final view = tester.widget<PagedTextReader>(
          find.byType(PagedTextReader, skipOffstage: false),
        );
        final a = view.layout.pages[view.controller.page!].anchor;
        return sourceParagraphs
                .take(a.paragraph)
                .fold<int>(0, (n, p) => n + (p as String).length) +
            a.start;
      }

      final beforeReflow = sourceAtTop();
      if (find.byTooltip('阅读设置').hitTestable().evaluate().isEmpty) {
        final area = tester.getRect(
          find.byKey(const ValueKey('reader-content-hit-region')),
        );
        await tester.tapAt(area.topLeft + const Offset(100, 50));
        await settle();
      }
      await tester.tap(find.byTooltip('阅读设置').hitTestable());
      await settle();
      final beforeMode = sourceAtTop();
      await tester.ensureVisible(find.text('上下滚动'));
      await tester.tap(find.text('上下滚动'));
      await settle();
      await tester.ensureVisible(find.text('左右翻页'));
      await tester.tap(find.text('左右翻页'));
      for (var i = 0; i < 3000; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
        final views = find.byType(PagedTextReader, skipOffstage: false);
        if (views.evaluate().isNotEmpty &&
            tester.widget<PagedTextReader>(views).layout.complete) {
          break;
        }
      }
      await settle();
      expect(
        (sourceAtTop() - beforeMode).abs(),
        lessThan(500),
        reason: 'mode roundtrip must retain source anchor',
      );
      debugPrint(
        'MODE_ROUNDTRIP_SOURCE before=$beforeMode after=${sourceAtTop()}',
      );
      await tester.ensureVisible(find.byTooltip('增大字号'));
      await tester.tap(find.byTooltip('增大字号'));
      await settle();
      for (var i = 0; i < 3000; i++) {
        final view = tester.widget<PagedTextReader>(
          find.byType(PagedTextReader, skipOffstage: false),
        );
        if (view.layout.complete && view.layout.style.fontSize == 21) break;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await settle();
      final afterReflow = sourceAtTop();
      expect(
        (afterReflow - beforeReflow).abs(),
        lessThan(1200),
        reason: 'font reflow must retain the deep source anchor',
      );
      debugPrint('DEEP_REFLOW_SOURCE before=$beforeReflow after=$afterReflow');
      final result = {
        'bytes': original.length,
        'chapters': outline.length,
        'pages': layout.pages.length,
        'effect': 'cover discrete',
        'screenshots': Platform.environment['AQ_SCREENSHOT_DIR'],
      };
      await File(
        '${Platform.environment['AQ_TEST_SUPPORT']}/reference-result.json',
      ).writeAsString(jsonEncode(result));
      // Render every real native page at its measured canvas size, including
      // the CJK system fallback and boundaries around all 43 detected headings.
      var checked = 0;
      for (var i = 0; i < layout.pages.length; i++) {
        await tester.pumpWidget(
          MaterialApp(
            home: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: layout.viewport.width,
                height: layout.viewport.height,
                child: ReaderTextPageView(
                  key: ValueKey(i),
                  layout: layout,
                  index: i,
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        final region = tester.getRect(find.byType(ReaderTextPageView));
        final text = tester.getRect(find.byType(SelectableText).last);
        expect(
          text.bottom,
          lessThanOrEqualTo(region.bottom - layout.padding.bottom + .5),
          reason: 'real TXT page $i',
        );
        expect(find.byType(SingleChildScrollView), findsNothing);
        expect(tester.takeException(), isNull);
        checked++;
      }
      debugPrint('REAL_TXT_ALL_PAGES_FIT $checked');
      expect(await sample.readAsBytes(), original);
      await tester.pumpWidget(const SizedBox());
      await settle();
      await api.idle;
    },
  );
}
