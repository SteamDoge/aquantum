// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:aquantum_reader/reader/reader_shell.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/main.dart';
import 'package:aquantum_reader/screens/profile_screen.dart';
import 'package:aquantum_reader/plugins/plugin_package.dart';
import '../test/plugin_fixtures.dart' show pluginZip;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrintDone;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aquantum_reader/widgets/reader_settings.dart';
import 'qa_storage.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native platform imports, reads, records a note and restores its position',
    (tester) async {
      await configureQaStorage();
      final support = await getApplicationSupportDirectory();
      final preferences = await SharedPreferences.getInstance();
      final previousTheme = preferences.getString('theme');
      final navBackup = {
        for (final key in [
          'navigation.v1.mobile',
          'navigation.v1.desktop',
          'plugins.javascript.v1',
          'reader-ui.v1',
        ])
          key: preferences.getString(key),
      };
      for (final key in navBackup.keys) {
        await preferences.remove(key);
      }
      // This flow exercises paragraph navigation; pagination has its own tests.
      await (ReaderPreferences()..textPaged = false).save();
      await preferences.setString('theme', 'light');
      addTearDown(() async {
        for (final entry in navBackup.entries) {
          if (entry.value == null) {
            await preferences.remove(entry.key);
          } else {
            await preferences.setString(entry.key, entry.value!);
          }
        }
        if (previousTheme == null) {
          await preferences.remove('theme');
        } else {
          await preferences.setString('theme', previousTheme);
        }
      });
      final root = Directory(
        '${support.path}/qa-${DateTime.now().millisecondsSinceEpoch}',
      );
      await root.create(recursive: true);
      final packages = FilePluginPackageStore('${root.path}/plugins/packages');
      await packages.retain(pluginZip());
      final api = ObservedApi(RustReaderApi(root.path));
      // A four-paragraph demo can fit entirely in a desktop viewport: its
      // physical top remains paragraph 0. Use a genuinely scrollable fixture
      // when asserting a persisted jump to paragraph 1.
      final inbox = (await api.call('snapshot'))['catalog']['inbox'];
      final longText = List.generate(
        80,
        (i) => '原生流程第${i + 1}段。${List.filled(20, '用于验证长文本真实滚动、定位和保存。').join()}',
      ).join('\n\n');
      await api.call('import_files', {
        'target': inbox,
        'files': [
          {'name': '原生流程长文.txt', 'data': base64Encode(utf8.encode(longText))},
        ],
      });
      const capture = Key('qa-capture');
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: ReaderApp(api: api, pluginPackages: packages),
        ),
      );
      Future<void> settleUntil(Finder finder) async {
        for (var n = 0; n < 120 && finder.evaluate().isEmpty; n++) {
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

      Future<void> revealReaderChrome() async {
        await settleUntil(find.byType(ReaderShell));
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

      Future<void> screenshot(String name) async {
        await tester.pumpAndSettle();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(capture),
        );
        final image = await boundary.toImage(pixelRatio: 1);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = Directory(
          Platform.environment['AQ_SCREENSHOT_DIR'] ??
              '${support.path}/qa-screenshots',
        );
        await output.create(recursive: true);
        await File(
          '${output.path}/$name.png',
        ).writeAsBytes(data!.buffer.asUint8List());
        if (Platform.isAndroid) {
          final encoded = base64Encode(data.buffer.asUint8List());
          for (var offset = 0; offset < encoded.length; offset += 512) {
            debugPrint(
              'QA_IMAGE:$name:${encoded.substring(offset, (offset + 512).clamp(0, encoded.length))}',
            );
          }
          await debugPrintDone;
        }
        image.dispose();
      }

      await settleUntil(find.byKey(const ValueKey('nav-core.projects')));
      await tester.tap(find.byKey(const ValueKey('nav-core.projects')));
      await settleUntil(find.text('原生流程长文'));
      await screenshot('library-light');
      if (find.byType(SnackBar).evaluate().isNotEmpty) {
        await tester.tap(
          find
              .descendant(
                of: find.byType(SnackBar),
                matching: find.byIcon(Icons.close),
              )
              .first,
        );
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text('原生流程长文').first);
      await revealReaderChrome();
      await settleUntil(find.byTooltip('目录与内容导航'));
      await tester.tap(find.byTooltip('目录与内容导航'));
      await tester.pumpAndSettle();
      final secondLocation = find.byKey(
        const ValueKey('reader-navigation-item-1'),
      );
      await settleUntil(secondLocation);
      await tester.ensureVisible(secondLocation);
      await tester.tap(secondLocation);
      await tester.pumpAndSettle();
      for (
        var attempt = 0;
        attempt < 100 &&
            tester
                    .widget<ReaderShell>(find.byType(ReaderShell))
                    .adapter
                    .position !=
                1;
        attempt++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        tester.widget<ReaderShell>(find.byType(ReaderShell)).adapter.position,
        1,
      );
      await screenshot('reader-light');
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('记笔记'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '平台原生运行验证笔记');
      await tester.tap(find.text('保存笔记'));
      await tester.pumpAndSettle();
      await settleUntil(find.text('笔记已保存，并关联当前阅读位置'));
      await tester.pageBack();
      await tester.pumpAndSettle();
      await settleUntil(find.text('原生流程长文'));
      await tester.tap(find.text('原生流程长文').first);
      await revealReaderChrome();
      await settleUntil(find.byTooltip('目录与内容导航'));
      expect(
        tester.widget<ReaderShell>(find.byType(ReaderShell)).adapter.position,
        1,
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-core.me')));
      await settleUntil(find.byType(ProfileScreen));
      await reveal(find.text('深色'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      await screenshot('profile-dark');
      final snapshot = await api.call('snapshot');
      final imageFiles = <Map<String, String>>[];
      for (var n = 1; n <= 2; n++) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        canvas.drawColor(
          n == 1 ? const Color(0xffdbe7dc) : const Color(0xffdadfeb),
          BlendMode.src,
        );
        canvas.drawRect(
          const Rect.fromLTWH(60, 90, 480, 620),
          Paint()..color = const Color(0xff31584e),
        );
        final picture = recorder.endRecording();
        final image = await picture.toImage(600, 900);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        imageFiles.add({
          'name': '漫画验证-$n.png',
          'data': base64Encode(bytes!.buffer.asUint8List()),
        });
        image.dispose();
        picture.dispose();
      }
      await api.call('import_files', {
        'target': snapshot['catalog']['inbox'],
        'files': imageFiles,
      });
      // This assertion exercises discrete page buttons. Comic defaults are
      // continuous; choose paging explicitly instead of relying on old defaults.
      final comicSnapshot = await api.call('snapshot');
      final comic = (comicSnapshot['catalog']['books'] as List).firstWhere(
        (b) => b['format'] == 'Comic',
      );
      await api.call('set_book_direction', {
        'book': comic['id'],
        'direction': 'LeftToRight',
      });

      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: ReaderApp(
            key: const ValueKey('reopened'),
            api: api,
            pluginPackages: packages,
          ),
        ),
      );
      await settleUntil(find.byKey(const ValueKey('nav-core.projects')));
      await tester.tap(find.byKey(const ValueKey('nav-core.projects')));
      await settleUntil(find.text('漫画验证-1'));
      await tester.ensureVisible(find.text('漫画验证-1').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('漫画验证-1').first);
      await revealReaderChrome();
      await settleUntil(find.byTooltip('下一页'));
      await tester.tap(find.byTooltip('下一页'));
      await settleUntil(find.text('已保存到第 2 页'));
      expect(find.text('2 / 2 页'), findsOneWidget);
      await screenshot('comic-dark');
      await tester.pageBack();
      await tester.pumpAndSettle();
      await settleUntil(find.text('漫画验证-1'));
      await tester.ensureVisible(find.text('漫画验证-1').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('漫画验证-1').first);
      await revealReaderChrome();
      await settleUntil(find.byTooltip('下一页'));
      expect(find.text('2 / 2 页'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-core.me')));
      await tester.pumpAndSettle();
      await reveal(find.text('插件'));
      await tester.tap(find.text('插件'));
      await settleUntil(find.widgetWithText(FilledButton, 'ZIP 导入插件'));
      await tester.tap(find.text('重新安装'));
      await settleUntil(find.text('启用'));
      await tester.tap(find.text('启用'));
      await settleUntil(find.text('停用'));
      expect(find.text('已注册页面 1 · 阅读处理器 0 · 上下文能力 0 · 组件 0'), findsOneWidget);
      await screenshot('plugins-native');
      await tester.tap(find.byKey(const ValueKey('nav-core.me')));
      await settleUntil(find.byType(ProfileScreen));
      await reveal(find.text('阅读清单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('阅读清单'));
      await settleUntil(find.text('记录想读的内容，按照自己的节奏阅读。'));
      expect(find.text('记录想读的内容，按照自己的节奏阅读。'), findsOneWidget);
      await screenshot('plugin-page-native');
      await tester.tap(find.byKey(const ValueKey('nav-core.me')));
      await settleUntil(find.byType(ProfileScreen));
      await reveal(find.text('导航栏自定义'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导航栏自定义'));
      await tester.pumpAndSettle();
      if (Platform.isWindows) {
        await tester.tap(find.text('桌面端'));
        await tester.pumpAndSettle();
      }
      await reveal(find.byTooltip('添加阅读清单'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('添加阅读清单'));
      await tester.pumpAndSettle();
      // The entry moves up to the visible section, which a tall feature list
      // (desktop window) has already scrolled out of the lazily built view.
      expect(find.byTooltip('添加阅读清单'), findsNothing);
      await tester.scrollUntilVisible(
        find.byTooltip('隐藏阅读清单'),
        -180,
        scrollable: find.byType(Scrollable).last,
      );
      await settleUntil(find.byTooltip('隐藏阅读清单'));
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('nav-community.reading.page.checklist')),
      );
      await settleUntil(find.text('记录想读的内容，按照自己的节奏阅读。'));
      expect(find.text('记录想读的内容，按照自己的节奏阅读。'), findsOneWidget);
      await screenshot('plugin-shortcut-native');
      await tester.tap(find.byKey(const ValueKey('nav-core.me')));
      await tester.pumpAndSettle();
      await reveal(find.text('插件'));
      await tester.tap(find.text('插件'));
      await settleUntil(find.widgetWithText(FilledButton, 'ZIP 导入插件'));
      await tester.tap(find.text('停用'));
      await settleUntil(find.text('启用'));
      expect(
        find.byKey(const ValueKey('nav-community.reading.page.checklist')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
      // Keep the isolated QA library for reproducibility. No user library was touched.
    },
  );
}

class ObservedApi implements ReaderApi {
  final ReaderApi native;
  ObservedApi(this.native);
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    debugPrint('Native QA calling $method');
    try {
      final result = await native.call(method, args);
      debugPrint('Native QA completed $method');
      return result;
    } catch (e) {
      debugPrint('Native QA failed $method: $e');
      rethrow;
    }
  }
}
