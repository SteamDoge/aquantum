// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import '../data/models.dart';
import '../plugins/plugin_manager.dart';
import 'reader_defaults_screen.dart';
import 'toolbar_editor.dart';
import '../design/appearance.dart';
import '../design/theme.dart';
import '../design/widgets.dart';
import '../l10n/l10n.dart';

String themeModeLabel(ThemeMode mode) => switch (mode) {
  ThemeMode.system => tr('跟随系统'),
  ThemeMode.light => tr('浅色'),
  ThemeMode.dark => tr('深色'),
};

/// The light/dark choice as one full-width segmented control.
class ThemeModeControl extends StatelessWidget {
  final ThemeMode mode;
  final ValueChanged<ThemeMode> onChanged;
  const ThemeModeControl({
    super.key,
    required this.mode,
    required this.onChanged,
  });
  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: SegmentedButton<ThemeMode>(
      showSelectedIcon: false,
      segments: [
        for (final value in ThemeMode.values)
          ButtonSegment(value: value, label: Text(themeModeLabel(value))),
      ],
      selected: {mode},
      onSelectionChanged: (value) => onChanged(value.first),
    ),
  );
}

/// Light/dark choice as one segmented control, then the color themes.
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
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 7),
        child: Text(
          tr('明暗'),
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w500),
        ),
      ),
      ThemeModeControl(mode: mode, onChanged: onChanged),
      const SizedBox(height: 28),
      if (showPalettes) const PaletteSettings(),
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
    appBar: AppBar(),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
          children: [
            AqPageHeading(tr('外观')),
            const SizedBox(height: 24),
            AppearanceSettings(
              mode: mode,
              onChanged: (value) {
                widget.onChanged(value);
                setState(() => mode = value);
              },
            ),
          ],
        ),
      ),
    ),
  );
}

/// The interface language on its own page, reached from Me and Settings.
class LanguageScreen extends StatelessWidget {
  const LanguageScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 32),
          children: [
            AqPageHeading(tr('语言')),
            const SizedBox(height: 24),
            const LanguageSettings(),
          ],
        ),
      ),
    ),
  );
}

/// The row that opens [LanguageScreen]; hidden when no app owns the choice.
Widget? languageRow(BuildContext context) {
  final appearance = AqAppearance.maybeOf(context);
  if (appearance?.onLanguageChanged == null) return null;
  return AqRow(
    icon: Icons.language,
    title: tr('语言'),
    value: languageLabel(appearance!.language),
    onTap: () => Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => const LanguageScreen()),
    ),
  );
}

/// Settings, storage and history: large title over inset grouped lists.
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
    final operations = (library.catalog['operations'] as List).reversed
        .take(12)
        .toList();
    final palette = AqAppearance.maybeOf(context)?.palette ?? AqPalette.lucent;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          key: PageStorageKey('profile-${section.name}'),
          padding: EdgeInsets.fromLTRB(
            20,
            28,
            20,
            24 + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            AqPageHeading(switch (section) {
              ProfileDetail.settings => tr('设置'),
              ProfileDetail.storage => tr('存储管理'),
              ProfileDetail.history => tr('操作记录'),
            }),
            const SizedBox(height: 24),
            if (section == ProfileDetail.settings) ...[
              AqSection(
                header: tr('界面'),
                children: [
                  AqRow(
                    icon: Icons.palette_outlined,
                    title: tr('外观'),
                    value: '${palette.label} · ${themeModeLabel(mode)}',
                    onTap: () => Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => AppearanceScreen(
                          mode: mode,
                          onChanged: onThemeChanged,
                        ),
                      ),
                    ),
                  ),
                  ?languageRow(context),
                  AqRow(
                    icon: Icons.tune,
                    title: tr('编辑工具栏'),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<bool>(
                        builder: (_) => ToolbarEditor(plugins: plugins),
                      ),
                    ),
                  ),
                ],
              ),
              AqSection(
                header: tr('阅读'),
                children: [
                  AqRow(
                    icon: Icons.auto_stories_outlined,
                    title: tr('阅读器选择'),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ReaderDefaultsScreen(plugins: plugins),
                      ),
                    ),
                  ),
                  AqRow(
                    icon: Icons.dashboard_customize_outlined,
                    title: tr('统计与自定义卡片'),
                    subtitle: tr('接口说明'),
                    onTap: onStatisticsHelp,
                  ),
                ],
              ),
            ],
            if (section == ProfileDetail.storage) ...[
              AqSection(
                header: tr('占用空间'),
                dividerIndent: 16,
                children: [
                  AqRow(
                    title: tr('已导入原件副本'),
                    value: sizeLabel(storage['original_bytes'] as num),
                  ),
                  AqRow(
                    title: tr('资料库与阅读记录'),
                    value: sizeLabel(storage['database_bytes'] as num),
                  ),
                  AqRow(
                    title: tr('待处理导入与残留'),
                    value: sizeLabel(
                      (storage['retained_unreferenced_bytes'] as num) +
                          (storage['incomplete_bytes'] as num) +
                          (library.raw['staging_bytes'] as num),
                    ),
                  ),
                ],
              ),
              AqSection(
                children: [
                  AqRow(
                    icon: Icons.storage_outlined,
                    title: tr('手动清理、任务与备份恢复'),
                    onTap: onStorageMaintenance,
                  ),
                ],
              ),
            ],
            if (section == ProfileDetail.history)
              operations.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 48),
                      child: Text(
                        tr('还没有操作记录'),
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AqColors.of(context).muted,
                        ),
                      ),
                    )
                  : AqSection(
                      header: tr('最近 {count} 项', {'count': operations.length}),
                      dividerIndent: 16,
                      children: [
                        for (final op in operations)
                          AqRow(
                            title: switch (op['action']) {
                              'import_book' => tr('导入内容'),
                              'create_project' => tr('创建项目'),
                              'add_note' => tr('保存笔记'),
                              'set_book_gap' => tr('修改阅读间隔'),
                              _ => tr('更新资料'),
                            },
                            value: DateTime.fromMillisecondsSinceEpoch(
                              (op['unix_seconds'] as int) * 1000,
                            ).toLocal().toString().substring(0, 16),
                          ),
                      ],
                    ),
          ],
        ),
      ),
    );
  }
}
