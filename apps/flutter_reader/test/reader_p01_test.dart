// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:aquantum_reader/widgets/text_reader.dart';
import 'package:aquantum_reader/reader/text_chunks.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'dart:ui' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aquantum_reader/reader/text_pagination.dart';
import 'package:aquantum_reader/widgets/article_settings_panel.dart';
import 'package:aquantum_reader/widgets/reader_settings.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/data/models.dart';
import 'package:aquantum_reader/reader/reader_contract.dart';
import 'package:aquantum_reader/reader/reader_page_overview.dart';
import 'reader_shell_test.dart' show FixtureAdapter;

class LayoutSwapAdapter extends FixtureAdapter implements PagedReaderAdapter {
  final int total;
  final List<int> writes;
  LayoutSwapAdapter(this.total, int initial, this.writes) : super('Txt') {
    current = initial;
  }
  @override
  int get count => total;
  @override
  bool get animatePageTurns => false;
  @override
  void goTo(int index) {
    writes.add(index);
    current = index;
  }

  @override
  Widget buildPage(BuildContext context, int index, {required bool preview}) =>
      Text('page $index');
}

void main() {
  test('saved text fractions share the scrollbar chunk weights and cache', () {
    final text = ['short', 'x' * 6000, 'end'];
    final progress = TextReader.progressOf(text);
    expect(identical(progress, TextReader.progressOf(text)), isTrue);
    final chunks = TextChunks.of(text);
    for (final paragraph in [0, 1, 2]) {
      for (final within in [0.0, 0.2, 0.8]) {
        final source = chunks.locate(paragraph, within);
        expect(
          TextReader.fractionOf(text, paragraph, within),
          progress.fractionAt(source.$1, source.$2),
        );
      }
    }
  });
  test(
    'real bridge persists measured content hint separately from paragraph position',
    () async {
      final dir = await Directory.systemTemp.createTemp('aq-content-progress-');
      final api = RustReaderApi(dir.path);
      final inbox = (await api.call('snapshot'))['catalog']['inbox'];
      await api.call('import_files', {
        'target': inbox,
        'files': [
          {
            'name': 'weighted.txt',
            'data': base64Encode(
              utf8.encode('短段。\n\n${List.filled(2000, '长正文').join()}'),
            ),
          },
        ],
      });
      var library = LibrarySnapshot(
        Map<String, dynamic>.from(await api.call('snapshot')),
      );
      final book = library.books.single;
      await api.call('save_progress', {
        'book': book.id,
        'index': 1,
        'content_progress': 7,
      });
      library = LibrarySnapshot(
        Map<String, dynamic>.from(await api.call('snapshot')),
      );
      expect(library.position(book), 1);
      expect(library.contentFraction(book), .0007);
      await expectLater(
        api.call('save_progress', {
          'book': book.id,
          'index': 1,
          'content_progress': 10001,
        }),
        throwsA(anything),
      );
      final after = LibrarySnapshot(
        Map<String, dynamic>.from(await api.call('snapshot')),
      );
      expect(after.contentFraction(book), .0007);
    },
  );
  testWidgets(
    'overview layout replacement cannot save a clamped page as reading progress',
    (tester) async {
      final writes = <int>[];
      late StateSetter update;
      var adapter = LayoutSwapAdapter(1000, 650, writes);
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return ReaderPageOverview(
                adapter: adapter,
                pageSize: const Size(390, 844),
                initialPage: adapter.position,
                onActivate: () {},
              );
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      update(() => adapter = LayoutSwapAdapter(20, 10, writes));
      await tester.pumpAndSettle();
      update(() => adapter = LayoutSwapAdapter(1100, 710, writes));
      await tester.pumpAndSettle();
      expect(
        writes,
        isEmpty,
        reason:
            'programmatic clamps must not write an ordinal into another source layout',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'deep-anchor preview is bounded and final source anchors remain exact',
    (tester) async {
      final source = List.generate(
        2000,
        (i) => '第$i段${List.filled(80, '正文😀').join()}',
      );
      TextPagination? preview;
      final completed = await tester.runAsync(
        () => TextPagination.layoutAsync(
          paragraphs: source,
          viewport: const Size(390, 850),
          style: const TextStyle(fontSize: 20, height: 1.8),
          scaler: TextScaler.noScaling,
          direction: TextDirection.ltr,
          margin: 24,
          paragraphGap: 16,
          anchorParagraph: 1500,
          anchorOffset: 80,
          onPreview: (value) => preview = value,
        ),
      );
      expect(preview, isNotNull);
      expect(preview!.complete, isFalse);
      expect(preview!.covers(1500, 80), isTrue);
      expect(preview!.pages.length, lessThan(50));
      expect(completed!.complete, isTrue);
      final fragment = completed.pages[completed.pageFor(1500, 80)].fragments
          .firstWhere(
            (f) => f.paragraph == 1500 && f.start <= 80 && f.end >= 80,
          );
      expect(
        fragment.text,
        source[1500].substring(fragment.start, fragment.end),
      );
    },
  );
  testWidgets(
    'phone diagonals, short drags and cancellation settle to full pages',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final layout = TextPagination.layout(
        paragraphs: [List.filled(3000, '正文内容😀。').join()],
        viewport: const Size(390, 844),
        style: const TextStyle(fontSize: 20, height: 1.8),
        scaler: TextScaler.noScaling,
        direction: TextDirection.ltr,
        margin: 24,
        paragraphGap: 16,
      );
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.view.gestureSettings = const ui.GestureSettings(
        physicalTouchSlop: 8,
      );
      addTearDown(tester.view.resetGestureSettings);
      final controller = PagedTextController();
      await tester.pumpWidget(
        MaterialApp(
          home: PagedTextReader(
            layout: layout,
            controller: controller,
            initialPage: 0,
            onPage: (_) {},
            effect: 'cover',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.dragFrom(const Offset(240, 420), const Offset(-12, 8));
      await tester.pumpAndSettle();
      expect(controller.page, 0);
      await tester.pump(const Duration(milliseconds: 500));
      final diagonal = await tester.startGesture(const Offset(300, 420));
      for (var i = 0; i < 65; i++) {
        await diagonal.moveBy(const Offset(-4, 2));
        await tester.pump(const Duration(milliseconds: 8));
      }
      await diagonal.up();
      await tester.pumpAndSettle();
      expect(controller.page, 1);
      await tester.dragFrom(const Offset(200, 420), const Offset(0, -220));
      await tester.pumpAndSettle();
      expect(controller.page, 1);
      final gesture = await tester.startGesture(const Offset(250, 420));
      await gesture.moveBy(const Offset(-110, 45));
      await gesture.cancel();
      await tester.pumpAndSettle();
      final pageView = tester.widget<PageView>(find.byType(PageView));
      expect(
        pageView.controller!.page,
        closeTo(pageView.controller!.page!.round(), 1e-5),
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    '5 MB deep resume exposes bounded first pages before measuring the whole book',
    (tester) async {
      final paragraphs = List.generate(
        3500,
        (i) => '$i ${List.filled(150, '长文😀').join()}',
      );
      final watch = Stopwatch()..start();
      var previewReady = false;
      await tester.runAsync(() async {
        await expectLater(
          TextPagination.layoutAsync(
            paragraphs: paragraphs,
            viewport: const Size(390, 844),
            style: const TextStyle(fontSize: 20, height: 1.8),
            scaler: TextScaler.noScaling,
            direction: TextDirection.ltr,
            margin: 24,
            paragraphGap: 16,
            anchorParagraph: 3400,
            anchorOffset: 100,
            cancelled: () => previewReady,
            onPreview: (preview) {
              expect(preview.covers(3400, 100), isTrue);
              expect(preview.pages.length, lessThan(50));
              previewReady = true;
              debugPrint(
                'P01_FIRST_PREVIEW_MS=${watch.elapsedMilliseconds} chars=${paragraphs.fold<int>(0, (n, p) => n + p.length)}',
              );
            },
          ),
          throwsA(isA<StateError>()),
        );
      });
      expect(previewReady, isTrue);
    },
  );
  for (final size in [
    const Size(320, 640),
    const Size(844, 390),
    const Size(430, 1100),
  ]) {
    testWidgets('Aa and spacing fit $size with large text', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      SharedPreferences.setMockInitialValues({});
      final p = ReaderPreferences();
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: TextScaler.linear(1.8),
            ),
            child: Scaffold(
              body: ArticleSettingsPanel(
                preferences: p,
                fontSize: 20,
                onFont: (_) {},
                onChanged: (f) => f(),
                advanced: (_, _) => const SizedBox(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('间距设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('间距设置'));
      await tester.pumpAndSettle();
      expect(find.text('行间距'), findsOneWidget);
      expect(find.byTooltip('返回阅读设置').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
