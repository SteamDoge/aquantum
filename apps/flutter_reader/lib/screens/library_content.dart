// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import '../data/models.dart';
import '../data/reader_api.dart';
import '../dashboard/dashboard_data.dart';
import '../widgets/book_cover.dart';
import '../design/widgets.dart';

class LibraryContent extends StatefulWidget {
  final LibrarySnapshot library;
  final String projectId, query, sort;
  final bool wide, busy, grid;
  final VoidCallback onImport, onCreateProject, onSample;
  final ValueChanged<String> onProject, onSearch;
  final ValueChanged<Book> onBook, onBookMenu;
  final ValueChanged<Project> onProjectMenu;
  final Future<void> Function(List<Book> books) onBatch;
  final TextEditingController searchController;
  final ReaderApi api;
  final void Function(bool grid, String sort) onView;
  const LibraryContent({
    super.key,
    required this.library,
    required this.projectId,
    required this.query,
    required this.wide,
    required this.busy,
    required this.onImport,
    required this.onCreateProject,
    required this.onSample,
    required this.onProject,
    required this.onSearch,
    required this.onBook,
    required this.searchController,
    required this.api,
    required this.onBookMenu,
    required this.onProjectMenu,
    required this.grid,
    required this.sort,
    required this.onView,
    required this.onBatch,
  });
  @override
  State<LibraryContent> createState() => _LibraryContentState();
}

