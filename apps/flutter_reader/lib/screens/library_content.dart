// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import '../data/models.dart';
import '../data/reader_api.dart';
import '../dashboard/dashboard_data.dart';
import '../design/theme.dart';
import '../widgets/book_cover.dart';
import '../design/widgets.dart';
import '../l10n/l10n.dart';

/// Folder colors chosen in the project menu, tuned for both brightnesses.
const projectColors = [
  Color(0xFF3B82D6),
  Color(0xFFC6427F),
  Color(0xFFC07A12),
  Color(0xFF3A9160),
  Color(0xFF8059BF),
  Color(0xFF7A8794),
];

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
  /// The add button's menu, drawn like every other context menu.
  Future<void> addContent() async {
    final action = await showAqContextMenu<String>(
      context,
      menuPosition(context),
      sections: [
        [
          AqMenuAction('import', tr('导入文件'), Icons.file_upload_outlined),
          AqMenuAction(
            'project',
            widget.projectId == widget.library.inbox ? tr('新建项目') : tr('新建文件夹'),
            Icons.create_new_folder_outlined,
          ),
        ],
      ],
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

  void viewOption(String value) {
    switch (value) {
      case 'grid' || 'list':
        widget.onView(value == 'grid', widget.sort);
      case 'select':
        setState(() {
          selecting = true;
          selected.clear();
        });
      default:
        widget.onView(widget.grid, value);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.library,
        current = widget.library.project(widget.projectId);
    final data = DashboardData(c);
    final theme = Theme.of(context);
    final colors = AqColors.of(context);
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
    final inset = widget.wide ? 32.0 : 20.0;
    // Pages run beneath the floating mobile dock; ends rest above it.
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final grid = widget.grid && MediaQuery.textScalerOf(context).scale(14) < 23;
    final parent = current.parent == null ? null : c.project(current.parent!);

    Widget bookAction(Book b, {bool compact = false}) => selecting
        ? Checkbox(
            value: selected.contains(b.id),
            onChanged: (_) => choose(b),
            shape: const CircleBorder(),
          )
        : IconButton(
            tooltip: tr('文件操作'),
            onPressed: widget.busy ? null : () => widget.onBookMenu(b),
            color: colors.muted,
            iconSize: compact ? 20 : 22,
            // Under a cover the whole tile also opens this menu (long press
            // or secondary click), so the caption keeps most of the width.
            style: compact
                ? IconButton.styleFrom(
                    minimumSize: const Size(36, 44),
                    padding: EdgeInsets.zero,
                  )
                : null,
            icon: const Icon(Icons.more_horiz),
          );

    Widget gesture(Book b, Widget child) => GestureDetector(
      onSecondaryTap: widget.busy ? null : () => widget.onBookMenu(b),
      child: InkWell(
        onTap: widget.busy ? null : () => choose(b),
        onLongPress: widget.busy ? null : () => widget.onBookMenu(b),
        borderRadius: BorderRadius.circular(12),
        child: child,
      ),
    );

    // A shelf caption: format and a short progress mark.
    String shortProgress(Book b) {
      final visit = data.latest[b.id];
      if (visit == null) return tr('未读');
      final f = data.fraction(b);
      if (f != null) return '${(f * 100).round()}%';
      final day = data.lastRead(b);
      final parts = day.split('-');
      return parts.length == 3
          ? '${int.parse(parts[1])}/${int.parse(parts[2])}'
          : day;
    }

    Widget gridTile(Book b) => gesture(
      b,
      Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Equal covers keep the shelf rows aligned whatever the titles.
            AspectRatio(
              aspectRatio: 1 / 1.4,
              child: AnimatedOpacity(
                opacity: selecting && !selected.contains(b.id) ? .55 : 1,
                duration: const Duration(milliseconds: 140),
                child: BookCover(api: widget.api, book: b),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              b.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall,
            ),
            const Spacer(),
            Row(
              children: [
                Expanded(
                  child: Text(
                    b.metadata['cover'] == null && !b.isComic
                        ? shortProgress(b) // The drawn cover names the format.
                        : '${b.label} · ${shortProgress(b)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                bookAction(b, compact: true),
              ],
            ),
          ],
        ),
      ),
    );

    Widget listRow(Book b) => gesture(
      b,
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 4, 8),
        child: Row(
          children: [
            SizedBox(
              width: 38,
              height: 53,
              child: BookCover(api: widget.api, book: b),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    b.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    data.latest.containsKey(b.id)
                        ? '${b.label} · ${data.progress(b)} · ${data.lastRead(b)}'
                        : tr('{label} · 未读', {'label': b.label}),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            bookAction(b),
          ],
        ),
      ),
    );

    Widget folder(Project p) {
      final count = c.booksIn(p.id).length + c.children(p.id).length;
      return Semantics(
        customSemanticsActions: {
          CustomSemanticsAction(label: tr('项目操作')): () =>
              widget.onProjectMenu(p),
        },
        child: GestureDetector(
          onSecondaryTap: widget.busy ? null : () => widget.onProjectMenu(p),
          child: AqRow(
            icon: Icons.folder_outlined,
            iconColor:
                projectColors[p.color.clamp(0, projectColors.length - 1)],
            title: p.name,
            value: '$count',
            onTap: widget.busy ? null : () => widget.onProject(p.id),
            onLongPress: widget.busy ? null : () => widget.onProjectMenu(p),
            chevron: true,
          ),
        ),
      );
    }

    final header = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AqPageHeading(
          current.id == c.inbox ? tr('资料库') : current.name,
          subtitle: query.isEmpty
              ? tr('{count} 份文件', {'count': books.length})
              : tr('找到 {count} 份文件', {'count': books.length}),
          leading: parent == null
              ? null
              : Align(
                  alignment: Alignment.centerLeft,
                  child: Tooltip(
                    message: tr('上级项目'),
                    child: TextButton.icon(
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.only(left: 2, right: 10),
                      ),
                      onPressed: () => widget.onProject(parent.id),
                      icon: const Icon(Icons.chevron_left, size: 24),
                      label: Text(
                        parent.id == c.inbox ? tr('资料库') : parent.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
          actions: [
            PopupMenuButton<String>(
              tooltip: tr('显示选项'),
              onSelected: viewOption,
              icon: const Icon(Icons.more_horiz),
              itemBuilder: (_) => [
                CheckedPopupMenuItem(
                  value: 'grid',
                  checked: widget.grid,
                  child: Text(tr('网格')),
                ),
                CheckedPopupMenuItem(
                  value: 'list',
                  checked: !widget.grid,
                  child: Text(tr('列表')),
                ),
                const PopupMenuDivider(),
                for (final e in [
                  ('name', tr('按名称')),
                  ('recent', tr('按最近阅读')),
                  ('format', tr('按文件类型')),
                ])
                  CheckedPopupMenuItem(
                    value: e.$1,
                    checked: widget.sort == e.$1,
                    child: Text(e.$2),
                  ),
                const PopupMenuDivider(),
                PopupMenuItem(value: 'select', child: Text(tr('选择文件'))),
              ],
            ),
          ],
        ),
        const SizedBox(height: 16),
        AqSearchField(
          controller: widget.searchController,
          hint: tr('搜索项目或文件'),
          onChanged: widget.onSearch,
        ),
        if (selecting)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    tr('已选择 {count} 份', {'count': selected.length}),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    selected
                      ..clear()
                      ..addAll(books.map((b) => b.id));
                  }),
                  child: Text(tr('全选')),
                ),
                TextButton(
                  onPressed: selected.isEmpty || widget.busy
                      ? null
                      : () => widget.onBatch(
                          books.where((b) => selected.contains(b.id)).toList(),
                        ),
                  child: Text(tr('批量移动')),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    selecting = false;
                    selected.clear();
                  }),
                  child: Text(tr('完成')),
                ),
              ],
            ),
          ),
        const SizedBox(height: 24),
      ],
    );

    final media = MediaQuery.of(context);
    final list = CustomScrollView(
      key: PageStorageKey('project-${widget.projectId}'),
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(inset, 28, inset, 0),
          sliver: SliverToBoxAdapter(child: header),
        ),
        if (children.isNotEmpty)
          SliverPadding(
            padding: EdgeInsets.symmetric(horizontal: inset),
            sliver: SliverToBoxAdapter(
              child: AqSection(
                header: tr('文件夹'),
                children: [for (final p in children) folder(p)],
              ),
            ),
          ),
        if (books.isNotEmpty && children.isNotEmpty)
          SliverPadding(
            padding: EdgeInsets.fromLTRB(inset + 16, 0, inset, 7),
            sliver: SliverToBoxAdapter(
              child: Text(
                tr('文件'),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        if (books.isNotEmpty)
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              grid ? inset - 4 : inset,
              0,
              grid ? inset - 4 : inset,
              84 + bottomInset,
            ),
            sliver: grid
                ? SliverLayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.crossAxisExtent;
                      // Three book-sized columns on a phone, more on wide
                      // windows; covers never grow past a shelf size.
                      const gap = 12.0;
                      final columns = math.max(
                        2,
                        ((width + gap) / ((widget.wide ? 150 : 108) + gap))
                            .floor(),
                      );
                      final tile = (width - gap * (columns - 1)) / columns;
                      final text = MediaQuery.textScalerOf(context).scale(14);
                      return SliverGrid.builder(
                        itemCount: books.length,
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: columns,
                          crossAxisSpacing: gap,
                          mainAxisSpacing: 14,
                          // Cover, gap, two title lines and the caption row.
                          mainAxisExtent: (tile - 8) * 1.4 + 70 + text * 2.9,
                        ),
                        itemBuilder: (_, i) => gridTile(books[i]),
                      );
                    },
                  )
                : SliverToBoxAdapter(
                    child: AqSection(
                      dividerIndent: 68,
                      children: [for (final b in books) listRow(b)],
                    ),
                  ),
          )
        else
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(32, 40, 32, 100 + bottomInset),
              child: Column(
                children: [
                  Icon(
                    query.isEmpty ? Icons.menu_book_outlined : Icons.search_off,
                    size: 44,
                    color: colors.muted.withValues(alpha: .6),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    query.isEmpty
                        ? (current.id == c.inbox
                              ? tr('资料库还没有文件')
                              : tr('此项目还没有文件'))
                        : tr('没有匹配的文件'),
                    style: theme.textTheme.titleMedium,
                  ),
                  if (query.isEmpty) ...[
                    const SizedBox(height: 20),
                    FilledButton.icon(
                      onPressed: widget.busy ? null : widget.onImport,
                      icon: const Icon(Icons.file_upload_outlined),
                      label: Text(tr('导入文件')),
                    ),
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: widget.busy ? null : widget.onSample,
                      child: Text(tr('试读示例')),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
    // The round add button sits above the floating dock (reported as bottom
    // padding), and gives way to the selection bar and the keyboard.
    final showAdd = !selecting && media.viewInsets.bottom == 0;
    return Stack(
      children: [
        Positioned.fill(child: list),
        if (showAdd)
          Positioned(
            right: media.padding.right + 20,
            bottom: bottomInset + 16,
            child: AqAddButton(
              key: const ValueKey('add-content'),
              tooltip: tr('添加内容'),
              onPressed: widget.busy ? null : addContent,
            ),
          ),
      ],
    );
  }
}
