// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import '../data/models.dart';
import '../features/feature_registry.dart';
import 'profile_details.dart';
import '../design/widgets.dart';

class ProfileScreen extends StatelessWidget {
  final LibrarySnapshot library;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  final FeatureRegistry registry;
  final ValueChanged<String> onOpen;
  final VoidCallback onCustomize, onImportPlugin;
  const ProfileScreen({
    super.key,
    required this.library,
    required this.themeMode,
    required this.onThemeChanged,
    required this.registry,
    required this.onOpen,
    required this.onCustomize,
    required this.onImportPlugin,
  });
  @override
  Widget build(BuildContext context) => ListView(
    key: const PageStorageKey('me-scroll'),
    padding: EdgeInsets.fromLTRB(
      24,
      24,
      24,
      24 + MediaQuery.paddingOf(context).bottom,
    ),
    children: [
      const SizedBox(height: 16),
      const AqPageHeading('我的', subtitle: '本机阅读空间'),
      const SizedBox(height: 20),
      const AqPanel(
        child: ListTile(
          leading: Icon(Icons.auto_stories_outlined),
          title: Text('本机资料库'),
          subtitle: Text('无需登录，可以离线阅读。'),
        ),
      ),
      const SizedBox(height: 28),
      const Text(
        '全部功能',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      AqPanel(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Column(
          children: [
            for (final feature in registry.all.where(
              (f) => f.source == 'core' && f.id != FeatureRegistry.me,
            ))
              _entry(feature),
          ],
        ),
      ),
      const SizedBox(height: 24),
      const Text(
        '扩展功能',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.folder_zip_outlined),
        title: const Text('ZIP 导入插件'),
        subtitle: const Text('从本机导入独立插件 ZIP'),
        trailing: const Icon(Icons.chevron_right),
        onTap: onImportPlugin,
      ),
      if (!registry.all.any((f) => f.source != 'core'))
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('启用插件后，其独立页面会显示在这里。'),
        ),
      for (final feature in registry.all.where((f) => f.source != 'core'))
        _entry(feature),
      const SizedBox(height: 24),
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.tune_outlined),
        title: const Text('导航栏自定义'),
        subtitle: const Text('分别管理移动端与桌面端的快捷入口'),
        trailing: const Icon(Icons.chevron_right),
        onTap: onCustomize,
      ),
      const SizedBox(height: 24),
      const Text(
        '外观',
        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 16),
      AppearanceSettings(
        mode: themeMode,
        onChanged: onThemeChanged,
        showPalettes: false,
      ),
      ListTile(
        leading: const Icon(Icons.palette_outlined),
        title: const Text('颜色主题'),
        subtitle: const Text('澄光 · 纸境 · 墨序 · 曜夜'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => Navigator.push<void>(
          context,
          MaterialPageRoute(
            builder: (_) =>
                AppearanceScreen(mode: themeMode, onChanged: onThemeChanged),
          ),
        ),
      ),
      const SizedBox(height: 32),
      Text(
        'AQuantum Reader  ${library.raw['display_version'] ?? '开发构建'}',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
    ],
  );
  Widget _entry(AppFeature feature) => ListTile(
    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    leading: Icon(feature.icon),
    title: Text(feature.name),
    subtitle: feature.source == 'core' ? null : Text(feature.source),
    trailing: const Icon(Icons.chevron_right),
    onTap: () => onOpen(feature.id),
  );
}
