// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'plugin_instance.dart';
export 'plugin_instance.dart';

const pluginZipLimit = 32 * 1024 * 1024;
const pluginManifestLimit = 128 * 1024;
const pluginManifestName = 'aquantum.plugin.json';

/// Validate off the UI isolate. No entry is ever extracted to a filesystem path.
Future<JavaScriptPlugin> inspectPluginZip(Uint8List bytes) async {
  final json = await Isolate.run(() => _readManifest(bytes));
  return JavaScriptPlugin.fromJson(
    Map<String, dynamic>.from(json['manifest']),
    assets: (json['assets'] as Map?)?.map(
      (key, value) => MapEntry(key as String, value as Uint8List),
    ),
  )..packageDigest = sha256.convert(bytes).toString();
}

Map<String, dynamic> _readManifest(Uint8List bytes) {
  if (bytes.length > pluginZipLimit || bytes.length < 22) {
    throw const FormatException('插件 ZIP 无效或超过32MiB');
  }
  final directory = ZipDirectory()..read(InputMemoryStream(bytes));
  if (directory.numberOfThisDisk != 0 ||
      directory.diskWithTheStartOfTheCentralDirectory != 0 ||
      directory.fileHeaders.isEmpty ||
      directory.fileHeaders.length > 4096 ||
      directory.fileHeaders.length != directory.totalCentralDirectoryEntries) {
    throw const FormatException('不支持空包、分卷包或过多条目');
  }
  final names = <String>{};
  var total = 0;
  ZipFile? manifest;
  for (final header in directory.fileHeaders) {
    final name = header.filename;
    final local = header.file;
    final mode = (header.externalFileAttributes >> 16) & 0xf000;
    if (!names.add(name.toLowerCase()) ||
        !RegExp(r'^[a-zA-Z0-9_][a-zA-Z0-9_./-]{0,239}$').hasMatch(name) ||
        name
            .split('/')
            .any((part) => part.isEmpty || part == '.' || part == '..') ||
        local == null ||
        local.filename != name ||
        (mode != 0 && mode != 0x8000) ||
        header.diskNumberStart != 0 ||
        header.generalPurposeBitFlag & 1 != 0 ||
        local.flags & 1 != 0 ||
        !{0, 8}.contains(header.compressionMethod) ||
        header.localHeaderOffset < 0 ||
        header.localHeaderOffset >= directory.centralDirectoryOffset ||
        header.compressedSize < 0 ||
        header.compressedSize > bytes.length ||
        header.uncompressedSize < 0 ||
        header.uncompressedSize >
            (name == pluginManifestName
                ? pluginManifestLimit
                : 16 * 1024 * 1024)) {
      throw const FormatException('包包含不允许的路径、重复文件、链接、加密或可执行内容');
    }
    total += header.uncompressedSize;
    if (total > 64 * 1024 * 1024) throw const FormatException('插件解压内容超过64MiB');
    if (name == pluginManifestName) manifest = local;
  }
  if (manifest == null) {
    throw const FormatException('ZIP 根目录缺少 aquantum.plugin.json');
  }
  // archive >=4.5.2 bounds decompression to the declared size. Validate actual
  // byte count and CRC explicitly; ZipDecoder.verify currently is not sufficient.
  final assets = <String, Uint8List>{};
  for (final header in directory.fileHeaders) {
    final content = header.file!.getStream().toUint8List();
    if (content.length != header.uncompressedSize ||
        getCrc32(content) != header.crc32) {
      throw const FormatException('插件文件大小或 CRC 校验失败');
    }
    assets[header.filename] = content;
  }
  final decoded = jsonDecode(utf8.decode(assets.remove(pluginManifestName)!));
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('插件清单必须是 JSON 对象');
  }
  // Validate the schema inside the isolate, not just ZIP structure.
  JavaScriptPlugin.validate(decoded);
  final entry = decoded['entry'] as String;
  if (!directory.fileHeaders.any((h) => h.filename == entry)) {
    throw const FormatException('缺少 JavaScript 入口');
  }
  if (directory.fileHeaders.any(
    (h) =>
        !RegExp(
          r'\.(html|js|mjs|css|json|png|jpg|jpeg|webp|gif|svg|ttf|otf|woff|woff2|txt|md)$',
          caseSensitive: false,
        ).hasMatch(h.filename) &&
        !{'LICENSE', 'NOTICES'}.contains(h.filename),
  )) {
    throw const FormatException('插件只允许 JavaScript 与静态资源，禁止原生代码和 WASM');
  }
  return {'manifest': decoded, 'assets': assets};
}

