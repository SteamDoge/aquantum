// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/feature_registry.dart';

enum NavigationProfile { mobile, desktop }

/// Placement is a layout concern, independent from registry and pin order.
/// Only left is rendered on desktop in rc.0.0.3; other values are reserved.
enum NavigationPosition { left, right, top, bottom }

class NavigationLayout {
  final NavigationPosition position;
  final bool expanded;
  const NavigationLayout({
    this.position = NavigationPosition.left,
    this.expanded = false,
  });
}

class NavigationPreferences {
  final List<String> pins;
  final String selected;
  final NavigationLayout layout;
  NavigationPreferences({
    required Iterable<String> pins,
    this.selected = FeatureRegistry.home,
    this.layout = const NavigationLayout(),
  }) : pins = List.unmodifiable({
         ...pins.where((id) => id != FeatureRegistry.me),
         FeatureRegistry.me,
       });

  factory NavigationPreferences.defaults() => NavigationPreferences(
    pins: [FeatureRegistry.home, FeatureRegistry.projects, FeatureRegistry.me],
  );

  factory NavigationPreferences.decode(String encoded) {
    final data = jsonDecode(encoded);
    if (data is! Map || data['version'] != 1) {
      throw const FormatException('无法读取此版本的导航配置，原配置已保留');
    }
    final pins = data['pins'];
    if (pins is! List ||
        pins.any((id) => id is! String) ||
        data['selected'] is! String ||
        data['layout'] is! Map) {
      throw const FormatException('导航配置损坏，原配置已保留');
    }
    final layout = data['layout'] as Map;
    return NavigationPreferences(
      pins: pins.cast<String>(),
      selected: data['selected'],
      layout: NavigationLayout(
        position: NavigationPosition.values.firstWhere(
          (v) => v.name == layout['position'],
          orElse: () => NavigationPosition.left,
        ),
        expanded: layout['expanded'] == true,
      ),
    );
  }

  String encode() => jsonEncode({
    'version': 1,
    'pins': pins,
    'selected': selected,
    'layout': {'position': layout.position.name, 'expanded': layout.expanded},
  });

  NavigationPreferences copyWith({
    Iterable<String>? pins,
    String? selected,
    NavigationLayout? layout,
  }) => NavigationPreferences(
    pins: pins ?? this.pins,
    selected: selected ?? this.selected,
    layout: layout ?? this.layout,
  );
}

abstract interface class NavigationStore {
  Future<String?> read(NavigationProfile profile);
  Future<void> write(NavigationProfile profile, String value);
}

class DeviceNavigationStore implements NavigationStore {
  String key(NavigationProfile profile) => 'navigation.v1.${profile.name}';
  @override
  Future<String?> read(NavigationProfile profile) async =>
      (await SharedPreferences.getInstance()).getString(key(profile));
  @override
  Future<void> write(NavigationProfile profile, String value) async {
    if (!await (await SharedPreferences.getInstance()).setString(
      key(profile),
      value,
    )) {
      throw StateError('导航配置保存失败');
    }
  }
}
