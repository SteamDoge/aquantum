// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

const _documents = MethodChannel('cn.aquantum/documents');

class _DocumentFailure implements Exception {
  final String message;
  _DocumentFailure(this.message);
  @override
  String toString() => message;
}

Future<T?> _invokeDocument<T>(
  String method, [
  Map<String, Object?>? args,
]) async {
  try {
    return await _documents.invokeMethod<T>(method, args);
  } on PlatformException catch (error) {
    throw _DocumentFailure(error.message ?? '系统存储操作失败，原文件和暂存保留。');
  }
}

Future<String?> pickImportDirectory() => Platform.isAndroid
    ? _invokeDocument<String>('importTree')
    : FilePicker.platform.getDirectoryPath(dialogTitle: '选择导入文件夹');

/// Rust creates and verifies a new local file first. Android publishes through
/// the selected document provider and verifies it again before reporting saved.
class DocumentOutput {
  final String path;
  final String? job;
  const DocumentOutput(this.path, [this.job]);
  String file(String name) => '$path/$name';
  Future<String> publish(String name) async => job == null
      ? file(name)
      : (await _invokeDocument<String>('publish', {'job': job, 'name': name}))!;
}

Future<DocumentOutput?> pickDocumentOutput(String title) async {
  if (Platform.isAndroid) {
    final value = await _invokeDocument<dynamic>('outputTree');
    return value == null
        ? null
        : DocumentOutput(value['path'] as String, value['job'] as String);
  }
  final path = await FilePicker.platform.getDirectoryPath(dialogTitle: title);
  return path == null ? null : DocumentOutput(path);
}

Future<List<Map<String, dynamic>>> pendingDocumentOutputs() async =>
    Platform.isAndroid
    ? (await _invokeDocument<List<dynamic>>('pending') ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList()
    : [];

Future<String?> retryDocumentOutput(String source) async {
  final output = await pickDocumentOutput('重新选择保存目录');
  if (output == null) return null;
  return _invokeDocument<String>('retry', {
    'job': output.job,
    'source': source,
  });
}

Future<Map<String, dynamic>?> retainedDocumentIo() async {
  if (!Platform.isAndroid) return null;
  final value = await _invokeDocument<dynamic>('retained');
  return Map<String, dynamic>.from(value as Map);
}
