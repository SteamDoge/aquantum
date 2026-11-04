// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:aquantum_reader/data/models.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/formats/pdf_reader.dart';
import 'package:aquantum_reader/reader/reader_shell.dart';
import 'package:aquantum_reader/reader/reader_scrollbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'qa_storage.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'actual PDF short fling, paged alignment, free inertia and setting round trips',
    (tester) async {
      await configureQaStorage();
      final root = Platform.environment['AQ_TEST_SUPPORT']!;
      final api = RustReaderApi('$root/library');
      final file = File(Platform.environment['AQ_USER_PDF']!);
      final inbox = (await api.call('snapshot'))['catalog']['inbox'];
      await api.call('import_files', {
        'target': inbox,
        'files': [
          {
            'name': file.uri.pathSegments.last,
            'data': base64Encode(await file.readAsBytes()),
          },
        ],
      });
      final book = LibrarySnapshot(
        Map<String, dynamic>.from(await api.call('snapshot')),
      ).books.single;
      await api.call('resolve_book_direction', {
        'book': book.id,
        'inherit': false,
        'direction': 'LeftToRight',
      });
      const capture = ValueKey('pdf-motion-capture');
      Widget render(Size size) => RepaintBoundary(
        key: capture,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: MaterialApp(
              theme: ThemeData(platform: TargetPlatform.android),
              home: PdfReaderScreen(api: api, book: book, initialPosition: 0),
            ),
          ),
        ),
      );
      await tester.pumpWidget(render(const Size(900, 650)));
      PdfViewer viewer() => tester.widget<PdfViewer>(find.byType(PdfViewer));
      ReaderShell shell() =>
          tester.widget<ReaderShell>(find.byType(ReaderShell));
      Future<void> ready() async {
        for (var i = 0; i < 300; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (find.byType(PdfViewer).evaluate().isEmpty ||
              !viewer().controller!.isReady) {
            continue;
          }
          try {
            if (viewer().controller!.viewSize.isEmpty) continue;
            viewer().controller!.visibleRect;
          } catch (_) {
            continue;
          }
          await tester.pumpAndSettle();
          return;
        }
        fail('PDF did not lay out');
      }

      Future<void> settings() async {
        if (find.byTooltip('阅读设置').hitTestable().evaluate().isEmpty) {
          final area = tester.getRect(
            find.byKey(const ValueKey('reader-content-hit-region')),
          );
          await tester.tapAt(area.topLeft + const Offset(90, 40));
          await tester.pumpAndSettle();
        }
        await tester.tap(find.byTooltip('阅读设置').hitTestable());
        await tester.pumpAndSettle();
      }

      await ready();
      expect(shell().adapter.paged, isTrue);
      final count = shell().adapter.count;
      expect(count, greaterThan(1));
      debugPrint(
        'PDF_MOTION: pages=$count zoom=${viewer().controller!.currentZoom} rect=${viewer().controller!.visibleRect} layout=${viewer().controller!.layout.documentSize}',
      );
      await tester.fling(find.byType(PdfViewer), const Offset(-80, 0), 1500);
      await tester.pumpAndSettle();
      debugPrint(
        'PDF_MOTION_AFTER: pos=${shell().adapter.position} zoom=${viewer().controller!.currentZoom} transform=${viewer().controller!.value.getTranslation()}',
      );
      expect(
        shell().adapter.position,
        1,
        reason: 'a short fast swipe advances exactly one page',
      );
      final controller = viewer().controller!;
      expect(
        -controller.value.getTranslation().x / controller.viewSize.width,
        closeTo(1, .01),
      );
      await settings();
      expect(find.text('2 / $count 页'), findsWidgets);
      await tester.tap(find.text('纵向连续阅读'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭面板'));
      await ready();
      expect(shell().adapter.paged, isFalse);
      expect(find.byType(ReaderScrollbar), findsOneWidget);
      final scrollController = viewer().controller!;
      await tester.fling(find.byType(PdfViewer), const Offset(0, -150), 1800);
      final released = scrollController.visibleRect.top;
      await tester.pump(const Duration(milliseconds: 150));
      final coast = scrollController.visibleRect.top;
      debugPrint('PDF_INERTIA: release=$released after150ms=$coast');
      expect(
        coast,
        greaterThan(released + 10),
        reason:
            'the PDF keeps coasting after release, like a native scrollable',
      );
      await tester.pumpAndSettle();
      final metrics = shell().scroll!.metrics.value;
      expect(metrics.viewport, isNotNull);
      expect(metrics.fraction, greaterThan(0));
      await settings();
      for (final gap in ['无缝', '有缝', '无缝']) {
        await tester.tap(find.text(gap));
        await tester.pumpAndSettle();
        expect(viewer().params.margin, gap == '无缝' ? 0 : 12);
      }
      await tester.tap(find.text('更多').last);
      await tester.pumpAndSettle();
      for (final theme in ['纸张', '夜间', '跟随应用', '纸张']) {
        await tester.tap(find.text(theme));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.text('布局'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('纵向连续阅读'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('从右到左'));
      await tester.tap(find.text('从右到左'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('更多').last);
      await tester.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('页面切换动画'));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byTooltip('关闭面板'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-page-overview')));
      await ready();
      expect(shell().adapter.paged, isTrue);
      expect(shell().adapter.rightToLeft, isTrue);
      final beforeRtl = shell().adapter.position;
      await tester.fling(find.byType(PdfViewer), const Offset(80, 0), 1500);
      await tester.pumpAndSettle();
      expect(shell().adapter.position, beforeRtl + 1);
      final effective = await api.call('effective_direction', {
        'book': book.id,
      });
      expect(effective['value'], 'RightToLeft');
      final beforeResize = shell().adapter.position;
      await tester.pumpWidget(render(const Size(400, 650)));
      await ready();
      expect(
        shell().adapter.position,
        beforeResize,
        reason: 'resizing keeps the logical PDF page',
      );
      expect(viewer().controller!.currentZoom, closeTo(1, .01));
      expect(
        -viewer().controller!.value.getTranslation().x /
            viewer().controller!.viewSize.width,
        closeTo(count - 1 - beforeResize, .01),
        reason:
            'resizing must align the whole page, not only retain its number',
      );
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(capture),
      );
      final image = await boundary.toImage(pixelRatio: 1);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      await File(
        '$root/user-pdf-paged.png',
      ).writeAsBytes(png!.buffer.asUint8List());
      image.dispose();
      expect(tester.takeException(), isNull);
      final savedPosition = shell().adapter.position;
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          home: PdfReaderScreen(
            api: api,
            book: book,
            initialPosition: savedPosition,
          ),
        ),
      );
      await ready();
      expect(shell().adapter.paged, isTrue);
      expect(shell().adapter.rightToLeft, isTrue);
      expect(shell().adapter.position, savedPosition);
      expect(find.byType(ColorFiltered), findsOneWidget);
      debugPrint(
        'PDF_MOTION_PASS: short fling alignment, inertia, modes, gaps, RTL, themes, animation and reopen',
      );
      await tester.pumpWidget(const SizedBox());
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
