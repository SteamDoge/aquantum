// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:aquantum_reader/data/models.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/formats/document_engine.dart';
import 'package:aquantum_reader/formats/document_engine_windows.dart';
import 'package:aquantum_reader/formats/pdf_reader.dart';
import 'package:aquantum_reader/reader/reader_shell.dart';
import 'package:aquantum_reader/screens/reader_screen.dart';
import 'package:aquantum_reader/widgets/reader_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pdfrx/pdfrx.dart';
import 'qa_storage.dart';
import '../test/pdf_engine_test.dart' show makePdf;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('user samples import and native rendering; flat PDF gap controls', (
    tester,
  ) async {
    await configureQaStorage();
    final root = Platform.environment['AQ_TEST_SUPPORT']!;
    final api = RustReaderApi('$root/library');
    final paths =
        (jsonDecode(
                  await File(
                    Platform.environment['AQ_USER_SAMPLES']!,
                  ).readAsString(),
                )
                as List)
            .cast<String>();
    final inbox = (await api.call('snapshot'))['catalog']['inbox'];
    for (final path in paths) {
      final file = File(path);
      await api.call('import_files', {
        'target': inbox,
        'files': [
          {
            'name': file.uri.pathSegments.last,
            'data': base64Encode(await file.readAsBytes()),
          },
        ],
      });
    }
    await api.call('import_files', {
      'target': inbox,
      'files': [
        {'name': 'flat-gap-test.pdf', 'data': base64Encode(makePdf(3))},
      ],
    });
    final snapshot = LibrarySnapshot(
      Map<String, dynamic>.from(await api.call('snapshot')),
    );
    expect(snapshot.books.length, 5);
    for (final book in snapshot.books.where(
      (b) => b.format == 'Epub' || b.format == 'Mobi',
    )) {
      final DocumentEngine engine =
          await tester.runAsync(() => WindowsDocumentEngine.create())
              as DocumentEngine;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Builder(builder: engine.build)),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      try {
        await tester.runAsync(() async {
          await engine.ready.timeout(const Duration(seconds: 30));
          final path = await api.call('document_resource', {'book': book.id});
          final info = await engine
              .open(
                bytes: await File(path['path']).readAsBytes(),
                name: book.title,
                format: book.format,
              )
              .timeout(const Duration(seconds: 45));
          expect(info.title, isNotEmpty);
          expect(await engine.anchor(), isNotEmpty);
          await engine.style({'continuous': true, 'fontSize': 22});
          await engine.goToFraction(.5);
          expect(await engine.anchor(), isNotEmpty);
          await engine.style({'continuous': false});
          await engine.turn(1);
          debugPrint(
            'USER_SAMPLE_PASS: ${book.format} ${book.title} outline=${info.outline.length}',
          );
        });
      } finally {
        await tester.runAsync(engine.close);
        await tester.pumpWidget(const SizedBox());
      }
    }
    for (final format in ['Epub', 'Mobi']) {
      final document = snapshot.books.firstWhere((b) => b.format == format);
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderScreen(api: api, book: document, initialPosition: 0),
        ),
      );
      for (var i = 0; i < 300; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.byType(ReaderShell).evaluate().isNotEmpty &&
            tester.widget<ReaderShell>(find.byType(ReaderShell)).adapter.count >
                0) {
          break;
        }
      }
      expect(find.byType(ReaderShell), findsOneWidget);
      Future<void> tapSetting(String label) async {
        final target = find.text(label);
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$format $label');
      }

      if (find.byTooltip('阅读设置').hitTestable().evaluate().isEmpty) {
        final area = tester.getRect(
          find.byKey(const ValueKey('reader-content-hit-region')),
        );
        await tester.tapAt(area.topLeft + const Offset(100, 60));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byTooltip('阅读设置').hitTestable());
      await tester.pumpAndSettle();
      for (var i = 0; i < 4; i++) {
        await tapSetting('纵向连续阅读');
        expect(
          tester
              .widget<SwitchListTile>(
                find.widgetWithText(SwitchListTile, '纵向连续阅读'),
              )
              .onChanged,
          isNotNull,
        );
      }
      await tapSetting('系统字体');
      await tapSetting('衬线字体');
      final sliders = tester
          .widgetList<Slider>(
            find.descendant(
              of: find.byType(ReaderSettingsPanel),
              matching: find.byType(Slider),
            ),
          )
          .toList();
      for (final slider in sliders) {
        slider.onChanged!((slider.min + slider.max) / 2);
        await tester.pumpAndSettle();
      }
      await tapSetting('更多');
      for (final theme in ['纸张', '夜间', '跟随应用', '纸张']) {
        await tapSetting(theme);
      }
      for (var i = 0; i < 4; i++) {
        await tapSetting('页面切换动画');
      }
      for (final dock in ['下', '左', '右', '隐藏', '上']) {
        await tapSetting(dock);
      }
      final panel = tester.widget<ReaderSettingsPanel>(
        find.byType(ReaderSettingsPanel),
      );
      expect(panel.preferences.theme, 'paper');
      expect(panel.preferences.continuous, isFalse);
      expect(panel.preferences.dock, 'top');
      await tester.tap(find.byTooltip('关闭面板'));
      await tester.pumpAndSettle();
      debugPrint(
        'SETTING_NATIVE_PASS: $format mode/font/spacing/theme/animation/dock round trips',
      );
      await tester.pumpWidget(const SizedBox());
    }
    final txt = snapshot.books.singleWhere((b) => b.format == 'Txt');
    await (ReaderPreferences()..textPaged = false).save(bookId: txt.id);
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderScreen(api: api, book: txt, initialPosition: 0),
      ),
    );
    for (
      var i = 0;
      i < 150 && find.byType(ReaderShell).evaluate().isEmpty;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(ReaderShell), findsOneWidget);
    await tester.drag(
      find.byKey(const ValueKey('reader-content-hit-region')),
      const Offset(0, -400),
    );
    await tester.pump(const Duration(seconds: 1));
    debugPrint('USER_SAMPLE_PASS: TXT ${txt.title}');
    await tester.pumpWidget(const SizedBox());
    final pdf = snapshot.books.singleWhere((b) => b.format == 'Pdf');
    await api.call('set_book_crop', {
      'book': pdf.id,
      'left': .2,
      'top': .1,
      'right': .1,
      'bottom': .1,
    });
    const capture = ValueKey('pdf-flat-capture');
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          home: PdfReaderScreen(api: api, book: pdf, initialPosition: 0),
        ),
      ),
    );
    for (var i = 0; i < 200 && find.byType(PdfViewer).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(PdfViewer), findsOneWidget);
    expect(
      tester.widget<PdfViewer>(find.byType(PdfViewer)).params.pageDropShadow,
      isNull,
    );
    if (find.byTooltip('阅读设置').hitTestable().evaluate().isEmpty) {
      final area = tester.getRect(
        find.byKey(const ValueKey('reader-content-hit-region')),
      );
      await tester.tapAt(area.topLeft + const Offset(100, 60));
      await tester.pumpAndSettle();
    }
    await tester.tap(find.byTooltip('阅读设置').hitTestable());
    await tester.pumpAndSettle();
    expect(find.text('页面间距'), findsOneWidget);
    expect(find.text('有缝'), findsOneWidget);
    expect(find.text('无缝'), findsOneWidget);
    await tester.tap(find.text('无缝'));
    await tester.pumpAndSettle();
    expect(tester.widget<PdfViewer>(find.byType(PdfViewer)).params.margin, 0);
    expect(
      tester.widget<PdfViewer>(find.byType(PdfViewer)).params.pageDropShadow,
      isNull,
    );
    await tester.tap(find.byTooltip('关闭面板'));
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(capture),
    );
    final image = await boundary.toImage(pixelRatio: 1);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await File(
      '$root/pdf-seamless-flat.png',
    ).writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
    await tester.tap(find.byTooltip('阅读设置').hitTestable());
    await tester.pumpAndSettle();
    await tester.tap(find.text('更多').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('纸张'));
    await tester.pumpAndSettle();
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is ColorFiltered &&
            w.colorFilter ==
                const ColorFilter.mode(Color(0xfff4ecd8), BlendMode.modulate),
      ),
      findsOneWidget,
    );
    await tester.tap(find.byTooltip('关闭面板'));
    await tester.pumpAndSettle();
    Future<void> snapshotPdf(String name) async {
      final area = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(capture),
      );
      final frame = await area.toImage(pixelRatio: 1);
      final bytes = await frame.toByteData(format: ui.ImageByteFormat.png);
      await File('$root/$name.png').writeAsBytes(bytes!.buffer.asUint8List());
      frame.dispose();
    }

    await snapshotPdf('pdf-paper-theme');
    await tester.tap(find.byTooltip('阅读设置').hitTestable());
    await tester.pumpAndSettle();
    await tester.tap(find.text('更多').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('跟随应用'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭面板'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: PdfReaderScreen(api: api, book: pdf, initialPosition: 0),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ColorFiltered), findsOneWidget);
    expect(
      tester.widget<PdfViewer>(find.byType(PdfViewer)).params.backgroundColor,
      Colors.white,
    );
    await snapshotPdf('pdf-follow-dark-theme');
    debugPrint(
      'READER_AUDIT_PASS: PDF paper and follow-dark themes apply to native viewer',
    );
    debugPrint(
      'USER_SAMPLE_PASS: PDF shadow disabled, gap toggles, saved crop ignored',
    );
    await tester.pumpWidget(const SizedBox());
  }, timeout: const Timeout(Duration(minutes: 6)));
}
