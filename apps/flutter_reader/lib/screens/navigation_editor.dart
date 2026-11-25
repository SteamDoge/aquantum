// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import '../features/feature_registry.dart';
import '../navigation/navigation_controller.dart';
import '../navigation/navigation_preferences.dart';
import '../design/widgets.dart';
import '../l10n/l10n.dart';

class NavigationEditor extends StatefulWidget {
  final AppNavigation navigation;
  final NavigationProfile initialProfile;
  const NavigationEditor({
    super.key,
    required this.navigation,
    required this.initialProfile,
  });
  @override
  State<NavigationEditor> createState() => _NavigationEditorState();
}

class _NavigationEditorState extends State<NavigationEditor> {
  late NavigationProfile profile = widget.initialProfile;
  bool saving = false;
  String? error;
  Future<void> update(Future<void> Function() action) async {
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await action();
    } catch (failure) {
      if (mounted) setState(() => error = failure.toString());
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  Future<void> reset() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('恢复此平台的默认导航？')),
        content: Text(tr('只重置快捷入口、顺序与展开偏好，功能和阅读资料保留。')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(tr('恢复默认')),
          ),
        ],
      ),
    );
    if (confirmed == true) await update(() => widget.navigation.reset(profile));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(),
    body: AnimatedBuilder(
      animation: widget.navigation,
      builder: (context, _) {
        final navigation = widget.navigation;
        final visible = navigation.items(profile);
        final hidden = navigation.registry.all.where(
          (f) => f.allowNavigation && !visible.any((v) => v.id == f.id),
        );
        return ListView(
          padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
          children: [
            AqPageHeading(tr('导航栏自定义')),
            const SizedBox(height: 20),
            Wrap(
              spacing: 8,
              children: [
                for (final option in NavigationProfile.values)
                  ChoiceChip(
                    label: Text(
                      option == NavigationProfile.mobile
                          ? tr('移动端')
                          : tr('桌面端'),
                    ),
                    selected: profile == option,
                    onSelected: saving
                        ? null
                        : (_) => setState(() {
                            profile = option;
                            error = null;
                          }),
                  ),
              ],
            ),
            if (saving) const LinearProgressIndicator(),
            if (error != null || navigation.loadErrors[profile] != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  error ?? navigation.loadErrors[profile]!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 24),
            Text(
              tr('已显示'),
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            for (var index = 0; index < visible.length; index++)
              ListTile(
                key: ValueKey('edit-${visible[index].id}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(visible[index].icon),
                title: Text(visible[index].name),
                trailing: visible[index].id == FeatureRegistry.me
                    ? const Icon(Icons.lock_outline)
                    : Wrap(
                        children: [
                          IconButton(
                            tooltip: tr('上移{value}', {
                              'value': visible[index].name,
                            }),
                            onPressed: saving || index == 0
                                ? null
                                : () {
                                    final ids = visible
                                        .map((f) => f.id)
                                        .toList();
                                    final id = ids.removeAt(index);
                                    ids.insert(index - 1, id);
                                    update(
                                      () => navigation.reorder(profile, ids),
                                    );
                                  },
                            icon: const Icon(Icons.arrow_upward),
                          ),
                          IconButton(
                            tooltip: tr('下移{value}', {
                              'value': visible[index].name,
                            }),
                            onPressed: saving || index >= visible.length - 2
                                ? null
                                : () {
                                    final ids = visible
                                        .map((f) => f.id)
                                        .toList();
                                    final id = ids.removeAt(index);
                                    ids.insert(index + 1, id);
                                    update(
                                      () => navigation.reorder(profile, ids),
                                    );
                                  },
                            icon: const Icon(Icons.arrow_downward),
                          ),
                          IconButton(
                            tooltip: tr('隐藏{value}', {
                              'value': visible[index].name,
                            }),
                            onPressed: saving
                                ? null
                                : () => update(
                                    () => navigation.pin(
                                      profile,
                                      visible[index].id,
                                      false,
                                    ),
                                  ),
                            icon: const Icon(Icons.remove_circle_outline),
                          ),
                        ],
                      ),
              ),
            const SizedBox(height: 24),
            for (final id
                in navigation
                    .preferences(profile)
                    .pins
                    .where((id) => navigation.registry[id] == null))
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.extension_off_outlined),
                title: Text(id),
                subtitle: Text(tr('已停用')),
                trailing: IconButton(
                  tooltip: tr('忘记快捷偏好'),
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: saving
                      ? null
                      : () => update(() => navigation.pin(profile, id, false)),
                ),
              ),
            Text(
              tr('可添加'),
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            for (final feature in hidden)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(feature.icon),
                title: Text(feature.name),
                subtitle: feature.source == 'core'
                    ? null
                    : Text(feature.source),
                trailing: IconButton(
                  tooltip: tr('添加{name}', {'name': feature.name}),
                  onPressed: saving
                      ? null
                      : () => update(
                          () => navigation.pin(profile, feature.id, true),
                        ),
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ),
            const SizedBox(height: 24),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton(
                onPressed: saving ? null : reset,
                child: Text(tr('恢复默认导航')),
              ),
            ),
          ],
        );
      },
    ),
  );
}
