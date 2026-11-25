// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../data/models.dart';
import '../data/reader_api.dart';
import '../design/widgets.dart';
import '../l10n/l10n.dart';
import '../data/core_messages.dart';

class ImportPreviewScreen extends StatefulWidget {
  final ReaderApi api;
  final Map<String, dynamic> plan;
  final Map<String, dynamic>? append;
  const ImportPreviewScreen({
    super.key,
    required this.api,
    required this.plan,
    this.append,
  });
  @override
  State<ImportPreviewScreen> createState() => _ImportPreviewScreenState();
}

class _ImportPreviewScreenState extends State<ImportPreviewScreen> {
  late final Map<String, dynamic> plan = jsonDecode(jsonEncode(widget.plan));
  List<dynamic> projects = [];
  bool busy = false, skip = false, allowLeave = false;
  String? error;
  @override
  void initState() {
    super.initState();
    skip = plan['_skip_issues'] == true;
    widget.api
        .call('snapshot')
        .then((s) {
          if (mounted) {
            final library = LibrarySnapshot(Map<String, dynamic>.from(s));
            setState(
              () => projects = [
                for (final project in library.projects)
                  {'id': project.id, 'name': project.name},
              ],
            );
          }
        })
        .catchError((Object e) {
          if (mounted) setState(() => error = '$e');
        });
  }

