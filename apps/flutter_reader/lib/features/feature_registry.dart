// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';

/// A workspace page is always discoverable in Me. Navigation only pins it.
enum FeatureOpening { workspace }

class AppFeature {
  final String id, name, source;
  final IconData icon;
  final WidgetBuilder builder;
  final bool allowNavigation;
  final FeatureOpening opening;

  const AppFeature({
    required this.id,
    required this.name,
    required this.icon,
    required this.builder,
    this.source = 'core',
    this.allowNavigation = true,
    this.opening = FeatureOpening.workspace,
  });
}

class FeatureRegistry extends ChangeNotifier {
  static const home = 'core.home';
  static const statistics = 'core.statistics';
  static const projects = 'core.projects';
  static const plugins = 'core.plugins';
  static const me = 'core.me';
  final Map<String, AppFeature> _features = {};

  FeatureRegistry(Iterable<AppFeature> core) {
    for (final feature in core) {
      if (feature.source != 'core' || !feature.id.startsWith('core.')) {
        throw ArgumentError('核心入口必须使用 core 命名空间');
      }
      _validate(feature);
      if (_features.containsKey(feature.id)) throw StateError('重复功能编号');
      _features[feature.id] = feature;
    }
    if (_features[me]?.allowNavigation != true) {
      throw StateError('必须注册我的入口');
    }
  }

  List<AppFeature> get all => List.unmodifiable(_features.values);
  AppFeature? operator [](String id) => _features[id];

  void _validate(AppFeature feature) {
    if (!RegExp(r'^[a-z][a-z0-9_.-]{2,95}$').hasMatch(feature.id) ||
        feature.name.trim().isEmpty) {
      throw ArgumentError('功能需要稳定编号和名称');
    }
  }

  /// Atomic publication: invalid contributions cannot leave half a plugin live.
  /// Only the plugin manager owns this operation; plugins receive a registrar.
  void publishPlugin(String source, Iterable<AppFeature> pages) {
    if (source == 'core' || !RegExp(r'^[a-z][a-z0-9_.-]+$').hasMatch(source)) {
      throw ArgumentError('插件来源无效');
    }
    final incoming = <String, AppFeature>{};
    for (final feature in pages) {
      _validate(feature);
      if (feature.source != source ||
          !feature.id.startsWith('$source.page.') ||
          incoming.containsKey(feature.id) ||
          (_features.containsKey(feature.id) &&
              _features[feature.id]!.source != source)) {
        throw StateError('插件入口编号或来源冲突');
      }
      incoming[feature.id] = feature;
    }
    _features.removeWhere((_, feature) => feature.source == source);
    _features.addAll(incoming);
    notifyListeners();
  }

  void revokePlugin(String source) {
    if (source == 'core') throw StateError('不能撤销核心功能');
    _features.removeWhere((_, feature) => feature.source == source);
    notifyListeners();
  }
}
