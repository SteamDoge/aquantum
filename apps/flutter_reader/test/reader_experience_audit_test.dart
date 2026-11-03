// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'package:aquantum_reader/widgets/reader_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'reader_shell_test.dart' show FixtureAdapter, shell, book;
import 'reader_modes_test.dart' show ComicApi;
import 'package:aquantum_reader/screens/reader_screen.dart';
import 'package:aquantum_reader/widgets/comic_strip.dart';

class ContinuousAuditAdapter extends FixtureAdapter {
  ContinuousAuditAdapter() : super('audit-scroll');
  @override
  bool get paged => false;
}

class InheritedComicApi extends ComicApi {
  final writes = <String>[];
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (method == 'effective_gap') {
      return {'value': 'Gapped', 'source': 'inbox'};
    }
    if (method == 'set_gap') {
      writes.add('gap:${args['seamless']}');
      return null;
    }
    if (method == 'resolve_book_direction') {
      writes.add('direction:${args['direction']}');
      direction = args['direction'];
      return null;
    }
    return super.call(method, args);
  }
}

void main() {
  testWidgets(
    'continuous reader shows the top toolbar with a saved bottom dock',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        shell(ContinuousAuditAdapter(), desktop: true, dock: 'bottom'),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('阅读设置').hitTestable(), findsOneWidget);
      expect(tester.getTopLeft(find.byTooltip('阅读设置')).dy, lessThan(100));
    },
  );
  test(
    'absent fields keep format defaults in an existing per-book record',
    () async {
      SharedPreferences.setMockInitialValues({
        'reader-ui.v2.partial': jsonEncode({'version': 1, 'theme': 'dark'}),
      });
      final p = ReaderPreferences();
      await p.load(bookId: 'partial', format: 'Comic');
      expect(p.theme, 'dark');
      expect(p.seamless, isTrue);
      expect(p.fit, 'width');
      expect(p.continuous, isTrue);
      expect(p.lineHeight, 1.9);
    },
  );
  testWidgets(
    'comic reads inherited gaps and writes changes through the core',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final api = InheritedComicApi();
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderScreen(api: api, book: book('Comic'), initialPosition: 0),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<ComicStrip>(find.byType(ComicStrip)).seamless,
        isFalse,
      );
      final area = tester.getRect(
        find.byKey(const ValueKey('reader-content-hit-region')),
      );
      await tester.tapAt(area.topLeft + const Offset(100, 60));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('阅读设置').hitTestable());
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('无缝'));
      await tester.tap(find.text('无缝'));
      await tester.pumpAndSettle();
      expect(api.writes, contains('gap:true'));
      expect(
        tester.widget<ComicStrip>(find.byType(ComicStrip)).seamless,
        isTrue,
      );
    },
  );
  testWidgets('comic quick horizontal direction persists through the core', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await (ReaderPreferences()..continuous = false).save(bookId: 'test-Comic');
    final api = InheritedComicApi();
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderScreen(api: api, book: book('Comic'), initialPosition: 0),
      ),
    );
    await tester.pumpAndSettle();
    final area = tester.getRect(
      find.byKey(const ValueKey('reader-content-hit-region')),
    );
    await tester.tapAt(area.topLeft + const Offset(100, 60));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('阅读设置').hitTestable());
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('从右到左'));
    await tester.tap(find.text('从右到左'));
    await tester.pumpAndSettle();
    expect(api.writes, contains('direction:RightToLeft'));
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    await tester.pumpWidget(
      MaterialApp(
        home: ReaderScreen(api: api, book: book('Comic'), initialPosition: 0),
      ),
    );
    await tester.pumpAndSettle();
    final pager = tester.widget<PageView>(find.byType(PageView));
    expect(pager.reverse, isTrue);
  });
}
