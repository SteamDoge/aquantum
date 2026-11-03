// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import '../data/models.dart';
import '../data/reader_api.dart';

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
          title: const Text('确认手动清理？'),
          content: Text(
            '永久删除所选 ${selected.length} 个文件，共 ${sizeLabel(bytes)}。此操作不可撤销。\n\n当前正文、历史快照、笔记、进度、配置和外部原件不在本次清理范围内。执行前会重新检查引用和文件校验值。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('清理所选文件'),
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
        appBar: AppBar(title: const Text('手动清理预览')),
        body: Column(
          children: [
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
                        '保护 ${state?['plan']['protected_resources'] ?? 0} 项正文、历史和任务资源。只列出可清理的未引用副本与失败临时文件。',
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '已选 ${selected.length} 项 · 已完成 ${completed.length} 项 · 剩余 $remaining 项',
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
                                'all' => '全部',
                                'unreferenced' => '未引用副本',
                                _ => '失败临时文件',
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
                            child: const Text('选择当前类别'),
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
                  ? const Center(child: Text('没有符合引用保护规则的可清理文件。'))
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
                                ? '失败临时文件'
                                : '未引用资源副本',
                          ),
                          subtitle: Text(
                            '$key\n${sizeLabel(item['bytes'] as num)}${completed.contains(key) ? ' · 已完成' : ''}',
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
                        child: Text(pause ? '正在暂停' : '本项结束后暂停'),
                      ),
                    if (!busy)
                      FilledButton(
                        onPressed:
                            selected.isEmpty || confirmed && remaining == 0
                            ? null
                            : execute,
                        child: Text(confirmed ? '继续已确认范围' : '确认清理所选'),
                      ),
                    if (!busy)
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('保留任务，返回'),
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
