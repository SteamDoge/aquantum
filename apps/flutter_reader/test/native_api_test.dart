// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:io';

import 'package:aquantum_reader/data/reader_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'real Rust DLL imports UTF-8, persists a paragraph and returns associated notes',
    () async {
      final library = Platform.environment['AQ_RUST_LIB'];
      if (library == null) {
        fail(
          'AQ_RUST_LIB must point to the built Rust bridge DLL for this native test',
        );
      }
      final root = await Directory.systemTemp.createTemp('aquantum-ffi-');
      addTearDown(() => root.delete(recursive: true));
      final api = RustReaderApi(root.path, libraryPath: library);
      final state = await api.call('snapshot');
      final done = await api.call('import_files', {
        'target': state['catalog']['inbox'],
        'files': [
          {'name': '真实桥接.txt', 'data': base64Encode(utf8.encode('第一段\n\n第二段'))},
        ],
      });
      final book = done['books'][0];
      await expectLater(
        api.call('unknown_operation'),
        throwsA(isA<ReaderFailure>()),
      );
      await Future.wait([
        for (var n = 0; n < 8; n++)
          api.call('save_progress', {'book': book, 'index': n % 2}),
        api.call('add_note', {'book': book, 'index': 1, 'text': '快速翻页期间的笔记'}),
      ]);
      await api.call('save_progress', {'book': book, 'index': 1});
      await api.call('add_note', {
        'book': book,
        'index': 1,
        'text': '真实 FFI 笔记',
      });
      final reopened = RustReaderApi(root.path, libraryPath: library);
      expect((await reopened.call('read_text', {'book': book}))['paragraphs'], [
        '第一段',
        '第二段',
      ]);
      expect(
        (await reopened.call(
          'snapshot',
        ))['catalog']['progress'][0]['location']['Paragraph']['index'],
        1,
      );
      expect(
        await reopened.call('notes_markdown', {'book': book}),
        contains('真实 FFI 笔记'),
      );
    },
  );
}
