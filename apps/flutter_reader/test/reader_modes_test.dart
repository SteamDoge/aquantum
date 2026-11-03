// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'package:aquantum_reader/data/models.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/reader/reader_scrollbar.dart';
import 'package:aquantum_reader/screens/reader_screen.dart';
import 'package:aquantum_reader/widgets/comic_strip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ComicApi implements ReaderApi {
  int position = 0;

  /// Effective turn direction the fake core reports, exactly like a real book
  /// that chose 从上到下 in the direction panel.
  String direction = 'LeftToRight';
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (method == 'read_image') {
      return 'data:image/png;base64,${base64Encode(base64Decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII='))}';
    }
    if (method == 'effective_direction') {
      return {
        'value': direction,
        'source': direction == 'LeftToRight' ? null : 'book',
      };
    }
    if (method == 'book_crops') return <String, dynamic>{};
    if (method == 'save_progress') position = args['index'];
    return null;
  }
}

void main() {
  testWidgets(
    'comic keeps the current stable page when switching continuous and paged modes',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'reader-ui.v2.book': jsonEncode({
          'version': 1,
          'lineHeight': 1.9,
          'paragraphGap': 24,
          'margin': 28,
          'font': 'serif',
          'theme': 'system',
          'dock': 'top',
          'continuous': false,
          'textPaged': false,
          'rotation': 0,
          'pageAnimation': true,
          'seamless': false,
          'rightToLeft': false,
          'fit': 'page',
          'weight': 400,
        }),
      });
      final api = ComicApi();
      final book = Book({
        'id': 'book',
        'project': 'inbox',
        'title': '漫画',
        'format': 'Comic',
        'revision': 1,
        'pages': [
          for (var i = 0; i < 3; i++)
            {
              'id': 'page-$i',
              'resource': {'bytes': 1},
            },
        ],
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        ReaderScreen(api: api, book: book, initialPosition: 0),
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(100, 60));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('纵向连续阅读'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      // Continuous reading swaps the bottom controller for the whole-book
      // scrollbar.
      expect(find.byType(ReaderScrollbar), findsOneWidget);
      expect(find.text('1 / 3 页'), findsNothing);
      await tester.tap(find.byTooltip('目录与内容导航'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ListTile).at(2));
      await tester.pumpAndSettle();
      expect(api.position, 2);
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('纵向连续阅读'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      // The second toggle returns to discrete paging, so the bottom controller
      // is present again without changing the stored page.
      expect(find.text('3 / 3 页'), findsOneWidget);
      expect(api.position, 2);
      expect(tester.takeException(), isNull);
      await tester.pageBack();
      await tester.pumpAndSettle();
    },
  );
  testWidgets('从上到下 reads a comic as one free scroll, never a vertical pager', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'reader-ui.v1': jsonEncode({
        'version': 1,
        'lineHeight': 1.9,
        'paragraphGap': 24,
        'margin': 28,
        'font': 'serif',
        'theme': 'system',
        'dock': 'top',
        'continuous': false,
        'textPaged': false,
        'rotation': 0,
        'pageAnimation': true,
        'seamless': false,
        'rightToLeft': false,
        'fit': 'page',
        'weight': 400,
      }),
    });
    final api = ComicApi()..direction = 'TopToBottom';
    final book = Book({
      'id': 'book',
      'project': 'inbox',
      'title': '漫画',
      'format': 'Comic',
      'revision': 1,
      'pages': [
        for (var i = 0; i < 3; i++)
          {
            'id': 'page-$i',
            'resource': {'bytes': 1},
          },
      ],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderScreen(api: api, book: book, initialPosition: 0),
      ),
    );
    await tester.pumpAndSettle();
    // Top-to-bottom reading is the continuous mode: pictures are joined into
    // one strip, there is no pager and no bottom page controller.
    expect(find.byType(PageView), findsNothing);
    expect(find.byType(ComicStrip), findsOneWidget);
    expect(find.byType(ReaderScrollbar), findsOneWidget);
    expect(find.text('1 / 3 页'), findsNothing);
    // Pictures do not decode in widget tests, so free stopping inside a
    // picture is checked on a device; the strip is the scroll that allows it.
    expect(tester.takeException(), isNull);
  });
  testWidgets('paged comics turn left/right by whole pages only', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      // The reader cached RTL from an earlier 从右到左 choice. Every numeric
      // field must be present: ReaderPreferences.load casts them directly.
      'reader-ui.v1': jsonEncode({
        'version': 1,
        'lineHeight': 1.9,
        'paragraphGap': 24,
        'margin': 28,
        'font': 'serif',
        'theme': 'system',
        'dock': 'top',
        'continuous': false,
        'textPaged': false,
        'rotation': 0,
        'pageAnimation': true,
        'seamless': false,
        'rightToLeft': true,
        'fit': 'page',
        'weight': 400,
      }),
    });
    final api = ComicApi()..direction = 'RightToLeft';
    final book = Book({
      'id': 'book',
      'project': 'inbox',
      'title': '漫画',
      'format': 'Comic',
      'revision': 1,
      'pages': [
        for (var i = 0; i < 3; i++)
          {
            'id': 'page-$i',
            'resource': {'bytes': 1},
          },
      ],
    });
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderScreen(api: api, book: book, initialPosition: 0),
      ),
    );
    await tester.pumpAndSettle();
    final pageView = tester.widget<PageView>(find.byType(PageView));
    expect(pageView.scrollDirection, Axis.horizontal);
    expect(pageView.reverse, isTrue, reason: '从右到左 mirrors the pager');
    expect(find.byType(ReaderScrollbar), findsNothing);
    final controller = pageView.controller!;
    // A short drag springs back to the whole page it started on.
    await tester.drag(find.byType(PageView), const Offset(60, 0));
    await tester.pumpAndSettle();
    expect(controller.page, 0);
    // A full drag lands exactly on the next page, never between two.
    await tester.drag(find.byType(PageView), const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(controller.page, 1);
    expect(api.position, 1);
    expect(tester.takeException(), isNull);
  });
}
