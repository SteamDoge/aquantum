// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'package:aquantum_reader/data/models.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/reader/reader_shell.dart';
import 'package:aquantum_reader/reader/text_pagination.dart';
import 'package:aquantum_reader/screens/reader_screen.dart';
import 'package:aquantum_reader/widgets/reader_settings.dart';
import 'package:aquantum_reader/widgets/text_reader.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android real Rust import and long single paragraph TXT opens in both modes',
    (tester) async {
      final support = await getApplicationSupportDirectory();
      final api = RustReaderApi(
        '${support.path}/qa-txt-opening-${DateTime.now().microsecondsSinceEpoch}',
      );
      final before = await api.call('snapshot');
      final source = List.filled(65000, '儒林外史长篇阅读测试。人物故事正文。').join();
      await api.call('import_files', {
        'target': before['catalog']['inbox'],
        'files': [
          {'name': '长篇单段落回归样例.txt', 'data': base64Encode(utf8.encode(source))},
        ],
      });
      final snapshot = LibrarySnapshot(
        Map<String, dynamic>.from(await api.call('snapshot')),
      );
      final book = snapshot.books.single;
      final result = await api.call('read_text', {'book': book.id});
      expect((result['paragraphs'] as List).single, source);
      for (final paged in [true, false]) {
        final settings = ReaderPreferences()..textPaged = paged;
        await settings.save(bookId: book.id);
        final watch = Stopwatch()..start();
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderScreen(api: api, book: book, initialPosition: 0),
          ),
        );
        var ready = false;
        for (var i = 0; i < 1800; i++) {
          await tester.pump(const Duration(milliseconds: 20));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          ready = paged
              ? find.byType(PagedTextReader).evaluate().isNotEmpty
              : find.byType(TextReader).evaluate().isNotEmpty;
          if (ready) break;
        }
        expect(ready, isTrue, reason: 'long TXT ready, paged=$paged');
        expect(tester.takeException(), isNull);
        final shell = tester.widget<ReaderShell>(find.byType(ReaderShell));
        if (paged) expect(shell.adapter.count, greaterThan(100));
        await tester.drag(
          find.byType(ReaderShell),
          paged ? const Offset(-250, 0) : const Offset(70, -250),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        debugPrint(
          'TXT_NATIVE paged=$paged chars=${source.length} readyMs=${watch.elapsedMilliseconds} count=${shell.adapter.count}',
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      }
      await api.idle;
    },
  );
}