class LoadedPluginPackages {
  final List<JavaScriptPlugin> plugins;
  final List<String> errors;
  final int packageCount, packageBytes, incompleteBytes;
  final List<JavaScriptPlugin> versions;
  LoadedPluginPackages(
    this.plugins,
    this.errors, {
    this.packageCount = 0,
    this.packageBytes = 0,
    this.incompleteBytes = 0,
    this.versions = const [],
  });
}

abstract interface class PluginPackageStore {
  Future<LoadedPluginPackages> load();
  Future<void> retain(Uint8List bytes);
}

/// Imports are immutable and retained even after uninstall or failed activation.
/// No archive path is ever used as a local destination.
class FilePluginPackageStore implements PluginPackageStore {
  final Directory root;
  FilePluginPackageStore(String path) : root = Directory(path);
  @override
  Future<void> retain(Uint8List bytes) async {
    await root.create(recursive: true);
    final folder = await root.createTemp('import-');
    final pending = File('${folder.path}/package.zip.part');
    await pending.writeAsBytes(bytes, flush: true);
    await pending.rename('${folder.path}/package.zip');
  }

  @override
  Future<LoadedPluginPackages> load() async {
    final plugins = <String, JavaScriptPlugin>{};
    final versions = <JavaScriptPlugin>[];
    final errors = <String>[];
    var packageCount = 0, packageBytes = 0, incompleteBytes = 0;
    if (!await root.exists()) return LoadedPluginPackages([], errors);
    await for (final directory in root.list(followLinks: false)) {
      if (directory is! Directory) continue;
      final file = File('${directory.path}/package.zip');
      if (!await file.exists()) {
        final pending = File('${directory.path}/package.zip.part');
        if (await FileSystemEntity.type(pending.path, followLinks: false) ==
            FileSystemEntityType.file) {
          incompleteBytes += await pending.length();
        }
        errors.add('存在未完成的插件导入，文件已保留');
        continue;
      }
      try {
        if (await FileSystemEntity.type(file.path, followLinks: false) ==
            FileSystemEntityType.file) {
          packageCount++;
          packageBytes += await file.length();
        }
        if ((await FileSystemEntity.type(file.path, followLinks: false)) !=
                FileSystemEntityType.file ||
            await file.length() > pluginZipLimit) {
          throw const FormatException('插件包过大或不是普通文件');
        }
        final plugin = await inspectPluginZip(await file.readAsBytes());
        versions.add(plugin);
        final previous = plugins[plugin.manifest.id];
        if (previous == null ||
            comparePluginVersions(
                  plugin.manifest.version,
                  previous.manifest.version,
                ) >
                0) {
          plugins[plugin.manifest.id] = plugin;
        }
      } catch (error) {
        errors.add('一个插件包未加载：$error');
      }
    }
    return LoadedPluginPackages(
      plugins.values.toList(),
      errors,
      packageCount: packageCount,
      packageBytes: packageBytes,
      incompleteBytes: incompleteBytes,
      versions: versions,
    );
  }
}

int comparePluginVersions(String a, String b) {
  final left = a.split('.').map(BigInt.parse).toList();
  final right = b.split('.').map(BigInt.parse).toList();
  for (var i = 0; i < 3; i++) {
    final order = left[i].compareTo(right[i]);
    if (order != 0) return order;
  }
  return 0;
}
