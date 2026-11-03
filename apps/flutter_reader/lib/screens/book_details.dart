// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import '../data/models.dart';
import '../data/reader_api.dart';
import '../design/widgets.dart';
import '../widgets/book_cover.dart';
import 'book_metadata_screen.dart';

class BookDetailsScreen extends StatefulWidget {
  final Book book;
  final LibrarySnapshot library;
  final ReaderApi api;
  final Future<void> Function(String, Book) onAction;
  final Future<void> Function(Book)? onRead;
  const BookDetailsScreen({
    super.key,
    required this.book,
    required this.library,
    required this.api,
    required this.onAction,
    this.onRead,
  });
  @override
  State<BookDetailsScreen> createState() => _BookDetailsScreenState();
}

class _BookDetailsScreenState extends State<BookDetailsScreen> {
  late Book book = widget.book;
  late LibrarySnapshot library = widget.library;
  bool busy = false;
  String? error;
  Future<void> refresh() async {
    final snapshot = LibrarySnapshot(await widget.api.call('snapshot'));
    if (mounted) {
      setState(() {
        library = snapshot;
        book = snapshot.allBooks.firstWhere((b) => b.id == book.id);
      });
    }
  }

  Future<void> run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await action();
      await refresh();
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget entry(
    String action,
    IconData icon,
    String label,
    String description,
  ) => ListTile(
    leading: Icon(icon),
    title: Text(label),
    subtitle: Text(description),
    trailing: const Icon(Icons.chevron_right),
    onTap: busy ? null : () => run(() => widget.onAction(action, book)),
  );
  @override
  Widget build(BuildContext context) {
    final metadata = book.metadata;
    final path = library.ancestors(book.project).map((p) => p.name).join(' / ');
    return Scaffold(
      appBar: AppBar(title: const Text('书籍详情')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 920),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              AqPageHeading('关于这本书', brand: false, subtitle: path),
              const SizedBox(height: 22),
              AqPanel(
                child: LayoutBuilder(
                  builder: (context, constraints) => Wrap(
                    spacing: 24,
                    runSpacing: 20,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      SizedBox(
                        width: 104,
                        height: 146,
                        child: BookCover(book: book, api: widget.api),
                      ),
                      SizedBox(
                        width:
                            (constraints.maxWidth >= 640 ||
                                constraints.maxWidth >= 280 &&
                                    MediaQuery.textScalerOf(context).scale(14) <
                                        21)
                            ? constraints.maxWidth - 128
                            : constraints.maxWidth,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SelectableText(
                              book.title,
                              style: Theme.of(context).textTheme.headlineSmall,
                            ),
                            if ((metadata['author'] as String? ?? '')
                                .isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Text(metadata['author']),
                              ),
                            const SizedBox(height: 12),
                            Text('${book.label} · ${sizeLabel(book.bytes)}'),
                            const SizedBox(height: 16),
                            if (widget.onRead != null && !book.archived)
                              FilledButton.icon(
                                onPressed: busy
                                    ? null
                                    : () => run(() => widget.onRead!(book)),
                                icon: const Icon(Icons.menu_book_outlined),
                                label: const Text('打开阅读'),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if ((metadata['summary'] as String? ?? '').isNotEmpty) ...[
                const SizedBox(height: 22),
                Text('简介', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 10),
                SelectableText(metadata['summary']),
              ],
              const SizedBox(height: 22),
              Text('文件信息', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
              AqPanel(
                child: Column(
                  children: [
                    ListTile(
                      title: const Text('格式与资源'),
                      subtitle: Text(
                        '${book.label} · ${book.pages.length} 个资源条目',
                      ),
                      trailing: Text(sizeLabel(book.bytes)),
                    ),
                    if ((metadata['publisher'] as String? ?? '').isNotEmpty)
                      ListTile(
                        title: const Text('出版社'),
                        subtitle: Text(metadata['publisher']),
                      ),
                    if ((metadata['isbn'] as String? ?? '').isNotEmpty)
                      ListTile(
                        title: const Text('ISBN'),
                        subtitle: SelectableText(metadata['isbn']),
                      ),
                    ListTile(
                      title: const Text('文件身份'),
                      subtitle: SelectableText(book.id),
                    ),
                    if ((metadata['provider'] as String? ?? '').isNotEmpty)
                      ListTile(
                        title: const Text('信息来源'),
                        subtitle: SelectableText(
                          '${metadata['provider']} · ${metadata['source_id'] ?? ''}',
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              Text('管理', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 10),
              AqPanel(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.image_search_outlined),
                      title: const Text('封面与信息匹配'),
                      subtitle: const Text('选择候选、手动编辑并确认保存'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: busy
                          ? null
                          : () => run(() async {
                              await Navigator.push<bool>(
                                context,
                                MaterialPageRoute(
                                  builder: (_) => BookMetadataScreen(
                                    book: book,
                                    api: widget.api,
                                  ),
                                ),
                              );
                            }),
                    ),
                    if (book.isComic && !book.archived)
                      entry(
                        'pages',
                        Icons.photo_library_outlined,
                        '页面管理',
                        '页序、追加与导出',
                      ),
                    entry('history', Icons.history, '历史版本', '查看修改与恢复'),
                    entry(
                      'move',
                      Icons.drive_file_move_outlined,
                      '移动到项目',
                      path,
                    ),
                    entry(
                      'rename',
                      Icons.drive_file_rename_outline,
                      '重命名',
                      '保留文件身份与阅读记录',
                    ),
                    entry(
                      'copy',
                      Icons.copy_outlined,
                      '复制到项目',
                      '新建独立书籍记录，共享原件副本',
                    ),
                    entry(
                      book.archived ? 'restore' : 'archive',
                      book.archived
                          ? Icons.restore
                          : Icons.remove_circle_outline,
                      book.archived ? '恢复到书架' : '移出书架',
                      '保留副本与个人记录',
                    ),
                  ],
                ),
              ),
              if (busy) const LinearProgressIndicator(),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: SelectableText(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
