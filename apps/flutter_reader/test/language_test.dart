// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:aquantum_reader/data/core_messages.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/l10n/l10n.dart';
import 'package:aquantum_reader/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _EmptyLibrary implements ReaderApi {
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (method != 'snapshot') throw StateError('unexpected $method');
    return {
      'catalog': {
        'id': 'library',
        'inbox': 'inbox',
        'actor': 'local',
        'projects': [
          {'id': 'inbox', 'parent': null, 'name': '收件箱'},
        ],
        'books': [],
        'progress': [],
        'operations': [],
      },
      'storage': {
        'original_bytes': 0,
        'database_bytes': 0,
        'retained_unreferenced_bytes': 0,
        'incomplete_bytes': 0,
      },
      'staging_bytes': 0,
    };
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() {
    debugSystemLocales = const [Locale('zh', 'CN')];
    initLanguage(AppLanguage.system);
  });

  Future<void> start(WidgetTester tester, {Key? key}) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ReaderApp(key: key, api: _EmptyLibrary()));
    await tester.pumpAndSettle();
  }

  Future<void> openMe(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('nav-core.me')));
    await tester.pumpAndSettle();
  }

  /// Scrolls the lazily built Me page until [row] is on screen.
  Future<void> showMeRow(WidgetTester tester, String row) async {
    await tester.scrollUntilVisible(
      find.text(row),
      120,
      scrollable: find.descendant(
        of: find.byKey(const PageStorageKey('me-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Opens the language page from Me through its row, named [row].
  Future<void> chooseLanguage(
    WidgetTester tester,
    String row,
    AppLanguage language,
  ) async {
    await showMeRow(tester, row);
    await tester.tap(find.text(row));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('language-${language.code}')));
    await tester.pumpAndSettle();
  }

  testWidgets('choosing a language switches the shell and open pages', (
    tester,
  ) async {
    await start(tester);
    await openMe(tester);
    expect(find.text('我的'), findsWidgets);

    await chooseLanguage(tester, '语言', AppLanguage.en);
    // The pushed language page itself follows at once.
    expect(find.text('Language'), findsWidgets);
    expect(find.text('System default'), findsOneWidget);
    // Simplified Chinese is both an option and what the system resolves to.
    expect(find.text('简体中文'), findsNWidgets(2));
    expect(find.text('繁體中文'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Me'), findsWidgets);
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('我的'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('nav-core.projects')));
    await tester.pumpAndSettle();
    expect(find.text('Library'), findsWidgets);
    expect(find.text('Import files'), findsWidgets);

    await openMe(tester);
    await chooseLanguage(tester, 'Language', AppLanguage.zhHant);
    expect(find.text('語言'), findsWidgets);
    expect(find.text('跟隨系統'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('外觀'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('nav-core.projects')));
    await tester.pumpAndSettle();
    expect(find.text('資料庫'), findsWidgets);
    expect(find.text('匯入檔案'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the chosen language is restored after a restart', (
    tester,
  ) async {
    await start(tester);
    await openMe(tester);
    await chooseLanguage(tester, '语言', AppLanguage.zhHant);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(languagePreferenceKey), 'zh-Hant');

    // A new app instance starts from the default and reads the preference.
    initLanguage(AppLanguage.system);
    await tester.pumpWidget(const SizedBox());
    await start(tester, key: const ValueKey('restarted'));
    expect(uiLanguage, UiLanguage.zhHant);
    await openMe(tester);
    expect(find.text('外觀'), findsOneWidget);
    await showMeRow(tester, '語言');
    expect(find.text('繁體中文'), findsOneWidget);
  });

  testWidgets('following the system uses the device language order', (
    tester,
  ) async {
    debugSystemLocales = const [Locale('fr'), Locale('en', 'GB')];
    await start(tester);
    expect(uiLanguage, UiLanguage.en);
    await openMe(tester);
    expect(find.text('Me'), findsWidgets);

    await chooseLanguage(tester, 'Language', AppLanguage.zhHans);
    expect(find.text('跟随系统'), findsOneWidget);
    await chooseLanguageOnPage(tester, AppLanguage.system);
    expect(uiLanguage, UiLanguage.en);
    expect(find.text('System default'), findsOneWidget);

    // The device switches to Traditional Chinese while the app is open.
    debugSystemLocales = const [Locale('zh', 'TW')];
    tester.platformDispatcher.localesTestValue = const [Locale('zh', 'TW')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    await tester.pumpAndSettle();
    expect(uiLanguage, UiLanguage.zhHant);
    expect(find.text('跟隨系統'), findsOneWidget);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getString(languagePreferenceKey), 'system');
  });

  test('core messages translate their wrapper and static detail', () {
    addTearDown(() => initLanguage(AppLanguage.system));
    initLanguage(AppLanguage.en);
    expect(
      coreText('无效操作：笔记不能为空'),
      "Invalid operation: The note can't be empty",
    );
    expect(
      coreText('版本冲突：所选页面已改变；请刷新后重试'),
      'Version conflict: The selected pages changed. Refresh and try again',
    );
    expect(coreText('找不到书籍：b1'), 'Book not found: b1');
    expect(coreText('默认（从左到右，继承自：漫画库）'), 'Default (Left to right, from 漫画库)');
    expect(coreText('未收录：动态内容'), '未收录：动态内容');
    initLanguage(AppLanguage.zhHant);
    expect(coreText('暂不支持：此书不是文档格式'), '暫不支援：此書不是文件格式');
    initLanguage(AppLanguage.zhHans);
    expect(coreText('无效操作：笔记不能为空'), '无效操作：笔记不能为空');
  });
}

/// Picks a language on the already open language page.
Future<void> chooseLanguageOnPage(
  WidgetTester tester,
  AppLanguage language,
) async {
  await tester.tap(find.byKey(ValueKey('language-${language.code}')));
  await tester.pumpAndSettle();
}
