// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';

class NoteDialog extends StatefulWidget {
  const NoteDialog({super.key});
  @override
  State<NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<NoteDialog> {
  final controller = TextEditingController();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('记下这一刻'),
    content: SizedBox(
      width: 480,
      child: TextField(
        controller: controller,
        autofocus: true,
        minLines: 4,
        maxLines: 8,
        decoration: const InputDecoration(
          labelText: '笔记正文',
          hintText: '想法、书摘，或留给自己的问题',
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, controller.text),
        child: const Text('保存笔记'),
      ),
    ],
  );
}
