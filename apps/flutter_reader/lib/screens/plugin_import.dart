// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../plugins/plugin_manager.dart';
import '../plugins/plugin_package.dart';
import '../plugins/plugin_download.dart';
import 'plugin_screen.dart' show permissionLabel;

Future<void> importPluginZip(
  BuildContext context,
  PluginManager manager,
  PluginPackageStore packages,
) async {
  FilePickerResult? picked;
  try {
    picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
      allowMultiple: false,
      withData: false,
      withReadStream: true,
    );
  } on PlatformException catch (error) {
    if (error.code == 'invalid_format_type') {
      throw const FormatException('系统无法打开 ZIP 文件选择器，请检查系统文件管理器是否可用。');
    }
    rethrow;
  }
  if (picked == null || picked.files.isEmpty || !context.mounted) return;
  final file = picked.files.single;
  if (file.size > pluginZipLimit || file.readStream == null) {
    throw const FormatException('插件 ZIP 最多32MiB，请重新选择');
  }
  final builder = BytesBuilder(copy: false);
  await for (final chunk in file.readStream!) {
    if (builder.length + chunk.length > pluginZipLimit) {
      throw const FormatException('插件 ZIP 超过32MiB');
    }
    builder.add(chunk);
  }
  final bytes = builder.takeBytes();
  final plugin = await inspectPluginZip(bytes);
  if (!context.mounted) return;
  await confirmPluginImport(context, manager, packages, plugin, bytes);
}

Future<void> importPluginLink(
  BuildContext context,
  PluginManager manager,
  PluginPackageStore packages, {
  PluginRecord? updating,
}) async {
  String? link = updating?.source;
  if (link == null || !link.startsWith('https://')) {
    final controller = TextEditingController();
    try {
      link = await showDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('从链接安装插件'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'GitHub 仓库、Release 或 HTTPS ZIP 链接',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('检查安装包'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }
  if (link == null || !context.mounted) return;
  ScaffoldMessenger.of(
    context,
  ).showSnackBar(const SnackBar(content: Text('正在下载并检查插件…')));
  final download = await PluginDownloader().inspect(
    link.replaceFirst('（默认分支声明）', ''),
  );
  if (!context.mounted) return;
  if (updating != null) {
    if (download.plugin.manifest.id != updating.manifest.id) {
      throw const FormatException('更新包的插件 ID 与已安装插件不同');
    }
    if (comparePluginVersions(
          download.plugin.manifest.version,
          updating.manifest.version,
        ) <=
        0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('没有更高版本；未修改已安装插件')));
      return;
    }
  }
  await confirmPluginImport(
    context,
    manager,
    packages,
    download.plugin,
    download.bytes,
    source: download.source,
    notes: download.releaseNotes,
    digest: download.digest,
  );
}

Future<void> confirmPluginImport(
  BuildContext context,
  PluginManager manager,
  PluginPackageStore packages,
  JavaScriptPlugin plugin,
  Uint8List bytes, {
  String source = '本地 ZIP',
  String notes = '',
  String? digest,
}) async {
  manager.checkImport(plugin);
  if (!context.mounted) return;
  final old = manager.records.where((r) => r.manifest.id == plugin.manifest.id);
  final accepted = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(old.isEmpty ? '导入插件' : '更新插件'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${plugin.manifest.name}  ${plugin.manifest.version}',
              style: const TextStyle(fontSize: 20),
            ),
            const SizedBox(height: 8),
            SelectableText(plugin.manifest.id),
            const SizedBox(height: 12),
            Text(plugin.manifest.description),
            Text(
              '作者：${plugin.manifest.author}\n发布者声明：${plugin.manifest.publisher}（未经身份验证）',
            ),
            SelectableText('来源：$source'),
            if (notes.isNotEmpty) Text(notes),
            if (digest != null) SelectableText('SHA-256：$digest'),
            const SizedBox(height: 12),
            Text(
              'JavaScript 入口：${plugin.entry}\n权限：${plugin.manifest.permissions.isEmpty ? '无需额外权限' : plugin.manifest.permissions.map(permissionLabel).join('、')}',
            ),
            const SizedBox(height: 12),
            Text('此包包含 JavaScript 代码。安装后停用；启用须确认权限，更新保留私有数据。发布者身份未经签名验证。'),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(old.isEmpty ? '导入副本' : '更新并停用'),
        ),
      ],
    ),
  );
  if (accepted != true) return;
  await manager.importPackage(plugin, packages, bytes, source: source);
  if (context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('插件已导入，请在插件页面启用')));
  }
}