  List<dynamic> get books => plan['books'];
  List<dynamic> get newProjects => plan['projects'];
  List<dynamic> get issues => plan['issues'];
  Map<String, dynamic> get edits => {
    'task': plan['task'],
    'base_revision': plan['base_revision'],
    'target': plan['target'],
    'projects': [
      for (final p in newProjects) {'id': p['id'], 'name': p['name']},
    ],
    'books': [
      for (final b in books)
        {
          'id': b['id'],
          'title': b['title'],
          'project': b['project'],
          'resources': [for (final r in b['resources']) r['id']],
        },
    ],
    'skip_issues': skip,
    'append': widget.append ?? plan['_append'],
  };
  Future<void> leave() async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.api.call('save_import_draft', edits);
      if (mounted) {
        setState(() => allowLeave = true);
        await WidgetsBinding.instance.endOfFrame;
        if (mounted) Navigator.pop(context, false);
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> commit() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.api.call('commit_import', edits);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr('已保存 {value} 项内容；外部原件保留。', {
                'value': (result['books'] as List).length,
              }),
            ),
          ),
        );
        setState(() => allowLeave = true);
        await WidgetsBinding.instance.endOfFrame;
        if (mounted) Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> editPages(Map<String, dynamic> book) async {
    final result = await Navigator.push<List<dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) =>
            ImportPagesScreen(api: widget.api, task: plan['task'], book: book),
      ),
    );
    if (result != null && mounted) setState(() => book['resources'] = result);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: allowLeave,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) leave();
    },
    child: Scaffold(
      appBar: AppBar(),
      body: Column(
        children: [
          if (busy) const LinearProgressIndicator(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
              children: [
                AqPageHeading(
                  widget.append == null ? tr('导入预览') : tr('追加 / 插入图片'),
                ),
                const SizedBox(height: 16),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: SelectableText(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                if (projects.isNotEmpty)
                  DropdownButtonFormField<String>(
                    initialValue: projects.any((p) => p['id'] == plan['target'])
                        ? plan['target']
                        : null,
                    decoration: InputDecoration(labelText: tr('保存到项目')),
                    isExpanded: true,
                    items: [
                      for (final p in projects)
                        DropdownMenuItem(
                          value: p['id'],
                          child: Text(
                            p['name'],
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: busy
                        ? null
                        : (value) {
                            if (value != null) {
                              setState(() {
                                final old = plan['target'];
                                plan['target'] = value;
                                for (final b in books) {
                                  if (b['project'] == old) b['project'] = value;
                                }
                              });
                            }
                          },
                  ),
                const SizedBox(height: 16),
                Text(
                  tr('{count} 个新项目 · {count2} 项内容 · {value}', {
                    'count': newProjects.length,
                    'count2': books.length,
                    'value': sizeLabel(
                      books.fold<int>(
                        0,
                        (n, b) =>
                            n +
                            (b['resources'] as List).fold<int>(
                              0,
                              (n, r) => n + (r['bytes'] as int),
                            ),
                      ),
                    ),
                  }),
                ),
                for (final p in newProjects)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: TextFormField(
                      key: ValueKey(p['id']),
                      initialValue: p['name'],
                      enabled: !busy,
                      decoration: InputDecoration(
                        labelText: tr('新项目名称'),
                        prefixIcon: Icon(Icons.folder_outlined),
                      ),
                      onChanged: (v) => p['name'] = v,
                    ),
                  ),
                for (final b in books)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextFormField(
                            key: ValueKey(b['id']),
                            initialValue: b['title'],
                            enabled: !busy,
                            decoration: InputDecoration(labelText: tr('内容名称')),
                            onChanged: (v) => b['title'] = v,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            tr('{value} · {value2} 个资源', {
                              'value': b['format'],
                              'value2': (b['resources'] as List).length,
                            }),
                          ),
                          if (projects.isNotEmpty)
                            DropdownButtonFormField<String>(
                              initialValue:
                                  [
                                    ...projects,
                                    ...newProjects,
                                  ].any((p) => p['id'] == b['project'])
                                  ? b['project']
                                  : null,
                              decoration: InputDecoration(
                                labelText: tr('所属项目'),
                              ),
                              isExpanded: true,
                              items: [
                                for (final p in [...projects, ...newProjects])
                                  DropdownMenuItem(
                                    value: p['id'],
                                    child: Text(
                                      p['name'],
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: busy
                                  ? null
                                  : (v) {
                                      if (v != null) {
                                        setState(() => b['project'] = v);
                                      }
                                    },
                            ),
                          if (b['format'] == 'Comic')
                            TextButton.icon(
                              onPressed: busy ? null : () => editPages(b),
                              icon: const Icon(Icons.photo_library_outlined),
                              label: Text(tr('缩略图、选择与页序')),
                            ),
                        ],
                      ),
                    ),
                  ),
                if (issues.isNotEmpty) ...[
                  Text(
                    tr('发现 {count} 项异常', {'count': issues.length}),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  for (final issue in issues) Text('• ${coreText(issue)}'),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: skip,
                    onChanged: busy
                        ? null
                        : (v) => setState(() => skip = v ?? false),
                    title: Text(tr('明确跳过以上异常，其余内容继续导入')),
                  ),
                ],
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: busy
                          ? null
                          : () => Navigator.pop(context, false),
                      child: Text(tr('保留任务，稍后继续')),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton(
                      onPressed: busy || (issues.isNotEmpty && !skip)
                          ? null
                          : commit,
                      child: Text(tr('确认导入副本')),
                    ),
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

class ImportPagesScreen extends StatefulWidget {
  final ReaderApi api;
  final String task;
  final Map<String, dynamic> book;
  const ImportPagesScreen({
    super.key,
    required this.api,
    required this.task,
    required this.book,
  });
  @override
  State<ImportPagesScreen> createState() => _ImportPagesScreenState();
}

class _ImportPagesScreenState extends State<ImportPagesScreen> {
  late final List<dynamic> resources = [...widget.book['resources']];
  late final Set<String> selected = {
    for (final r in resources) r['id'] as String,
  };
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(
            context,
            resources.where((r) => selected.contains(r['id'])).toList(),
          ),
          child: Text(tr('应用')),
        ),
      ],
    ),
    body: ReorderableListView.builder(
      header: Padding(
        padding: EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: AqPageHeading(tr('选择导入页与顺序')),
      ),
      itemCount: resources.length,
      buildDefaultDragHandles: false,
      onReorderItem: (oldIndex, newIndex) => setState(() {
        final item = resources.removeAt(oldIndex);
        resources.insert(newIndex, item);
      }),
      itemBuilder: (context, i) {
        final r = resources[i];
        return ListTile(
          key: ValueKey(r['id']),
          minVerticalPadding: 12,
          leading: SizedBox(
            width: 64,
            height: 64,
            child: ImportThumbnail(
              api: widget.api,
              task: widget.task,
              resource: r['id'],
            ),
          ),
          title: Text('${i + 1} · ${r['original_name']}'),
          subtitle: Row(
            children: [
              Checkbox(
                value: selected.contains(r['id']),
                onChanged: (v) => setState(() {
                  if (v == true) {
                    selected.add(r['id']);
                  } else {
                    selected.remove(r['id']);
                  }
                }),
              ),
              IconButton(
                tooltip: tr('上移一页'),
                onPressed: i == 0
                    ? null
                    : () => setState(() {
                        final item = resources.removeAt(i);
                        resources.insert(i - 1, item);
                      }),
                icon: const Icon(Icons.arrow_upward),
              ),
              IconButton(
                tooltip: tr('下移一页'),
                onPressed: i == resources.length - 1
                    ? null
                    : () => setState(() {
                        final item = resources.removeAt(i);
                        resources.insert(i + 1, item);
                      }),
                icon: const Icon(Icons.arrow_downward),
              ),
            ],
          ),
          trailing: ReorderableDragStartListener(
            index: i,
            child: const SizedBox(
              width: 48,
              height: 48,
              child: Icon(Icons.drag_handle),
            ),
          ),
        );
      },
    ),
  );
}

class ImportThumbnail extends StatefulWidget {
  final ReaderApi api;
  final String task, resource;
  const ImportThumbnail({
    super.key,
    required this.api,
    required this.task,
    required this.resource,
  });
  @override
  State<ImportThumbnail> createState() => _ImportThumbnailState();
}

class _ImportThumbnailState extends State<ImportThumbnail> {
  late final Future<Uint8List> bytes = widget.api
      .call('preview_image', {'task': widget.task, 'resource': widget.resource})
      .then((v) => base64Decode(v as String));
  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: bytes,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Tooltip(
          message: tr('无法解码或读取，原件保留'),
          child: Icon(Icons.broken_image_outlined),
        );
      }
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
