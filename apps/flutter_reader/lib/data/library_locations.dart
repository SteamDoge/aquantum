// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'backup_preferences.dart';

/// Device-local selection history. Restore publishes a new verified root first;
/// selecting it keeps every existing library and previous setting checkpoint.
class LibraryLocations {
  final String base;
  LibraryLocations(this.base);
  Directory get records => Directory('$base/library-selections');
  Directory get switches => Directory('$base/library-switches');

  Future<String> beginSwitch(String previousRoot, String preferences) async {
    final selection = jsonEncode(await latest());
    await switches.create(recursive: true);
    final directory = await switches.createTemp('switch-');
    final pending = File('${directory.path}/intent.pending');
    await pending.writeAsString(
      jsonEncode({
        'version': 1,
        'previous': await relative(previousRoot),
        'preferences': preferences,
        'selection_before': selection,
      }),
      flush: true,
    );
    await pending.rename('${directory.path}/intent.json');
    return directory.path;
  }

  Future<void> finishSwitch(String directory) async {
    final receipt = File('$directory/completed.json');
    if (!await receipt.exists()) {
      await receipt.writeAsString('{"version":1}', flush: true);
    }
  }

  /// Reconcile only unfinished setting transactions. A changed selection
  /// proves the root commit completed; otherwise restore its prior settings.
  /// Intents, checkpoints and receipts remain available for manual diagnosis.
  Future<void> recoverInterruptedSwitches() async {
    if (!await switches.exists()) return;
    await for (final entity in switches.list(followLinks: false)) {
      if (entity is! Directory ||
          await File('${entity.path}/completed.json').exists()) {
        continue;
      }
      final file = File('${entity.path}/intent.json');
      if (!await file.exists()) {
        continue; // crash before an intent was published
      }
      final intent = jsonDecode(await file.readAsString());
      if (intent is! Map ||
          intent['version'] != 1 ||
          intent['selection_before'] is! String) {
        throw const FormatException('资料库切换记录无法读取，原资料与设置快照保留。');
      }
      if (jsonEncode(await latest()) == intent['selection_before']) {
        final previous = await resolve(intent['previous']);
        await applyPreferenceSnapshot(
          await readCheckpoint(previous, intent['preferences']),
        );
      }
      await finishSwitch(entity.path);
    }
  }

  Future<Map<String, dynamic>?> latest() async {
    if (!await records.exists()) return null;
    final files = await records
        .list(followLinks: false)
        .where((e) => e is File && e.path.endsWith('.json'))
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    if (files.isEmpty) return null;
    final data = jsonDecode(await files.last.readAsString());
    if (data is! Map<String, dynamic> ||
        data['version'] != 1 ||
        data['root'] is! String) {
      throw const FormatException('资料库选择记录无法读取，原记录已保留。');
    }
    return data;
  }

  Future<String> current() async {
    final value = await latest();
    if (value == null) return base;
    return resolve(value['root']);
  }

  Future<Map<String, dynamic>?> rollbackData() async {
    final record = await latest();
    if (record == null ||
        record['previous'] is! String ||
        record['previousPreferences'] is! String) {
      return null;
    }
    final root = await resolve(record['previous']);
    return {
      'root': root,
      'device_preferences': await readCheckpoint(
        root,
        record['previousPreferences'],
      ),
    };
  }

  Future<Map<String, dynamic>> readCheckpoint(
    String root,
    String checkpoint,
  ) async {
    final file = File(checkpoint);
    final path = await file.resolveSymbolicLinks();
    final prefix =
        '${normalized(await Directory(root).resolveSymbolicLinks())}/device-preference-history/';
    if (!normalized(path).startsWith(prefix) ||
        !normalized(path).endsWith('/preferences.json')) {
      throw const FormatException('恢复回退的设置路径无效。');
    }
    final value = jsonDecode(await File(path).readAsString());
    if (value is! Map || value['version'] != 1 || value['values'] is! Map) {
      throw const FormatException('恢复前设置快照无法读取。');
    }
    return Map<String, dynamic>.from(value['values']);
  }

  String normalized(String path) {
    var value = path.replaceAll('\\', '/');
    if (value.startsWith('//?/UNC/')) {
      value = '//${value.substring(8)}';
    } else if (value.startsWith('//?/')) {
      value = value.substring(4);
    }
    return Platform.isWindows ? value.toLowerCase() : value;
  }

  Future<String> resolve(String relative) async {
    if (relative != '.' &&
        (relative.startsWith('/') ||
            relative.contains(':') ||
            relative
                .split(RegExp(r'[/\\]'))
                .any((s) => s.isEmpty || s == '.' || s == '..'))) {
      throw const FormatException('资料库选择路径无效。');
    }
    final directory = Directory(relative == '.' ? base : '$base/$relative');
    final canonicalBase = await Directory(base).resolveSymbolicLinks();
    final target = await directory.resolveSymbolicLinks();
    final a = normalized(canonicalBase), b = normalized(target);
    if (b != a && !b.startsWith('$a/')) {
      throw const FormatException('资料库超出应用保留目录。');
    }
    if (relative != '.') {
      final marker = jsonDecode(
        await File('$target/recovery.json').readAsString(),
      );
      if (marker is! Map ||
          marker['version'] != 1 ||
          marker['task'] is! String ||
          marker['library'] is! String) {
        throw const FormatException('恢复副本尚未完成校验。');
      }
    }
    return target;
  }

  Future<String> relative(String root) async {
    final a = await Directory(base).resolveSymbolicLinks();
    final b = await Directory(root).resolveSymbolicLinks();
    final an = normalized(a), bn = normalized(b);
    if (an == bn) return '.';
    if (!bn.startsWith('$an/')) throw const FormatException('恢复副本不在应用保留目录内。');
    return bn.substring(an.length + 1);
  }

  Future<void> select(
    String root, {
    required String previousRoot,
    required String previousPreferences,
  }) async {
    final relativeRoot = await relative(root);
    await resolve(relativeRoot);
    final previous = await relative(previousRoot);
    await records.create(recursive: true);
    final nonce = Random.secure()
        .nextInt(1 << 32)
        .toRadixString(16)
        .padLeft(8, '0');
    final stem =
        '${DateTime.now().microsecondsSinceEpoch.toString().padLeft(24, '0')}-$nonce';
    final pending = File('${records.path}/$stem.pending');
    await pending.writeAsString(
      jsonEncode({
        'version': 1,
        'root': relativeRoot,
        'previous': previous,
        'previousPreferences': previousPreferences,
      }),
      flush: true,
    );
    await pending.rename('${records.path}/$stem.json');
  }
}
