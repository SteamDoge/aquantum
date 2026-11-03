// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../data/book_metadata.dart';
import '../data/models.dart';
import '../data/reader_api.dart';
import '../design/widgets.dart';

class BookMetadataScreen extends StatefulWidget {
  final Book book;
  final ReaderApi api;
  final BookMetadataSource? source;
  const BookMetadataScreen({
    super.key,
    required this.book,
    required this.api,
    this.source,
  });
  @override
  State<BookMetadataScreen> createState() => _BookMetadataScreenState();
}

class _BookMetadataScreenState extends State<BookMetadataScreen> {
  late final source = widget.source ?? BookMetadataSource();
  late final query = TextEditingController(text: widget.book.title);
  late final title = TextEditingController(text: widget.book.title);
  late final author = TextEditingController(
    text: widget.book.metadata['author'] as String? ?? '',
  );
  late final publisher = TextEditingController(
    text: widget.book.metadata['publisher'] as String? ?? '',
  );
  late final isbn = TextEditingController(
    text: widget.book.metadata['isbn'] as String? ?? '',
  );
  late final summary = TextEditingController(
    text: widget.book.metadata['summary'] as String? ?? '',
  );
  List<BookMatch>? matches;
  BookMatch? selected;
  Uint8List? cover;
  bool busy = false, clearCover = false;
  String? error;
  @override
  void dispose() {
    source.close();
    for (final controller in [query, title, author, publisher, isbn, summary]) {
      controller.dispose();
    }
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
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> validateCover(Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
      throw const FormatException('封面须小于8MiB');
    }
    final codec = await ui.instantiateImageCodec(bytes, targetWidth: 512);
    try {
      final frame = await codec.getNextFrame();
      frame.image.dispose();
    } finally {
      codec.dispose();
    }
  }

