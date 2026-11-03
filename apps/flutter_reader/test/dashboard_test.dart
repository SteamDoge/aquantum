// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'package:aquantum_reader/main.dart';
import 'package:aquantum_reader/dashboard/dashboard_data.dart';
import 'package:aquantum_reader/dashboard/dashboard_layout.dart';
import 'package:aquantum_reader/dashboard/widget_registry.dart';
import 'package:aquantum_reader/dashboard/reading_tracker.dart';
import 'package:aquantum_reader/data/models.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/plugins/plugin_package.dart';
import 'package:aquantum_reader/plugins/plugin_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'plugin_fixtures.dart';
import 'library_test.dart' show TestApi;

class ManualClock extends Stopwatch {
  int time = 0;
  bool running = false;
  @override
  int get elapsedMilliseconds => time;
  @override
  bool get isRunning => running;
  @override
  void start() {
    running = true;
  }

  @override
  void stop() {
    running = false;
  }

  @override
  void reset() {
    time = 0;
  }

  void add(int ms) {
    if (running) time += ms;
  }
}

class SessionApi implements ReaderApi {
  final sessions = <String, Map<String, dynamic>>{};
  bool fail = false;
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (fail) throw StateError('disk unavailable');
    sessions[args['id']] = Map.of(args);
    return null;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'dashboards and projects remain usable on phone, tablet, landscape and large text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      for (final (i, size) in [
        const Size(375, 812),
        const Size(812, 375),
        const Size(768, 1024),
      ].indexed) {
        tester.view.physicalSize = size;
        tester.platformDispatcher.textScaleFactorTestValue = i == 0 ? 1 : 2;
        tester.platformDispatcher.accessibilityFeaturesTestValue =
            const FakeAccessibilityFeatures(disableAnimations: true);
        final currentPrefs = await SharedPreferences.getInstance();
        await currentPrefs.remove('navigation.v1.mobile');
        await currentPrefs.remove('navigation.v1.desktop');
        await currentPrefs.setBool('project-grid.v1', true);
        await (await SharedPreferences.getInstance()).setString(
          'theme',
          i == 0 ? 'light' : 'dark',
        );
        await tester.pumpWidget(ReaderApp(key: ValueKey(i), api: TestApi()));
        await tester.pumpAndSettle();
        for (var n = 0; n < 8; n++) {
          await tester.drag(
            find.byType(Scrollable).last,
            const Offset(0, -260),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        }
        await tester.tap(find.byKey(const ValueKey('nav-core.projects')));
        await tester.pumpAndSettle();
        expect(find.byTooltip('添加内容'), findsOneWidget);
        await tester.tap(find.byTooltip('切换列表'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('切换网格'), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test(
    'home and statistics layout settings persist independently, unavailable entries remain',
    () async {
      final home = DashboardLayout(DashboardPage.home),
          stats = DashboardLayout(DashboardPage.statistics);
      await home.load();
      await stats.load();
      await home.save([
        const DashboardInstance(
          'community.extra.widget.status',
          limit: 5,
          wide: false,
        ),
      ]);
      final reopened = DashboardLayout(DashboardPage.home);
      await reopened.load();
      expect(reopened.items.single.id, 'community.extra.widget.status');
      expect(reopened.items.single.limit, 5);
      expect(reopened.items.single.wide, false);
      expect(stats.items.length, 5);
      expect(stats.items.first.style, 'detailed');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('dashboard.v1.home', '{"version":99}');
      final future = DashboardLayout(DashboardPage.home);
      await future.load();
      await expectLater(future.save([]), throwsStateError);
      expect(prefs.getString('dashboard.v1.home'), '{"version":99}');
      for (final l in [home, stats, reopened, future]) {
        l.dispose();
      }
    },
  );
  test(
    'foreground time excludes background, splits midnight, and replays failed checkpoints once',
    () async {
      final api = SessionApi(), clock = ManualClock();
      var now = DateTime(2026, 10, 19, 23, 59, 59);
      final tracker = ReadingTracker(api, 'book', now: () => now, clock: clock)
        ..total = 3;
      tracker.resume();
      clock.add(1000);
      now = DateTime(2026, 10, 20);
      await tracker.checkpoint();
      clock.add(500);
      now = now.add(const Duration(milliseconds: 500));
      await tracker.pause();
      clock.add(60000);
      expect(
        api.sessions.values.fold<int>(
          0,
          (n, s) => n + (s['elapsed_ms'] as int),
        ),
        1500,
      );
      expect(api.sessions.values.map((s) => s['day']).toSet(), {
        '2026-10-19',
        '2026-10-20',
      });
      tracker.resume();
      clock.add(500);
      api.fail = true;
      await tracker.pause();
      expect(tracker.error, isNotNull);
      expect(
        (await SharedPreferences.getInstance()).getKeys().any(
          (k) => k.startsWith('reading-pending.'),
        ),
        true,
      );
      api.fail = false;
      expect(await recoverReadingCheckpoints(api), isEmpty);
      expect(
        api.sessions.values.fold<int>(
          0,
          (n, s) => n + (s['elapsed_ms'] as int),
        ),
        2000,
      );
      expect(await recoverReadingCheckpoints(api), isEmpty);
    },
  );
  test(
    'same snapshot supplies consistent today, year, streak and stable book references',
    () async {
      final raw = await TestApi().call('snapshot');
      raw['catalog']['reading_sessions'] = [
        for (final (i, day) in ['2026-10-18', '2026-10-19'].indexed)
          {
            'id': '$i',
            'book': 'book',
            'actor': 'local',
            'day': day,
            'started_at': i,
            'elapsed_ms': 35000,
            'position': 1,
            'total': 2,
          },
        {
          'id': 'other',
          'book': 'book',
          'actor': 'other',
          'day': '2026-10-19',
          'started_at': 8,
          'elapsed_ms': 999999,
          'position': 0,
          'total': 2,
        },
      ];
      final d = DashboardData(
        LibrarySnapshot(raw),
        now: DateTime(2026, 10, 19),
      );
      expect(d.today, 35000);
      expect(d.yearTime, 70000);
      expect(d.streak, 2);
      expect(d.completedBooks, 1);
    },
  );
  test(
    'plugin without a page registers real widgets, cached providers and revokes on disable',
    () async {
      final features = testRegistry(), widgets = DashboardRegistry();
      final plugin = await inspectPluginZip(
        pluginZip(
          extra: {
            'main.js': utf8.encode(
              "export async function activate(ctx){await ctx.slots.register({id:'today',type:'dashboard',name:'我的今日时长',pages:['home','statistics'],ui:{type:'text',text:'今日时长'}});}",
            ),
          },
        ),
      );
      final manager = PluginManager(
        features,
        MemoryPluginStore(),
        dashboards: widgets,
        hostServices: testServices(),
        bundled: [plugin],
      );
      await manager.load();
      await manager.install(plugin.manifest.id);
      await manager.enable(plugin.manifest.id, {});
      expect(widgets.all.single.id, 'community.reading.widget.today');
      expect(features.all.any((f) => f.source == plugin.manifest.id), false);
      await manager.disable(plugin.manifest.id);
      expect(widgets.all, isEmpty);
      await manager.enable(plugin.manifest.id, {});
      expect(widgets.all.length, 1);
      var calls = 0;
      widgets.publish(
        'community.provider',
        [
          DashboardDefinition(
            id: 'community.provider.widget.test',
            name: '测试',
            source: 'community.provider',
            icon: Icons.book,
            dependencies: {'community.provider.metric.test'},
            render: (_, _, _, _) => const SizedBox(),
          ),
        ],
        [
          DashboardProvider(
            id: 'community.provider.metric.test',
            source: 'community.provider',
            read: (_) {
              calls++;
              return 35;
            },
          ),
        ],
      );
      final d = DashboardData(
            LibrarySnapshot(await TestApi().call('snapshot')),
          ),
          def = widgets['community.provider.widget.test']!;
      await Future.wait([widgets.metrics(def, d), widgets.metrics(def, d)]);
      expect(calls, 1);
      manager.dispose();
      features.dispose();
      widgets.dispose();
    },
  );
}
