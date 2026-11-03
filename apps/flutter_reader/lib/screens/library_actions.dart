// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import '../data/models.dart';
import '../data/reader_api.dart';
import '../plugins/plugin_api.dart';
import '../plugins/plugin_manager.dart';
import 'page_manager.dart';
import 'book_history.dart';
import 'book_details.dart';

class LibraryActions {
  final BuildContext context;
  final LibrarySnapshot library;
  final ReaderApi api;
  final PluginManager plugins;
  final Future<void> Function(Future<void> Function()) perform;
  final Future<void> Function(Book)? onRead;
  LibraryActions(
    this.context,
    this.library,
    this.api,
    this.plugins,
    this.perform, {
    this.onRead,
  });
  Future<String?> name(String title, String initial) => showDialog<String>(
    context: context,
    builder: (_) => NameDialog(title: title, initial: initial),
  );
  Future<bool> confirm(String title, String message) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('确认'),
            ),
          ],
        ),
      ) ==
      true;
  Future<String?> target({String? movingProject}) => showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('选择目标项目'),
      content: SizedBox(
        width: 420,
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final p in library.projects.where(
              (p) =>
                  movingProject == null ||
                  !library.ancestors(p.id).any((a) => a.id == movingProject),
            ))
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(
                  library.ancestors(p.id).map((a) => a.name).join(' / '),
                ),
                onTap: () => Navigator.pop(c, p.id),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
      ],
    ),
  );
  Future<String?> menu(
    String title,
    List<(String, IconData, String)> entries,
  ) => showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (c) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(c).height * .8,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            for (final e in entries)
              ListTile(
                leading: Icon(e.$2),
                title: Text(e.$3),
                onTap: () => Navigator.pop(c, e.$1),
              ),
          ],
        ),
      ),
    ),
  );
  Future<void> details(String title, String body) => showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: SelectableText(body)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('关闭')),
      ],
    ),
  );
  Future<void> project(Project p) async {
    final scope = ExtensionContext(projectId: p.id);
    final ext = plugins.actions(ExtensionPoint.projectMenu, scope);
    final action = await menu(p.name, [
      ('rename', Icons.drive_file_rename_outline, '重命名'),
      ('color', Icons.palette_outlined, '文件夹颜色'),
      if (p.id != library.inbox)
        ('move', Icons.drive_file_move_outlined, '移动项目'),
      ('details', Icons.info_outline, '详情'),
      for (final e in ext) (e.id, e.icon, e.name),
      if (p.id != library.inbox) ('delete', Icons.delete_outline, '删除空项目'),
    ]);
    if (!context.mounted || action == null) return;
    if (ext.any((e) => e.id == action)) {
      await perform(() async {
        final result = await plugins.invoke(action, scope);
        if (result != null && context.mounted) await details('操作结果', result);
      });
      return;
    }
    switch (action) {
      case 'rename':
        final v = await name('重命名项目', p.name);
        if (v != null) {
          await perform(() async {
            await api.call('rename_project', {'project': p.id, 'name': v});
          });
        }
      case 'color':
        final v = await menu('文件夹颜色', [
          for (final (i, n) in ['蓝色', '粉色', '橙色', '绿色', '紫色', '灰色'].indexed)
            ('$i', Icons.folder, n),
        ]);
        if (v != null) {
          await perform(() async {
            await api.call('color_project', {
              'project': p.id,
              'color': int.parse(v),
            });
          });
        }
      case 'move':
        final v = await target(movingProject: p.id);
        if (v != null) {
          await perform(() async {
            await api.call('move_project', {'project': p.id, 'target': v});
          });
        }
      case 'delete':
        if (await confirm('删除空项目？', '仅可删除没有子项目和文件（含已移除文件）的空项目。外部原件不会改变。')) {
          await perform(() async {
            await api.call('delete_project', {'project': p.id});
          });
        }
      case 'details':
        await details(
          p.name,
          '路径：${library.ancestors(p.id).map((a) => a.name).join(' / ')}\n直接文件：${library.booksIn(p.id).length}\n子项目：${library.children(p.id).length}\nID：${p.id}',
        );
    }
  }

  Future<void> book(Book b, {String? selectedAction}) async {
    final scope = ExtensionContext(
      bookId: b.id,
      format: b.format,
      capabilities: b.isComic
          ? {ReaderCapability.image, ReaderCapability.fixedLayout}
          : {ReaderCapability.selectableText, ReaderCapability.reflow},
    );
    final ext = plugins.actions(ExtensionPoint.fileMenu, scope);
    final action =
        selectedAction ??
        await menu(b.title, [
          ('history', Icons.history, '修改记录与恢复'),
          if (b.isComic && !b.archived)
            ('pages', Icons.photo_library_outlined, '页面管理、追加与导出'),
          ('rename', Icons.drive_file_rename_outline, '重命名'),
          ('copy', Icons.copy_outlined, '复制到项目'),
          ('move', Icons.drive_file_move_outlined, '移动到项目'),
          if (b.project != library.inbox)
            ('remove', Icons.folder_off_outlined, '从项目移除（移回资料库）'),
          ('details', Icons.info_outline, '详情'),
          for (final e in ext) (e.id, e.icon, e.name),
          (
            b.archived ? 'restore' : 'archive',
            b.archived ? Icons.restore : Icons.remove_circle_outline,
            b.archived ? '恢复到书架' : '移出书架（保留副本与记录）',
          ),
        ]);
    if (!context.mounted || action == null) return;
    String? newName, destination;
    if (action == 'history') {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              BookHistoryScreen(api: api, book: b.id, title: b.title),
        ),
      );
      await perform(() async {});
      return;
    }
    if (action == 'pages') {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => PageManagerScreen(
            api: api,
            book: b,
            initialPage: library.position(b),
          ),
        ),
      );
      await perform(() async {});
      return;
    }
    if (action == 'details') {
      await Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => BookDetailsScreen(
            book: b,
            library: library,
            api: api,
            onRead: onRead,
            onAction: (action, book) => this.book(book, selectedAction: action),
          ),
        ),
      );
      await perform(() async {});
      return;
    }
    if (ext.any((e) => e.id == action)) {
      await perform(() async {
        final result = await plugins.invoke(action, scope);
        if (result != null && context.mounted) await details('操作结果', result);
      });
      return;
    }
    if (action == 'rename') {
      newName = await name('重命名文件', b.title);
      if (newName == null) return;
    }
    if (action == 'move' || action == 'copy') {
      destination = await target();
      if (destination == null) return;
    }
    if (action == 'archive' &&
        !await confirm('移出书架？', '内部副本、笔记和阅读记录会保留。可通过「我的 → 已移除文件」恢复。')) {
      return;
    }
    await perform(() async {
      await api.call('manage_book', {
        'book': b.id,
        'action': action,
        'name': ?newName,
        'target': ?destination,
      });
    });
  }
}

class NameDialog extends StatefulWidget {
  final String title, initial;
  const NameDialog({super.key, required this.title, required this.initial});
  @override
  State<NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<NameDialog> {
  late final controller = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: TextField(
      controller: controller,
      autofocus: true,
      maxLength: 80,
      decoration: const InputDecoration(labelText: '名称'),
      onSubmitted: (v) {
        if (v.trim().isNotEmpty) Navigator.pop(context, v);
      },
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (controller.text.trim().isNotEmpty) {
            Navigator.pop(context, controller.text);
          }
        },
        child: const Text('保存'),
      ),
    ],
  );
}
