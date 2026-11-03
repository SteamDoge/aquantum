// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';

/// User-initiated maintenance. Package versions and private data have separate lifetimes.
class PluginData {
  final String base;
  PluginData(this.base);
  Future<Directory> directory(String id) async {
    if (!RegExp(r'^[a-z][a-z0-9_-]*(?:\.[a-z][a-z0-9_-]*)+$').hasMatch(id)) {
      throw const FormatException('插件ID无效');
    }
    final parent = await Directory(base).create(recursive: true);
    final canonical = await parent.resolveSymbolicLinks();
    final root = Directory('$canonical/$id');
    await _noLinks(root);
    await root.create(recursive: true);
    return root;
  }

  Future<void> _noLinks(FileSystemEntity entity) async {
    if (await FileSystemEntity.type(entity.path, followLinks: false) ==
        FileSystemEntityType.link) {
      throw StateError('插件数据目录禁止链接');
    }
    if (entity is Directory && await entity.exists()) {
      await for (final child in entity.list(
        recursive: true,
        followLinks: false,
      )) {
        if (await FileSystemEntity.type(child.path, followLinks: false) ==
            FileSystemEntityType.link) {
          throw StateError('插件数据包含链接，维护已停止');
        }
      }
    }
  }

  Future<int> usage(String id) async {
    final root = await directory(id);
    var bytes = 0;
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is File) bytes += await entity.length();
    }
    return bytes;
  }

  Future<void> clearCache(String id) async {
    final root = await directory(id);
    for (final name in ['cache', 'temp']) {
      final target = Directory('${root.path}/$name');
      await _noLinks(target);
      if (await target.exists()) await target.delete(recursive: true);
    }
  }

  Future<void> deleteData(String id) async {
    final root = await directory(id);
    // Only named data areas. Immutable package versions and external imports survive.
    for (final name in ['data', 'config', 'files', 'cache', 'temp']) {
      final target = Directory('${root.path}/$name');
      await _noLinks(target);
      if (await target.exists()) await target.delete(recursive: true);
    }
  }

  Future<Uint8List> backup(String id) async {
    final root = await directory(id);
    final archive = Archive();
    var total = 0;
    final manifest = utf8.encode(
      jsonEncode({'schemaVersion': 1, 'pluginId': id}),
    );
    archive.addFile(
      ArchiveFile('plugin-backup.json', manifest.length, manifest),
    );
    await for (final entity in root.list(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final relative = entity.path
          .substring(root.path.length + 1)
          .replaceAll('\\', '/');
      if (!{'data', 'config', 'files'}.contains(relative.split('/').first)) {
        continue;
      }
      total += await entity.length();
      if (total > 64 * 1024 * 1024) throw StateError('备份超过64MiB，请分批导出文件');
      final bytes = await entity.readAsBytes();
      archive.addFile(ArchiveFile(relative, bytes.length, bytes));
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  Future<void> restore(String id, Uint8List bytes) async {
    if (bytes.length > 64 * 1024 * 1024) throw StateError('备份文件过大');
    final central = ZipDirectory()..read(InputMemoryStream(bytes));
    var expanded = 0;
    if (central.fileHeaders.length > 4096 ||
        central.numberOfThisDisk != 0 ||
        central.diskWithTheStartOfTheCentralDirectory != 0) {
      throw const FormatException('备份目录无效');
    }
    for (final header in central.fileHeaders) {
      expanded += header.uncompressedSize;
      if (expanded > 64 * 1024 * 1024 ||
          header.uncompressedSize > 16 * 1024 * 1024 ||
          header.generalPurposeBitFlag & 1 != 0 ||
          header.file == null ||
          header.file!.filename != header.filename) {
        throw const FormatException('备份文件超限或加密');
      }
    }
    final root = await directory(id);
    final archive = ZipDecoder().decodeBytes(bytes, verify: true);
    var total = 0;
    final names = <String>{};
    for (final file in archive.files) {
      final name = file.name;
      if (!file.isFile ||
          file.isSymbolicLink ||
          !names.add(name.toLowerCase()) ||
          !RegExp(r'^[a-zA-Z0-9_][a-zA-Z0-9_./-]{0,239}$').hasMatch(name) ||
          name
              .split('/')
              .any(
                (p) => p.isEmpty || p == '.' || p == '..' || p.endsWith('.'),
              ) ||
          name != 'plugin-backup.json' &&
              !{'data', 'config', 'files'}.contains(name.split('/').first)) {
        throw const FormatException('备份路径无效');
      }
      total += file.size;
      if (total > 64 * 1024 * 1024 ||
          file.size > 16 * 1024 * 1024 ||
          archive.files.length > 4096) {
        throw const FormatException('备份解压大小超限');
      }
    }
    final manifest = archive.findFile('plugin-backup.json');
    if (manifest == null) throw const FormatException('缺少插件备份清单');
    final info = jsonDecode(utf8.decode(manifest.content));
    if (info['schemaVersion'] != 1 || info['pluginId'] != id) {
      throw const FormatException('备份插件身份不匹配');
    }
    // Validate all entries first, stage all bytes, then preserve each overwritten file.
    final staging = await root.createTemp('restore-');
    for (final file in archive.files.where(
      (f) => f.name != 'plugin-backup.json',
    )) {
      final target = File('${staging.path}/${file.name}');
      await target.parent.create(recursive: true);
      await target.writeAsBytes(file.content, flush: true);
    }
    await _noLinks(root);
    for (final file in archive.files.where(
      (f) => f.name != 'plugin-backup.json',
    )) {
      final target = File('${root.path}/${file.name}');
      await target.parent.create(recursive: true);
      if (await target.exists()) {
        await target.rename(
          '${target.path}.${DateTime.now().microsecondsSinceEpoch}.previous',
        );
      }
      await File('${staging.path}/${file.name}').rename(target.path);
    }
  }
}
