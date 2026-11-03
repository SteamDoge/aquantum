// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io';
import 'package:flutter/material.dart';
import '../data/models.dart';
import '../data/reader_api.dart';
import '../data/document_io.dart';
import 'import_dialog.dart';
import 'book_history.dart';

class PageManagerScreen extends StatefulWidget {
  final ReaderApi api;
  final Book book;
  final int initialPage;
  const PageManagerScreen({
    super.key,
    required this.api,
    required this.book,
    this.initialPage = 0,
  });
  @override
  State<PageManagerScreen> createState() => _PageManagerScreenState();
}

class _PageManagerScreenState extends State<PageManagerScreen> {
  final scroll = ScrollController();
  bool positioned = false;
  late final String? currentPage = widget.book.pages.isEmpty
      ? null
      : widget.book.pages[widget.initialPage.clamp(
              0,
              widget.book.pages.length - 1,
            )]['id']
            as String;
  @override
  void dispose() {
    scroll.dispose();
    super.dispose();
  }

  double rowHeight(BuildContext context) {
    final theme = Theme.of(context).textTheme;
    double height(String text, TextStyle? style) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final result = painter.height;
      painter.dispose();
      return result;
    }

    final text =
        height('页面\n名称', theme.titleMedium) + height('当前阅读页', theme.bodyMedium);
    return (text > 64 ? text : 64) + 32;
  }

  late Book book = widget.book;
  final Set<String> selected = {};
  bool busy = false;
  String? error, message;
  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
      message = null;
    });
    try {
      await action();
      final snapshot = LibrarySnapshot(
        Map<String, dynamic>.from(await widget.api.call('snapshot')),
      );
      if (mounted) {
        setState(() {
          book = snapshot.allBooks.firstWhere((b) => b.id == book.id);
          selected.retainAll(book.pages.map((p) => p['id'] as String));
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Map<String, dynamic> get selection => {
    'book': book.id,
    'revision': book.revision,
    'pages': selected.toList(),
  };
  Future<void> move(String? before) => run(() async {
    await widget.api.call('move_pages', {...selection, 'before': before});
  });
  Future<void> chooseTarget() async {
    final candidates = book.pages
        .where((p) => !selected.contains(p['id']))
        .toList();
    final target = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('移动到目标页之前'),
        content: SizedBox(
          width: 420,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: candidates.length,
            itemBuilder: (_, i) {
              final p = candidates[i];
              return ListTile(
                title: Text('第 ${book.pages.indexOf(p) + 1} 页'),
                subtitle: Text(p['resource']['original_name']),
                onTap: () => Navigator.pop(c, p['id']),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (target != null) await move(target);
  }

  Future<void> export(bool cut) async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(cut ? '剪切导出所选页？' : '导出所选页'),
        content: Text(
          cut
              ? '先写入并校验新文件，成功后再剪切。包含笔记或当前阅读位置的页面会保留，并说明原因。剪切可从操作记录撤销。'
              : '导出 ${selected.length} 页，保持当前页序。源页和笔记保留；同名文件不会覆盖。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('选择保存目录'),
          ),
        ],
      ),
    );
    if (accepted != true) return;
    final directory = await pickDocumentOutput('选择导出目录');
    if (directory == null || !mounted) return;
    final controller = TextEditingController(
      text: '页面-${DateTime.now().millisecondsSinceEpoch}.cbz',
    );
    final name = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('导出文件名'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(labelText: '文件名（.cbz 或 .zip）'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, controller.text.trim()),
            child: const Text('导出'),
          ),
        ],
      ),
    );
    // Dialog route may animate out while its text field is still mounted.
    WidgetsBinding.instance.addPostFrameCallback((_) => controller.dispose());
    if (name == null) return;
    if (name.isEmpty ||
        name.contains(RegExp(r'[/\\:]')) ||
        name == '.' ||
        name == '..') {
      if (mounted) setState(() => error = '请输入不含路径的文件名。');
      return;
    }
    await run(() async {
      final result = await widget.api.call('export_pages', {
        ...selection,
        'destination': directory.file(name),
        'cut': cut,
      });
      final published = await directory.publish(name);
      message = '已导出 $published';
      if (cut && result['cut']['applied'] != true) {
        message = '$message\n${result['cut']['reason']}';
      }
    });
  }

  Future<void> append({required bool atStart}) => run(() async {
    await pickAndImport(
      context,
      widget.api,
      book.project,
      book.title,
      append: {
        'book': book.id,
        'revision': book.revision,
        'before': atStart ? book.pages.first['id'] : null,
      },
    );
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('${book.title} · 页面管理'),
      actions: [
        IconButton(
          tooltip: '修改记录与恢复',
          onPressed: busy
              ? null
              : () async {
                  await Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => BookHistoryScreen(
                        api: widget.api,
                        book: book.id,
                        title: book.title,
                      ),
                    ),
                  );
                  await run(() async {});
                },
          icon: const Icon(Icons.history),
        ),
        IconButton(
          tooltip: '刷新页面',
          onPressed: busy ? null : () => run(() async {}),
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: Column(
      children: [
        if (busy) const LinearProgressIndicator(),
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .34,
          ),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text('已选 ${selected.length} / ${book.pages.length} 页'),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => setState(() {
                            if (selected.length == book.pages.length) {
                              selected.clear();
                            } else {
                              selected.addAll(
                                book.pages.map((p) => p['id'] as String),
                              );
                            }
                          }),
                    child: const Text('全选 / 取消'),
                  ),
                  OutlinedButton(
                    onPressed: busy ? null : () => append(atStart: false),
                    child: const Text('追加到末尾'),
                  ),
                  OutlinedButton(
                    onPressed: busy ? null : () => append(atStart: true),
                    child: const Text('插入开头'),
                  ),
                  OutlinedButton(
                    onPressed: busy || selected.isEmpty
                        ? null
                        : () => run(() async {
                            await widget.api.call('reverse_pages', selection);
                          }),
                    child: const Text('反转选中页'),
                  ),
                  OutlinedButton(
                    onPressed: busy || selected.isEmpty ? null : chooseTarget,
                    child: const Text('移至指定页前'),
                  ),
                  OutlinedButton(
                    onPressed: busy || selected.isEmpty
                        ? null
                        : () => move(
                            book.pages.firstWhere(
                              (p) => !selected.contains(p['id']),
                              orElse: () => {'id': null},
                            )['id'],
                          ),
                    child: const Text('移至开头'),
                  ),
                  OutlinedButton(
                    onPressed: busy || selected.isEmpty
                        ? null
                        : () => move(null),
                    child: const Text('移至末尾'),
                  ),
                  OutlinedButton(
                    onPressed: busy || selected.isEmpty
                        ? null
                        : () => export(false),
                    child: const Text('复制导出 CBZ / ZIP'),
                  ),
                  if (!Platform.isAndroid)
                    OutlinedButton(
                      onPressed: busy || selected.isEmpty
                          ? null
                          : () => export(true),
                      child: const Text('剪切导出'),
                    ),
                ],
              ),
            ),
          ),
        ),
        if (error != null || message != null)
          Padding(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              error ?? message!,
              style: TextStyle(
                color: error == null
                    ? null
                    : Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, size) {
              final extent = rowHeight(context);
              if (!positioned && book.pages.isNotEmpty) {
                positioned = true;
                final index = book.pages.indexWhere(
                  (p) => p['id'] == currentPage,
                );
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && scroll.hasClients && index >= 0) {
                    scroll.jumpTo(
                      (index * extent - size.maxHeight * .35).clamp(
                        0.0,
                        scroll.position.maxScrollExtent,
                      ),
                    );
                  }
                });
              }
              return ReorderableListView.builder(
                scrollController: scroll,
                itemExtent: extent,
                itemCount: book.pages.length,
                buildDefaultDragHandles: false,
                onReorderItem: (oldIndex, newIndex) {
                  if (busy) return;
                  final order = book.pages
                      .map((p) => p['id'] as String)
                      .toList();
                  order.insert(newIndex, order.removeAt(oldIndex));
                  run(() async {
                    await widget.api.call('reorder_pages', {
                      'book': book.id,
                      'revision': book.revision,
                      'pages': order,
                    });
                  });
                },
                itemBuilder: (context, i) {
                  final page = book.pages[i];
                  final id = page['id'] as String;
                  return ListTile(
                    key: ValueKey(id),
                    selected: selected.contains(id),
                    minVerticalPadding: 12,
                    onTap: busy
                        ? null
                        : () => setState(() {
                            if (!selected.add(id)) selected.remove(id);
                          }),
                    leading: SizedBox(
                      width: 64,
                      height: 64,
                      child: PageThumbnail(
                        key: ValueKey(id),
                        api: widget.api,
                        book: book.id,
                        page: id,
                      ),
                    ),
                    title: Text(
                      '第 ${i + 1} 页 · ${page['resource']['original_name']}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      '${id == currentPage ? '当前阅读页 · ' : ''}${sizeLabel(page['resource']['bytes'] as num)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Checkbox(
                          value: selected.contains(id),
                          onChanged: busy
                              ? null
                              : (v) => setState(() {
                                  if (v == true) {
                                    selected.add(id);
                                  } else {
                                    selected.remove(id);
                                  }
                                }),
                        ),
                        ReorderableDragStartListener(
                          enabled: !busy,
                          index: i,
                          child: const SizedBox(
                            width: 48,
                            height: 48,
                            child: Icon(Icons.drag_handle),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          ),
        ),
      ],
    ),
  );
}

class PageThumbnail extends StatefulWidget {
  final ReaderApi api;
  final String book, page;
  const PageThumbnail({
    super.key,
    required this.api,
    required this.book,
    required this.page,
  });
  @override
  State<PageThumbnail> createState() => _PageThumbnailState();
}

class _PageThumbnailState extends State<PageThumbnail> {
  late final Future<Uint8List> bytes = widget.api
      .call('read_image', {'book': widget.book, 'page': widget.page})
      .then((v) => base64Decode((v as String).split(',').last));
  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: bytes,
    builder: (context, snapshot) {
      if (snapshot.hasError) return const Icon(Icons.broken_image_outlined);
      if (!snapshot.hasData) {
        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      }
      return Image.memory(
        snapshot.data!,
        cacheWidth: 160,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => const Icon(Icons.broken_image_outlined),
      );
    },
  );
}
