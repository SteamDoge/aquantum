// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import '../data/reader_api.dart';
import '../design/widgets.dart';
import '../data/models.dart';

/// Search scope sent to the core. Mirrors `aq_application::SearchScope`; a
/// scope without its id is rejected by the core rather than widened to all.
class _Scope {
  final String kind;
  final String? id;
  const _Scope(this.kind, [this.id]);
  Map<String, dynamic> get json => {
    'kind': kind,
    if (id != null) ...{kind: id},
  };

  /// Names the chosen kind; the specific book or project is shown next to it by
  /// the chip so a reader never has to open the sheet to know the scope.
  String get label => switch (kind) {
    'book' => '当前书',
    'project' => '当前项目及子项目',
    _ => '全部内容',
  };
  String? nameFor(LibrarySnapshot library) => switch (kind) {
    'book' =>
      library.books.where((b) => b.id == id).map((b) => b.title).firstOrNull,
    'project' =>
      library.projects.where((p) => p.id == id).map((p) => p.name).firstOrNull,
    _ => null,
  };
}

class SearchScreen extends StatefulWidget {
  final ReaderApi api;
  final LibrarySnapshot library;
  final void Function(Book book, int paragraph) onOpen;
  final VoidCallback onIndexChanged;
  const SearchScreen({
    super.key,
    required this.api,
    required this.library,
    required this.onOpen,
    required this.onIndexChanged,
  });
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final controller = TextEditingController();
  Map<String, dynamic>? status;
  List<dynamic> hits = [];
  String? error;
  bool busy = false, searched = false;
  _Scope scope = const _Scope('all');

  /// Projects that still have descendant books, plus the flat book list, drive
  /// the two-picker layout: scope stays visible while the query runs.
  List<Project> get projects => widget.library.projects;

  @override
  void initState() {
    super.initState();
    run(() async {
      status = Map<String, dynamic>.from(
        await widget.api.call('index_status', {'scope': scope.json}),
      );
    });
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
    } catch (e) {
      error = e.toString();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> pickScope() async {
    final chosen = await showModalBottomSheet<_Scope>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              dense: true,
              title: Text('搜索范围'),
              subtitle: Text('默认搜全部内容；选项目会包含其所有子项目。'),
            ),
            ListTile(
              leading: const Icon(Icons.all_inbox),
              title: const Text('全部内容'),
              trailing: scope.kind == 'all' ? const Icon(Icons.check) : null,
              onTap: () => Navigator.pop(context, const _Scope('all')),
            ),
            for (final p in projects)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(p.name),
                trailing: scope.id == p.id && scope.kind == 'project'
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(context, _Scope('project', p.id)),
              ),
            for (final b in widget.library.books)
              ListTile(
                leading: const Icon(Icons.menu_book_outlined),
                title: Text(b.title),
                subtitle: Text(b.label),
                trailing: scope.id == b.id && scope.kind == 'book'
                    ? const Icon(Icons.check)
                    : null,
                onTap: () => Navigator.pop(context, _Scope('book', b.id)),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      scope = chosen;
      hits = [];
      searched = false;
    });
    await run(() async {
      status = Map<String, dynamic>.from(
        await widget.api.call('index_status', {'scope': scope.json}),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final small = Theme.of(context).textTheme.bodySmall;
    final visible = [
      for (final hit in hits)
        if (widget.library.books.any((b) => b.id == hit['book'])) hit,
    ];
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820),
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            20,
            28,
            20,
            24 + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            const AqPageHeading('全文搜索'),
            const SizedBox(height: 16),
            AqSearchField(
              controller: controller,
              hint: '搜索 TXT / Markdown 正文',
              maxLength: 200,
              onSubmitted: (_) => search(),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: busy ? null : pickScope,
                  icon: const Icon(Icons.filter_alt_outlined, size: 18),
                  label: Text(
                    '范围：${scope.nameFor(widget.library) ?? scope.label}',
                  ),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => run(() async {
                          status = Map<String, dynamic>.from(
                            await widget.api.call('build_index', {
                              'scope': scope.json,
                            }),
                          );
                          widget.onIndexChanged();
                        }),
                  child: const Text('建立 / 更新索引'),
                ),
                FilledButton(
                  onPressed: busy ? null : search,
                  child: const Text('搜索'),
                ),
              ],
            ),
            if (busy)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(),
              ),
            if (status != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                child: Text(
                  '本范围已索引 ${status!['indexed']} / ${status!['eligible']} 份文本；图片 OCR 待实现。',
                  style: small,
                ),
              ),
            for (final failure in status?['failures'] as List? ?? [])
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
                child: Text(failure.toString(), style: small),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
                child: Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 20),
            if (searched && hits.isEmpty && !busy)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  '没有匹配内容。新导入的文本请先建立索引。',
                  textAlign: TextAlign.center,
                  style: small,
                ),
              ),
            if (visible.isNotEmpty)
              AqSection(
                header: '${visible.length} 条结果',
                footer: hits.length == 100 ? '显示前 100 条结果，请缩小关键词或范围。' : null,
                dividerIndent: 16,
                children: [
                  for (final hit in visible)
                    AqRow(
                      title: widget.library.books
                          .firstWhere((b) => b.id == hit['book'])
                          .title,
                      subtitle:
                          '第 ${(hit['paragraph'] as int) + 1} 段 · ${hit['snippet']}',
                      onTap: () => widget.onOpen(
                        widget.library.books.firstWhere(
                          (b) => b.id == hit['book'],
                        ),
                        hit['paragraph'],
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Future<void> search() => run(() async {
    hits = await widget.api.call('search_text', {
      'query': controller.text,
      'scope': scope.json,
    });
    searched = true;
  });
}
