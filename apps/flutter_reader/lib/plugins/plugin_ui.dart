// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'plugin_instance.dart';

bool pluginUiHasEvents(dynamic node) =>
    node is Map &&
    ({'button', 'switch', 'slider', 'textField'}.contains(node['type']) ||
        (node['children'] as List? ?? []).any(pluginUiHasEvents));

/// Schema 1: bounded native trees, stable keys, semantic theme tokens.
void validatePluginUi(dynamic ui) {
  var count = 0;
  void visit(dynamic node, int depth) {
    if (++count > 256 ||
        depth > 12 ||
        node is! Map ||
        node['schemaVersion'] != null && node['schemaVersion'] != 1 ||
        !{
          'page',
          'column',
          'row',
          'text',
          'button',
          'card',
          'list',
          'grid',
          'textField',
          'switch',
          'slider',
          'progress',
          'icon',
          'tabs',
          'menu',
          'fileList',
          'error',
          'loading',
        }.contains(node['type']) ||
        node.keys.any(
          (k) => !{
            'schemaVersion',
            'type',
            'id',
            'text',
            'event',
            'value',
            'min',
            'max',
            'children',
            'token',
            'label',
            'columns',
          }.contains(k),
        ) ||
        ['text', 'label', 'id', 'event'].any(
          (k) =>
              node[k] != null &&
              (node[k] is! String || (node[k] as String).length > 8000),
        )) {
      throw const FormatException('Plugin UI Schema 1 无效或超出渲染限制');
    }
    if (node['children'] != null) {
      if (node['children'] is! List) {
        throw const FormatException('children必须是列表');
      }
      for (final child in node['children']) {
        visit(child, depth + 1);
      }
    }
    if (node['type'] == 'slider' &&
        (node['value'] is! num ||
            node['min'] is! num ||
            node['max'] is! num ||
            node['min'] >= node['max'] ||
            node['value'] < node['min'] ||
            node['value'] > node['max'])) {
      throw const FormatException('滑块数值无效');
    }
    if (node['type'] == 'switch' && node['value'] is! bool) {
      throw const FormatException('开关值必须为布尔值');
    }
    if ({'button', 'switch', 'slider', 'textField'}.contains(node['type']) &&
        (node['event'] is! String || (node['event'] as String).isEmpty)) {
      throw const FormatException('交互组件必须有事件标识');
    }
  }

  if (jsonEncode(ui).length > 128 * 1024) throw const FormatException('UI描述过大');
  visit(ui, 0);
}

class PluginNativePage extends StatefulWidget {
  final JavaScriptPlugin plugin;
  final String slotId;
  const PluginNativePage({
    super.key,
    required this.plugin,
    required this.slotId,
  });
  @override
  State<PluginNativePage> createState() => _PluginNativePageState();
}

class _PluginNativePageState extends State<PluginNativePage> {
  bool busy = false;
  String? error;
  Future<void> event(Map node, dynamic value) async {
    final slot = widget.plugin.slots[widget.slotId];
    if (busy || node['event'] == null || slot?['handler'] == null) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.plugin.invoke(slot!['handler'], {
        'event': node['event'],
        'nodeId': node['id'],
        'value': value,
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget node(Map n) {
    final children = [
      for (final child in n['children'] as List? ?? []) node(child as Map),
    ];
    final text = n['text'] as String? ?? n['label'] as String? ?? '';
    final theme = Theme.of(context);
    final Widget content = switch (n['type']) {
      'page' || 'column' || 'list' || 'fileList' => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
      'row' => Wrap(spacing: 8, runSpacing: 8, children: children),
      'grid' => LayoutBuilder(
        builder: (context, constraints) => Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            for (final child in children)
              SizedBox(
                width:
                    (constraints.maxWidth /
                                ((n['columns'] is int ? n['columns'] as int : 2)
                                    .clamp(1, 4)) -
                            12)
                        .clamp(0, double.infinity),
                child: child,
              ),
          ],
        ),
      ),
      'text' => SelectableText(
        text,
        style: n['token'] == 'title'
            ? theme.textTheme.headlineSmall
            : theme.textTheme.bodyLarge,
      ),
      'error' => Text(text, style: TextStyle(color: theme.colorScheme.error)),
      'button' => FilledButton(
        onPressed: busy || n['event'] == null ? null : () => event(n, null),
        child: Text(text),
      ),
      'card' => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ),
      'textField' => TextFormField(
        initialValue: n['value']?.toString(),
        decoration: InputDecoration(labelText: text),
        onFieldSubmitted: (v) => event(n, v),
      ),
      'switch' => SwitchListTile(
        title: Text(text),
        value: n['value'] == true,
        onChanged: busy ? null : (v) => event(n, v),
      ),
      'slider' => Column(
        children: [
          Text(text),
          Slider(
            value: (n['value'] as num).toDouble(),
            min: (n['min'] as num).toDouble(),
            max: (n['max'] as num).toDouble(),
            onChanged: busy ? null : (v) => event(n, v),
          ),
        ],
      ),
      'progress' || 'loading' => const LinearProgressIndicator(),
      'icon' => Icon(
        pluginIcons[text] ?? Icons.extension_outlined,
        semanticLabel: n['label'] as String?,
      ),
      'tabs' =>
        children.isEmpty
            ? const SizedBox.shrink()
            : DefaultTabController(
                length: children.length,
                child: Column(
                  children: [
                    TabBar(
                      isScrollable: true,
                      tabs: [
                        for (var i = 0; i < children.length; i++)
                          Tab(
                            text: (n['children'][i]['label'] ?? '${i + 1}')
                                .toString(),
                          ),
                      ],
                    ),
                    SizedBox(
                      height: 400,
                      child: TabBarView(children: children),
                    ),
                  ],
                ),
              ),
      'menu' => Wrap(spacing: 8, children: children),
      _ => throw const FormatException('不支持的组件'),
    };
    return Padding(
      key: n['id'] is String ? ValueKey(n['id']) : null,
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: content,
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.plugin,
    builder: (context, _) {
      final slot = widget.plugin.slots[widget.slotId];
      if (slot == null || !widget.plugin.active) {
        return const Center(child: Text('插件已停用'));
      }
      return ListView(
        padding: EdgeInsets.fromLTRB(
          24,
          24,
          24,
          24 + MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          if (busy) const LinearProgressIndicator(),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          node(slot['ui'] as Map),
        ],
      );
    },
  );
}
