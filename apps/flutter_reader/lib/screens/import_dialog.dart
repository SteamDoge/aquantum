// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import '../data/reader_api.dart';
import '../data/picked_paths.dart';
import '../data/document_io.dart';
import 'import_preview.dart';

Future<bool> pickAndImport(
  BuildContext context,
  ReaderApi api,
  String target,
  String targetName, {
  Map<String, dynamic>? append,
}) async {
  final source = await showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (c) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.insert_drive_file_outlined),
            title: Text(append == null ? '选择文件 / ZIP / CBZ' : '选择追加图片'),
            onTap: () => Navigator.pop(c, 'files'),
          ),
          if (append == null)
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('选择整个文件夹'),
              subtitle: const Text('递归保留子项目，每层图片合为漫画'),
              onTap: () => Navigator.pop(c, 'folder'),
            ),
          if (append == null)
            ListTile(
              leading: const Icon(Icons.restore),
              title: const Text('继续导入任务'),
              onTap: () => Navigator.pop(c, 'resume'),
            ),
        ],
      ),
    ),
  );
  if (source == null || !context.mounted) return false;
  Map<String, dynamic> plan;
  if (source == 'resume') {
    final tasks = (await api.call('import_tasks') as List)
        .where((t) => t['status'] == 'pending')
        .toList();
    if (!context.mounted) return false;
    final task = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('继续导入任务'),
        content: SizedBox(
          width: 460,
          child: tasks.isEmpty
              ? const Text('没有待处理任务。')
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final t in tasks)
                      ListTile(
                        title: Text('${t['books']} 项内容 · ${t['issues']} 项异常'),
                        subtitle: Text(t['task']),
                        onTap: () => Navigator.pop(c, t['task']),
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (task == null) return false;
    plan = Map<String, dynamic>.from(
      await api.call('import_plan', {'task': task}),
    );
  } else if (source == 'folder') {
    final path = await pickImportDirectory();
    if (path == null) return false;
    plan = Map<String, dynamic>.from(
      await api.call('preview_import', {
        'target': target,
        'paths': [path],
      }),
    );
  } else {
    final files = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: false,
      withReadStream: true,
      type: FileType.custom,
      allowedExtensions: append == null
          ? [
              'txt',
              'md',
              'markdown',
              'jpg',
              'jpeg',
              'png',
              'gif',
              'webp',
              'zip',
              'cbz',
              'pdf',
              'epub',
              'mobi',
              'azw3',
              'fb2',
            ]
          : ['jpg', 'jpeg', 'png', 'gif', 'webp'],
    );
    if (files == null || files.files.isEmpty) return false;
    if (files.files.every((f) => f.path != null)) {
      plan = Map<String, dynamic>.from(
        await api.call('preview_import', {
          'target': target,
          'paths': [
            for (final f in files.files) await pickedCachePath(f.path!),
          ],
        }),
      );
    } else {
      final payload = <Map<String, dynamic>>[];
      var total = 0;
      for (final file in files.files) {
        final stream = file.readStream;
        if (stream == null) throw ReaderFailure('无法读取 ${file.name}，请重新选择。');
        final data = BytesBuilder(copy: false);
        await for (final chunk in stream) {
          total += chunk.length;
          if (total > 32 * 1024 * 1024) {
            throw ReaderFailure('文件流每批最多 32 MiB，请分批选择。');
          }
          data.add(chunk);
        }
        payload.add({
          'name': file.name,
          'data': base64Encode(data.takeBytes()),
        });
      }
      plan = Map<String, dynamic>.from(
        await api.call('preview_import', {'target': target, 'files': payload}),
      );
    }
  }
  if (!context.mounted) return false;
  return await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (_) =>
              ImportPreviewScreen(api: api, plan: plan, append: append),
        ),
      ) ==
      true;
}
