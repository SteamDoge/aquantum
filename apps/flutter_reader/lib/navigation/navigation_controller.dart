// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/foundation.dart';
import '../features/feature_registry.dart';
import 'navigation_preferences.dart';

class AppNavigation extends ChangeNotifier {
  final FeatureRegistry registry;
  final NavigationStore store;
  final Map<NavigationProfile, NavigationPreferences> _preferences = {};
  final Map<NavigationProfile, String> loadErrors = {};
  Future<void> _pending = Future.value();
  bool _disposed = false;
  bool ready = false;

  AppNavigation(this.registry, this.store) {
    registry.addListener(_registryChanged);
  }

  Future<void> load() async {
    for (final profile in NavigationProfile.values) {
      try {
        final saved = await store.read(profile);
        _preferences[profile] = saved == null
            ? NavigationPreferences.defaults()
            : NavigationPreferences.decode(saved);
        // Upgrade only the untouched rc3 default; preserve customized pins.
        if (registry[FeatureRegistry.home] != null &&
            _preferences[profile]!.pins.join(',') ==
                'core.projects,core.plugins,core.me') {
          _preferences[profile] = _preferences[profile]!.copyWith(
            pins: [
              FeatureRegistry.home,
              FeatureRegistry.projects,
              FeatureRegistry.me,
            ],
            selected: FeatureRegistry.home,
          );
          await store.write(profile, _preferences[profile]!.encode());
        }
        if (profile == NavigationProfile.mobile &&
            _preferences[profile]!.pins.length > 5) {
          throw const FormatException('移动导航配置超过五项，原配置已保留');
        }
      } catch (error) {
        _preferences[profile] = NavigationPreferences.defaults();
        loadErrors[profile] = error.toString();
      }
    }
    ready = true;
    _repairSelections();
    _notify();
  }

  NavigationPreferences preferences(NavigationProfile profile) =>
      _preferences[profile] ?? NavigationPreferences.defaults();

  List<AppFeature> items(NavigationProfile profile) {
    final result = <AppFeature>[];
    for (final id in preferences(profile).pins) {
      final feature = registry[id];
      if (feature != null &&
          feature.allowNavigation &&
          id != FeatureRegistry.me &&
          (profile == NavigationProfile.desktop || result.length < 4)) {
        result.add(feature);
      }
    }
    return [...result, registry[FeatureRegistry.me]!];
  }

  String selected(NavigationProfile profile) {
    final id = preferences(profile).selected;
    return registry[id] == null ? FeatureRegistry.me : id;
  }

  Future<void> open(NavigationProfile profile, String id) {
    if (ready && loadErrors.containsKey(profile) && registry[id] != null) {
      // Keep settings reachable even with unreadable future-version prefs.
      _preferences[profile] = preferences(profile).copyWith(selected: id);
      _notify();
      return Future.value();
    }
    return _change(profile, (old) {
      if (registry[id] == null) throw StateError('此功能已停用');
      return old.copyWith(selected: id);
    }).catchError((Object error, StackTrace stack) {
      // A transient page choice must stay usable when preference storage is
      // read-only. Layout edits still commit only after a successful write.
      if (ready && !_disposed && registry[id] != null) {
        _preferences[profile] = preferences(profile).copyWith(selected: id);
        _notify();
      }
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<void> pin(NavigationProfile profile, String id, bool show) =>
      _change(profile, (old) {
        if (id == FeatureRegistry.me) throw StateError('我的不能移除');
        if (show && registry[id]?.allowNavigation != true) {
          throw StateError('只有已注册到我的且允许添加的功能可以加入导航');
        }
        final pins = old.pins
            .where((item) => item != id && item != FeatureRegistry.me)
            .toList();
        if (show) {
          if (profile == NavigationProfile.mobile &&
              old.pins.length >= 5 &&
              !old.pins.contains(id)) {
            throw StateError('移动导航最多保留 5 个位置，请先隐藏入口或忘记停用插件的快捷偏好');
          }
          pins.add(id);
        }
        return old.copyWith(pins: pins);
      });

  /// Reorder the available subset without losing disabled-plugin preferences.
  Future<void> reorder(NavigationProfile profile, List<String> visible) =>
      _change(profile, (old) {
        final expected = items(profile).map((item) => item.id).toSet();
        if (visible.length != expected.length ||
            visible.toSet().length != visible.length ||
            !visible.toSet().containsAll(expected) ||
            visible.last != FeatureRegistry.me) {
          throw StateError('导航顺序无效，我的必须在最后');
        }
        var next = 0;
        final pins = old.pins
            .map((id) => expected.contains(id) ? visible[next++] : id)
            .toList();
        return old.copyWith(pins: pins);
      });

  Future<void> setExpanded(NavigationProfile profile, bool expanded) => _change(
    profile,
    (old) => old.copyWith(
      layout: NavigationLayout(
        position: old.layout.position,
        expanded: expanded,
      ),
    ),
  );

  Future<void> reset(NavigationProfile profile) => _change(
    profile,
    (_) => NavigationPreferences.defaults(),
    allowReset: true,
  );

  Future<void> _change(
    NavigationProfile profile,
    NavigationPreferences Function(NavigationPreferences) edit, {
    bool allowReset = false,
  }) {
    final operation = _pending.then((_) async {
      if (!ready) throw StateError('导航配置仍在读取');
      if (!allowReset && loadErrors.containsKey(profile)) {
        throw StateError('旧导航配置无法读取；请先明确恢复默认，原配置尚未覆盖');
      }
      final next = edit(preferences(profile));
      await store.write(profile, next.encode());
      _preferences[profile] = next;
      loadErrors.remove(profile);
      _notify();
    });
    _pending = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  void _repairSelections() {
    for (final profile in _preferences.keys.toList()) {
      final value = _preferences[profile]!;
      if (registry[value.selected] == null) {
        _preferences[profile] = value.copyWith(selected: FeatureRegistry.me);
      }
    }
  }

  void _registryChanged() {
    _repairSelections();
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    registry.removeListener(_registryChanged);
    super.dispose();
  }
}
