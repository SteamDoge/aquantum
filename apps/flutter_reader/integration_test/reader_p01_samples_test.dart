// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:aquantum_reader/data/models.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/formats/document_engine.dart';
import 'package:aquantum_reader/formats/document_engine_windows.dart';
import 'package:aquantum_reader/reader/reader_contract.dart';
import 'package:aquantum_reader/screens/reader_screen.dart';
import 'package:aquantum_reader/reader/reader_shell.dart';
import 'package:aquantum_reader/widgets/article_settings_panel.dart';
import 'qa_storage.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'four real EPUB/MOBI samples import, reflow, effects and restore anchors',
    (tester) async {
      await configureQaStorage();
      await Directory(
        Platform.environment['AQ_SCREENSHOT_DIR']!,
      ).create(recursive: true);
      final support = Platform.environment['AQ_TEST_SUPPORT']!;
      final api = RustReaderApi('$support/sample-library');
      final paths =
          (jsonDecode(
                    await File(
                      Platform.environment['AQ_P01_SAMPLES']!,
                    ).readAsString(),
                  )
                  as List)
              .cast<String>();
      final inbox = (await api.call('snapshot'))['catalog']['inbox'];
      for (final path in paths) {
        await api.call('import_files', {
          'target': inbox,
          'files': [
            {
              'name': File(path).uri.pathSegments.last,
              'data': base64Encode(await File(path).readAsBytes()),
            },
          ],
        });
      }
      final library = LibrarySnapshot(
        Map<String, dynamic>.from(await api.call('snapshot')),
      );
      expect(library.books.length, 4);
      final results = <Map<String, dynamic>>[];
      for (var i = 0; i < library.books.length; i++) {
        final book = library.books[i];
        final engine =
            await tester.runAsync(WindowsDocumentEngine.create)
                as DocumentEngine;
        final key = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: RepaintBoundary(
                key: key,
                child: Builder(builder: engine.build),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(seconds: 1));
        await tester.runAsync(() async {
          final watch = Stopwatch()..start();
          await engine.ready;
          final resource = await api.call('document_resource', {
            'book': book.id,
          });
          final info = await engine.open(
            bytes: await File(resource['path']).readAsBytes(),
            name: book.title,
            format: book.format,
          );
          final openMs = watch.elapsedMilliseconds;
          expect(info.outline, isNotEmpty);
          expect(
            info.pageEffects,
            isTrue,
            reason: 'current WebView2 must support actual page snapshots',
          );
          expect(
            engine.capabilities.supports(ReaderSetting.turnEffect),
            isTrue,
          );
          await engine.goToFraction(.45);
          await Future<void>.delayed(const Duration(milliseconds: 400));
          final middle = await engine.anchor();
          expect(middle, isNotEmpty);
          for (final effect in ['slide', 'cover', 'curl']) {
            await engine.style({
              'continuous': false,
              'animation': true,
              'turnEffect': effect,
              'fontSize': 21,
              'lineHeight': 1.8,
              'paragraphGap': 16,
              'margin': 24,
              'theme': 'paper',
            });
            await Future<void>.delayed(const Duration(milliseconds: 250));
            final before = await engine.anchor();
            await engine.turn(1);
            expect(await engine.anchor(), isNot(before), reason: effect);
            await engine.turn(-1);
          }
          await engine.style({
            'continuous': true,
            'fontSize': 25,
            'lineHeight': 2,
            'paragraphGap': 24,
            'margin': 32,
            'theme': 'dark',
          });
          await Future<void>.delayed(const Duration(milliseconds: 400));
          await engine.goTo(anchor: middle);
          expect(await engine.anchor(), isNotEmpty);
          results.add({
            'name': book.title,
            'format': book.format,
            'openMs': openMs,
            'outline': info.outline.length,
            'pageEffects': info.pageEffects,
            'anchor': middle,
          });
          debugPrint('P01_SAMPLE_PASS ${jsonEncode(results.last)}');
        });
        await tester.pump(const Duration(milliseconds: 300));
        final boundary =
            key.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await tester.runAsync(
          () => File(
            '${Platform.environment['AQ_SCREENSHOT_DIR']}/sample-$i.png',
          ).writeAsBytes(bytes!.buffer.asUint8List()),
        );
        image.dispose();
        await tester.runAsync(engine.close);
        await tester.pumpWidget(const SizedBox());
      }
      // The actual shell must expose the compact panel, not only engine controls.
      final epub = library.books.firstWhere((b) => b.format == 'Epub');
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderScreen(api: api, book: epub, initialPosition: 0),
        ),
      );
      for (var i = 0; i < 200; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.byType(ReaderShell).evaluate().isNotEmpty &&
            tester.widget<ReaderShell>(find.byType(ReaderShell)).adapter.count >
                0) {
          break;
        }
      }
      if (find.byTooltip('阅读设置').hitTestable().evaluate().isEmpty) {
        final area = tester.getRect(
          find.byKey(const ValueKey('reader-content-hit-region')),
        );
        await tester.tapAt(area.topLeft + const Offset(120, 50));
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byTooltip('阅读设置').hitTestable());
      await tester.pumpAndSettle();
      expect(find.byType(ArticleSettingsPanel), findsOneWidget);
      expect(find.text('上下翻页'), findsNothing);
      await tester.ensureVisible(find.text('间距设置'));
      await tester.tap(find.text('间距设置'));
      await tester.pumpAndSettle();
      expect(find.text('行间距'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await File(
        '$support/sample-results.json',
      ).writeAsString(jsonEncode(results));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
