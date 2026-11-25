// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import '../data/models.dart';
import '../data/reader_api.dart';
import '../design/widgets.dart';
import '../plugins/plugin_api.dart';
import '../plugins/plugin_manager.dart';
import 'page_manager.dart';
import 'book_history.dart';
import 'book_details.dart';
import 'library_content.dart' show projectColors;
import '../l10n/l10n.dart';

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
  Future<bool> confirm(String title, [String? message]) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(title),
          content: message == null ? null : Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(tr('取消')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(tr('确认')),
            ),
          ],
        ),
      ) ==
      true;
  Future<String?> target({String? movingProject}) => showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(tr('选择目标项目')),
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
        TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('取消'))),
      ],
    ),
  );

  /// A context menu beside the press: the subject's name as a gray header
  /// over groups of actions, as in ASpan. Only irreversible deletion is drawn
  /// as destructive, in the last group.
  Future<String?> menu(
    String title,
    List<List<(String, IconData, String)>> sections, {
    List<Color>? iconColors,
  }) {
    var i = 0;
    return showAqContextMenu<String>(
      context,
      menuPosition(context),
      title: title,
      sections: [
        for (final s in sections)
          [
            for (final e in s)
              AqMenuAction(
                e.$1,
                e.$3,
                e.$2,
                iconColor: iconColors?[i++ % iconColors.length],
                destructive: e.$1 == 'delete',
              ),
          ],
      ],
    );
  }

  Future<void> details(String title, String body) => showDialog<void>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(child: SelectableText(body)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: Text(tr('关闭'))),
      ],
    ),
  );
  Future<void> project(Project p) async {
    final scope = ExtensionContext(projectId: p.id);
    final ext = plugins.actions(ExtensionPoint.projectMenu, scope);
    final action = await menu(p.name, [
      [
        ('rename', Icons.drive_file_rename_outline, tr('重命名')),
        ('color', Icons.palette_outlined, tr('文件夹颜色')),
        if (p.id != library.inbox)
          ('move', Icons.drive_file_move_outlined, tr('移动项目')),
      ],
      [
        ('details', Icons.info_outline, tr('详情')),
        for (final e in ext) (e.id, e.icon, e.name),
      ],
      [
        if (p.id != library.inbox)
          ('delete', Icons.delete_outline, tr('删除空项目')),
      ],
    ]);
    if (!context.mounted || action == null) return;
    if (ext.any((e) => e.id == action)) {
      await perform(() async {
        final result = await plugins.invoke(action, scope);
        if (result != null && context.mounted) {
          await details(tr('操作结果'), result);
        }
      });
      return;
    }
    switch (action) {
      case 'rename':
        final v = await name(tr('重命名项目'), p.name);
        if (v != null) {
          await perform(() async {
            await api.call('rename_project', {'project': p.id, 'name': v});
          });
        }
      case 'color':
        final v = await menu(tr('文件夹颜色'), [
          [
            for (final (i, n) in [
              tr('蓝色'),
              tr('粉色'),
              tr('橙色'),
              tr('绿色'),
              tr('紫色'),
              tr('灰色'),
            ].indexed)
              ('$i', Icons.folder, n),
          ],
        ], iconColors: projectColors);
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
        if (await confirm(tr('删除空项目？'))) {
          await perform(() async {
            await api.call('delete_project', {'project': p.id});
          });
        }
      case 'details':
        await details(
          p.name,
          tr('路径：{value}\n直接文件：{value2}\n子项目：{value3}\nID：{id}', {
            'value': library.ancestors(p.id).map((a) => a.name).join(' / '),
            'value2': library.booksIn(p.id).length,
            'value3': library.children(p.id).length,
            'id': p.id,
          }),
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
          [
            ('rename', Icons.drive_file_rename_outline, tr('重命名')),
            ('copy', Icons.copy_outlined, tr('复制到项目')),
            ('move', Icons.drive_file_move_outlined, tr('移动到项目')),
            if (b.project != library.inbox)
              ('remove', Icons.folder_off_outlined, tr('从项目移除')),
          ],
          [
            ('details', Icons.info_outline, tr('详情')),
            ('history', Icons.history, tr('修改记录与恢复')),
            if (b.isComic && !b.archived)
              ('pages', Icons.photo_library_outlined, tr('页面管理')),
            for (final e in ext) (e.id, e.icon, e.name),
          ],
          [
            (
              b.archived ? 'restore' : 'archive',
              b.archived ? Icons.restore : Icons.remove_circle_outline,
              b.archived ? tr('恢复到书架') : tr('移出书架'),
            ),
          ],
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
        if (result != null && context.mounted) {
          await details(tr('操作结果'), result);
        }
      });
      return;
    }
    if (action == 'rename') {
      newName = await name(tr('重命名文件'), b.title);
      if (newName == null) return;
    }
    if (action == 'move' || action == 'copy') {
      destination = await target();
      if (destination == null) return;
    }
    if (action == 'archive' &&
        !await confirm(tr('移出书架？'), tr('内部副本、笔记和阅读记录会保留。可通过「我的 → 已移除文件」恢复。'))) {
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
      decoration: InputDecoration(labelText: tr('名称')),
      onSubmitted: (v) {
        if (v.trim().isNotEmpty) Navigator.pop(context, v);
      },
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr('取消')),
      ),
      FilledButton(
        onPressed: () {
          if (controller.text.trim().isNotEmpty) {
            Navigator.pop(context, controller.text);
          }
        },
        child: Text(tr('保存')),
      ),
    ],
  );
}
