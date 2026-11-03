// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import 'package:aquantum_reader/screens/import_preview.dart';
import 'library_test.dart' show TestApi;
import 'dart:ui' as ui;
import 'package:aquantum_reader/data/models.dart';
import 'package:aquantum_reader/reader/text_chunks.dart';
import 'package:aquantum_reader/reader/reader_scrollbar.dart';
import 'package:aquantum_reader/reader/reader_contract.dart';
import 'package:aquantum_reader/reader/text_pagination.dart';
import 'package:aquantum_reader/reader/reader_image_viewport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'bounded runs preserve a million source characters and surrogate pairs',
    () {
      final source = List.filled(100000, '儒林外史正文😀\n').join();
      final chunks = TextChunks.of([source]);
      expect(List.generate(chunks.chunks.length, chunks.text).join(), source);
      for (var i = 0; i < chunks.chunks.length; i++) {
        expect(chunks.text(i).length, lessThanOrEqualTo(TextChunks.maxLength));
        expect(
          chunks.text(i).codeUnitAt(0),
          isNot(inInclusiveRange(0xdc00, 0xdfff)),
        );
      }
      for (final within in [0.0, .1, .5, .999]) {
        final (run, local) = chunks.locate(0, within);
        final restored = chunks.source(run, local);
        expect(restored.$1, 0);
        expect(restored.$2, closeTo(within, 1e-9));
      }
    },
  );
  test('system root label changes without changing original catalog', () {
    final raw = <String, dynamic>{
      'catalog': {
        'inbox': 'root',
        'projects': [
          {'id': 'root', 'name': '收件箱'},
          {'id': 'other', 'name': '收件箱'},
        ],
      },
    };
    final library = LibrarySnapshot(raw);
    expect(library.project('root').name, '资料库');
    expect(library.project('other').name, '收件箱');
    expect((raw['catalog']['projects'] as List).first['name'], '收件箱');
  });
  testWidgets('import preview reuses the library root presentation name', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ImportPreviewScreen(
          api: TestApi(),
          plan: {
            'target': 'inbox',
            'projects': [],
            'books': [],
            'issues': [],
            'task': 'qa',
            'base_revision': 0,
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('资料库'), findsOneWidget);
    expect(find.text('收件箱'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('cooperative pagination yields and keeps original anchors', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final source = List.filled(1500, '儒林外史 mixed 😀 正文。\n').join();
      var turns = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => turns++,
      );
      final layout = await TextPagination.layoutAsync(
        paragraphs: [source],
        viewport: const Size(375, 700),
        style: const TextStyle(fontSize: 20),
        scaler: TextScaler.noScaling,
        direction: TextDirection.ltr,
        margin: 28,
        paragraphGap: 24,
      );
      timer.cancel();
      expect(turns, greaterThan(0));
      expect(
        layout.pages.expand((p) => p.fragments).map((f) => f.text).join(),
        source,
      );
      for (final page in layout.pages) {
        for (final f in page.fragments) {
          expect(f.text, source.substring(f.start, f.end));
        }
      }
    });
  });
  for (final slop in [8.0, 18.0]) {
    for (final step in [const Offset(4, -4), const Offset(12, -4)]) {
      testWidgets('continuous image diagonal scroll slop=$slop step=$step', (
        tester,
      ) async {
        tester.view.gestureSettings = ui.GestureSettings(
          physicalTouchSlop: slop,
        );
        addTearDown(tester.view.resetGestureSettings);
        final scroll = ScrollController();
        final transform = TransformationController();
        await tester.pumpWidget(
          MaterialApp(
            home: ListView(
              controller: scroll,
              children: [
                ReaderImageViewport(
                  controller: transform,
                  child: Container(height: 1800, color: Colors.blue),
                ),
                const SizedBox(height: 1800),
              ],
            ),
          ),
        );
        final drag = await tester.startGesture(const Offset(100, 300));
        for (var i = 0; i < 12; i++) {
          await drag.moveBy(step);
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(scroll.offset, greaterThan(20));
        expect(transform.value.getMaxScaleOnAxis(), 1);
        await drag.up();
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        scroll.dispose();
        transform.dispose();
      });
    }
  }
  testWidgets('cancelled scrollbar press never changes reading position', (
    tester,
  ) async {
    final metrics = ValueNotifier(const ReaderScrollMetrics(0, .1));
    var seeks = 0;
    final source = ReaderScrollSource(metrics: metrics, seek: (_) => seeks++);
    await tester.pumpWidget(
      MaterialApp(
        home: Align(
          alignment: Alignment.centerRight,
          child: SizedBox(
            width: 28,
            height: 500,
            child: ReaderScrollbar(source: source),
          ),
        ),
      ),
    );
    metrics.value = const ReaderScrollMetrics(.1, .1);
    await tester.pump(const Duration(milliseconds: 200));
    final press = await tester.startGesture(
      tester.getCenter(find.byType(ReaderScrollbar)),
    );
    await tester.pump(const Duration(milliseconds: 150));
    expect(seeks, 0);
    await press.cancel();
    await tester.pump(const Duration(milliseconds: 100));
    expect(seeks, 0);
    await tester.pumpWidget(const SizedBox());
    metrics.dispose();
  });

  testWidgets('two fingers still enlarge a continuous image', (tester) async {
    final transform = TransformationController();
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 400,
          height: 600,
          child: ReaderImageViewport(
            controller: transform,
            child: Container(color: Colors.blue),
          ),
        ),
      ),
    );
    final a = await tester.startGesture(const Offset(200, 200), pointer: 1);
    final b = await tester.startGesture(const Offset(300, 200), pointer: 2);
    for (var i = 0; i < 10; i++) {
      await a.moveBy(const Offset(-6, 0));
      await b.moveBy(const Offset(6, 0));
      await tester.pump();
    }
    expect(transform.value.getMaxScaleOnAxis(), greaterThan(1.1));
    await a.up();
    await b.up();
    await tester.pumpWidget(const SizedBox());
    transform.dispose();
  });
}
