// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../data/models.dart';
import '../data/reader_api.dart';
import '../reader/continuous_progress.dart';
import '../reader/reader_contract.dart';
import '../reader/reader_interaction.dart';
import 'markdown_document.dart';

class MarkdownContent extends StatefulWidget {
  final ReaderApi api;
  final Book book;
  final MarkdownDocument document;
  final ItemScrollController controller;
  final int position;
  final ValueChanged<int> onPosition;
  final ValueChanged<bool> onSelectionActive;
  final double fontSize, lineHeight, margin, paragraphGap;
  final String? fontFamily;

  /// Whole-book position on every scroll frame, weighted by block length.
  final ValueChanged<ReaderScrollMetrics>? onMetrics;
  final ReaderSeekController? seek;
  const MarkdownContent({
    super.key,
    required this.api,
    required this.book,
    required this.document,
    required this.controller,
    required this.position,
    required this.onPosition,
    required this.onSelectionActive,
    required this.fontSize,
    required this.lineHeight,
    required this.margin,
    this.paragraphGap = 24,
    this.fontFamily,
    this.onMetrics,
    this.seek,
  });
  @override
  State<MarkdownContent> createState() => _MarkdownContentState();
}

class _MarkdownContentState extends State<MarkdownContent> {
  final positions = ItemPositionsListener.create();
  final offsets = ScrollOffsetController();
  late final seeker = PositionedListSeeker(
    items: widget.controller,
    offsets: offsets,
    positions: positions,
  );
  late WeightedProgress progress = _progressFor(widget.document);
  final Map<String, Map<String, dynamic>> states = {};
  final Set<String> busy = {};
  bool ready = false;
  int orphaned = 0, lastPosition = -1;
  String? error;
  String get source => widget.book.pages.first['resource']['id'];

  static WeightedProgress _progressFor(MarkdownDocument document) =>
      WeightedProgress(document.blocks.map((b) => b.source.length + 8.0));

  @override
  void initState() {
    super.initState();
    positions.itemPositions.addListener(onScroll);
    widget.seek?.attach(seekTo);
    load();
  }

