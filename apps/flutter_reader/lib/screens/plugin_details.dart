// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import '../data/models.dart' show sizeLabel;
import '../plugins/plugin_manager.dart';
import '../plugins/plugin_package.dart';
import '../plugins/plugin_export.dart';
import '../plugins/plugin_system.dart';

Future<void> showPluginDetails(
  BuildContext context,
  PluginManager manager,
  PluginRecord record,
) async {
  final data = await manager.data();
  final bytes = await data.usage(record.manifest.id);
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheet) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(sheet).height * .8,
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              record.manifest.name,
              style: Theme.of(sheet).textTheme.headlineSmall,
            ),
            const SizedBox(height: 12),
            Text('私有存储 ${sizeLabel(bytes)} · 安装来源 ${record.source}'),
            Text(
              'API ${record.manifest.apiVersion} · 已授权 ${record.grants.map((p) => p.name).join('、')}',
            ),
            if (record.implementation is JavaScriptPlugin)
              Text(
                '兼容平台 ${(record.implementation as JavaScriptPlugin).platforms.join('、')}',
              ),
            const SizedBox(height: 16),
            for (final page in manager.features.all.where(
              (p) => p.source == record.manifest.id && !p.allowNavigation,
            ))
              ListTile(
                title: Text(page.name),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(sheet);
                  manager.hostServices?.onOpenPage?.call(page.id);
                },
              ),
            OutlinedButton.icon(
              icon: const Icon(Icons.save_alt),
              label: const Text('导出数据备份'),
              onPressed: () async {
                await _perform(sheet, () async {
                  final archive = await data.backup(record.manifest.id);
                  await exportPluginBytes(
                    '${record.manifest.id}-backup.zip',
                    archive,
                  );
                });
              },
            ),
            OutlinedButton.icon(
              icon: const Icon(Icons.restore),
              label: const Text('从备份恢复数据'),
              onPressed: () async {
                final confirmed = await _confirm(
                  sheet,
                  '恢复此插件的数据？',
                  '同名文件将保留 previous 副本，恢复前停用插件；包和资料库副本不受影响。',
                );
                if (confirmed != true || !sheet.mounted) return;
                await _perform(sheet, () async {
                  final picked = await FilePicker.platform.pickFiles(
                    type: FileType.custom,
                    allowedExtensions: ['zip'],
                    withReadStream: true,
                    withData: false,
                  );
                  if (picked == null || picked.files.isEmpty) return;
                  final file = picked.files.single;
                  if (file.size > 64 * 1024 * 1024 || file.readStream == null) {
                    throw StateError('备份过大或不可读取');
                  }
                  final content = BytesBuilder(copy: false);
                  await for (final chunk in file.readStream!) {
                    if (content.length + chunk.length > 64 * 1024 * 1024) {
                      throw StateError('备份过大');
                    }
                    content.add(chunk);
                  }
                  await manager.disable(record.manifest.id);
                  await data.restore(record.manifest.id, content.takeBytes());
                });
              },
            ),
            TextButton(
              onPressed: () =>
                  _perform(sheet, () => data.clearCache(record.manifest.id)),
              child: const Text('清理此插件缓存与临时文件'),
            ),
            TextButton(
              onPressed: () async {
                final confirmed = await _confirm(
                  sheet,
                  '删除此插件的私有数据？',
                  '这会删除设置、下载文件和此插件的凭据，并停用插件。备份不含凭据；资料库中的副本保留。',
                );
                if (confirmed != true || !sheet.mounted) return;
                await _perform(sheet, () async {
                  await manager.disable(record.manifest.id);
                  await PluginSystemAccess.deleteCredentials(
                    record.manifest.id,
                  );
                  await data.deleteData(record.manifest.id);
                });
              },
              child: const Text('删除此插件私有数据'),
            ),
            if (manager.previousVersions(record.manifest.id).isNotEmpty)
              TextButton(
                onPressed: () async {
                  final confirmed = await _confirm(
                    sheet,
                    '恢复保留的上一个版本？',
                    '私有数据保留，恢复后插件停用，需要重新确认权限。',
                  );
                  if (confirmed == true && sheet.mounted) {
                    await _perform(
                      sheet,
                      () => manager.rollback(record.manifest.id),
                    );
                  }
                },
                child: const Text('恢复保留的上一个版本'),
              ),
            const Divider(),
            Text('插件错误与日志', style: Theme.of(sheet).textTheme.titleMedium),
            if (record.error != null) SelectableText(record.error!),
            SelectableText(
              (manager.hostServices?.logs[record.manifest.id] ?? ['暂无日志']).join(
                '\n',
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Future<bool?> _confirm(BuildContext context, String title, String message) =>
    showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认'),
          ),
        ],
      ),
    );
Future<void> _perform(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('操作已完成')));
    }
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }
}