class _LibraryContentState extends State<LibraryContent> {
  Future<void> addContent() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: Text(
                widget.projectId == widget.library.inbox ? '新建项目' : '新建文件夹',
              ),
              onTap: () => Navigator.pop(c, 'project'),
            ),
            ListTile(
              leading: const Icon(Icons.file_upload_outlined),
              title: const Text('导入文件'),
              onTap: () => Navigator.pop(c, 'import'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'project') widget.onCreateProject();
    if (action == 'import') widget.onImport();
  }

  bool selecting = false;
  final Set<String> selected = {};
  @override
  void didUpdateWidget(covariant LibraryContent old) {
    super.didUpdateWidget(old);
    if (old.projectId != widget.projectId) {
      selected.clear();
      selecting = false;
    }
    selected.removeWhere((id) => !widget.library.books.any((b) => b.id == id));
  }

  void choose(Book b) {
    if (selecting) {
      setState(() {
        if (!selected.add(b.id)) selected.remove(b.id);
      });
    } else {
      widget.onBook(b);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.library,
        current = widget.library.project(widget.projectId);
    final data = DashboardData(c);
    final query = widget.query.trim().toLowerCase();
    final books = query.isEmpty
        ? c.booksIn(current.id)
        : c.books.where((b) => b.title.toLowerCase().contains(query)).toList();
    final children = query.isEmpty
        ? c.children(current.id)
        : c.projects
              .where(
                (p) => p.id != c.inbox && p.name.toLowerCase().contains(query),
              )
              .toList();
    books.sort(
      (a, b) => switch (widget.sort) {
        'recent' => (data.latest[b.id]?.startedAt ?? 0).compareTo(
          data.latest[a.id]?.startedAt ?? 0,
        ),
        'format' => a.format.compareTo(b.format),
        _ => a.title.compareTo(b.title),
      },
    );
    children.sort((a, b) => a.name.compareTo(b.name));
    final inset = widget.wide ? 32.0 : 22.0;
    // Pages run beneath the floating mobile dock; ends rest above it.
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final grid = widget.grid && MediaQuery.textScalerOf(context).scale(14) < 23;
    Widget file(Book b, bool isGrid) {
      final info = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            b.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 5),
          Text(
            '${b.label} · ${data.progress(b)}',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (!isGrid)
            Text(
              data.lastRead(b),
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      );
      final action = selecting
          ? Checkbox(
              value: selected.contains(b.id),
              onChanged: (_) => choose(b),
            )
          : IconButton(
              tooltip: '文件操作',
              onPressed: widget.busy ? null : () => widget.onBookMenu(b),
              icon: Icon(isGrid ? Icons.more_horiz : Icons.more_vert),
            );
      return GestureDetector(
        onSecondaryTap: widget.busy ? null : () => widget.onBookMenu(b),
        child: InkWell(
          onTap: widget.busy ? null : () => choose(b),
          onLongPress: widget.busy ? null : () => widget.onBookMenu(b),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: isGrid
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Center(
                          child: AspectRatio(
                            aspectRatio: 1 / 1.4,
                            child: BookCover(api: widget.api, book: b),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      info,
                      Align(alignment: Alignment.centerRight, child: action),
                    ],
                  )
                : Row(
                    children: [
                      SizedBox(
                        width: 48,
                        height: 64,
                        child: BookCover(api: widget.api, book: b),
                      ),
                      const SizedBox(width: 14),
                      Expanded(child: info),
                      action,
                    ],
                  ),
          ),
        ),
      );
    }

    Widget folder(Project p) {
      final colors = [
        const Color(0xFF4077C8),
        const Color(0xFFC13883),
        const Color(0xFFB26A16),
        const Color(0xFF39835C),
        const Color(0xFF7C56AC),
        const Color(0xFF687482),
      ];
      return GestureDetector(
        onSecondaryTap: widget.busy ? null : () => widget.onProjectMenu(p),
        child: Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: InkWell(
            onTap: widget.busy ? null : () => widget.onProject(p.id),
            onLongPress: widget.busy ? null : () => widget.onProjectMenu(p),
            borderRadius: BorderRadius.circular(23),
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Icon(
                    Icons.folder_outlined,
                    size: 36,
                    color: colors[p.color.clamp(0, 5)],
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        Text(
                          '${c.children(p.id).length} 个子项目 · ${c.booksIn(p.id).length} 份文件',
                          maxLines: 2,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '项目操作',
                    onPressed: widget.busy
                        ? null
                        : () => widget.onProjectMenu(p),
                    icon: const Icon(Icons.more_vert),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Stack(
      children: [
        CustomScrollView(
          key: PageStorageKey('project-${widget.projectId}'),
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(inset, 8, inset, 0),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 14, bottom: 24),
                      child: Row(
                        children: [
                          const Expanded(child: AqBrand()),
                          IconButton.filledTonal(
                            tooltip: '添加内容',
                            onPressed: widget.busy ? null : addContent,
                            icon: const Icon(Icons.add),
                          ),
                        ],
                      ),
                    ),
                    Text(
                      '本机内容 · ${books.length} 份文件',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        if (current.parent != null)
                          IconButton(
                            tooltip: '上级项目',
                            onPressed: () => widget.onProject(current.parent!),
                            icon: const Icon(Icons.arrow_back),
                          ),
                        Expanded(
                          child: Text(
                            current.id == c.inbox ? '资料库' : current.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 32,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        PopupMenuButton<String>(
                          tooltip: '排序方式',
                          initialValue: widget.sort,
                          onSelected: (v) => widget.onView(widget.grid, v),
                          icon: const Icon(Icons.sort),
                          itemBuilder: (_) => [
                            for (final e in [
                              ('name', '名称'),
                              ('recent', '最近阅读'),
                              ('format', '文件类型'),
                            ])
                              CheckedPopupMenuItem(
                                value: e.$1,
                                checked: widget.sort == e.$1,
                                child: Text(e.$2),
                              ),
                          ],
                        ),
                        IconButton(
                          tooltip: widget.grid ? '切换列表' : '切换网格',
                          onPressed: () =>
                              widget.onView(!widget.grid, widget.sort),
                          icon: Icon(
                            widget.grid
                                ? Icons.view_list_outlined
                                : Icons.grid_view_outlined,
                          ),
                        ),
                        IconButton(
                          tooltip: '多选文件',
                          isSelected: selecting,
                          onPressed: () => setState(() {
                            selecting = !selecting;
                            selected.clear();
                          }),
                          icon: const Icon(Icons.checklist),
                        ),
                      ],
                    ),
                    if (current.parent != null)
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          children: [
                            for (final p in c.ancestors(current.id))
                              TextButton(
                                onPressed: () => widget.onProject(p.id),
                                child: Text(p.id == c.inbox ? '资料库' : p.name),
                              ),
                          ],
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: TextField(
                        controller: widget.searchController,
                        decoration: const InputDecoration(
                          hintText: '搜索项目或文件名称',
                          prefixIcon: Icon(Icons.search),
                          isDense: true,
                        ),
                        onChanged: widget.onSearch,
                      ),
                    ),
                    if (selecting)
                      Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text('已选择 ${selected.length} 份'),
                          TextButton(
                            onPressed: () => setState(() {
                              selected.clear();
                              selected.addAll(books.map((b) => b.id));
                            }),
                            child: const Text('全选'),
                          ),
                          TextButton(
                            onPressed: selected.isEmpty || widget.busy
                                ? null
                                : () => widget.onBatch(
                                    books
                                        .where((b) => selected.contains(b.id))
                                        .toList(),
                                  ),
                            child: const Text('批量移动'),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            if (children.isNotEmpty)
              SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: inset),
                sliver: grid
                    ? SliverGrid.builder(
                        itemCount: children.length,
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 440,
                              mainAxisExtent: 108,
                            ),
                        itemBuilder: (_, i) => folder(children[i]),
                      )
                    : SliverList.builder(
                        itemCount: children.length,
                        itemBuilder: (_, i) => folder(children[i]),
                      ),
              ),
            if (books.isNotEmpty)
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                  inset - 4,
                  8,
                  inset - 4,
                  84 + bottomInset,
                ),
                sliver: grid
                    ? SliverGrid.builder(
                        itemCount: books.length,
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 220,
                              mainAxisExtent: 340,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 16,
                            ),
                        itemBuilder: (_, i) => file(books[i], true),
                      )
                    : SliverList.builder(
                        itemCount: books.length,
                        itemBuilder: (_, i) => file(books[i], false),
                      ),
              )
            else
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(24, 32, 24, 100 + bottomInset),
                  child: Column(
                    children: [
                      Text(
                        query.isEmpty
                            ? (current.id == c.inbox ? '资料库还没有文件' : '此项目还没有文件')
                            : '没有匹配的文件',
                      ),
                      const SizedBox(height: 12),
                      if (query.isEmpty)
                        TextButton(
                          onPressed: widget.busy ? null : widget.onSample,
                          child: const Text('试读示例'),
                        ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}
