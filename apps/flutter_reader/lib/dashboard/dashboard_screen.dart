// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import '../design/motion.dart';
import 'dashboard_data.dart';
import 'dashboard_layout.dart';
import 'widget_registry.dart';
import '../design/widgets.dart';

class DashboardScreen extends StatelessWidget {
  final DashboardPage page;
  final DashboardRegistry registry;
  final DashboardLayout layout;
  final DashboardDataSource data;
  final VoidCallback? onSearch, onImport;
  const DashboardScreen({
    super.key,
    required this.page,
    required this.registry,
    required this.layout,
    required this.data,
    this.onSearch,
    this.onImport,
  });
  Future<void> edit(BuildContext context) => Navigator.of(context).push<void>(
    ReaderMotion.route(
      context,
      (_) => DashboardEditor(registry: registry, layout: layout),
      '/dashboard/${page.name}/edit',
    ),
  );
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([data, registry, layout]),
    builder: (context, _) {
      if (!TickerMode.valuesOf(context).enabled) return const SizedBox.shrink();
      if (data.value == null || !layout.ready) {
        return const Center(child: CircularProgressIndicator());
      }
      final value = data.value!;
      return LayoutBuilder(
        builder: (context, constraints) {
          final two =
              constraints.maxWidth >= 760 &&
              MediaQuery.textScalerOf(context).scale(14) < 25;
          final rows = <List<DashboardInstance>>[];
          for (final item in layout.items) {
            final min = registry[item.id]?.minWidth ?? 240;
            if (two &&
                constraints.maxWidth / 2 - 40 >= min &&
                !item.wide &&
                rows.isNotEmpty &&
                rows.last.length == 1 &&
                !rows.last.first.wide &&
                (registry[rows.last.first.id]?.minWidth ?? 240) <=
                    constraints.maxWidth / 2 - 40) {
              rows.last.add(item);
            } else {
              rows.add([item]);
            }
          }
          return ListView.builder(
            key: PageStorageKey('dashboard-${page.name}'),
            padding: EdgeInsets.fromLTRB(
              two ? 32 : 20,
              16,
              two ? 32 : 20,
              32 + MediaQuery.paddingOf(context).bottom,
            ),
            itemCount: rows.length + 1,
            itemBuilder: (context, index) {
              if (index == 0) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AqPageHeading(
                        page == DashboardPage.home ? '主页' : '阅读统计',
                        subtitle: page == DashboardPage.home
                            ? '你的私人阅读空间'
                            : '把阅读，慢慢累积',
                        actions: [
                          if (page == DashboardPage.home && onImport != null)
                            IconButton(
                              tooltip: '导入文件',
                              onPressed: onImport,
                              icon: const Icon(Icons.add),
                            ),
                          IconButton(
                            key: ValueKey('edit-${page.name}'),
                            tooltip: '管理组件',
                            onPressed: () => edit(context),
                            icon: const Icon(
                              Icons.dashboard_customize_outlined,
                            ),
                          ),
                        ],
                      ),
                      if (page == DashboardPage.home && onSearch != null) ...[
                        const SizedBox(height: 22),
                        InkWell(
                          onTap: onSearch,
                          borderRadius: BorderRadius.circular(14),
                          child: InputDecorator(
                            decoration: const InputDecoration(
                              prefixIcon: Icon(Icons.search),
                            ),
                            child: Text(
                              '搜索书名、项目或内容',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                      ],
                      if (layout.error != null)
                        Text(
                          layout.error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      if (layout.items.isEmpty)
                        TextButton(
                          onPressed: () => edit(context),
                          child: const Text('添加你的第一个组件'),
                        ),
                    ],
                  ),
                );
              }
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final (i, item) in rows[index - 1].indexed) ...[
                      if (i > 0) const SizedBox(width: 16),
                      Expanded(
                        child: GestureDetector(
                          onLongPress: () => edit(context),
                          onSecondaryTap: () => edit(context),
                          child: _DashboardTile(
                            key: ValueKey(item.id),
                            registry: registry,
                            data: value,
                            config: item.copy(
                              skipLatest: layout.items.any(
                                (e) => e.id == 'core.widget.continue',
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            },
          );
        },
      );
    },
  );
}

class _DashboardTile extends StatefulWidget {
  final DashboardRegistry registry;
  final DashboardData data;
  final DashboardInstance config;
  const _DashboardTile({
    super.key,
    required this.registry,
    required this.data,
    required this.config,
  });
  @override
  State<_DashboardTile> createState() => _DashboardTileState();
}

class _DashboardTileState extends State<_DashboardTile> {
  Future<Map<String, Object?>>? metrics;
  DashboardDefinition? definition;
  void update() {
    definition = widget.registry[widget.config.id];
    metrics = definition == null
        ? null
        : widget.registry.metrics(definition!, widget.data);
  }

  @override
  void initState() {
    super.initState();
    update();
  }

  @override
  void didUpdateWidget(covariant _DashboardTile old) {
    super.didUpdateWidget(old);
    if (!identical(old.data, widget.data) ||
        !identical(definition, widget.registry[widget.config.id])) {
      update();
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = definition;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: d == null
            ? const ListTile(
                leading: Icon(Icons.extension_off_outlined),
                title: Text('组件暂不可用'),
                subtitle: Text('已保留布局，重新启用插件后恢复'),
              )
            : FutureBuilder<Map<String, Object?>>(
                future: metrics,
                builder: (context, result) {
                  if (result.hasError) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${d.name}暂时无法读取'),
                        TextButton(
                          onPressed: () {
                            widget.registry.retry(d);
                            setState(update);
                          },
                          child: const Text('重试'),
                        ),
                      ],
                    );
                  }
                  if (!result.hasData) {
                    return const SizedBox(
                      height: 72,
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  try {
                    return d.render(
                      context,
                      widget.data,
                      widget.config,
                      result.data!,
                    );
                  } catch (_) {
                    return Text('${d.name}显示失败，其他组件仍可使用');
                  }
                },
              ),
      ),
    );
  }
}

class DashboardEditor extends StatelessWidget {
  final DashboardRegistry registry;
  final DashboardLayout layout;
  const DashboardEditor({
    super.key,
    required this.registry,
    required this.layout,
  });
  Future<void> perform(
    BuildContext context,
    Future<void> Function() operation,
  ) async {
    try {
      await operation();
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> restore(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('恢复默认组件布局？'),
        content: const Text('只重置本页面的布局。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('恢复'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      await perform(
        context,
        () => layout.save(DashboardLayout.defaults(layout.page), restore: true),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([layout, registry]),
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: Text(layout.page == DashboardPage.home ? '主页组件' : '统计组件'),
        actions: [
          TextButton(
            onPressed: layout.busy ? null : () => restore(context),
            child: const Text('恢复默认'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (layout.error != null) Text(layout.error!),
          const Text('当前布局', style: TextStyle(fontSize: 20)),
          for (final (index, item) in layout.items.indexed)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            registry[item.id]?.name ?? '已停用组件 ${item.id}',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        IconButton(
                          tooltip: '上移',
                          onPressed: index == 0 || layout.busy
                              ? null
                              : () => perform(context, () {
                                  final next = [...layout.items];
                                  next[index - 1] = item;
                                  next[index] = layout.items[index - 1];
                                  return layout.save(next);
                                }),
                          icon: const Icon(Icons.arrow_upward),
                        ),
                        IconButton(
                          tooltip: '下移',
                          onPressed:
                              index == layout.items.length - 1 || layout.busy
                              ? null
                              : () => perform(context, () {
                                  final next = [...layout.items];
                                  next[index + 1] = item;
                                  next[index] = layout.items[index + 1];
                                  return layout.save(next);
                                }),
                          icon: const Icon(Icons.arrow_downward),
                        ),
                        IconButton(
                          tooltip: '移除组件',
                          onPressed: layout.busy
                              ? null
                              : () => perform(
                                  context,
                                  () => layout.save(
                                    layout.items
                                        .where((e) => e != item)
                                        .toList(),
                                  ),
                                ),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                    if (registry[item.id] != null)
                      Wrap(
                        spacing: 12,
                        runSpacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          DropdownButton<String>(
                            value:
                                registry[item.id]!.styles.contains(item.style)
                                ? item.style
                                : registry[item.id]!.styles.first,
                            items: registry[item.id]!.styles
                                .map(
                                  (s) => DropdownMenuItem(
                                    value: s,
                                    child: Text(
                                      s == 'compact' ? '紧凑样式' : '详细样式',
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: layout.busy
                                ? null
                                : (s) => perform(
                                    context,
                                    () => layout.save([
                                      for (final e in layout.items)
                                        e == item ? e.copy(style: s) : e,
                                    ]),
                                  ),
                          ),
                          FilterChip(
                            label: const Text('宽屏整行'),
                            selected: item.wide,
                            onSelected: layout.busy
                                ? null
                                : (v) => perform(
                                    context,
                                    () => layout.save([
                                      for (final e in layout.items)
                                        e == item ? e.copy(wide: v) : e,
                                    ]),
                                  ),
                          ),
                          if (registry[item.id]!.supportsLimit)
                            DropdownButton<int>(
                              value: item.limit,
                              items: {1, 3, 5, 10, 20, item.limit}
                                  .map(
                                    (n) => DropdownMenuItem(
                                      value: n,
                                      child: Text('显示 $n 条'),
                                    ),
                                  )
                                  .toList(),
                              onChanged: layout.busy
                                  ? null
                                  : (n) => perform(
                                      context,
                                      () => layout.save([
                                        for (final e in layout.items)
                                          e == item ? e.copy(limit: n) : e,
                                      ]),
                                    ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 20),
          const Text('可用组件', style: TextStyle(fontSize: 20)),
          for (final d in registry.all.where(
            (d) => d.pages.contains(layout.page),
          ))
            ListTile(
              leading: Icon(d.icon),
              title: Text(d.name),
              subtitle: Text(d.source == 'core' ? '内置组件' : d.source),
              trailing: IconButton(
                tooltip: '添加组件',
                onPressed: layout.busy || layout.items.any((i) => i.id == d.id)
                    ? null
                    : () => perform(
                        context,
                        () => layout.save([
                          ...layout.items,
                          DashboardInstance(
                            d.id,
                            style: d.styles.contains('compact')
                                ? 'compact'
                                : d.styles.first,
                          ),
                        ]),
                      ),
                icon: Icon(
                  layout.items.any((i) => i.id == d.id)
                      ? Icons.check
                      : Icons.add,
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
