// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import '../data/models.dart';
import '../plugins/plugin_manager.dart';
import 'reader_defaults_screen.dart';
import 'toolbar_editor.dart';
import '../design/appearance.dart';
import '../design/widgets.dart';

class AppearanceSettings extends StatelessWidget {
  final bool showPalettes;
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChanged;
  const AppearanceSettings({
    super.key,
    required this.mode,
    required this.onChanged,
    this.showPalettes = true,
  });
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (showPalettes) const PaletteSettings(),
      Text('明暗模式', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 12),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final value in ThemeMode.values)
            ChoiceChip(
              label: Text(switch (value) {
                ThemeMode.system => '跟随系统',
                ThemeMode.light => '浅色',
                ThemeMode.dark => '深色',
              }),
              selected: mode == value,
              onSelected: (_) => onChanged(value),
            ),
        ],
      ),
    ],
  );
}

enum ProfileDetail { settings, storage, history }

class AppearanceScreen extends StatefulWidget {
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChanged;
  const AppearanceScreen({
    super.key,
    required this.mode,
    required this.onChanged,
  });
  @override
  State<AppearanceScreen> createState() => _AppearanceScreenState();
}

class _AppearanceScreenState extends State<AppearanceScreen> {
  late ThemeMode mode = widget.mode;
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('外观')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const AqPageHeading(
              '你的阅读空间',
              brand: false,
              subtitle: '共享布局 / 颜色主题',
            ),
            const SizedBox(height: 24),
            AqPanel(
              child: AppearanceSettings(
                mode: mode,
                onChanged: (value) {
                  widget.onChanged(value);
                  setState(() => mode = value);
                },
              ),
            ),
            const SizedBox(height: 16),
            const Text('颜色主题只改变应用界面配色。阅读正文的纸色和日夜配置仍在阅读设置中独立保存。'),
          ],
        ),
      ),
    ),
  );
}

class ProfileDetails extends StatelessWidget {
  final PluginManager? plugins;
  final LibrarySnapshot library;
  final ProfileDetail section;
  final VoidCallback? onStatisticsHelp;
  final VoidCallback? onStorageMaintenance;
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onThemeChanged;
  const ProfileDetails({
    super.key,
    this.plugins,
    required this.library,
    required this.section,
    this.onStatisticsHelp,
    this.onStorageMaintenance,
    required this.mode,
    required this.onThemeChanged,
  });
  @override
  Widget build(BuildContext context) {
    final storage = library.raw['storage'] as Map;
    return ListView(
      key: PageStorageKey('profile-${section.name}'),
      padding: EdgeInsets.fromLTRB(
        24,
        24,
        24,
        24 + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        const SizedBox(height: 16),
        AqPageHeading(switch (section) {
          ProfileDetail.settings => '设置',
          ProfileDetail.storage => '存储管理',
          ProfileDetail.history => '操作记录',
        }, subtitle: '我的 / 本机偏好'),
        const SizedBox(height: 24),
        if (section == ProfileDetail.settings) ...[
          ListTile(
            leading: const Icon(Icons.palette_outlined),
            title: const Text('外观'),
            subtitle: const Text('颜色主题与明暗模式'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push<void>(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    AppearanceScreen(mode: mode, onChanged: onThemeChanged),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('编辑工具栏'),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<bool>(
                builder: (_) => ToolbarEditor(plugins: plugins),
              ),
            ),
          ),
          const SizedBox(height: 24),
          ListTile(
            leading: const Icon(Icons.auto_stories_outlined),
            title: const Text('阅读器选择'),
            subtitle: const Text('按文件格式选择默认阅读器'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ReaderDefaultsScreen(plugins: plugins),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.dashboard_customize_outlined),
            title: const Text('统计与自定义卡片'),
            subtitle: const Text('接口说明'),
            trailing: const Icon(Icons.chevron_right),
            onTap: onStatisticsHelp,
          ),
        ],
        if (section == ProfileDetail.storage) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('已导入原件副本'),
            trailing: Text(sizeLabel(storage['original_bytes'] as num)),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('资料库与阅读记录'),
            trailing: Text(sizeLabel(storage['database_bytes'] as num)),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('待处理导入与残留'),
            trailing: Text(
              sizeLabel(
                (storage['retained_unreferenced_bytes'] as num) +
                    (storage['incomplete_bytes'] as num) +
                    (library.raw['staging_bytes'] as num),
              ),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.storage_outlined),
            title: const Text('手动清理、任务与备份恢复'),
            trailing: const Icon(Icons.chevron_right),
            onTap: onStorageMaintenance,
          ),
        ],
        if (section == ProfileDetail.history) ...[
          ...((library.catalog['operations'] as List).reversed
              .take(12)
              .map(
                (op) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.history),
                  title: Text(switch (op['action']) {
                    'import_book' => '导入内容',
                    'create_project' => '创建项目',
                    'add_note' => '保存笔记',
                    'set_book_gap' => '修改阅读间隔',
                    _ => '更新资料',
                  }),
                  subtitle: Text(
                    DateTime.fromMillisecondsSinceEpoch(
                      (op['unix_seconds'] as int) * 1000,
                    ).toLocal().toString().split('.').first,
                  ),
                ),
              )),
          if ((library.catalog['operations'] as List).isEmpty)
            const Text('还没有操作记录。'),
        ],
      ],
    );
  }
}
