// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:io';
import 'plugin_manifest.dart';

/// Plugin-owned file boundaries, quotas and recoverable writes. No UI or network.
class PluginStorage {
  static bool retainedVersion(String path) =>
      RegExp(r'\.\d+\.(previous|part)$').hasMatch(path);
  final Directory root;
  final void Function([PluginPermission? permission]) check;
  PluginStorage(this.root, this.check);
  Future<File> file(Object? value) async {
    check(PluginPermission.derivedFiles);
    if (value is! String ||
        retainedVersion(value) ||
        !RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_./-]{0,239}$').hasMatch(value) ||
        value
            .split('/')
            .any(
              (p) =>
                  p.isEmpty ||
                  p == '.' ||
                  p == '..' ||
                  p.endsWith('.') ||
                  p.contains(':'),
            ) ||
        value
            .split('/')
            .any(
              (p) => RegExp(
                r'^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)',
                caseSensitive: false,
              ).hasMatch(p),
            )) {
      throw const FormatException('只接受插件私有目录内的相对路径');
    }
    // Check every ancestor, including a user-replaced support/plugin-data root.
    var ancestor = root.absolute;
    while (true) {
      if (await FileSystemEntity.type(ancestor.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FormatException('插件存储禁止链接');
      }
      final parent = ancestor.parent;
      if (parent.path == ancestor.path) break;
      ancestor = parent;
    }
    await root.create(recursive: true);
    final file = File('${root.path}/$value');
    var parent = file.parent;
    while (parent.path.length >= root.path.length) {
      if (await FileSystemEntity.type(parent.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const FormatException('插件存储禁止链接');
      }
      if (parent.path == root.path) break;
      parent = parent.parent;
    }
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw const FormatException('插件存储禁止链接');
    }
    return file;
  }

  Future<void> write(File file, List<int> bytes) async {
    check(PluginPermission.derivedFiles);
    var size = 0;
    await for (final entry in root.list(recursive: true, followLinks: false)) {
      if (entry is File && !retainedVersion(entry.path)) {
        size += await entry.length();
      }
    }
    final replaced = await file.exists() ? await file.length() : 0;
    if (size - replaced + bytes.length > 256 * 1024 * 1024) {
      throw StateError('插件文件总量超过256MiB，请手动管理文件');
    }
    // Unique staging files preserve failed writes and existing user versions.
    final staging = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.part',
    );
    await file.parent.create(recursive: true);
    await staging.writeAsBytes(bytes, flush: true);
    check(PluginPermission.derivedFiles);
    if (await file.exists()) {
      await file.rename(
        '${file.path}.${DateTime.now().microsecondsSinceEpoch}.previous',
      );
    }
    await staging.rename(file.path);
  }

  Future<File> configuration({String area = 'config'}) async {
    // Config is private, permission-free, bounded, and checked independently of files.
    var ancestor = root.parent.absolute;
    while (true) {
      if (await FileSystemEntity.type(ancestor.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw StateError('配置目录禁止链接');
      }
      final next = ancestor.parent;
      if (next.path == ancestor.path) break;
      ancestor = next;
    }
    final directory = Directory('${root.parent.path}/$area');
    if (await FileSystemEntity.type(directory.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StateError('配置目录禁止链接');
    }
    await directory.create(recursive: true);
    final file = File('${directory.path}/settings.json');
    if (await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StateError('配置文件禁止链接');
    }
    if (await file.exists() && await file.length() > 256 * 1024) {
      throw StateError('配置文件过大');
    }
    return file;
  }
}
