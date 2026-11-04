// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:aquantum_reader/design/theme.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:aquantum_reader/data/models.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/screens/reader_screen.dart';
import 'package:aquantum_reader/widgets/reader_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'qa_storage.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native Rust resources use identical reader chrome and real panels',
    (tester) async {
      // Isolated QA storage: never the reader's real app data.
      await configureQaStorage();
      final prefs = await SharedPreferences.getInstance();
      final oldUi = prefs.getString('reader-ui.v1');
      final oldFont = prefs.getDouble('reader-font-size');
      await prefs.remove('reader-ui.v1');
      await prefs.setDouble('reader-font-size', 20);
      addTearDown(() async {
        if (oldUi == null) {
          await prefs.remove('reader-ui.v1');
        } else {
          await prefs.setString('reader-ui.v1', oldUi);
        }
        if (oldFont == null) {
          await prefs.remove('reader-font-size');
        } else {
          await prefs.setDouble('reader-font-size', oldFont);
        }
      });
      final support = await getApplicationSupportDirectory();
      final root = Directory(
        '${support.path}/qa-reader-shell-${DateTime.now().millisecondsSinceEpoch}',
      );
      await root.create(recursive: true);
      final api = RustReaderApi(root.path);
      final initial = await api.call('snapshot');
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawColor(const Color(0xffece9df), BlendMode.src);
      for (var i = 0; i < 4; i++) {
        canvas.drawRect(
          Rect.fromLTWH(12, 12 + i * 145, 216, 130),
          Paint()..color = Color(i.isEven ? 0xff5f6d72 : 0xffa0b0a9),
        );
      }
      final picture = recorder.endRecording();
      final image = await picture.toImage(240, 600);
      final png = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
      image.dispose();
      picture.dispose();
      await api.call('import_files', {
        'target': initial['catalog']['inbox'],
        'files': [
          {
            'name': '工具栏验证.txt',
            'data': base64Encode(
              utf8.encode('统一阅读工具栏\n\n第二段：真实检索命中。\n\n第三段：阅读位置与工具栏解耦。'),
            ),
          },
          {'name': '001.png', 'data': base64Encode(png)},
          {'name': '002.png', 'data': base64Encode(png)},
        ],
      });
      final snapshot = LibrarySnapshot(await api.call('snapshot'));
      final text = snapshot.books.firstWhere((b) => !b.isComic);
      final comic = snapshot.books.firstWhere((b) => b.isComic);
      // TXT opens left/right by default since RC007; this flow checks that a
      // search hit lands on its paragraph, which scrolling reports exactly
      // (three short paragraphs share one page when paged).
      await (ReaderPreferences()..textPaged = false).save(bookId: text.id);
      // Comics default to continuous since RC007; this flow starts paged and
      // switches to continuous itself.
      await (ReaderPreferences()..continuous = false).save(bookId: comic.id);
      const capture = ValueKey('shell-native-capture');
      Future<void> pumpBook(Book book) async {
        await tester.pumpWidget(
          Align(
            alignment: Alignment.topLeft,
            child: RepaintBoundary(
              key: capture,
              child: SizedBox(
                width: 375,
                child: MaterialApp(
                  key: ValueKey(book.id),
                  debugShowCheckedModeBanner: false,
                  theme: readerTheme(
                    Brightness.light,
                  ).copyWith(platform: TargetPlatform.android),
                  home: ReaderScreen(api: api, book: book, initialPosition: 0),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        for (
          var i = 0;
          i < 100 &&
              find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
          i++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        final rect = tester.getRect(
          find.byKey(const ValueKey('reader-content-hit-region')),
        );
        await tester.tapAt(rect.topLeft + const Offset(100, 50));
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

      await pumpBook(text);
      final textPositions = [
        for (final id in [
          'back',
          'settings',
          'navigation',
          'view',
          'bookmarks',
          'search',
          'more',
        ])
          tester.getCenter(find.byKey(ValueKey('reader-action-$id'))),
      ];
      await screenshot('shell-text-toolbar');
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      await screenshot('shell-text-aa');
      await tester.tap(find.byTooltip('关闭面板'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '真实检索');
      await tester.tap(find.byTooltip('开始搜索'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ListTile).first);
      await tester.pumpAndSettle();
      final position = LibrarySnapshot(
        await api.call('snapshot'),
      ).position(text);
      expect(position, 1);
      await tester.tap(find.byTooltip('书签'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加当前位置书签'));
      await tester.pumpAndSettle();
      await screenshot('shell-text-bookmarks');
      await tester.tap(find.byTooltip('关闭面板'));
      await tester.pumpAndSettle();
      await pumpBook(comic);
      final comicPositions = [
        for (final id in [
          'back',
          'settings',
          'navigation',
          'view',
          'bookmarks',
          'search',
          'more',
        ])
          tester.getCenter(find.byKey(ValueKey('reader-action-$id'))),
      ];
      expect(comicPositions, textPositions);
      await screenshot('shell-comic-toolbar');
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      expect(find.text('适应宽度'), findsOneWidget);
      expect(find.textContaining('字号'), findsNothing);
      await screenshot('shell-comic-aa');
      await tester.tap(find.text('适应宽度'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('纵向连续阅读'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('无缝图片衔接'));
      await tester.tap(find.text('无缝图片衔接'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭面板'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('阅读视图与页面导航'));
      await tester.pumpAndSettle();
      await screenshot('shell-comic-navigation');
      await tester.tap(find.byTooltip('关闭面板'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
