// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'package:flutter/material.dart';
import '../data/reader_api.dart';
import '../design/widgets.dart';
import '../l10n/l10n.dart';

class BookHistoryScreen extends StatefulWidget {
  final ReaderApi api;
  final String book, title;
  const BookHistoryScreen({
    super.key,
    required this.api,
    required this.book,
    required this.title,
  });
  @override
  State<BookHistoryScreen> createState() => _BookHistoryScreenState();
}

class _BookHistoryScreenState extends State<BookHistoryScreen> {
  List<dynamic> operations = [];
  bool busy = true;
  String? error;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final s = await widget.api.call('snapshot');
      if (mounted) {
        setState(
          () => operations = (s['catalog']['operations'] as List)
              .where((o) => o['target'] == widget.book)
              .toList()
              .reversed
              .toList(),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> restore(Map<String, dynamic> operation) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(tr('撤销此书籍修改？')),
        content: Text(tr('恢复修改前的书籍状态，保留资源并产生一条新记录。如果书籍已有后续修改，操作会被拒绝。')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(tr('取消')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(tr('撤销修改')),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.api.call('undo_book_change', {'operation': operation['id']});
      await load();
    } catch (e) {
      if (mounted) {
        setState(() {
          error = '$e';
          busy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: AqPageHeading(tr('修改记录'), subtitle: widget.title),
        ),
        if (busy) const LinearProgressIndicator(),
        if (error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: SelectableText(error!),
          ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: operations.length,
            itemBuilder: (context, i) {
              final op = operations[i] as Map<String, dynamic>;
              final before = op['before'] as Map?;
              final after = op['after'] as Map?;
              final differences = <String>[];
              if (before != null && after != null) {
                for (final key in [
                  'title',
                  'project',
                  'gap',
                  'archived',
                  'pages',
                  'metadata',
                ]) {
                  if (jsonEncode(before[key]) != jsonEncode(after[key])) {
                    differences.add(switch (key) {
                      'title' => tr('名称：{value} → {value2}', {
                        'value': before[key],
                        'value2': after[key],
                      }),
                      'metadata' => tr('书籍信息与封面'),
                      'project' => tr('项目：{value} → {value2}', {
                        'value': before[key],
                        'value2': after[key],
                      }),
                      'gap' => tr('间隔：{value} → {value2}', {
                        'value': before[key],
                        'value2': after[key],
                      }),
                      'archived' => tr('移出书架：{value} → {value2}', {
                        'value': before[key],
                        'value2': after[key],
                      }),
                      _ => tr('页序 / 资源：{value} → {value2} 页', {
                        'value': (before['pages'] as List).length,
                        'value2': (after['pages'] as List).length,
                      }),
                    });
                  }
                }
              }
              return Card(
                child: ExpansionTile(
                  title: Text(
                    tr('{action} · 版本 {from} → {to}', {
                      'action': switch (op['action']) {
                        'book_metadata' => tr('更新信息与封面'),
                        'book_rename' => tr('重命名'),
                        'book_move' || 'book_remove' => tr('移动项目'),
                        'book_copy' => tr('复制书籍'),
                        'book_archive' => tr('移出书架'),
                        'book_restore' => tr('恢复到书架'),
                        'reorder_pages' => tr('调整页序'),
                        'reverse_pages' => tr('反转选中页'),
                        'set_book_gap' => tr('修改阅读间隔'),
                        'set_book_direction' => tr('修改阅读方向'),
                        'undo_book_change' => tr('恢复历史版本'),
                        'import_book' => tr('导入书籍'),
                        _ => tr('书籍修改'),
                      },
                      'from': before?['revision'] ?? '—',
                      'to': after?['revision'] ?? '—',
                    }),
                  ),
                  subtitle: Text(
                    tr('{value}\n操作者：{value2}', {
                      'value': DateTime.fromMillisecondsSinceEpoch(
                        (op['unix_seconds'] as int) * 1000,
                      ),
                      'value2': op['actor'],
                    }),
                  ),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          for (final diff in differences) SelectableText(diff),
                          if (before != null && after != null)
                            OutlinedButton(
                              onPressed: busy ? null : () => restore(op),
                              child: Text(tr('撤销此修改')),
                            ),
                          ExpansionTile(
                            title: Text(tr('完整前后差异')),
                            children: [
                              SelectableText(
                                const JsonEncoder.withIndent(
                                  '  ',
                                ).convert({'before': before, 'after': after}),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    ),
  );
}
