// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import '../plugins/plugin_api.dart';
import '../plugins/plugin_manager.dart';
import '../data/models.dart' show sizeLabel;
import 'plugin_details.dart';
import '../design/widgets.dart';

class PluginScreen extends StatelessWidget {
  final PluginManager manager;
  final VoidCallback onImport;
  final VoidCallback? onLink;
  final void Function(PluginRecord)? onUpdate;
  const PluginScreen({
    super.key,
    required this.manager,
    required this.onImport,
    this.onLink,
    this.onUpdate,
  });
  Future<void> perform(
    BuildContext context,
    Future<void> Function() operation,
  ) async {
    try {
      await operation();
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    }
  }

  Future<void> enable(BuildContext context, PluginRecord record) async {
    final permissions = record.manifest.permissions;
    if (permissions.isNotEmpty) {
      final approved = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('启用${record.manifest.name}'),
          content: Text(
            '此插件请求以下权限：\n${permissions.map(permissionLabel).join('\n')}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('授权并启用'),
            ),
          ],
        ),
      );
      if (approved != true || !context.mounted) return;
    }
    await perform(
      context,
      () => manager.enable(record.manifest.id, permissions),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: manager,
      builder: (context, _) {
        final records = [...manager.records]
          ..sort(
            (a, b) => (a.manifest.id.startsWith('builtin.') ? 1 : 0).compareTo(
              b.manifest.id.startsWith('builtin.') ? 1 : 0,
            ),
          );
        final ready = manager.ready && !manager.busy;
        return ListView(
          key: const PageStorageKey('plugins-scroll'),
          padding: EdgeInsets.fromLTRB(
            20,
            28,
            20,
            24 + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            AqPageHeading(
              '插件',
              actions: [
                if (onLink != null)
                  IconButton(
                    tooltip: '从链接安装插件',
                    onPressed: ready ? onLink : null,
                    icon: const Icon(Icons.link),
                  ),
                IconButton(
                  tooltip: 'ZIP 导入插件',
                  onPressed: ready ? onImport : null,
                  icon: const Icon(Icons.add),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (manager.packageCount > 0 || manager.incompleteBytes > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                child: Text(
                  '包副本 ${manager.packageCount} 个 · ${sizeLabel(manager.packageBytes)}\n未完成导入 ${sizeLabel(manager.incompleteBytes)}；副本和残留均保留。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            if (!manager.ready || manager.busy) const LinearProgressIndicator(),
            if (manager.loadError != null)
              Text(
                manager.loadError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            for (final error in manager.packageErrors)
              Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (manager.records.isEmpty) ...[
              const SizedBox(height: 40),
              Icon(
                Icons.extension_outlined,
                size: 44,
                color: Theme.of(
                  context,
                ).colorScheme.onSurfaceVariant.withValues(alpha: .6),
              ),
              const SizedBox(height: 14),
              Text(
                '尚未导入插件',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              Text(
                '安装独立 JavaScript 插件 ZIP，按需启用阅读工具、原生页面或自定义页面。',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            for (final record in records)
              Card(
                margin: const EdgeInsets.only(bottom: 16),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: DefaultTextStyle.merge(
                    style: Theme.of(context).textTheme.bodySmall,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          record.manifest.name,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(
                          '${record.manifest.version} · API ${record.manifest.apiVersion} · ${statusLabel(record.status)}',
                        ),
                        const SizedBox(height: 8),
                        Text(
                          record.manifest.description,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 4),
                        SelectableText('来源：${record.source}'),
                        TextButton(
                          onPressed: manager.busy
                              ? null
                              : () => perform(
                                  context,
                                  () => showPluginDetails(
                                    context,
                                    manager,
                                    record,
                                  ),
                                ),
                          child: const Text('设置、存储与日志'),
                        ),
                        if (onUpdate != null &&
                            record.source.startsWith('https://'))
                          TextButton(
                            onPressed: manager.busy
                                ? null
                                : () => onUpdate!(record),
                            child: const Text('检查更新'),
                          ),
                        for (final action in record.actions)
                          Text(
                            '${action.name} · ${action.point.name} · ${action.id}',
                          ),
                        Text(
                          '权限：${record.manifest.permissions.isEmpty ? '无需额外权限' : record.manifest.permissions.map(permissionLabel).join('、')}',
                        ),
                        Text(
                          '已注册页面 ${manager.features.all.where((p) => p.source == record.manifest.id).length} · 阅读处理器 ${record.formats.length} · 上下文能力 ${record.actions.length} · 组件 ${manager.dashboards?.all.where((d) => d.source == record.manifest.id).length ?? 0}',
                        ),
                        if (record.error != null)
                          Text(
                            record.error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        const SizedBox(height: 12),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (record.status == PluginStatus.available)
                              FilledButton(
                                onPressed: manager.busy
                                    ? null
                                    : () => perform(
                                        context,
                                        () =>
                                            manager.install(record.manifest.id),
                                      ),
                                child: const Text('重新安装'),
                              )
                            else ...[
                              FilledButton(
                                onPressed: manager.busy
                                    ? null
                                    : () =>
                                          record.status == PluginStatus.enabled
                                          ? perform(
                                              context,
                                              () => manager.disable(
                                                record.manifest.id,
                                              ),
                                            )
                                          : enable(context, record),
                                child: Text(
                                  record.status == PluginStatus.enabled
                                      ? '停用'
                                      : '启用',
                                ),
                              ),
                              OutlinedButton(
                                onPressed: manager.busy
                                    ? null
                                    : () async {
                                        final approved = await showDialog<bool>(
                                          context: context,
                                          builder: (context) => AlertDialog(
                                            title: Text(
                                              '卸载${record.manifest.name}？',
                                            ),
                                            content: const Text(
                                              '卸载后保留插件数据，可重新安装恢复。若需删除数据，请先在设置、存储与日志中导出备份并选择删除。',
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.pop(
                                                  context,
                                                  false,
                                                ),
                                                child: const Text('取消'),
                                              ),
                                              FilledButton(
                                                onPressed: () => Navigator.pop(
                                                  context,
                                                  true,
                                                ),
                                                child: const Text('卸载'),
                                              ),
                                            ],
                                          ),
                                        );
                                        if (approved == true &&
                                            context.mounted) {
                                          await perform(
                                            context,
                                            () => manager.uninstall(
                                              record.manifest.id,
                                            ),
                                          );
                                        }
                                      },
                                child: const Text('卸载'),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Text(
              '支持 ZIP 与 GitHub / HTTPS 安装 JavaScript 插件。安装后默认停用，更新需重新确认。',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        );
      },
    );
  }
}

String permissionLabel(PluginPermission permission) => switch (permission) {
  PluginPermission.selectedText => '读取你选中的文字',
  PluginPermission.documentText => '读取当前阅读状态与事件',
  PluginPermission.derivedFiles => '创建独立派生文件',
  PluginPermission.network => '联网访问',
  PluginPermission.libraryImport => '复制插件文件到资料库',
  PluginPermission.libraryRead => '读取资料库文件信息',
  PluginPermission.services => '与已声明依赖的插件交换数据',
  PluginPermission.clipboard => '使用剪贴板',
  PluginPermission.externalFiles => '访问用户选择的外部文件',
  PluginPermission.secureStorage => '保存敏感凭据',
};
String statusLabel(PluginStatus status) => switch (status) {
  PluginStatus.available => '未安装',
  PluginStatus.disabled => '已停用',
  PluginStatus.enabled => '已启用',
  PluginStatus.suspended => '已暂停 · 返回前台恢复',
  PluginStatus.failed => '启用失败 / 已撤销入口',
};
