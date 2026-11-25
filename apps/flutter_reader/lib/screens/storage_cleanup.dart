// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import '../data/models.dart';
import '../data/reader_api.dart';
import '../design/widgets.dart';
import '../l10n/l10n.dart';

class StorageCleanupScreen extends StatefulWidget {
  final ReaderApi api;
  final String task;
  const StorageCleanupScreen({
    super.key,
    required this.api,
    required this.task,
  });
  @override
  State<StorageCleanupScreen> createState() => _StorageCleanupScreenState();
}

class _StorageCleanupScreenState extends State<StorageCleanupScreen> {
  Map<String, dynamic>? state;
  final Set<String> selected = {}, completed = {};
  bool loading = true, busy = false, pause = false, wantsExit = false;
  String filter = 'all';
  String? error;
  List<dynamic> get items => state?['plan']['items'] ?? [];
  bool get confirmed => state?['confirmed'] != null;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final result = Map<String, dynamic>.from(
        await widget.api.call('cleanup_state', {'task': widget.task}),
      );
      if (!mounted) return;
      setState(() {
        state = result;
        completed.addAll((result['completed'] as List).cast<String>());
        if (result['confirmed'] != null) {
          selected.addAll((result['confirmed']['keys'] as List).cast<String>());
        }
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> execute() async {
    if (busy || selected.isEmpty) return;
    if (!confirmed) {
      final bytes = items
          .where((i) => selected.contains(i['key']))
          .fold<int>(0, (n, i) => n + (i['bytes'] as int));
      final accepted = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(tr('确认手动清理？')),
          content: Text(
            tr('永久删除所选 {count} 个文件，共 {value}。此操作不可撤销。', {
              'count': selected.length,
              'value': sizeLabel(bytes),
            }),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(tr('取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(tr('清理所选文件')),
            ),
          ],
        ),
      );
      if (accepted != true || !mounted) return;
    }
    setState(() {
      busy = true;
      pause = false;
      error = null;
    });
    try {
      if (!confirmed) {
        await widget.api.call('cleanup_confirm', {
          'task': widget.task,
          'keys': selected.toList(),
        });
        await load();
      }
      for (final key in selected.toList()) {
        if (pause || !mounted) break;
        if (completed.contains(key)) continue;
        await widget.api.call('cleanup_step', {
          'task': widget.task,
          'key': key,
        });
        if (mounted) setState(() => completed.add(key));
        await Future<void>.delayed(Duration.zero);
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) {
        setState(() => busy = false);
        if (wantsExit) Navigator.pop(context);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final visible = items
        .where((i) => filter == 'all' || i['category'] == filter)
        .toList();
    final remaining = selected.difference(completed).length;
    return PopScope(
      canPop: !busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          setState(() {
            pause = true;
            wantsExit = true;
          });
        }
      },
      child: Scaffold(
        appBar: AppBar(),
        body: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 4),
              child: AqPageHeading(tr('手动清理预览')),
            ),
            if (loading || busy)
              LinearProgressIndicator(
                value: busy && selected.isNotEmpty
                    ? completed.intersection(selected).length / selected.length
                    : null,
              ),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .38,
              ),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr('已选 {count} 项 · 已完成 {count2} 项 · 剩余 {remaining} 项', {
                          'count': selected.length,
                          'count2': completed.length,
                          'remaining': remaining,
                        }),
                      ),
                      if (error != null)
                        SelectableText(
                          error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      Wrap(
                        spacing: 8,
                        children: [
                          for (final value in [
                            'all',
                            'unreferenced',
                            'incomplete',
                          ])
                            ChoiceChip(
                              label: Text(switch (value) {
                                'all' => tr('全部'),
                                'unreferenced' => tr('未引用副本'),
                                _ => tr('失败临时文件'),
                              }),
                              selected: filter == value,
                              onSelected: busy
                                  ? null
                                  : (_) => setState(() => filter = value),
                            ),
                          TextButton(
                            onPressed: busy || confirmed
                                ? null
                                : () => setState(
                                    () => selected.addAll(
                                      visible.map((i) => i['key'] as String),
                                    ),
                                  ),
                            child: Text(tr('选择当前类别')),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child: items.isEmpty && !loading
                  ? Center(child: Text(tr('没有可清理的文件。')))
                  : ListView.builder(
                      itemCount: visible.length,
                      itemBuilder: (context, i) {
                        final item = visible[i];
                        final key = item['key'] as String;
                        return CheckboxListTile(
                          value: selected.contains(key),
                          onChanged: busy || confirmed
                              ? null
                              : (value) => setState(() {
                                  if (value == true) {
                                    selected.add(key);
                                  } else {
                                    selected.remove(key);
                                  }
                                }),
                          title: Text(
                            item['category'] == 'incomplete'
                                ? tr('失败临时文件')
                                : tr('未引用资源副本'),
                          ),
                          subtitle: Text(
                            completed.contains(key)
                                ? tr('{key}\n{size} · 已完成', {
                                    'key': key,
                                    'size': sizeLabel(item['bytes'] as num),
                                  })
                                : '$key\n${sizeLabel(item['bytes'] as num)}',
                          ),
                          secondary: Icon(
                            completed.contains(key)
                                ? Icons.check_circle_outline
                                : Icons.insert_drive_file_outlined,
                          ),
                        );
                      },
                    ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    if (busy)
                      OutlinedButton(
                        onPressed: () => setState(() => pause = true),
                        child: Text(pause ? tr('正在暂停') : tr('本项结束后暂停')),
                      ),
                    if (!busy)
                      FilledButton(
                        onPressed:
                            selected.isEmpty || confirmed && remaining == 0
                            ? null
                            : execute,
                        child: Text(confirmed ? tr('继续已确认范围') : tr('确认清理所选')),
                      ),
                    if (!busy)
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(tr('保留任务，返回')),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
