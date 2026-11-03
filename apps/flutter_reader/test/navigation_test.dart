// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:aquantum_reader/features/feature_registry.dart';
import 'package:aquantum_reader/plugins/plugin_package.dart';
import 'package:aquantum_reader/plugins/plugin_api.dart';
import 'package:aquantum_reader/navigation/navigation_controller.dart';
import 'package:aquantum_reader/navigation/navigation_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'plugin_fixtures.dart';

void main() {
  const mobile = NavigationProfile.mobile, desktop = NavigationProfile.desktop;
  test(
    'read-only preferences report failure but do not block page navigation',
    () async {
      final registry = testRegistry();
      final store = MemoryNavigationStore();
      final nav = AppNavigation(registry, store);
      await nav.load();
      await nav.open(desktop, FeatureRegistry.home);
      final saved = store.saved[desktop];
      final pins = nav.preferences(desktop).pins;
      store.fail = true;
      await expectLater(
        nav.open(desktop, FeatureRegistry.projects),
        throwsStateError,
      );
      expect(nav.selected(desktop), FeatureRegistry.projects);
      expect(store.saved[desktop], saved);
      await expectLater(
        nav.pin(desktop, FeatureRegistry.projects, false),
        throwsStateError,
      );
      expect(nav.preferences(desktop).pins, pins);
      await expectLater(
        nav.open(desktop, 'unregistered.page'),
        throwsStateError,
      );
      expect(nav.selected(desktop), FeatureRegistry.projects);
      store.fail = false;
      await nav.open(desktop, FeatureRegistry.me);
      expect(nav.selected(desktop), FeatureRegistry.me);
      nav.dispose();
      registry.dispose();
    },
  );
  test(
    'dormant pins reserve their position until the user explicitly forgets them',
    () async {
      final registry = testRegistry();
      final nav = AppNavigation(registry, MemoryNavigationStore());
      await nav.load();
      final plugin = await inspectPluginZip(pluginZip());
      plugin.hostServices = testServices();
      addTearDown(plugin.deactivate);
      final registrar = PluginRegistrar(plugin.manifest);
      await plugin.activate(registrar);
      registry.publishPlugin(plugin.manifest.id, registrar.pages);
      await nav.pin(mobile, registrar.pages.single.id, true);
      await nav.pin(mobile, 'core.settings', true);
      registry.revokePlugin(plugin.manifest.id);
      expect(nav.items(mobile).length, 4);
      await expectLater(
        nav.pin(mobile, 'core.history', true),
        throwsStateError,
      );
      await nav.pin(mobile, registrar.pages.single.id, false);
      await nav.pin(mobile, 'core.history', true);
      registry.publishPlugin(plugin.manifest.id, registrar.pages);
      expect(nav.items(mobile).last.id, FeatureRegistry.me);
      expect(nav.items(mobile).any((f) => f.id == 'core.history'), isTrue);
      expect(
        nav.items(mobile).any((f) => f.id == registrar.pages.single.id),
        isFalse,
      );
      nav.dispose();
      registry.dispose();
    },
  );
  test(
    'hiding projects keeps them accessible, Me is fixed and platforms persist separately',
    () async {
      final registry = testRegistry();
      final store = MemoryNavigationStore();
      final nav = AppNavigation(registry, store);
      await nav.load();
      await nav.pin(mobile, FeatureRegistry.projects, false);
      await nav.pin(mobile, FeatureRegistry.home, false);
      expect(nav.items(mobile).map((f) => f.id), [FeatureRegistry.me]);
      await nav.open(mobile, FeatureRegistry.projects);
      expect(nav.selected(mobile), FeatureRegistry.projects);
      expect(registry[FeatureRegistry.projects], isNotNull);
      expect(nav.items(desktop).length, 3);
      await expectLater(
        nav.pin(mobile, FeatureRegistry.me, false),
        throwsStateError,
      );
      final restored = AppNavigation(registry, store);
      await restored.load();
      expect(restored.items(mobile).single.id, FeatureRegistry.me);
      expect(restored.selected(mobile), FeatureRegistry.projects);
      nav.dispose();
      restored.dispose();
      registry.dispose();
    },
  );
  test(
    'mobile cap and reorder survive queued actions and a failed write',
    () async {
      final registry = testRegistry();
      final store = MemoryNavigationStore();
      final nav = AppNavigation(registry, store);
      await nav.load();
      await Future.wait([
        nav.pin(mobile, 'core.settings', true),
        nav.pin(mobile, 'core.storage', true),
      ]);
      await expectLater(
        nav.pin(mobile, 'core.history', true),
        throwsStateError,
      );
      final reversed = nav
          .items(mobile)
          .where((f) => f.id != FeatureRegistry.me)
          .map((f) => f.id)
          .toList()
          .reversed
          .toList();
      await nav.reorder(mobile, [...reversed, FeatureRegistry.me]);
      expect(nav.items(mobile).first.id, 'core.storage');
      store.fail = true;
      await expectLater(
        nav.pin(mobile, 'core.storage', false),
        throwsStateError,
      );
      expect(nav.items(mobile).first.id, 'core.storage');
      store.fail = false;
      await nav.pin(mobile, 'core.storage', false);
      expect(nav.items(mobile).length, 4);
      nav.dispose();
      registry.dispose();
    },
  );
  test(
    'plugin pages require registration and user pinning; revoke retains dormant ordering',
    () async {
      final registry = testRegistry();
      final nav = AppNavigation(registry, MemoryNavigationStore());
      await nav.load();
      const id = 'community.reading.page.checklist';
      await expectLater(nav.pin(mobile, id, true), throwsStateError);
      final plugin = await inspectPluginZip(pluginZip());
      plugin.hostServices = testServices();
      addTearDown(plugin.deactivate);
      final registrar = PluginRegistrar(plugin.manifest);
      await plugin.activate(registrar);
      registrar.seal();
      registry.publishPlugin(plugin.manifest.id, registrar.pages);
      expect(nav.items(mobile).any((f) => f.id == id), isFalse);
      await nav.pin(mobile, id, true);
      await nav.open(mobile, id);
      registry.revokePlugin(plugin.manifest.id);
      expect(nav.selected(mobile), FeatureRegistry.me);
      expect(nav.preferences(mobile).pins, contains(id));
      expect(nav.items(mobile).any((f) => f.id == id), isFalse);
      registry.publishPlugin(plugin.manifest.id, registrar.pages);
      expect(nav.items(mobile).any((f) => f.id == id), isTrue);
      expect(nav.selected(mobile), FeatureRegistry.me);
      nav.dispose();
      registry.dispose();
    },
  );
  test(
    'future or corrupt preferences stay untouched while Me and recovery remain accessible',
    () async {
      final registry = testRegistry();
      final store = MemoryNavigationStore();
      store.saved[mobile] = '{"version":99}';
      final nav = AppNavigation(registry, store);
      await nav.load();
      await nav.open(mobile, FeatureRegistry.me);
      expect(nav.selected(mobile), FeatureRegistry.me);
      await expectLater(
        nav.pin(mobile, FeatureRegistry.projects, false),
        throwsStateError,
      );
      expect(store.saved[mobile], '{"version":99}');
      await nav.reset(mobile);
      expect(nav.loadErrors, isEmpty);
      nav.dispose();
      registry.dispose();
    },
  );
}
