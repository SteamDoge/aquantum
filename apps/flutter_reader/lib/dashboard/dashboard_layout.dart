// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'widget_registry.dart';

class DashboardLayout extends ChangeNotifier {
  final DashboardPage page;
  List<DashboardInstance> items;
  String? error;
  bool ready = false, busy = false;
  DashboardLayout(this.page) : items = defaults(page);
  static List<DashboardInstance> defaults(DashboardPage page) => [
    for (final id in ['continue', 'recent', 'goal', 'week', 'year'])
      DashboardInstance(
        'core.widget.$id',
        style: page == DashboardPage.home ? 'compact' : 'detailed',
        wide: id == 'continue' || id == 'recent',
      ),
  ];
  String get key => 'dashboard.v1.${page.name}';
  Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(key);
      if (raw != null) {
        final json = jsonDecode(raw);
        if (json is! Map ||
            json['version'] != 1 ||
            json['items'] is! List ||
            json['items'].length > 64) {
          throw const FormatException('无法读取组件布局，原配置已保留');
        }
        final parsed = (json['items'] as List)
            .map(
              (e) => DashboardInstance.fromJson(Map<String, dynamic>.from(e)),
            )
            .toList();
        if (parsed.map((e) => e.id).toSet().length != parsed.length) {
          throw const FormatException('组件配置有重复编号');
        }
        items = parsed;
      }
    } catch (e) {
      error = e.toString();
    }
    ready = true;
    notifyListeners();
  }

  Future<void> save(
    List<DashboardInstance> next, {
    bool restore = false,
  }) async {
    if (!ready || busy || (error != null && !restore)) {
      throw StateError(error ?? '组件设置忙碌中');
    }
    if (next.map((i) => i.id).toSet().length != next.length ||
        next.length > 64) {
      throw StateError('组件重复或超过上限');
    }
    busy = true;
    notifyListeners();
    try {
      if (!await (await SharedPreferences.getInstance()).setString(
        key,
        jsonEncode({
          'version': 1,
          'items': next.map((e) => e.toJson()).toList(),
        }),
      )) {
        throw StateError('组件布局保存失败');
      }
      items = List.unmodifiable(next);
      error = null;
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
