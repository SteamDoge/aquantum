// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:aquantum_reader/reader/reader_shell.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:aquantum_reader/main.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/screens/profile_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'rc4 real menu, reader, shared stats, configurable layouts and restart',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      final keys = [
        'navigation.v1.mobile',
        'navigation.v1.desktop',
        'dashboard.v1.home',
        'dashboard.v1.statistics',
        'project-grid.v1',
        'project-sort.v1',
        'theme',
        'reader-font-size',
        'reader-ui.v1',
        'plugins.compiled.v1',
        ...prefs.getKeys().where((k) => k.startsWith('reading-pending.')),
      ];
      final backup = {for (final k in keys) k: prefs.get(k)};
      for (final k in keys) {
        await prefs.remove(k);
      }
      await prefs.setString('theme', 'light');
      addTearDown(() async {
        for (final k in keys) {
          final v = backup[k];
          if (v is String) {
            await prefs.setString(k, v);
          } else if (v is double) {
            await prefs.setDouble(k, v);
          } else if (v is bool) {
            await prefs.setBool(k, v);
          } else {
            await prefs.remove(k);
          }
        }
      });
      final support = await getApplicationSupportDirectory();
      final root = Directory(
        '${support.path}/qa-rc4-${DateTime.now().millisecondsSinceEpoch}',
      );
      await root.create(recursive: true);
      final api = RustReaderApi(root.path);
      final initial = await api.call('snapshot');
      final project = await api.call('create_project', {
        'parent': initial['catalog']['inbox'],
        'name': '考试资料',
      });
      final imported = await api.call('import_files', {
        'target': project,
        'files': [
          {
            'name': '阅读验证.txt',
            'data': base64Encode(utf8.encode('第一段\n\n第二段\n\n第三段\n\n第四段')),
          },
        ],
      });
      const capture = Key('rc4-capture');
      Future<void> showApp(String key) async {
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: ReaderApp(key: ValueKey(key), api: api),
          ),
        );
      }

      Future<void> wait(Finder finder) async {
        for (var i = 0; i < 150 && finder.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(finder, findsWidgets);
        await tester.pumpAndSettle();
      }

      Future<void> revealReaderChrome() async {
        if (find.byTooltip('阅读设置').hitTestable().evaluate().isEmpty) {
          final rect = tester.getRect(
            find.byKey(const ValueKey('reader-content-hit-region')),
          );
          await tester.tapAt(rect.topLeft + const Offset(100, 60));
          await tester.pumpAndSettle();
        }
      }

      Future<void> reveal(Finder finder) async {
        if (finder.evaluate().isEmpty) {
          await tester.drag(
            find.byType(Scrollable).last,
            const Offset(0, 5000),
          );
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            finder,
            180,
            scrollable: find.byType(Scrollable).last,
          );
        } else {
          await tester.ensureVisible(finder);
        }
        await tester.pumpAndSettle();
      }

      Future<void> image(String name) async {
        await tester.pumpAndSettle();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(capture),
        );
        final img = await boundary.toImage(pixelRatio: 1);
        final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
        final dir = Directory(
          Platform.environment['AQ_SCREENSHOT_DIR'] ?? '${root.path}/captures',
        );
        await dir.create(recursive: true);
        await File(
          '${dir.path}/rc4-$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        img.dispose();
      }

      await showApp('first');
      await wait(find.byKey(const ValueKey('nav-core.home')));
      expect(find.byKey(const ValueKey('nav-core.plugins')), findsNothing);
      await image('home-empty');
      await tester.tap(find.byKey(const ValueKey('nav-core.projects')));
      await wait(find.text('考试资料'));
      await tester.tap(find.text('考试资料'));
      await wait(find.text('阅读验证'));
      await tester.longPress(find.text('阅读验证').first);
      await wait(find.text('重命名'));
      await image('file-menu');
      await tester.tap(find.text('重命名'));
      await wait(find.widgetWithText(AlertDialog, '重命名文件'));
      await tester.enterText(find.byType(TextField).last, '更名后的资料');
      await tester.tap(find.text('保存'));
      await wait(find.text('更名后的资料'));
      await tester.tap(find.text('更名后的资料').first);
      await revealReaderChrome();
      await wait(find.byTooltip('目录与内容导航'));
      await tester.tap(find.byTooltip('目录与内容导航'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(ListTile).at(1));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ReaderShell>(find.byType(ReaderShell)).adapter.position,
        1,
      );
      await tester.tap(find.byTooltip('阅读设置'));
      await wait(find.text('阅读设置'));
      await tester.tap(find.text('系统字体'));
      await tester.pumpAndSettle();
      await image('reader-settings');
      await tester.tapAt(const Offset(10, 70));
      await tester.pumpAndSettle();
      await Future<void>.delayed(const Duration(seconds: 2));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await wait(find.byKey(const ValueKey('nav-core.home')));
      await tester.tap(find.byKey(const ValueKey('nav-core.home')));
      await wait(find.text('继续阅读'));
      await image('home-reading');
      final snap = await api.call('snapshot');
      expect(snap['catalog']['books'][0]['title'], '更名后的资料');
      expect(snap['catalog']['reading_sessions'], isNotEmpty);
      final milliseconds = (snap['catalog']['reading_sessions'] as List)
          .fold<int>(0, (n, s) => n + (s['elapsed_ms'] as int));
      expect(milliseconds, greaterThan(0));
      await tester.tap(find.byKey(const ValueKey('edit-home')));
      await wait(find.text('主页组件'));
      await tester.tap(find.byTooltip('移除组件').first);
      await tester.pumpAndSettle();
      await image('widget-editor');
      await tester.pageBack();
      await tester.pumpAndSettle();
      final homeConfig = prefs.getString('dashboard.v1.home');
      expect(homeConfig, isNotNull);
      expect(prefs.getString('dashboard.v1.statistics'), isNull);
      await tester.tap(find.byKey(const ValueKey('nav-core.me')));
      await wait(find.byType(ProfileScreen));
      await reveal(find.text('阅读统计'));
      await tester.tap(find.text('阅读统计'));
      await wait(find.byKey(const ValueKey('edit-statistics')));
      await image('statistics');
      await showApp('restart');
      await wait(find.byKey(const ValueKey('nav-core.home')));
      await tester.tap(find.byKey(const ValueKey('nav-core.home')));
      await tester.pumpAndSettle();
      expect(prefs.getString('dashboard.v1.home'), homeConfig);
      await api.call('build_index');
      expect(
        (await api.call('search_text', {'query': '第二段'}))[0]['paragraph'],
        1,
      );
      final current = await api.call('snapshot');
      expect(
        current['catalog']['progress'][0]['location']['Paragraph']['index'],
        1,
      );
      await File('${root.path}/rc4-receipt.json').writeAsString(
        jsonEncode({
          'book': imported['books'][0],
          'elapsed_ms': milliseconds,
          'sessions': snap['catalog']['reading_sessions'],
          'home_layout': homeConfig,
          'index_status': await api.call('index_status'),
          'result': 'pass',
        }),
      );
      debugPrint('RC4_NATIVE_RECEIPT: ${root.path}/rc4-receipt.json');
      expect(tester.takeException(), isNull);
    },
  );
}