  @override
  void didUpdateWidget(covariant MarkdownContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.document, widget.document)) {
      progress = _progressFor(widget.document);
    }
    if (!identical(oldWidget.seek, widget.seek)) {
      oldWidget.seek?.detach(seekTo);
      widget.seek?.attach(seekTo);
    }
  }

  void seekTo(double fraction) {
    if (!widget.controller.isAttached) return;
    final (block, within) = progress.locate(fraction);
    seeker.jump(block, within);
  }

  Future<void> load() async {
    try {
      final records =
          await widget.api.call('document_interactions', {
                'book': widget.book.id,
              })
              as List;
      if (!mounted) return;
      setState(() {
        states.clear();
        orphaned = 0;
        for (final record in records) {
          if (record['source'] == source) {
            states['${record['kind']}:${record['node']}'] =
                Map<String, dynamic>.from(record);
          } else {
            orphaned++;
          }
        }
        ready = true;
      });
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    }
  }

  void onScroll() {
    final metrics = progress.measure(positions.itemPositions.value);
    if (metrics != null) widget.onMetrics?.call(metrics);
    final visible =
        positions.itemPositions.value
            .where((p) => p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1)
            .toList()
          ..sort((a, b) => a.index.compareTo(b.index));
    if (visible.isEmpty) return;
    final paragraph = widget.document.blocks[visible.first.index].paragraph;
    if (lastPosition == paragraph) return;
    lastPosition = paragraph;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onPosition(paragraph);
    });
  }

  Future<void> change(String kind, String node, bool value) async {
    final key = '$kind:$node';
    if (!ready || busy.contains(key)) return;
    setState(() => busy.add(key));
    try {
      final result = await widget.api.call('set_document_interaction', {
        'book': widget.book.id,
        'source': source,
        'node': node,
        'kind': kind,
        'value': value,
        'revision': states[key]?['revision'] ?? 0,
      });
      if (mounted) {
        setState(() => states[key] = Map<String, dynamic>.from(result));
      }
    } catch (e) {
      if (mounted) {
        setState(() => error = '$e');
        await load();
      }
    } finally {
      if (mounted) setState(() => busy.remove(key));
    }
  }

  Future<void> link(String label, String? href, String title) async {
    if (href == null) return;
    if (href.startsWith('#')) {
      final target = Uri.decodeComponent(href.substring(1));
      final seen = <String, int>{};
      for (var i = 0; i < widget.document.blocks.length; i++) {
        final b = widget.document.blocks[i];
        if (b.level == 0) continue;
        final root = b.label
            .toLowerCase()
            .replaceAll(RegExp(r'[^\p{L}\p{N}\s-]', unicode: true), '')
            .trim()
            .replaceAll(RegExp(r'\s+'), '-');
        final occurrence = seen[root] ?? 0;
        seen[root] = occurrence + 1;
        if ((occurrence == 0 ? root : '$root-$occurrence') == target) {
          widget.controller.jumpTo(index: i);
          return;
        }
      }
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未找到这个文档锚点。')));
      }
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('文档链接'),
        content: SelectableText(href),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: href));
              if (c.mounted) Navigator.pop(c);
            },
            child: const Text('复制链接'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Widget block(BuildContext context, int i) {
    final b = widget.document.blocks[i];
    var taskIndex = 0;
    Widget markdown(String data) => MarkdownBody(
      key: ValueKey(
        '${b.node}:$ready:${b.tasks.map((node) => states['task:$node']?['revision'] ?? 0).join(',')}',
      ),
      data: data,
      selectable: true,
      onSelectionChanged: (text, selection, cause) =>
          widget.onSelectionActive(!selection.isCollapsed),
      onTapLink: link,
      imageBuilder: (uri, title, alt) => attachment(uri, alt),
      styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
        p: TextStyle(
          fontSize: widget.fontSize,
          height: widget.lineHeight,
          fontFamily: widget.fontFamily,
        ),
        listIndent: 56,
        code: TextStyle(
          fontSize: widget.fontSize * .85,
          fontFamily: 'monospace',
        ),
      ),
      checkboxBuilder: (baseline) {
        final index = taskIndex++;
        if (index >= b.tasks.length) return const Icon(Icons.error_outline);
        final node = b.tasks[index];
        final key = 'task:$node';
        return SizedBox(
          width: 48,
          height: 48,
          child: ReaderInteractiveRegion(
            child: Checkbox(
              semanticLabel: '阅读任务',
              value: states[key]?['value'] ?? baseline,
              onChanged: !ready || busy.contains(key)
                  ? null
                  : (value) {
                      if (value != null) change('task', node, value);
                    },
            ),
          ),
        );
      },
      builders: {'pre': _CodeBuilder()},
    );
    final details = RegExp(
      r'^\s*<details(?:\s[^>]*)?>\s*(?:<summary>([\s\S]*?)</summary>)?([\s\S]*?)</details>\s*$',
      caseSensitive: false,
    ).firstMatch(b.source);
    if (details != null) {
      final key = 'fold:${b.node}';
      final expanded = states[key]?['value'] ?? false;
      return Padding(
        padding: EdgeInsets.symmetric(
          horizontal: widget.margin,
          vertical: widget.paragraphGap / 3,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ReaderInteractiveRegion(
              child: TextButton.icon(
                onPressed: !ready || busy.contains(key)
                    ? null
                    : () => change('fold', b.node, !expanded),
                icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
                label: Text(details.group(1) ?? '折叠内容'),
              ),
            ),
            if (expanded) markdown(details.group(2) ?? ''),
          ],
        ),
      );
    }
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: widget.margin,
        vertical: widget.paragraphGap / 3,
      ),
      child: markdown(b.source),
    );
  }

  Widget attachment(Uri uri, String? alt) {
    if (uri.hasScheme || uri.hasAuthority) {
      return Text('远程图片未自动下载：${alt ?? uri.toString()}');
    }
    final original =
        widget.book.pages.first['resource']['original_name'] as String? ??
        'source.md';
    final name = Uri(path: original).resolveUri(uri).path;
    final matches = widget.book.pages
        .skip(1)
        .where((p) => p['resource']['original_name'] == name);
    if (matches.isEmpty) return Text('附件尚未导入或无法读取：$name');
    final resource = matches.first['resource']['id'] as String;
    return ManagedMarkdownImage(
      key: ValueKey(resource),
      api: widget.api,
      book: widget.book.id,
      resource: resource,
      alt: alt ?? name,
    );
  }

  @override
  void dispose() {
    widget.seek?.detach(seekTo);
    positions.itemPositions.removeListener(onScroll);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      if (error != null)
        MaterialBanner(
          content: Text(error!),
          actions: [
            TextButton(
              onPressed: () async {
                setState(() => error = null);
                await load();
              },
              child: const Text('重读交互状态'),
            ),
          ],
        ),
      if (orphaned > 0)
        Padding(
          padding: const EdgeInsets.all(8),
          child: Text('保留了 $orphaned 项旧正文交互，未自动套用到当前版本。'),
        ),
      Expanded(
        child: widget.document.blocks.isEmpty
            ? const Center(child: Text('这份文档没有可显示的正文。'))
            : LayoutBuilder(
                builder: (context, constraints) {
                  seeker.viewportExtent = constraints.maxHeight;
                  return ScrollablePositionedList.builder(
                    itemScrollController: widget.controller,
                    scrollOffsetController: offsets,
                    itemPositionsListener: positions,
                    initialScrollIndex: widget.document.blockForParagraph(
                      widget.position,
                    ),
                    itemCount: widget.document.blocks.length,
                    itemBuilder: block,
                  );
                },
              ),
      ),
    ],
  );
}

class _CodeBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;
  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    color: Theme.of(context).colorScheme.surfaceContainer,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: ReaderInteractiveRegion(
            child: TextButton.icon(
              onPressed: () =>
                  Clipboard.setData(ClipboardData(text: element.textContent)),
              icon: const Icon(Icons.copy_outlined),
              label: const Text('复制代码'),
            ),
          ),
        ),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText(
            element.textContent,
            style: const TextStyle(fontFamily: 'monospace'),
          ),
        ),
      ],
    ),
  );
}

class ManagedMarkdownImage extends StatefulWidget {
  final ReaderApi api;
  final String book, resource, alt;
  const ManagedMarkdownImage({
    super.key,
    required this.api,
    required this.book,
    required this.resource,
    required this.alt,
  });
  @override
  State<ManagedMarkdownImage> createState() => _ManagedMarkdownImageState();
}

class _ManagedMarkdownImageState extends State<ManagedMarkdownImage> {
  late final Future<Uint8List> bytes = widget.api
      .call('read_attachment', {
        'book': widget.book,
        'resource': widget.resource,
      })
      .then((v) => base64Decode(v as String));
  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List>(
    future: bytes,
    builder: (context, snapshot) {
      if (snapshot.hasError) return Text('附件无法读取：${snapshot.error}');
      if (!snapshot.hasData) {
        return const SizedBox(
          height: 100,
          child: Center(child: CircularProgressIndicator()),
        );
      }
      return Image.memory(
        snapshot.data!,
        cacheWidth: 1024,
        semanticLabel: widget.alt,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => Text('图片无法解码：${widget.alt}。原副本保留。'),
      );
    },
  );
}