  Future<void> choose(BookMatch candidate) => run(() async {
    final result = await source.detail(candidate);
    if (!mounted) return;
    setState(() {
      selected = result;
      title.text = result.title;
      if (result.author.isNotEmpty) author.text = result.author;
      if (result.publisher.isNotEmpty) publisher.text = result.publisher;
      if (result.isbn.isNotEmpty) isbn.text = result.isbn;
      if (result.summary.isNotEmpty) summary.text = result.summary;
      cover = null;
      clearCover = false;
    });
  });
  Future<void> fetchCover() => run(() async {
    final id = selected?.coverId;
    if (id == null) return;
    final bytes = await source.cover(id);
    await validateCover(bytes);
    if (mounted) {
      setState(() {
        cover = bytes;
        clearCover = false;
      });
    }
  });
  Future<void> pickCover() => run(() async {
    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp'],
      withData: false,
    );
    if (picked == null) return;
    final file = picked.files.single;
    if (file.size > 8 * 1024 * 1024) throw const FormatException('封面须小于8MiB');
    if (file.path != null &&
        await File(file.path!).length() > 8 * 1024 * 1024) {
      throw const FormatException('封面须小于8MiB');
    }
    final bytes =
        file.bytes ??
        (file.path == null ? null : await File(file.path!).readAsBytes());
    if (bytes == null) throw const FormatException('无法读取封面');
    await validateCover(bytes);
    if (mounted) {
      setState(() {
        cover = bytes;
        clearCover = false;
      });
    }
  });
  Future<void> save() => run(() async {
    if (title.text.trim().isEmpty) throw const FormatException('书名不能为空');
    await widget.api.call('update_book_metadata', {
      'book': widget.book.id,
      'revision': widget.book.revision,
      'title': title.text.trim(),
      'metadata': {
        ...widget.book.metadata,
        ...?selected?.metadata,
        'author': author.text.trim(),
        'publisher': publisher.text.trim(),
        'isbn': isbn.text.trim(),
        'summary': summary.text.trim(),
      },
      'clear_cover': clearCover,
      if (cover != null) 'cover_data': base64Encode(cover!),
    });
    if (mounted) Navigator.pop(context, true);
  });
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('封面与信息')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const AqPageHeading(
              '让每本书完整',
              brand: false,
              subtitle: '信息匹配 / 确认后保存',
            ),
            const SizedBox(height: 22),
            AqPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('在线匹配 · Open Library'),
                  const SizedBox(height: 10),
                  const Text('只在搜索时发送输入的书名、作者或ISBN；结果可能不完整，请核对版本。'),
                  const SizedBox(height: 16),
                  TextField(
                    controller: query,
                    maxLength: 256,
                    decoration: const InputDecoration(labelText: '书名、作者或ISBN'),
                    onSubmitted: busy
                        ? null
                        : (_) => run(() async {
                            final result = await source.search(query.text);
                            if (mounted) setState(() => matches = result);
                          }),
                  ),
                  FilledButton.icon(
                    onPressed: busy
                        ? null
                        : () => run(() async {
                            final result = await source.search(query.text);
                            if (mounted) setState(() => matches = result);
                          }),
                    icon: const Icon(Icons.search),
                    label: const Text('搜索候选'),
                  ),
                  if (matches?.isEmpty == true)
                    const Padding(
                      padding: EdgeInsets.only(top: 16),
                      child: Text('没有找到候选。可修改关键词，或在下方手动填写。'),
                    ),
                  for (final candidate in matches ?? <BookMatch>[])
                    ListTile(
                      key: ValueKey('metadata-candidate-${candidate.sourceId}'),
                      selected: selected?.sourceId == candidate.sourceId,
                      title: Text(candidate.title),
                      subtitle: Text('作品贡献者：${candidate.author}'),
                      trailing: Icon(
                        selected?.sourceId == candidate.sourceId
                            ? Icons.check_circle
                            : Icons.chevron_right,
                      ),
                      onTap: busy ? null : () => choose(candidate),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            AqPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('核对信息', style: Theme.of(context).textTheme.titleMedium),
                  const Text('候选缺少的字段会保留现有信息，也可以手动编辑或清空。'),
                  for (final field in [
                    (title, '书名'),
                    (author, '作者 / 贡献者'),
                    (publisher, '出版社'),
                    (isbn, 'ISBN'),
                    (summary, '简介'),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: TextField(
                        controller: field.$1,
                        maxLines: field.$1 == summary ? 4 : 1,
                        maxLength: field.$1 == summary
                            ? 20000
                            : field.$1 == title
                            ? 512
                            : 2048,
                        decoration: InputDecoration(labelText: field.$2),
                      ),
                    ),
                  if (selected != null)
                    SelectableText('来源：Open Library · ${selected!.sourceId}'),
                  const SizedBox(height: 16),
                  if (cover != null)
                    SizedBox(
                      height: 180,
                      child: Image.memory(cover!, fit: BoxFit.contain),
                    ),
                  Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: [
                      if (selected?.coverId != null)
                        OutlinedButton.icon(
                          onPressed: busy ? null : fetchCover,
                          icon: const Icon(Icons.image_search),
                          label: const Text('使用此版本封面'),
                        ),
                      OutlinedButton.icon(
                        onPressed: busy ? null : pickCover,
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        label: const Text('选择本地封面'),
                      ),
                      if (cover != null ||
                          widget.book.metadata['cover'] != null)
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => setState(() {
                                  cover = null;
                                  clearCover = true;
                                }),
                          child: const Text('恢复默认封面'),
                        ),
                    ],
                  ),
                  if (clearCover) const Text('保存后使用默认封面；历史封面仍可随修改记录恢复。'),
                  if (cover == null && !clearCover)
                    const Text('未选择新封面时保留当前封面。'),
                ],
              ),
            ),
            const SizedBox(height: 16),
            if (busy) const LinearProgressIndicator(),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: SelectableText(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            FilledButton.icon(
              onPressed: busy ? null : save,
              icon: const Icon(Icons.check),
              label: const Text('确认并保存'),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    ),
  );
}
