// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aquantum_reader/reader/toolbar_preferences.dart';
import 'package:aquantum_reader/reader/reader_toolbar.dart';
import 'package:aquantum_reader/screens/toolbar_editor.dart';
import 'package:aquantum_reader/plugins/plugin_manager.dart';
import 'package:aquantum_reader/plugins/plugin_package.dart';
import 'package:aquantum_reader/plugins/plugin_api.dart';
import 'package:aquantum_reader/plugins/plugin_result.dart';
import 'plugin_fixtures.dart';
import 'reader_shell_test.dart' as fixtures;

void main() {
  testWidgets('shared module result displays returned text in native dialog', (
    tester,
  ) async {
    final action = PluginAction(
      id: 'example.action.result',
      name: '测试结果',
      icon: Icons.info,
      point: ExtensionPoint.readerMore,
      invoke: (_) async => '可见结果',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showPluginResult(context, action, '可见结果'),
              child: const Text('run'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('run'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('可见结果'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'layout persists unavailable module preferences and rejects loss of exits',
    () async {
      final layout = ToolbarLayout(
        ['core.back', 'module.action.x', 'core.more'],
        {'core.search'},
      );
      await ToolbarPreferences().save(layout);
      expect((await ToolbarPreferences().load()).pinned, layout.pinned);
      expect(
        () => ToolbarLayout.decode('{"version":1,"pinned":[],"hidden":[]}'),
        throwsFormatException,
      );
      final bad = jsonEncode({
        'version': 2,
        'pinned': ['core.back', 'core.more'],
        'hidden': [],
      });
      SharedPreferences.setMockInitialValues({ToolbarPreferences.key: bad});
      await expectLater(
        ToolbarPreferences().save(ToolbarLayout.defaults()),
        throwsFormatException,
      );
      expect(
        (await SharedPreferences.getInstance()).getString(
          ToolbarPreferences.key,
        ),
        bad,
      );
    },
  );
  testWidgets(
    'default glyphs and order remain identical; custom overflow stays reachable',
    (tester) async {
      final actions = <ReaderToolbarAction>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ReaderToolbar(onAction: actions.add)),
        ),
      );
      expect(tester.widgetList<IconButton>(find.byType(IconButton)).length, 7);
      for (final action in readerToolbarOrder) {
        expect(
          find.byKey(ValueKey('reader-action-${action.name}')),
          findsOneWidget,
        );
      }
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 180,
              child: ReaderToolbar(
                onAction: actions.add,
                customButtons: [
                  for (final action in readerToolbarOrder)
                    ToolbarButton(
                      toolbarCoreId(action),
                      ReaderToolbar.label(action),
                      ReaderToolbar.glyph(action),
                      () => actions.add(action),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('reader-action-core.back')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('reader-action-core.more')),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('溢出操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('搜索'));
      await tester.pumpAndSettle();
      expect(actions.last, ReaderToolbarAction.search);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'editor reorders, moves to more, saves and reapplies shared layout',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => const ToolbarEditor(),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      final list = tester.widget<ReorderableListView>(
        find.byType(ReorderableListView),
      );
      list.onReorderItem!(1, 3);
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView).first, const Offset(0, -240));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('移入更多搜索'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存并应用'));
      await tester.pumpAndSettle();
      final layout = await ToolbarPreferences().load();
      expect(layout.pinned.indexOf('core.settings'), 3);
      expect(layout.pinned, isNot(contains('core.search')));
      await tester.pumpWidget(
        fixtures.shell(fixtures.FixtureAdapter('Txt'), desktop: true),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('reader-action-core.search')),
        findsNothing,
      );
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      expect(find.text('搜索'), findsOneWidget);
      expect(find.text('编辑工具栏'), findsOneWidget);
    },
  );
  testWidgets(
    'scroll reading stays without bottom controller after customization',
    (tester) async {
      await ToolbarPreferences().save(
        ToolbarLayout(['core.back', 'core.search', 'core.more'], {}),
      );
      await tester.pumpWidget(
        fixtures.shell(
          fixtures.ScrollingAdapter(),
          desktop: true,
          dock: 'bottom',
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('reader-page-controller')),
        findsNothing,
      );
      expect(find.byType(Slider), findsNothing);
      expect(find.byTooltip('搜索'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'installed declaration appears in editor; disable removes button and reenable restores placement',
    (tester) async {
      final registry = testRegistry();
      final plugin = (await tester.runAsync(
        () => inspectPluginZip(
          pluginZip(
            extra: {
              'main.js': utf8.encode(
                "export async function activate(ctx){await ctx.slots.register({id:'notice',name:'插件操作',type:'readerToolbar',icon:'info'},()=> '已执行');}",
              ),
            },
          ),
        ),
      ))!;
      const id = 'community.reading.action.notice';
      final manager = PluginManager(
        registry,
        MemoryPluginStore(),
        bundled: [plugin],
        hostServices: testServices(),
      );
      await manager.load();
      await manager.install('community.reading');
      await tester.runAsync(() => manager.enable('community.reading', {}));
      await ToolbarPreferences().save(
        ToolbarLayout(['core.back', id, 'core.more'], {}),
      );
      await tester.pumpWidget(
        fixtures.shell(
          fixtures.FixtureAdapter('Txt'),
          desktop: true,
          plugins: manager,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('插件操作'), findsOneWidget);
      await tester.runAsync(() => manager.disable('community.reading'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('插件操作'), findsNothing);
      expect((await ToolbarPreferences().load()).pinned, contains(id));
      await tester.runAsync(() => manager.enable('community.reading', {}));
      await tester.pumpAndSettle();
      expect(find.byTooltip('插件操作'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      manager.dispose();
      registry.dispose();
    },
  );
}
