// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import '../features/feature_registry.dart';
import '../navigation/navigation_controller.dart';
import '../navigation/navigation_preferences.dart';

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
        title: const Text('恢复此平台的默认导航？'),
        content: const Text('只重置快捷入口、顺序与展开偏好，功能和阅读资料保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('恢复默认'),
          ),
        ],
      ),
    );
    if (confirmed == true) await update(() => widget.navigation.reset(profile));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('导航栏自定义')),
    body: AnimatedBuilder(
      animation: widget.navigation,
      builder: (context, _) {
        final navigation = widget.navigation;
        final visible = navigation.items(profile);
        final hidden = navigation.registry.all.where(
          (f) => f.allowNavigation && !visible.any((v) => v.id == f.id),
        );
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Wrap(
              spacing: 8,
              children: [
                for (final option in NavigationProfile.values)
                  ChoiceChip(
                    label: Text(
                      option == NavigationProfile.mobile ? '移动端' : '桌面端',
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
            const SizedBox(height: 16),
            const Text('导航是快捷入口。隐藏后仍可从“我的”打开；我的始终保留在末尾。'),
            if (profile == NavigationProfile.mobile)
              const Text('最多显示 5 项；可只保留我的。'),
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
            const Text(
              '已显示',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            for (var index = 0; index < visible.length; index++)
              ListTile(
                key: ValueKey('edit-${visible[index].id}'),
                contentPadding: EdgeInsets.zero,
                leading: Icon(visible[index].icon),
                title: Text(visible[index].name),
                subtitle: visible[index].id == FeatureRegistry.me
                    ? const Text('固定入口')
                    : null,
                trailing: visible[index].id == FeatureRegistry.me
                    ? const Icon(Icons.lock_outline)
                    : Wrap(
                        children: [
                          IconButton(
                            tooltip: '上移${visible[index].name}',
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
                            tooltip: '下移${visible[index].name}',
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
                            tooltip: '隐藏${visible[index].name}',
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
                subtitle: const Text('已停用或不可用；保留快捷位置，重新启用后恢复'),
                trailing: IconButton(
                  tooltip: '忘记快捷偏好',
                  icon: const Icon(Icons.remove_circle_outline),
                  onPressed: saving
                      ? null
                      : () => update(() => navigation.pin(profile, id, false)),
                ),
              ),
            const Text(
              '可添加',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
            ),
            for (final feature in hidden)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(feature.icon),
                title: Text(feature.name),
                subtitle: Text(
                  feature.source == 'core' ? '内置功能' : feature.source,
                ),
                trailing: IconButton(
                  tooltip: '添加${feature.name}',
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
                child: const Text('恢复默认导航'),
              ),
            ),
          ],
        );
      },
    ),
  );
}
