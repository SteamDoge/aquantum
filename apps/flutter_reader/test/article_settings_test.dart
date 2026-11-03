// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aquantum_reader/widgets/article_settings_panel.dart';
import 'package:aquantum_reader/widgets/reader_settings.dart';
import 'package:aquantum_reader/reader/text_pagination.dart';

void main() {
  test(
    'day and night colours persist independently and legacy brightness is discarded',
    () async {
      SharedPreferences.setMockInitialValues({
        'reader-ui.v2.palette':
            '{"version":1,"theme":"green","brightness":0.2}',
      });
      final p = ReaderPreferences();
      await p.load(bookId: 'palette', format: 'Txt');
      expect(p.dayBackground, 'green');
      p.selectBackground('navy', dark: true);
      p.selectBackground('paper', dark: false);
      await p.save(bookId: 'palette');
      final restored = ReaderPreferences();
      await restored.load(bookId: 'palette', format: 'Txt');
      expect(restored.dayBackground, 'paper');
      expect(restored.nightBackground, 'navy');
      restored.theme = 'system';
      expect(restored.activeBackground(Brightness.light), 'paper');
      expect(restored.activeBackground(Brightness.dark), 'navy');
      expect(
        (await SharedPreferences.getInstance()).getString(
          'reader-ui.v2.palette',
        ),
        isNot(contains('brightness')),
      );
    },
  );

  test(
    'removed vertical effect falls back without changing book preferences',
    () async {
      SharedPreferences.setMockInitialValues({
        'reader-ui.v2.legacy':
            '{"version":1,"turnEffect":"vertical","textPaged":true,"continuous":false,"lineHeight":2.0}',
      });
      final prefs = ReaderPreferences();
      await prefs.load(bookId: 'legacy', format: 'Txt');
      expect(prefs.turnEffect, 'slide');
      expect(prefs.textPaged, isTrue);
      expect(prefs.continuous, isFalse);
      expect(prefs.lineHeight, 2);
    },
  );
  testWidgets(
    'Aa spacing presets and effect persist without changing reading mode',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = ReaderPreferences()
        ..textPaged = true
        ..continuous = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, refresh) => ArticleSettingsPanel(
                preferences: prefs,
                fontSize: 20,
                onFont: (_) {},
                onChanged: (edit) => refresh(edit),
                advanced: (_, _) => const SizedBox(),
              ),
            ),
          ),
        ),
      );
      expect(find.text('上下翻页'), findsNothing);
      expect(find.text('阅读亮度'), findsNothing);
      expect(find.text('日间背景'), findsOneWidget);
      expect(find.text('夜间背景'), findsOneWidget);
      await tester.ensureVisible(find.text('覆盖翻页'));
      await tester.tap(find.text('覆盖翻页'));
      await tester.pumpAndSettle();
      expect(prefs.turnEffect, 'cover');
      expect(prefs.textPaged, isTrue);
      expect(prefs.continuous, isFalse);
      await tester.ensureVisible(find.text('间距设置'));
      await tester.tap(find.text('间距设置'));
      await tester.pumpAndSettle();
      expect(find.text('行间距'), findsOneWidget);
      expect(find.text('段间距'), findsOneWidget);
      expect(find.text('页面边距'), findsOneWidget);
      await tester.tap(find.text('较大').first);
      await tester.pumpAndSettle();
      expect(prefs.lineHeight, 2);
      await prefs.save(bookId: 'article');
      final restored = ReaderPreferences();
      await restored.load(bookId: 'article', format: 'Txt');
      expect(restored.turnEffect, 'cover');
      expect(restored.textPaged, isTrue);
      expect(restored.lineHeight, 2);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('changing the turn effect preserves the current discrete page', (
    tester,
  ) async {
    final layout = TextPagination.layout(
      paragraphs: [List.filled(300, '正文内容。').join()],
      viewport: const Size(375, 800),
      style: const TextStyle(fontSize: 20, height: 1.9),
      scaler: TextScaler.noScaling,
      direction: TextDirection.ltr,
      margin: 28,
      paragraphGap: 24,
    );
    final controller = PagedTextController();
    var effect = 'slide';
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return PagedTextReader(
              layout: layout,
              controller: controller,
              initialPage: 0,
              onPage: (_) {},
              effect: effect,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    controller.goTo(2, animate: false);
    await tester.pumpAndSettle();
    expect(controller.page, 2);
    update(() => effect = 'cover');
    await tester.pumpAndSettle();
    expect(controller.page, 2);
    update(() => effect = 'curl');
    await tester.pumpAndSettle();
    expect(controller.page, 2);
    await tester.pumpWidget(const SizedBox());
  });
  for (final effect in ['slide', 'cover', 'curl']) {
    testWidgets('$effect page effect always settles on an integer page', (
      tester,
    ) async {
      final layout = TextPagination.layout(
        paragraphs: [List.filled(300, '正文内容。').join()],
        viewport: const Size(375, 800),
        style: const TextStyle(fontSize: 20, height: 1.9),
        scaler: TextScaler.noScaling,
        direction: TextDirection.ltr,
        margin: 28,
        paragraphGap: 24,
      );
      final controller = PagedTextController();
      await tester.pumpWidget(
        MaterialApp(
          home: PagedTextReader(
            layout: layout,
            controller: controller,
            initialPage: 0,
            onPage: (_) {},
            effect: effect,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final area = find.byType(PagedTextReader);
      await tester.dragFrom(
        tester.getTopLeft(area) + const Offset(10, 10),
        const Offset(-650, 0),
      );
      await tester.pumpAndSettle();
      expect(controller.page, 1);
      await tester.dragFrom(
        tester.getTopLeft(area) + const Offset(10, 10),
        const Offset(650, 0),
      );
      await tester.pumpAndSettle();
      expect(controller.page, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
