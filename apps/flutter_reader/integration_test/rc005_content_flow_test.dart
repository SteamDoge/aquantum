// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:aquantum_reader/screens/reader_defaults_screen.dart';
import 'qa_storage.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:aquantum_reader/data/models.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/design/theme.dart';
import 'package:aquantum_reader/reader/reader_shell.dart';
import 'package:aquantum_reader/screens/reader_screen.dart';
import 'package:aquantum_reader/screens/page_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import '../test/pdf_engine_test.dart' show makePdf;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'rc005 native managed PDF, Markdown interactions and page management',
    (tester) async {
      await configureQaStorage();
      final support = await getApplicationSupportDirectory();
      final root = Directory(
        '${support.path}/qa-rc005-${DateTime.now().millisecondsSinceEpoch}',
      );
      await root.create(recursive: true);
      final api = RustReaderApi('${root.path}/app');
      final source = Directory('${root.path}/original');
      await source.create();
      await Directory('${source.path}/assets').create();
      await Directory('${source.path}/comic').create();
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder)
        ..drawColor(const Color(0xffd1e4fa), BlendMode.src);
      canvas.drawRect(
        const Rect.fromLTWH(12, 12, 156, 56),
        Paint()..color = const Color(0xff426eab),
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(180, 80);
      final png = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      image.dispose();
      picture.dispose();
      await File('${source.path}/assets/offline.png').writeAsBytes(png);
      for (var i = 0; i < 3; i++) {
        await File('${source.path}/comic/$i.png').writeAsBytes(png);
      }
      await File('${source.path}/sample.pdf').writeAsBytes(makePdf(8));
      const markdown =
          '# Offline document\n\n- [ ] duplicate\n- [ ] duplicate\n\n![Offline image](assets/offline.png)\n\n## Read only\n\n**Native Markdown** with independent task state.\n\n```dart\nvoid main() {\n\n  print("kept verbatim");\n}\n```\n\n<details>\n<summary>More details</summary>\n\nFold state is personal.\n\n</details>';
      await File('${source.path}/sample.md').writeAsString(markdown);
      final inbox = (await api.call('snapshot'))['catalog']['inbox'];
      final plan = await api.call('preview_import', {
        'target': inbox,
        'paths': [source.path],
      });
      await api.call('commit_import', {
        'task': plan['task'],
        'base_revision': plan['base_revision'],
        'target': plan['target'],
        'projects': [
          for (final p in plan['projects']) {'id': p['id'], 'name': p['name']},
        ],
        'books': [
          for (final b in plan['books'])
            {
              'id': b['id'],
              'title': b['title'],
              'project': b['project'],
              'resources': [for (final r in b['resources']) r['id']],
            },
        ],
        'append': null,
        'skip_issues': false,
      });
      final library = LibrarySnapshot(
        Map<String, dynamic>.from(await api.call('snapshot')),
      );
      final pdf = library.books.firstWhere((b) => b.isPdf);
      final md = library.books.firstWhere((b) => b.isMarkdown);
      final comic = library.books.firstWhere((b) => b.isComic);
      const capture = ValueKey('rc005-capture');
      var serial = 0;
      Future<void> until(Finder finder) async {
        for (var i = 0; i < 200 && finder.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(
          finder,
          findsWidgets,
          reason: tester
              .widgetList<Text>(find.byType(Text))
              .map((t) => t.data)
              .join(' | '),
        );
        await tester.pumpAndSettle();
      }

      Future<void> show(Widget child, {Size? size}) async {
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await tester.pumpWidget(
          Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: capture,
              child: SizedBox(
                width: size?.width,
                height: size?.height,
                child: MaterialApp(
                  key: ValueKey(serial++),
                  debugShowCheckedModeBanner: false,
                  theme: readerTheme(Brightness.light).copyWith(
                    platform: size == null
                        ? TargetPlatform.windows
                        : TargetPlatform.android,
                  ),
                  builder: (c, child) => MediaQuery(
                    data: MediaQuery.of(
                      c,
                    ).copyWith(size: size ?? MediaQuery.sizeOf(c)),
                    child: child!,
                  ),
                  home: child,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      Future<void> screenshot(String name) async {
        await tester.pumpAndSettle();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(capture),
        );
        final bitmap = await boundary.toImage(pixelRatio: 1);
        final bytes = await bitmap.toByteData(format: ui.ImageByteFormat.png);
        final folder = Directory(
          Platform.environment['AQ_SCREENSHOT_DIR'] ?? '${root.path}/captures',
        );
        await folder.create(recursive: true);
        await File(
          '${folder.path}/$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        bitmap.dispose();
      }

      Future<void> chrome() async {
        await until(find.byType(ReaderShell));
        if (find.byTooltip('阅读设置').hitTestable().evaluate().isEmpty) {
          final rect = tester.getRect(
            find.byKey(const ValueKey('reader-content-hit-region')),
          );
          await tester.tapAt(rect.topLeft + const Offset(100, 40));
          await tester.pumpAndSettle();
        }
      }

      await show(ReaderScreen(api: api, book: pdf, initialPosition: 7));
      await chrome();
      expect(tester.getSize(find.byKey(capture)).width, greaterThan(900));
      expect(
        tester.widget<ReaderShell>(find.byType(ReaderShell)).adapter.position,
        7,
      );
      await screenshot('rc005-windows-pdf');
      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();
      // Profile has assertions disabled: the debug-only input client -1 is
      // rejected. Register the test IME so it receives the real connection id.
      if (!tester.testTextInput.isRegistered) {
        tester.testTextInput.register();
        addTearDown(tester.testTextInput.unregister);
      }
      await tester.enterText(find.byType(TextField), 'Hello PDF page 3');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Hello PDF page 3',
      );
      await tester.tap(find.byTooltip('开始搜索'));
      await until(find.textContaining('Hello PDF page 3'));
      await tester.tap(find.textContaining('Hello PDF page 3').last);
      await tester.pumpAndSettle();
      for (
        var i = 0;
        i < 60 &&
            tester
                    .widget<ReaderShell>(find.byType(ReaderShell))
                    .adapter
                    .position !=
                2;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        tester.widget<ReaderShell>(find.byType(ReaderShell)).adapter.position,
        2,
      );
      await screenshot('rc005-windows-pdf-search');
      await api.call('set_book_direction', {
        'book': pdf.id,
        'direction': 'RightToLeft',
      });
      final boundPdf = LibrarySnapshot(
        Map<String, dynamic>.from(await api.call('snapshot')),
      ).books.firstWhere((b) => b.id == pdf.id);
      await api.call('set_page_crop', {
        'book': pdf.id,
        'page': boundPdf.pages[2]['id'],
        'left': 0.1,
        'right': 0.1,
        'top': 0.1,
        'bottom': 0.1,
      });
      await show(ReaderScreen(api: api, book: boundPdf, initialPosition: 2));
      await chrome();
      expect(
        tester.widget<ReaderShell>(find.byType(ReaderShell)).adapter.paged,
        isTrue,
      );
      expect(
        tester
            .widget<ReaderShell>(find.byType(ReaderShell))
            .adapter
            .rightToLeft,
        isTrue,
      );
      tester.widget<ReaderShell>(find.byType(ReaderShell)).adapter.goTo(5);
      await tester.pumpAndSettle();
      expect(
        tester.widget<ReaderShell>(find.byType(ReaderShell)).adapter.position,
        5,
      );
      await screenshot('rc005-pdf-cropped-rtl');
      await show(
        ReaderScreen(api: api, book: md, initialPosition: 0),
        size: const Size(375, 812),
      );
      await until(find.byType(Checkbox));
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).first).value,
        isTrue,
      );
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).last).value,
        isFalse,
      );
      await screenshot('rc005-phone-markdown');
      await show(
        ReaderScreen(
          api: RustReaderApi('${root.path}/app'),
          book: md,
          initialPosition: 0,
        ),
        size: const Size(812, 375),
      );
      await until(find.byType(Checkbox));
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).first).value,
        isTrue,
      );
      await screenshot('rc005-landscape-markdown');
      await show(const ReaderDefaultsScreen(), size: const Size(812, 375));
      await tester.tap(find.byKey(const ValueKey('reader-default-Markdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('纯文字阅读').last);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await show(
        ReaderScreen(api: api, book: md, initialPosition: 0),
        size: const Size(812, 375),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNothing);
      await screenshot('rc005-markdown-text-provider');
      await show(
        ReaderScreen(api: api, book: md, initialPosition: 0),
        size: const Size(812, 375),
      );
      await until(find.byType(ReaderShell));
      expect(find.byType(Checkbox), findsNothing);
      await show(const ReaderDefaultsScreen(), size: const Size(812, 375));
      await tester.tap(find.byKey(const ValueKey('reader-default-Markdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Markdown 阅读').last);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await show(
        ReaderScreen(api: api, book: md, initialPosition: 0),
        size: const Size(812, 375),
      );
      await until(find.byType(Checkbox));
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).first).value,
        isTrue,
      );
      expect(await File('${source.path}/sample.md').readAsString(), markdown);
      await show(
        PageManagerScreen(api: api, book: comic),
        size: const Size(812, 375),
      );
      await until(find.byType(Checkbox));
      final firstRow = find.byWidgetPredicate(
        (w) =>
            w is ListTile &&
            w.key == ValueKey<String>(comic.pages.first['id'] as String),
      );
      final lastRow = find.byWidgetPredicate(
        (w) =>
            w is ListTile &&
            w.key == ValueKey<String>(comic.pages.last['id'] as String),
      );
      await tester.tap(
        find.descendant(of: firstRow, matching: find.byType(Checkbox)),
      );
      await tester.scrollUntilVisible(
        lastRow,
        100,
        scrollable: find
            .descendant(
              of: find.byType(ReorderableListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(
        find.descendant(of: lastRow, matching: find.byType(Checkbox)),
      );
      await tester.tap(
        find.descendant(of: lastRow, matching: find.byType(Checkbox)),
      );
      await tester.pumpAndSettle();
      final reverse = find.text('反转选中页');
      await tester.ensureVisible(reverse);
      await tester.tap(reverse);
      await tester.pumpAndSettle();
      final changed = LibrarySnapshot(
        Map<String, dynamic>.from(await api.call('snapshot')),
      ).books.firstWhere((b) => b.id == comic.id);
      expect(changed.pages.first['id'], comic.pages.last['id']);
      await screenshot('rc005-landscape-pages');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await File('${root.path}/receipt.json').writeAsString(
        jsonEncode({
          'status': 'pass',
          'platform': Platform.operatingSystem,
          'root': root.path,
          'pdfPage': 2,
          'markdownOriginalUnchanged': true,
          'independentTasks': true,
          'pageReverse': true,
          'phoneEvidence': 'Windows-rendered viewport, not Android device',
        }),
      );
    },
  );
}
