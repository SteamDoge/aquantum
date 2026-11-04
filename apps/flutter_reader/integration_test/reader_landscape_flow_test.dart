// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:aquantum_reader/data/models.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/design/theme.dart';
import 'package:aquantum_reader/reader/reader_page_overview.dart';
import 'package:aquantum_reader/reader/reader_shell.dart';
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
  testWidgets('native wide windows and phone landscape use real page previews', (
    tester,
  ) async {
    // Isolated QA storage: never the reader's real app data.
    await configureQaStorage();
    final prefs = await SharedPreferences.getInstance();
    final old = prefs.getString('reader-ui.v1');
    addTearDown(() async {
      if (old == null) {
        await prefs.remove('reader-ui.v1');
      } else {
        await prefs.setString('reader-ui.v1', old);
      }
    });
    final support = await getApplicationSupportDirectory();
    final root = Directory(
      '${support.path}/qa-landscape-${DateTime.now().millisecondsSinceEpoch}',
    );
    await root.create(recursive: true);
    final api = RustReaderApi(root.path);
    final initial = await api.call('snapshot');
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..drawColor(const Color(0xfff5efe1), BlendMode.src);
    for (var i = 0; i < 4; i++) {
      canvas.drawRect(
        Rect.fromLTWH(16, 16 + i * 140, 208, 125),
        Paint()..color = Color(i.isEven ? 0xff6b7b82 : 0xffb5b9a8),
      );
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(240, 600);
    final png = (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
    image.dispose();
    picture.dispose();
    final paragraphs = [
      for (var i = 0; i < 15; i++)
        '第 ${i + 1} 段 · 横屏阅读\n${List.filled(8, '阅读器应当根据窗口宽度排版。显示工具后，原页面缩小，左右邻页仍然可见；滑动预览即可切换实际阅读位置。').join()}',
    ];
    await api.call('import_files', {
      'target': initial['catalog']['inbox'],
      'files': [
        {
          'name': '横屏阅读验证.txt',
          'data': base64Encode(utf8.encode(paragraphs.join('\n\n'))),
        },
        for (var i = 0; i < 3; i++)
          {'name': '00$i.png', 'data': base64Encode(png)},
      ],
    });
    final library = LibrarySnapshot(await api.call('snapshot'));
    final text = library.books.firstWhere((b) => !b.isComic);
    final comic = library.books.firstWhere((b) => b.isComic);
    const capture = ValueKey('landscape-native-capture');
    var serial = 0;
    Future<void> show(Book book, {Size? size, bool paged = false}) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await (ReaderPreferences()
            ..textPaged = paged
            ..continuous = !paged)
          .save(bookId: book.id);
      if (book.isComic || book.isPdf) {
        await api.call('set_book_direction', {
          'book': book.id,
          'direction': paged ? 'LeftToRight' : 'TopToBottom',
        });
      }
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
                builder: (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(size: size ?? MediaQuery.sizeOf(context)),
                  child: child!,
                ),
                home: ReaderScreen(api: api, book: book, initialPosition: 0),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (
        var i = 0;
        i < 100 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      if (find.byTooltip('阅读设置').hitTestable().evaluate().isEmpty) {
        final rect = tester.getRect(
          find.byKey(const ValueKey('reader-content-hit-region')),
        );
        await tester.tapAt(rect.topLeft + const Offset(100, 50));
        await tester.pumpAndSettle();
      }
    }

    Future<void> screenshot(String name) async {
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

    List<Offset> actions() => [
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
    await show(text);
    expect(tester.getSize(find.byKey(capture)).width, greaterThan(900));
    expect(find.byType(Slider), findsNothing);
    await screenshot('windows-wide-scroll');
    final desktopActions = actions();
    await show(text, paged: true);
    expect(find.byType(ReaderPageOverview), findsOneWidget);
    expect(actions(), desktopActions);
    await tester.tap(find.byTooltip('下一页'));
    await tester.pumpAndSettle();
    await screenshot('windows-wide-text-pages');
    final before = tester
        .widget<ReaderShell>(find.byType(ReaderShell))
        .adapter
        .position;
    await tester.drag(
      find.byKey(const ValueKey('reader-page-overview')),
      const Offset(-700, 0),
    );
    await tester.pumpAndSettle();
    final after = tester
        .widget<ReaderShell>(find.byType(ReaderShell))
        .adapter
        .position;
    expect(after, greaterThan(before));
    await tester.tap(find.byKey(ValueKey('reader-overview-page-$after')));
    await tester.pumpAndSettle();
    expect(find.byType(ReaderPageOverview), findsNothing);
    await screenshot('windows-wide-text-immersive');
    await show(comic, paged: true);
    expect(actions(), desktopActions);
    await tester.tap(find.byTooltip('下一页'));
    await tester.pumpAndSettle();
    await screenshot('windows-wide-comic-pages');
    await show(text, size: const Size(812, 375));
    expect(find.byType(Slider), findsNothing);
    await screenshot('phone-landscape-scroll');
    await tester.pump(const Duration(seconds: 5));
    expect(find.byTooltip('阅读设置').hitTestable(), findsOneWidget);
    await tester.tapAt(const Offset(400, 250));
    await tester.pumpAndSettle();
    expect(find.byTooltip('阅读设置').hitTestable(), findsNothing);
    await show(text, size: const Size(812, 375), paged: true);
    await tester.tap(find.byTooltip('下一页'));
    await tester.pumpAndSettle();
    await screenshot('phone-landscape-text-pages');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
