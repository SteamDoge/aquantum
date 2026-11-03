// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'reader_api.dart';

/// The managed copy of a document the reader is about to lay out.
///
/// The bridge hands back the path of the imported copy in the library, never
/// the user's original file: importing copies first, and that copy is what the
/// engine reads and what every saved anchor refers to.
class DocumentResource {
  final String book, resource, name, format, path;
  final int revision, bytes;
  final String sha256;
  const DocumentResource({
    required this.book,
    required this.resource,
    required this.name,
    required this.format,
    required this.path,
    required this.revision,
    required this.bytes,
    required this.sha256,
  });

  factory DocumentResource.parse(Map<dynamic, dynamic> json) =>
      DocumentResource(
        book: json['book']?.toString() ?? '',
        resource: json['resource']?.toString() ?? '',
        name: json['name']?.toString() ?? '',
        format: json['format']?.toString() ?? '',
        path: json['path']?.toString() ?? '',
        revision: (json['revision'] as num?)?.toInt() ?? 0,
        bytes: (json['bytes'] as num?)?.toInt() ?? 0,
        sha256: json['sha256']?.toString() ?? '',
      );

  Future<Uint8List> read() async {
    final file = File(path);
    if (!await file.exists()) throw ReaderFailure('正文副本不存在：$path');
    if (await file.length() != bytes) throw ReaderFailure('正文副本大小改变');
    final data = await file.readAsBytes();
    if (crypto.sha256.convert(data).toString() != sha256.toLowerCase()) {
      throw ReaderFailure('正文副本校验失败');
    }
    return data;
  }
}

/// Asks the core for the document's managed bytes, then reads them.
Future<DocumentResource> loadDocument(ReaderApi api, String book) async {
  final json = await api.call('document_resource', {'book': book});
  if (json is! Map) throw ReaderFailure('无法读取文档资源');
  return DocumentResource.parse(json);
}
