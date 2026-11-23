// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import '../data/models.dart';
import '../design/appearance.dart';
import '../design/theme.dart';
import '../features/feature_registry.dart';
import 'profile_details.dart';
import '../design/widgets.dart';

/// Me lists every workspace page (navigation only pins them), grouped by
/// purpose, followed by plugins and personalization.
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

  static const _reading = {
    FeatureRegistry.home,
    FeatureRegistry.projects,
    'core.search',
    FeatureRegistry.statistics,
    'core.archive',
  };

  @override
  Widget build(BuildContext context) {
    final core = registry.all.where(
      (f) => f.source == 'core' && f.id != FeatureRegistry.me,
    );
    final reading = [
      for (final id in _reading) ...core.where((f) => f.id == id),
    ];
    final manage = core.where((f) => !_reading.contains(f.id)).toList();
    final extensions = registry.all.where((f) => f.source != 'core').toList();
    final palette = AqAppearance.maybeOf(context)?.palette ?? AqPalette.lucent;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          key: const PageStorageKey('me-scroll'),
          padding: EdgeInsets.fromLTRB(
            20,
            28,
            20,
            24 + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            const AqPageHeading('我的'),
            const SizedBox(height: 24),
            AqSection(
              header: '阅读',
              children: [for (final f in reading) _entry(f)],
            ),
            AqSection(
              header: '管理',
              children: [for (final f in manage) _entry(f)],
            ),
            AqSection(
              header: '扩展',
              footer: extensions.isEmpty ? '启用插件后，其独立页面会显示在这里。' : null,
              children: [
                for (final f in extensions) _entry(f),
                AqRow(
                  icon: Icons.folder_zip_outlined,
                  title: 'ZIP 导入插件',
                  onTap: onImportPlugin,
                ),
              ],
            ),
            AqSection(
              header: '外观',
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: ThemeModeControl(
                    mode: themeMode,
                    onChanged: onThemeChanged,
                  ),
                ),
                AqRow(
                  icon: Icons.palette_outlined,
                  title: '颜色主题',
                  value: palette.label,
                  onTap: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => AppearanceScreen(
                        mode: themeMode,
                        onChanged: onThemeChanged,
                      ),
                    ),
                  ),
                ),
                AqRow(
                  icon: Icons.space_dashboard_outlined,
                  title: '导航栏自定义',
                  onTap: onCustomize,
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                children: [
                  Text(
                    'AQuantum Reader  ${library.raw['display_version'] ?? '开发构建'}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Text(
                    '本机资料库 · 无需登录 · 可离线阅读',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _entry(AppFeature feature) => AqRow(
    icon: feature.icon,
    title: feature.name,
    subtitle: feature.source == 'core' ? null : feature.source,
    onTap: () => onOpen(feature.id),
  );
}
