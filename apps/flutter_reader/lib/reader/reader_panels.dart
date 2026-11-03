// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:flutter/material.dart';
import 'reader_contract.dart';
import 'reader_renderers.dart' show PagedTextReaderAdapter;
import '../formats/reader_provider_preferences.dart';

class ReaderNavigationPanel extends StatelessWidget {
  final ReaderAdapter adapter;
  final bool thumbnails;

  /// Reports the chosen location, not only its index: a chapter target is a
  /// real place of its own that no linear index can name.
  final ValueChanged<ReaderLocation> onSelect;
  const ReaderNavigationPanel({
    super.key,
    required this.adapter,
    required this.onSelect,
    this.thumbnails = false,
  });
  @override
  Widget build(BuildContext context) {
    if (adapter.count == 0) return const Center(child: Text('内容仍在加载或无法读取。'));
    if (thumbnails &&
        adapter is LiveReaderAdapter &&
        (adapter as LiveReaderAdapter).liveSurface) {
      return Column(
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('正文由文档引擎实时排版，当前不提供邻页缩略图。可通过目录和进度跳转。'),
          ),
          Expanded(
            child: ReaderNavigationPanel(adapter: adapter, onSelect: onSelect),
          ),
        ],
      );
    }
    final outline = adapter is OutlineReaderAdapter
        ? (adapter as OutlineReaderAdapter).outline
        : <ReaderLocation>[];
    int? active;
    if (thumbnails || outline.isEmpty) {
      active = adapter.position.clamp(0, adapter.count - 1);
    } else if (adapter is ActiveOutlineReaderAdapter) {
      active = (adapter as ActiveOutlineReaderAdapter).activeOutlineIndex;
    } else {
      // A chapter remains current until the next chapter starts, including
      // paragraphs/pages in the middle. Outline indices are not page numbers.
      for (var i = 0; i < outline.length; i++) {
        if (outline[i].index <= adapter.position &&
            (active == null || outline[i].index >= outline[active].index)) {
          active = i;
        }
      }
    }
    if (thumbnails) {
      return LayoutBuilder(
        builder: (context, size) {
          final columns = (size.maxWidth / 168).ceil().clamp(1, 1000);
          final rows = (adapter.count / columns).ceil();
          final currentRow = (active ?? 0) ~/ columns;
          final width = (size.maxWidth - (columns - 1) * 8) / columns;
          return ScrollablePositionedList.builder(
            key: ValueKey((
              'page-grid',
              adapter.documentId,
              columns,
              currentRow,
            )),
            itemCount: rows,
            initialScrollIndex: currentRow,
            initialAlignment: .35,
            itemBuilder: (context, row) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: SizedBox(
                height: width / .8,
                child: Row(
                  children: [
                    for (var col = 0; col < columns; col++) ...[
                      if (col > 0) const SizedBox(width: 8),
                      Expanded(
                        child: row * columns + col < adapter.count
                            ? thumbnail(context, row * columns + col)
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      );
    }
    ReaderLocation entry(int i) =>
        outline.isEmpty ? adapter.location(i) : outline[i];
    return ScrollablePositionedList.builder(
      key: ValueKey(('navigation', adapter.documentId, outline.length, active)),
      itemCount: outline.isEmpty ? adapter.count : outline.length,
      initialScrollIndex: active ?? 0,
      initialAlignment: .35,
      itemBuilder: (context, i) => ListTile(
        key: ValueKey('reader-navigation-item-$i'),
        selected: i == active,
        leading: Text(
          adapter is PagedTextReaderAdapter
              ? '第 ${entry(i).index + 1} 页'
              : '${i + 1}',
        ),
        title: Text(
          adapter is PagedTextReaderAdapter
              ? entry(i).label.replaceFirst(RegExp(r'^第 \d+ 页 · '), '')
              : entry(i).label,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        onTap: () => onSelect(entry(i)),
      ),
    );
  }

  Widget thumbnail(BuildContext context, int index) {
    final selected = index == adapter.position;
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      child: OutlinedButton(
        key: ValueKey('reader-navigation-thumbnail-$index'),
        style: OutlinedButton.styleFrom(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: const EdgeInsets.all(8),
          backgroundColor: selected ? colors.primaryContainer : null,
          side: BorderSide(
            color: selected ? colors.primary : colors.outline,
            width: selected ? 2 : 1,
          ),
        ),
        onPressed: () => onSelect(adapter.location(index)),
        child: Column(
          children: [
            Expanded(
              child:
                  adapter.buildThumbnail(context, index) ??
                  Center(
                    child: Text(
                      adapter.location(index).label,
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
            ),
            Text(
              '${index + 1}',
              style: TextStyle(
                color: selected ? colors.onPrimaryContainer : colors.onSurface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ReaderSearchPanel extends StatefulWidget {
  final ReaderAdapter adapter;
  final ValueChanged<ReaderLocation> onSelect;
  const ReaderSearchPanel({
    super.key,
    required this.adapter,
    required this.onSelect,
  });
  @override
  State<ReaderSearchPanel> createState() => _ReaderSearchPanelState();
}

class _ReaderSearchPanelState extends State<ReaderSearchPanel> {
  final query = TextEditingController();
  List<ReaderSearchHit>? hits;
  bool busy = false;
  String? error;
  int generation = 0;
  @override
  void dispose() {
    generation++;
    query.dispose();
    super.dispose();
  }

  Future<void> search() async {
    final current = ++generation;
    setState(() {
      busy = true;
      error = null;
      hits = null;
    });
    try {
      final result = await widget.adapter.search(query.text.trim());
      if (mounted && current == generation) setState(() => hits = result);
    } catch (e) {
      if (mounted && current == generation) {
        setState(() => error = e.toString());
      }
    } finally {
      if (mounted && current == generation) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.adapter.capabilities.search) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(widget.adapter.capabilities.searchExplanation),
        ),
      );
    }
    return Column(
      children: [
        TextField(
          controller: query,
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            labelText: '搜索当前内容',
            suffixIcon: IconButton(
              tooltip: '开始搜索',
              onPressed: busy ? null : search,
              icon: const Icon(Icons.search),
            ),
          ),
          onChanged: (_) {
            generation++;
            setState(() {
              busy = false;
              hits = null;
              error = null;
            });
          },
          onSubmitted: (_) => search(),
        ),
        const SizedBox(height: 8),
        if (busy) const LinearProgressIndicator(),
        if (error != null) Text(error!),
        Expanded(
          child: hits == null
              ? const Center(child: Text('输入文字，搜索当前文件。'))
              : hits!.isEmpty
              ? const Center(child: Text('没有找到匹配内容。'))
              : ListView.builder(
                  itemCount: hits!.length,
                  itemBuilder: (context, i) {
                    final hit = hits![i];
                    return ListTile(
                      title: Text(
                        hit.excerpt,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(hit.location.label, maxLines: 1),
                      onTap: busy ? null : () => widget.onSelect(hit.location),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Encoding override for text books (R06-03). It previews every candidate
/// decoded by the core, so a wrong guess is visible before it is stored, and
/// "自动识别" clears the stored choice. Original bytes are never rewritten.
class ReaderEncodingPanel extends StatefulWidget {
  final Future<dynamic> Function() load;
  final Future<void> Function(String? encoding) apply;
  const ReaderEncodingPanel({
    super.key,
    required this.load,
    required this.apply,
  });
  @override
  State<ReaderEncodingPanel> createState() => _ReaderEncodingPanelState();
}

class _ReaderEncodingPanelState extends State<ReaderEncodingPanel> {
  Map<String, dynamic>? info;
  String? error;
  bool busy = false;
  int generation = 0;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  @override
  void dispose() {
    generation++;
    super.dispose();
  }

  Future<void> refresh() async {
    final current = ++generation;
    try {
      final loaded = Map<String, dynamic>.from(await widget.load());
      if (mounted && current == generation) setState(() => info = loaded);
    } catch (e) {
      if (mounted && current == generation) {
        setState(() => error = e.toString());
      }
    }
  }

  Future<void> choose(String? encoding) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.apply(encoding);
      await refresh();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (error != null && info == null) {
      return Center(
        child: Padding(padding: const EdgeInsets.all(20), child: Text(error!)),
      );
    }
    if (info == null) return const Center(child: CircularProgressIndicator());
    final candidates = (info!['candidates'] as List? ?? const []);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          info!['stored'] == true
              ? '当前使用手动指定的编码；原文件字节保持不变。'
              : '当前按自动识别读取；识别不确定时可以手动指定。',
        ),
        const SizedBox(height: 8),
        Text(
          '识别结果：${info!['label']}（质量 ${info!['quality']}/100'
          '${info!['confident'] == true ? '' : '，可能不准'}）',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.auto_fix_high),
          title: const Text('自动识别'),
          selected: info!['stored'] != true,
          onTap: busy ? null : () => choose(null),
        ),
        const Divider(),
        for (final candidate in candidates)
          ListTile(
            leading: Icon(
              candidate['encoding'] == info!['encoding']
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
            ),
            title: Text(candidate['label'].toString()),
            subtitle: Text(
              candidate['sample'].toString(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Text('${candidate['confidence']}'),
            selected: candidate['encoding'] == info!['encoding'],
            onTap: busy ? null : () => choose(candidate['encoding'].toString()),
          ),
        if (busy) const LinearProgressIndicator(),
      ],
    );
  }
}

/// Direction for image books, independent of project defaults. Crop is
/// recorded per page and applied while painting, never baked into the file.
class ComicDirectionPanel extends StatefulWidget {
  final dynamic api;
  final dynamic book;
  final dynamic preferences;
  final Future<void> Function() onChanged;
  const ComicDirectionPanel({
    super.key,
    required this.api,
    required this.book,
    required this.preferences,
    required this.onChanged,
  });
  @override
  State<ComicDirectionPanel> createState() => _ComicDirectionPanelState();
}

class _ComicDirectionPanelState extends State<ComicDirectionPanel> {
  static const choices = [
    ('LeftToRight', '从左到右', Icons.arrow_forward),
    ('RightToLeft', '从右到左', Icons.arrow_back),
    ('TopToBottom', '从上到下（连续滚动）', Icons.arrow_downward),
  ];
  Map<String, dynamic>? effective;
  String? error;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    refresh();
  }

  Future<void> refresh() async {
    try {
      final direction = Map<String, dynamic>.from(
        await widget.api.call('effective_direction', {'book': widget.book.id}),
      );
      if (!mounted) return;
      setState(() {
        if (direction['source'] != widget.book.id) {
          direction['value'] = widget.preferences.continuous
              ? 'TopToBottom'
              : widget.preferences.rightToLeft
              ? 'RightToLeft'
              : 'LeftToRight';
          direction['description'] = '格式默认或本文件阅读设置';
        }
        effective = direction;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  /// `null` drops the core book override and selects the format default,
  /// so a right-to-left comic can be reset without picking a new fixed value.
  Future<void> setDirection(String? value) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await widget.api.call('resolve_book_direction', {
        'book': widget.book.id,
        'inherit': value == null,
        'direction': ?value,
      });
      final paged = value == null
          ? await ReaderProviderPreferences.paged(widget.book.format)
          : value != 'TopToBottom';
      widget.preferences.continuous = !paged;
      widget.preferences.textPaged = paged;
      widget.preferences.rightToLeft = value == 'RightToLeft';
      await widget.preferences.save(bookId: widget.book.id);
      await widget.onChanged();
      await refresh();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final source = effective?['source'];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text('阅读方向', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Text(
          effective?['description']?.toString() ?? '正在读取方向…',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        for (final (value, label, icon) in choices)
          ListTile(
            leading: Icon(icon),
            title: Text(label),
            selected: effective?['value'] == value,
            trailing: effective?['value'] == value
                ? const Icon(Icons.check)
                : null,
            onTap: busy ? null : () => setDirection(value),
          ),
        if (source != null && source == widget.book.id)
          ListTile(
            leading: const Icon(Icons.settings_backup_restore),
            title: const Text('恢复格式默认'),
            subtitle: const Text('使用阅读器选择中的格式默认翻页'),
            onTap: busy ? null : () => setDirection(null),
          ),
        if (busy) const LinearProgressIndicator(),
        if (error != null) Text(error!),
      ],
    );
  }
}
