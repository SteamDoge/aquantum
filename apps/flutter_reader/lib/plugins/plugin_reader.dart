// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import '../data/models.dart';
import '../data/reader_api.dart';

/// A private reading session never adds the source to the user's main library.
class PluginReaderSession {
  final RustReaderApi api;
  final Book book;
  final int position;
  PluginReaderSession(this.api, this.book, this.position);
  static final _opening = <String, Future<PluginReaderSession>>{};
  static Future<PluginReaderSession> open(
    String base,
    String name,
    Uint8List bytes, {
    String scope = '',
  }) {
    final identity = BytesBuilder(copy: false)
      ..add(utf8.encode('$scope\u0000$name\u0000'))
      ..add(bytes);
    final digest = sha256.convert(identity.takeBytes());
    final path = '$base/plugin-reader-$digest';
    return _opening.putIfAbsent(
      path,
      () => _open(path, name, bytes).whenComplete(() {
        _opening.remove(path);
      }),
    );
  }

  static Future<PluginReaderSession> _open(
    String path,
    String name,
    Uint8List bytes,
  ) async {
    final session = await Directory(path).create(recursive: true);
    final api = RustReaderApi(session.path);
    final snapshot = LibrarySnapshot(
      Map<String, dynamic>.from(await api.call('snapshot')),
    );
    if (snapshot.books.isNotEmpty) {
      final book = snapshot.books.first;
      return PluginReaderSession(api, book, snapshot.position(book));
    }
    final plan = await api.call('preview_import', {
      'target': snapshot.inbox,
      'files': [
        {'name': name, 'data': base64Encode(bytes)},
      ],
    });
    if ((plan['issues'] as List).isNotEmpty) {
      throw StateError('直接阅读的文件预览失败：${plan['issues']}');
    }
    await api.call('commit_import', {
      'task': plan['task'],
      'base_revision': plan['base_revision'],
      'target': plan['target'],
      'projects': [
        for (final p in plan['projects']) {'id': p['id'], 'name': p['name']},
      ],
      'books': [
        for (final b in plan['books'])
          {
            'id': b['id'],
            'title': b['title'],
            'project': b['project'],
            'resources': [for (final r in b['resources']) r['id']],
          },
      ],
      'skip_issues': false,
      'append': null,
    });
    final opened = LibrarySnapshot(
      Map<String, dynamic>.from(await api.call('snapshot')),
    );
    if (opened.books.isEmpty) throw StateError('此文件没有可阅读内容');
    return PluginReaderSession(
      api,
      opened.books.first,
      opened.position(opened.books.first),
    );
  }
}
