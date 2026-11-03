// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

Future<Map<String, dynamic>> preferenceSnapshot() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  return {for (final key in prefs.getKeys()) key: prefs.get(key)};
}

/// Backup bytes retain plugin packages/data, never permission to execute code.
/// The original snapshot remains intact for verification and explicit rollback.
Map<String, dynamic> restoredPreferenceSnapshot(Map<String, dynamic> values) {
  final result = Map<String, dynamic>.from(values);
  final encoded = result['plugins.javascript.v1'];
  if (encoded == null) return result;
  if (encoded is! String) throw const FormatException('备份插件设置类型无效');
  final state = jsonDecode(encoded);
  if (state is! Map || state['version'] != 1 || state['plugins'] is! Map) {
    throw const FormatException('备份插件授权记录无效，未切换资料库');
  }
  for (final config in (state['plugins'] as Map).values) {
    if (config is! Map) throw const FormatException('备份插件记录无效');
    config['enabled'] = false;
    config['grants'] = <String>[];
  }
  result['plugins.javascript.v1'] = jsonEncode(state);
  return result;
}

Future<void> applyPreferenceSnapshot(Map<String, dynamic> values) async {
  for (final entry in values.entries) {
    final value = entry.value;
    if (!(value is bool ||
        value is String ||
        value is int ||
        value is double ||
        value is List && value.every((v) => v is String))) {
      throw const FormatException('备份包含不受支持的设置类型');
    }
  }
  final prefs = await SharedPreferences.getInstance();
  for (final key
      in prefs.getKeys().where((key) => !values.containsKey(key)).toList()) {
    if (!await prefs.remove(key)) throw StateError('无法恢复设置 $key');
  }
  for (final entry in values.entries) {
    final value = entry.value;
    final ok = switch (value) {
      bool v => await prefs.setBool(entry.key, v),
      int v => await prefs.setInt(entry.key, v),
      double v => await prefs.setDouble(entry.key, v),
      String v => await prefs.setString(entry.key, v),
      List v => await prefs.setStringList(entry.key, v.cast<String>()),
      _ => false,
    };
    if (!ok) throw StateError('无法恢复设置 ${entry.key}');
  }
}

Future<String> retainPreferenceSnapshot(
  String root,
  Map<String, dynamic> values,
) async {
  var directory = Directory('$root/device-preference-history');
  // Windows' temporary-directory API needs the extended path form even though
  // ordinary Dart file I/O already accepts the same long restored-library path.
  if (Platform.isWindows) {
    var path = directory.absolute.path.replaceAll('/', '\\');
    if (!path.startsWith(r'\\?\')) {
      path = path.startsWith(r'\\')
          ? r'\\?\UNC\' + path.substring(2)
          : r'\\?\' + path;
    }
    directory = Directory(path);
  }
  await directory.create(recursive: true);
  final file = await directory.createTemp('checkpoint-');
  final path = '${file.path}/preferences.json';
  await File(
    path,
  ).writeAsString(jsonEncode({'version': 1, 'values': values}), flush: true);
  return path;
}
