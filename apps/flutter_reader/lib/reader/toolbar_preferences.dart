// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'reader_toolbar.dart';

String toolbarCoreId(ReaderToolbarAction action) => 'core.${action.name}';

/// Stable action IDs survive disable/re-enable; unresolved IDs are never drawn.
class ToolbarLayout {
  final List<String> pinned;
  final Set<String> hidden;
  const ToolbarLayout(this.pinned, this.hidden);
  factory ToolbarLayout.defaults() => ToolbarLayout([
    for (final action in readerToolbarOrder) toolbarCoreId(action),
  ], {});
  static const requiredIds = {'core.back', 'core.more'};
  static ToolbarLayout decode(String raw) {
    final json = jsonDecode(raw);
    if (json is! Map ||
        json['version'] != 1 ||
        json['pinned'] is! List ||
        json['hidden'] is! List) {
      throw const FormatException('工具栏配置无法读取，原记录已保留');
    }
    final pinned = json['pinned'] as List, hidden = json['hidden'] as List;
    if (pinned.length + hidden.length > 512 ||
        [
          ...pinned,
          ...hidden,
        ].any((id) => id is! String || id.isEmpty || id.length > 160) ||
        pinned.toSet().length != pinned.length ||
        hidden.toSet().length != hidden.length ||
        !pinned.toSet().containsAll(requiredIds) ||
        hidden.any(pinned.contains)) {
      throw const FormatException('工具栏配置无效，原记录已保留');
    }
    return ToolbarLayout(List<String>.from(pinned), Set<String>.from(hidden));
  }

  String encode() =>
      jsonEncode({'version': 1, 'pinned': pinned, 'hidden': hidden.toList()});
}

class ToolbarPreferences {
  static const key = 'reader.toolbar.v1';
  Future<ToolbarLayout> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(key);
    return raw == null ? ToolbarLayout.defaults() : ToolbarLayout.decode(raw);
  }

  Future<void> save(ToolbarLayout layout) async {
    // Do not silently replace an invalid or future record.
    await load();
    ToolbarLayout.decode(layout.encode());
    if (!await (await SharedPreferences.getInstance()).setString(
      key,
      layout.encode(),
    )) {
      throw StateError('工具栏保存失败');
    }
  }
}
