// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:ui' show SemanticsAction;

import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TestApi implements ReaderApi {
  final List<Map<String, dynamic>> books = [];
  int position = 0;
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    switch (method) {
      case 'snapshot':
        return {
          'catalog': {
            'id': 'library',
            'inbox': 'inbox',
            'actor': 'local',
            'projects': [
              {'id': 'inbox', 'parent': null, 'name': '收件箱'},
            ],
            'books': books,
            'progress': [
              {
                'book': 'book',
                'actor': 'local',
                'location': {
                  'Paragraph': {'index': position},
                },
              },
            ],
            'operations': [],
          },
          'storage': {
            'original_bytes': 20,
            'database_bytes': 8192,
            'retained_unreferenced_bytes': 0,
            'incomplete_bytes': 0,
          },
          'staging_bytes': 0,
        };
      case 'import_files':
        final file = (args['files'] as List).first;
        expect(utf8.decode(base64Decode(file['data'])), contains('山间笔记'));
        books.add({
          'id': 'book',
          'project': 'inbox',
          'title': '山间笔记',
          'format': 'Txt',
          'revision': 1,
          'pages': [
            {
              'id': 'page',
              'resource': {'bytes': 20},
            },
          ],
        });
        return null;
      case 'reading_checkpoint':
        return null;
      case 'read_text':
        return {
          'paragraphs': ['第一段', '第二段', '第三段'],
        };
      case 'save_progress':
        position = args['index'];
        return null;
      default:
        throw StateError('unexpected $method');
    }
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });
  testWidgets('keyboard resizes content without lifting the mobile dock', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(ReaderApp(api: TestApi()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-core.projects')));
    await tester.pumpAndSettle();
    final dock = find.byKey(const ValueKey('mobile-navigation'));
    final original = tester.getRect(dock);
    await tester.enterText(find.byType(TextField), '键盘期间保留');
    tester.view.viewInsets = const FakeViewPadding(bottom: 310);
    await tester.pumpAndSettle();
    expect(dock, findsNothing);
    expect(tester.getRect(find.byType(TextField)).bottom, lessThan(534));
    expect(tester.takeException(), isNull);
    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pumpAndSettle();
    expect(tester.getRect(dock), original);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '键盘期间保留',
    );
    tester.view.physicalSize = const Size(1220, 844);
    await tester.pumpAndSettle();
    final me = find.byKey(const ValueKey('nav-core.me'));
    final desktopPosition = tester.getRect(me);
    tester.view.viewInsets = const FakeViewPadding(bottom: 310);
    await tester.pumpAndSettle();
    expect(tester.getRect(me), desktopPosition);
    expect(tester.takeException(), isNull);
  });
  testWidgets('mobile pages run beneath the floating dock and end above it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ReaderApp(api: TestApi()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-core.me')));
    await tester.pumpAndSettle();
    final dock = tester.getRect(
      find.byKey(const ValueKey('mobile-navigation')),
    );
    // The dock keeps its place above the system gesture area.
    expect(dock.bottom, 844 - 24 - 12);
    // No tray around the dock: the page itself reaches the bottom edge.
    final page = find.byKey(const PageStorageKey('me-scroll'));
    expect(tester.getRect(page).bottom, 844);
    await tester.drag(page, const Offset(0, -4000));
    await tester.pumpAndSettle();
    expect(
      tester.getRect(find.text('AQuantum Reader  开发构建')).bottom,
      lessThanOrEqualTo(dock.top),
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'floating pages retain safe scroll ends with large text and IME',
    (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(
            disableAnimations: true,
            highContrast: true,
          );
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpWidget(ReaderApp(api: TestApi()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-core.me')));
      await tester.pumpAndSettle();
      final page = find.byKey(const PageStorageKey('me-scroll'));
      final dock = find.byKey(const ValueKey('mobile-navigation'));
      final footer = find.text('AQuantum Reader  开发构建');
      for (final size in [const Size(375, 812), const Size(812, 375)]) {
        tester.view.physicalSize = size;
        await tester.pumpAndSettle();
        expect(tester.getRect(page).bottom, size.height);
        await tester.drag(page, const Offset(0, -10000));
        await tester.pumpAndSettle();
        expect(
          tester.getRect(footer).bottom,
          lessThanOrEqualTo(tester.getRect(dock).top),
        );
        expect(tester.takeException(), isNull);
      }
      tester.view.physicalSize = const Size(375, 812);
      await tester.pumpAndSettle();
      final original = tester.getRect(dock);
      // With an IME, padding excludes its area but viewPadding retains the
      // physical system inset. The shell must consume the keyboard only once.
      tester.view.padding = const FakeViewPadding(top: 24);
      tester.view.viewInsets = const FakeViewPadding(bottom: 310);
      await tester.pumpAndSettle();
      expect(dock, findsNothing);
      expect(tester.getRect(page).bottom, 502);
      await tester.drag(page, const Offset(0, -10000));
      await tester.pumpAndSettle();
      expect(tester.getRect(footer).bottom, lessThanOrEqualTo(502));
      tester.view.viewInsets = FakeViewPadding.zero;
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      await tester.pumpAndSettle();
      expect(tester.getRect(dock), original);
      expect(tester.getRect(page).bottom, 812);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('system bar icons follow the in-app theme under the page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
    // Gesture navigation: the app's appearance request decides the handle.
    tester.view.systemGestureInsets = const FakeViewPadding(
      left: 30,
      right: 30,
    );
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ReaderApp(api: TestApi()));
    await tester.pumpAndSettle();
    SystemUiOverlayStyle bars() => tester
        .widgetList<AnnotatedRegion<SystemUiOverlayStyle>>(
          find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
        )
        .map((region) => region.value)
        .singleWhere((style) => style.systemNavigationBarColor != null);
    expect(bars().statusBarIconBrightness, Brightness.dark);
    expect(bars().systemNavigationBarIconBrightness, Brightness.dark);
    // Android 15 keeps its own scrim at the launch theme; the shell paints it.
    expect(bars().systemNavigationBarContrastEnforced, isFalse);
    await tester.tap(find.byKey(const ValueKey('nav-core.me')));
    await tester.pumpAndSettle();
    await reveal(tester, find.text('深色'));
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    // The in-app choice, not the platform brightness, decides icon contrast.
    expect(bars().statusBarIconBrightness, Brightness.light);
    expect(bars().systemNavigationBarIconBrightness, Brightness.light);
    // A status bar with its own colour is not under the page: leave it alone.
    tester.view.padding = const FakeViewPadding(bottom: 24);
    tester.view.viewPadding = const FakeViewPadding(bottom: 24);
    await tester.pumpAndSettle();
    expect(bars().statusBarIconBrightness, isNull);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'button navigation gets a theme scrim that follows live changes',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      // Three-button navigation: a 48 dp bar and no side back-swipe zones.
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 48);
      tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 48);
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpWidget(ReaderApp(api: TestApi()));
      await tester.pumpAndSettle();
      final scrim = find.byKey(const ValueKey('navigation-bar-scrim'));
      Color scrimColor() => tester
          .widget<ColoredBox>(
            find.descendant(of: scrim, matching: find.byType(ColoredBox)),
          )
          .color;
      Color background() =>
          Theme.of(tester.element(scrim)).scaffoldBackgroundColor;
      Brightness? buttons() => tester
          .widgetList<AnnotatedRegion<SystemUiOverlayStyle>>(
            find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
          )
          .map((region) => region.value)
          .singleWhere((style) => style.systemNavigationBarColor != null)
          .systemNavigationBarIconBrightness;
      expect(tester.getRect(scrim), const Rect.fromLTRB(0, 796, 390, 844));
      // In-app theme matches the system: the scrim continues the page.
      expect(scrimColor(), background().withValues(alpha: 0.9));
      expect(buttons(), Brightness.dark);
      final light = background();
      await tester.tap(find.byKey(const ValueKey('nav-core.me')));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('深色'));
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      // In-app dark under a light system: the device may draw the buttons for
      // the system theme whatever the request, so both stay on its side.
      expect(background(), isNot(light));
      expect(scrimColor(), const Color(0xE6FFFFFF));
      expect(buttons(), Brightness.dark);
      // A live system change to dark restores the match, without a restart.
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(scrimColor(), background().withValues(alpha: 0.9));
      expect(buttons(), Brightness.light);
      // And the opposite mismatch.
      await reveal(tester, find.text('浅色'));
      await tester.tap(find.text('浅色'));
      await tester.pumpAndSettle();
      expect(background(), light);
      expect(scrimColor(), const Color(0xCC000000));
      expect(buttons(), Brightness.light);
      // Gesture navigation reports side back-swipe zones: no scrim there, the
      // page shows through to the screen edge under the handle.
      tester.view.systemGestureInsets = const FakeViewPadding(
        left: 30,
        right: 30,
      );
      await tester.pumpAndSettle();
      expect(scrim, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('library list runs beneath the floating dock and ends above it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(tester.view.reset);
    final api = TestApi();
    for (var i = 0; i < 12; i++) {
      api.books.add({
        'id': 'book-$i',
        'project': 'inbox',
        'title': '书籍$i',
        'format': 'Txt',
        'revision': 1,
        'pages': [
          {
            'id': 'page-$i',
            'resource': {'bytes': 20},
          },
        ],
      });
    }
    await tester.pumpWidget(ReaderApp(api: api));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('nav-core.projects')));
    await tester.pumpAndSettle();
    final dock = tester.getRect(
      find.byKey(const ValueKey('mobile-navigation')),
    );
    final list = find.byKey(const PageStorageKey('project-inbox'));
    // Pages are not shortened for the dock: the list reaches the screen edge.
    expect(tester.getRect(list).bottom, 844);
    await tester.drag(list, const Offset(0, -9000));
    await tester.pumpAndSettle();
    // The last file's own controls can still be reached above the dock.
    expect(
      tester.getRect(find.byTooltip('文件操作').last).bottom,
      lessThanOrEqualTo(dock.top),
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'switching shortcuts and resizing retains the project search context',
    (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(ReaderApp(api: TestApi()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-core.projects')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '保留查询');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-core.me')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-core.projects')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '保留查询',
      );
      tester.view.physicalSize = const Size(1220, 820);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '保留查询',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    '375px phone imports an explicit sample, reads and resumes a paragraph',
    (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = TestApi();
      await tester.pumpWidget(ReaderApp(api: api));
      await tester.pumpAndSettle();
      // ignore: avoid_print
      expect(find.text('继续阅读'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('nav-core.projects')));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('试读示例'));
      await tester.tap(find.text('试读示例'));
      await tester.pumpAndSettle();
      expect(find.text('山间笔记'), findsWidgets);
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.tap(find.text('山间笔记').first);
      await tester.pumpAndSettle();
      expect(find.text('第一段'), findsOneWidget);
      await tester.tapAt(const Offset(100, 60));
      await tester.pumpAndSettle();
      // The one controller moves a paged text by page; the second paragraph is
      // on the page the slider lands on next.
      await tester.tap(find.byTooltip('下一页'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('目录与内容导航'));
      await tester.pumpAndSettle();
      // The sample is three short paragraphs, so the page layout puts them all
      // on its first page and the outline lists that one page.
      await tester.tap(find.byType(ListTile).first);
      await tester.pumpAndSettle();
      expect(find.text('第一段'), findsOneWidget);
      expect(api.position, 0);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('山间笔记').first);
      await tester.pumpAndSettle();
      expect(find.text('第一段'), findsOneWidget);
      await tester.tapAt(const Offset(100, 60));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pageBack();
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'desktop layout and large-text landscape preserve navigation and theme access',
    (tester) async {
      final semantics = tester.ensureSemantics();
      tester.view.physicalSize = const Size(1220, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = TestApi();
      await tester.pumpWidget(ReaderApp(api: api));
      await tester.pumpAndSettle();
      expect(
        tester
            .getSemantics(find.bySemanticsLabel(RegExp('^我的\$')))
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isTrue,
      );
      semantics.dispose();
      expect(
        tester.getSize(find.byKey(const ValueKey('nav-core.me'))).width,
        greaterThanOrEqualTo(48),
      );
      await tester.tap(find.byTooltip('展开导航'));
      await tester.pumpAndSettle();
      expect(find.text('AQuantum\nReader'), findsOneWidget);
      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('深色'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      final context = tester.element(find.text('存储管理'));
      expect(Theme.of(context).brightness, Brightness.dark);
      tester.view.physicalSize = const Size(812, 375);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> reveal(WidgetTester tester, Finder finder) async {
  if (finder.evaluate().isEmpty) {
    await tester.drag(find.byType(Scrollable).last, const Offset(0, 5000));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      finder,
      160,
      scrollable: find.byType(Scrollable).last,
    );
  } else {
    await tester.ensureVisible(finder);
  }
  await tester.pumpAndSettle();
}
