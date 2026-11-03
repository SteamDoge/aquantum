// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import '../plugins/plugin_api.dart';
import '../plugins/plugin_manager.dart';
import '../reader/reader_toolbar.dart';
import '../reader/toolbar_preferences.dart';

class ToolbarItem {
  final String id, name, source;
  final Widget icon;
  const ToolbarItem(this.id, this.name, this.source, this.icon);
}

List<ToolbarItem> toolbarItems(PluginManager? plugins) => [
  for (final action in readerToolbarOrder)
    ToolbarItem(
      toolbarCoreId(action),
      ReaderToolbar.label(action),
      'AQuantum Reader',
      ReaderToolbar.glyph(action),
    ),
  for (final record in plugins?.records ?? <PluginRecord>[])
    if (record.status == PluginStatus.enabled)
      for (final action in record.actions)
        if (action.point == ExtensionPoint.readerToolbar &&
            record.grants.containsAll(action.permissions))
          ToolbarItem(
            action.id,
            action.name,
            record.manifest.name,
            Icon(action.icon),
          ),
];

class ToolbarEditor extends StatefulWidget {
  final PluginManager? plugins;
  const ToolbarEditor({super.key, this.plugins});
  @override
  State<ToolbarEditor> createState() => _ToolbarEditorState();
}

class _ToolbarEditorState extends State<ToolbarEditor> {
  final store = ToolbarPreferences();
  ToolbarLayout? layout;
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final result = await store.load();
      if (mounted) setState(() => layout = result);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  void place(String id, String destination) {
    final current = layout!;
    setState(
      () => layout = ToolbarLayout(
        [
          ...current.pinned.where((value) => value != id),
          if (destination == 'pin') id,
        ],
        {
          ...current.hidden.where((value) => value != id),
          if (destination == 'hide') id,
        },
      ),
    );
  }

  Future<void> save() async {
    setState(() => busy = true);
    try {
      await store.save(layout!);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          busy = false;
        });
      }
    }
  }

  Widget content() {
    final current = layout;
    if (current == null) {
      return Center(
        child: error == null ? const CircularProgressIndicator() : Text(error!),
      );
    }
    final items = toolbarItems(widget.plugins);
    final pinned = [
      for (final id in current.pinned) ...items.where((item) => item.id == id),
    ];
    return Column(
      children: [
        if (error != null)
          Text(
            error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                '当前工具栏',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              const Text('拖动调整顺序；返回与更多保留。所有格式共用配置，上下滚动不显示底部工具栏。'),
              ReorderableListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: pinned.length,
                onReorderItem: busy
                    ? (_, _) {}
                    : (oldIndex, newIndex) {
                        final ids = [...current.pinned];
                        final moved = pinned[oldIndex].id;
                        final visible = pinned.map((item) => item.id).toList()
                          ..remove(moved);
                        visible.insert(newIndex, moved);
                        // Keep unavailable module preferences without drawing empty rows.
                        setState(
                          () => layout = ToolbarLayout([
                            ...visible,
                            ...ids.where(
                              (id) => !pinned.any((p) => p.id == id),
                            ),
                          ], current.hidden),
                        );
                      },
                itemBuilder: (context, i) {
                  final item = pinned[i];
                  return ListTile(
                    key: ValueKey(item.id),
                    leading: item.icon,
                    title: Text(item.name),
                    subtitle: Text(item.source),
                    trailing: ToolbarLayout.requiredIds.contains(item.id)
                        ? const Icon(Icons.lock_outline)
                        : Padding(
                            padding: const EdgeInsets.only(right: 32),
                            child: IconButton(
                              tooltip: '移入更多${item.name}',
                              onPressed: busy
                                  ? null
                                  : () => place(item.id, 'more'),
                              icon: const Icon(Icons.remove_circle_outline),
                            ),
                          ),
                  );
                },
              ),
              const SizedBox(height: 24),
              const Text(
                '更多功能',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
              for (final item in items.where(
                (item) => !current.pinned.contains(item.id),
              ))
                ListTile(
                  leading: item.icon,
                  title: Text(item.name),
                  subtitle: Text(
                    '${item.source}${current.hidden.contains(item.id) ? ' · 已隐藏' : ''}',
                  ),
                  trailing: PopupMenuButton<String>(
                    tooltip: '配置${item.name}',
                    enabled: !busy,
                    onSelected: (value) => place(item.id, value),
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'pin', child: Text('固定到工具栏')),
                      const PopupMenuItem(value: 'more', child: Text('保留在更多')),
                      const PopupMenuItem(value: 'hide', child: Text('隐藏')),
                    ],
                  ),
                ),
            ],
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 16,
              children: [
                OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => setState(() => layout = ToolbarLayout.defaults()),
                  child: const Text('恢复默认'),
                ),
                FilledButton(
                  onPressed: busy ? null : save,
                  child: Text(busy ? '保存中…' : '保存并应用'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('编辑工具栏')),
    body: widget.plugins == null
        ? content()
        : ListenableBuilder(
            listenable: widget.plugins!,
            builder: (_, _) => content(),
          ),
  );
}
