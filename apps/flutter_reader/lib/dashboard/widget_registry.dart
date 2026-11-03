// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import 'package:flutter/material.dart';
import 'dashboard_data.dart';

enum DashboardPage { home, statistics }

typedef DashboardRenderer =
    Widget Function(
      BuildContext context,
      DashboardData data,
      DashboardInstance config,
      Map<String, Object?> metrics,
    );

class DashboardDefinition {
  final String id, name, source;
  final IconData icon;
  final Set<DashboardPage> pages;
  final Set<String> styles, dependencies;
  final DashboardRenderer render;
  final double minWidth;
  final bool supportsLimit;
  const DashboardDefinition({
    required this.id,
    required this.name,
    required this.icon,
    required this.render,
    this.source = 'core',
    this.pages = const {DashboardPage.home, DashboardPage.statistics},
    this.styles = const {'compact', 'detailed'},
    this.dependencies = const {},
    this.minWidth = 240,
    this.supportsLimit = false,
  });
}

class DashboardInstance {
  final String id, style;
  final bool wide, skipLatest;
  final int limit;
  const DashboardInstance(
    this.id, {
    this.style = 'compact',
    this.wide = true,
    this.skipLatest = false,
    this.limit = 3,
  });
  factory DashboardInstance.fromJson(Map<String, dynamic> json) {
    if (json['id'] is! String ||
        !{'compact', 'detailed'}.contains(json['style']) ||
        json['wide'] is! bool ||
        json['limit'] is! int ||
        json['limit'] < 1 ||
        json['limit'] > 20) {
      throw const FormatException('组件配置损坏，原配置已保留');
    }
    return DashboardInstance(
      json['id'],
      style: json['style'],
      wide: json['wide'],
      limit: json['limit'],
    );
  }
  Map<String, dynamic> toJson() => {
    'id': id,
    'style': style,
    'wide': wide,
    'limit': limit,
  };
  DashboardInstance copy({
    String? style,
    bool? wide,
    int? limit,
    bool? skipLatest,
  }) => DashboardInstance(
    id,
    style: style ?? this.style,
    wide: wide ?? this.wide,
    skipLatest: skipLatest ?? this.skipLatest,
    limit: limit ?? this.limit,
  );
}

class DashboardProvider {
  final String id, source;
  final FutureOr<Object?> Function(DashboardData data) read;
  const DashboardProvider({
    required this.id,
    required this.source,
    required this.read,
  });
}

/// Page registrations, dashboard renderers and metric providers are separate.
class DashboardRegistry extends ChangeNotifier {
  final Map<String, DashboardDefinition> _definitions = {};
  final Map<String, DashboardProvider> _providers = {};
  final Map<String, Future<Object?>> _cache = {};
  DashboardData? _cachedData;
  List<DashboardDefinition> get all => List.unmodifiable(_definitions.values);
  DashboardDefinition? operator [](String id) => _definitions[id];
  void registerCore(Iterable<DashboardDefinition> definitions) {
    for (final d in definitions) {
      if (d.source != 'core' ||
          !d.id.startsWith('core.widget.') ||
          _definitions.containsKey(d.id)) {
        throw StateError('核心组件编号冲突');
      }
      _definitions[d.id] = d;
    }
  }

  void publish(
    String source,
    List<DashboardDefinition> widgets,
    List<DashboardProvider> providers,
  ) {
    if (source == 'core') throw StateError('插件不能覆盖核心');
    final ids = <String>{};
    for (final p in providers) {
      if (p.source != source ||
          !p.id.startsWith('$source.metric.') ||
          !ids.add(p.id)) {
        throw StateError('数据提供者编号冲突');
      }
    }
    for (final d in widgets) {
      if (d.source != source ||
          !d.id.startsWith('$source.widget.') ||
          !ids.add(d.id) ||
          d.pages.isEmpty ||
          d.styles.isEmpty ||
          !{'compact', 'detailed'}.containsAll(d.styles) ||
          !d.dependencies.every((id) => providers.any((p) => p.id == id))) {
        throw StateError('组件来源、展示或数据依赖无效');
      }
    }
    _definitions.removeWhere((_, d) => d.source == source);
    _providers.removeWhere((_, p) => p.source == source);
    _definitions.addEntries(widgets.map((d) => MapEntry(d.id, d)));
    _providers.addEntries(providers.map((p) => MapEntry(p.id, p)));
    _cache.clear();
    notifyListeners();
  }

  void revoke(String source) {
    _definitions.removeWhere((_, d) => d.source == source);
    _providers.removeWhere((_, p) => p.source == source);
    _cache.clear();
    notifyListeners();
  }

  Future<Map<String, Object?>> metrics(
    DashboardDefinition definition,
    DashboardData data,
  ) async {
    if (!identical(data, _cachedData)) {
      _cache.clear();
      _cachedData = data;
    }
    final values = await Future.wait(
      definition.dependencies.map((id) async {
        final provider = _providers[id] ?? (throw StateError('组件数据已停用'));
        final value = await _cache.putIfAbsent(
          id,
          () => Future.sync(
            () => provider.read(data),
          ).timeout(const Duration(seconds: 5)),
        );
        return MapEntry(id, value);
      }),
    );
    return Map.unmodifiable(Map.fromEntries(values));
  }

  void retry(DashboardDefinition definition) {
    for (final id in definition.dependencies) {
      _cache.remove(id);
    }
  }
}
