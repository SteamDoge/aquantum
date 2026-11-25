// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import '../plugins/plugin_api.dart';
import '../plugins/plugin_manager.dart';
import '../data/models.dart' show sizeLabel;
import 'plugin_details.dart';
import '../design/widgets.dart';
import '../l10n/l10n.dart';

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
          title: Text(tr('启用{name}', {'name': record.manifest.name})),
          content: Text(
            tr('此插件请求以下权限：\n{value}', {
              'value': permissions.map(permissionLabel).join('\n'),
            }),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr('取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr('授权并启用')),
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
              tr('插件'),
              actions: [
                if (onLink != null)
                  IconButton(
                    tooltip: tr('从链接安装插件'),
                    onPressed: ready ? onLink : null,
                    icon: const Icon(Icons.link),
                  ),
                IconButton(
                  tooltip: tr('ZIP 导入插件'),
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
                  tr('包副本 {packageCount} 个 · {value}\n未完成导入 {value2}', {
                    'packageCount': manager.packageCount,
                    'value': sizeLabel(manager.packageBytes),
                    'value2': sizeLabel(manager.incompleteBytes),
                  }),
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
                tr('尚未导入插件'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
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
                        SelectableText(
                          tr('来源：{source}', {'source': tr(record.source)}),
                        ),
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
                          child: Text(tr('设置、存储与日志')),
                        ),
                        if (onUpdate != null &&
                            record.source.startsWith('https://'))
                          TextButton(
                            onPressed: manager.busy
                                ? null
                                : () => onUpdate!(record),
                            child: Text(tr('检查更新')),
                          ),
                        for (final action in record.actions)
                          Text(
                            '${action.name} · ${action.point.name} · ${action.id}',
                          ),
                        Text(
                          tr('权限：{permissions}', {
                            'permissions': permissionList(
                              record.manifest.permissions,
                            ),
                          }),
                        ),
                        Text(
                          tr(
                            '已注册页面 {value} · 阅读处理器 {count} · 上下文能力 {count2} · 组件 {value2}',
                            {
                              'value': manager.features.all
                                  .where((p) => p.source == record.manifest.id)
                                  .length,
                              'count': record.formats.length,
                              'count2': record.actions.length,
                              'value2':
                                  manager.dashboards?.all
                                      .where(
                                        (d) => d.source == record.manifest.id,
                                      )
                                      .length ??
                                  0,
                            },
                          ),
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
                                child: Text(tr('重新安装')),
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
                                      ? tr('停用')
                                      : tr('启用'),
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
                                              tr('卸载{name}？', {
                                                'name': record.manifest.name,
                                              }),
                                            ),
                                            content: Text(
                                              tr('卸载后保留插件数据，可重新安装恢复。'),
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.pop(
                                                  context,
                                                  false,
                                                ),
                                                child: Text(tr('取消')),
                                              ),
                                              FilledButton(
                                                onPressed: () => Navigator.pop(
                                                  context,
                                                  true,
                                                ),
                                                child: Text(tr('卸载')),
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
                                child: Text(tr('卸载')),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

String permissionLabel(PluginPermission permission) => switch (permission) {
  PluginPermission.selectedText => tr('读取你选中的文字'),
  PluginPermission.documentText => tr('读取当前阅读状态与事件'),
  PluginPermission.derivedFiles => tr('创建独立派生文件'),
  PluginPermission.network => tr('联网访问'),
  PluginPermission.libraryImport => tr('复制插件文件到资料库'),
  PluginPermission.libraryRead => tr('读取资料库文件信息'),
  PluginPermission.services => tr('与已声明依赖的插件交换数据'),
  PluginPermission.clipboard => tr('使用剪贴板'),
  PluginPermission.externalFiles => tr('访问用户选择的外部文件'),
  PluginPermission.secureStorage => tr('保存敏感凭据'),
};

/// The permissions a plugin asks for, joined for one line of text.
String permissionList(Iterable<PluginPermission> permissions) =>
    permissions.isEmpty
    ? tr('无需额外权限')
    : permissions.map(permissionLabel).join(tr('、'));
String statusLabel(PluginStatus status) => switch (status) {
  PluginStatus.available => tr('未安装'),
  PluginStatus.disabled => tr('已停用'),
  PluginStatus.enabled => tr('已启用'),
  PluginStatus.suspended => tr('已暂停 · 返回前台恢复'),
  PluginStatus.failed => tr('启用失败 / 已撤销入口'),
};
