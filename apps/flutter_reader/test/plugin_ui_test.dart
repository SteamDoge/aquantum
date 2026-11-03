// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:aquantum_reader/main.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'library_test.dart' show TestApi;
import 'plugin_fixtures.dart';
import 'package:aquantum_reader/plugins/plugin_manager.dart';
import 'package:aquantum_reader/plugins/plugin_package.dart';
import 'package:aquantum_reader/screens/plugin_screen.dart';

void main() {
  testWidgets(
    'an open plugin manager refreshes when a new independent ZIP is installed',
    (tester) async {
      final features = testRegistry();
      final manager = (await tester.runAsync(() async {
        final manager = PluginManager(
          features,
          MemoryPluginStore(),
          hostServices: testServices(),
        );
        await manager.load();
        return manager;
      }))!;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PluginScreen(manager: manager, onImport: () {}),
          ),
        ),
      );
      expect(find.text('尚未导入插件'), findsOneWidget);
      final zip = pluginZip();
      await tester.runAsync(() async {
        await manager.importPackage(
          await inspectPluginZip(zip),
          MemoryPackages(),
          zip,
        );
      });
      await tester.pumpAndSettle();
      expect(find.text('阅读清单'), findsOneWidget);
      expect(find.text('尚未导入插件'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      manager.dispose();
      features.dispose();
    },
  );

  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'missing system picker reports an actionable error without installing a plugin',
    (tester) async {
      FilePicker.platform = FixturePicker(pluginZip(), missingExplorer: true);
      final packages = MemoryPackages();
      await tester.pumpWidget(
        ReaderApp(
          api: TestApi(),
          pluginPackages: packages,
          pluginServices: testServices(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-core.me')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('ZIP 导入插件'),
        160,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('ZIP 导入插件'));
      await tester.pumpAndSettle();
      expect(find.textContaining('系统无法打开 ZIP 文件选择器'), findsOneWidget);
      expect(packages.copies, isEmpty);
    },
  );
  testWidgets(
    'Me ZIP picker imports a real package, enables its page, and hides shortcuts without disabling',
    (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final picker = FixturePicker(pluginZip());
      FilePicker.platform = picker;
      final packages = MemoryPackages();
      final api = TestApi();
      await tester.pumpWidget(
        ReaderApp(
          api: api,
          pluginPackages: packages,
          pluginServices: testServices(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-core.me')));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('ZIP 导入插件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ZIP 导入插件'));
      await pumpUntil(tester, find.text('导入副本'));
      expect(picker.calls, 1);
      await tester.tap(find.text('导入副本'));
      await pumpUntil(tester, find.text('插件已导入，请在插件页面启用'));
      await tester.pumpAndSettle();
      expect(packages.copies.length, 1);
      await tester.tap(find.byKey(const ValueKey('nav-core.me')));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('插件'));
      await tester.tap(find.text('插件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('启用'));
      await pumpUntil(tester, find.text('停用'));
      await tester.pumpAndSettle();
      expect(find.text('已注册页面 1 · 阅读处理器 0 · 上下文能力 0 · 组件 0'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('nav-community.reading.page.checklist')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('nav-core.me')));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('阅读清单'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('阅读清单'));
      // The JS page arrives through real native I/O, beyond the fake frame clock.
      await pumpUntil(tester, find.text('记录想读的内容，按照自己的节奏阅读。'));
      expect(find.text('记录想读的内容，按照自己的节奏阅读。'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('nav-core.me')));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('导航栏自定义'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导航栏自定义'));
      await tester.pumpAndSettle();
      await reveal(tester, find.byTooltip('添加阅读清单'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('添加阅读清单'));
      await tester.pumpAndSettle();
      await reveal(tester, find.byTooltip('隐藏资料库'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('隐藏资料库'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('nav-core.projects')), findsNothing);
      expect(
        find.byKey(const ValueKey('nav-community.reading.page.checklist')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('nav-community.reading.page.checklist')),
      );
      await pumpUntil(tester, find.text('记录想读的内容，按照自己的节奏阅读。'));
      expect(find.text('记录想读的内容，按照自己的节奏阅读。'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('nav-core.me')));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('插件'));
      await tester.tap(find.text('插件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('停用'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('nav-community.reading.page.checklist')),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('nav-core.me')));
      await tester.pumpAndSettle();
      expect(find.text('阅读清单'), findsNothing);
      // Hidden projects remain functional in the unified directory.
      await reveal(tester, find.text('资料库'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('资料库'));
      await tester.pumpAndSettle();
      expect(find.text('资料库还没有文件'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> pumpUntil(WidgetTester tester, Finder finder) async {
  for (var n = 0; n < 100 && finder.evaluate().isEmpty; n++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  expect(finder, findsOneWidget);
  // Import progress intentionally animates while the confirmation is open.
  await tester.pump(const Duration(milliseconds: 350));
}

class FixturePicker extends FilePicker {
  final Uint8List zip;
  final bool missingExplorer;
  int calls = 0;
  FixturePicker(this.zip, {this.missingExplorer = false});
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    calls++;
    if (missingExplorer) throw PlatformException(code: 'invalid_format_type');
    expect(allowedExtensions, ['zip']);
    expect(withReadStream, isTrue);
    return FilePickerResult([
      PlatformFile(
        name: 'reading.zip',
        size: zip.length,
        readStream: Stream.value(zip),
      ),
    ]);
  }
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
