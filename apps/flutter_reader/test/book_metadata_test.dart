// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aquantum_reader/data/book_metadata.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/data/models.dart';
import 'package:aquantum_reader/screens/book_metadata_screen.dart';
import 'package:aquantum_reader/design/theme.dart';
import 'reader_shell_test.dart' show book;

class MetadataSourceFixture extends BookMetadataSource {
  final requests = <Uri>[];
  @override
  Future<Uint8List> read(Uri uri, int limit, [int redirects = 0]) async {
    requests.add(uri);
    if (uri.path.startsWith('/authors/')) {
      return Uint8List.fromList(utf8.encode(jsonEncode({'name': '此版本作者'})));
    }
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode(
          uri.path == '/search.json'
              ? {
                  'docs': [
                    {
                      'title': '聚合书名',
                      'author_name': ['真实作者'],
                      'isbn': ['错误聚合ISBN'],
                      'publisher': ['错误聚合出版社'],
                      'editions': {
                        'docs': [
                          {'key': '/books/OL123M', 'title': '具体版本'},
                        ],
                      },
                    },
                  ],
                }
              : {
                  'title': '确认版本',
                  'authors': [
                    {'key': '/authors/OL1A'},
                  ],
                  'publishers': ['此版本出版社'],
                  'isbn_13': ['9781234567890'],
                  'covers': [12],
                },
        ),
      ),
    );
  }
}

class MetadataApiFixture implements ReaderApi {
  final writes = <Map<String, dynamic>>[];
  bool fail = false;
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (fail) throw StateError('版本冲突');
    if (method != 'update_book_metadata') throw StateError(method);
    writes.add(args);
    return null;
  }
}

class IncompleteMetadataSource extends MetadataSourceFixture {
  @override
  Future<BookMatch> detail(BookMatch match) async =>
      BookMatch(title: '新版本书名', author: '', sourceId: match.sourceId);
}

void main() {
  testWidgets('an incomplete candidate retains existing descriptive fields', (
    tester,
  ) async {
    final original = book('Txt');
    final existing = Book({
      'id': original.id,
      'project': original.project,
      'title': original.title,
      'format': original.format,
      'revision': original.revision,
      'pages': original.pages,
      'metadata': {
        'author': '原作者',
        'publisher': '原出版社',
        'isbn': '原ISBN',
        'summary': '原简介',
      },
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: readerTheme(Brightness.light),
        home: BookMetadataScreen(
          book: existing,
          api: MetadataApiFixture(),
          source: IncompleteMetadataSource(),
        ),
      ),
    );
    await tester.tap(find.text('搜索候选'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('具体版本'));
    await tester.pumpAndSettle();
    for (final value in ['原作者', '原出版社', '原ISBN', '原简介']) {
      expect(find.widgetWithText(TextField, value), findsOneWidget);
    }
    expect(find.widgetWithText(TextField, '新版本书名'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  test(
    'search keeps edition identity and never borrows ISBN from other editions',
    () async {
      final source = MetadataSourceFixture();
      addTearDown(source.close);
      final matches = await source.search('三体');
      expect(source.requests.single.queryParameters['title'], '三体');
      expect(matches.single.isbn, isEmpty);
      final edition = await source.detail(matches.single);
      expect(edition.sourceId, '/books/OL123M');
      expect(edition.isbn, '9781234567890');
      expect(edition.publisher, '此版本出版社');
      expect(edition.author, '此版本作者');
      expect(edition.author, isNot('真实作者'));
      expect(edition.metadata['provider'], 'Open Library');
    },
  );
  testWidgets(
    'candidate selection does not save before explicit confirmation; failed save retains edits',
    (tester) async {
      final api = MetadataApiFixture();
      final source = MetadataSourceFixture();
      await tester.pumpWidget(
        MaterialApp(
          theme: readerTheme(Brightness.light),
          home: BookMetadataScreen(book: book('Txt'), api: api, source: source),
        ),
      );
      expect(source.requests, isEmpty);
      await tester.tap(find.text('搜索候选'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('具体版本'));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
      expect(find.widgetWithText(TextField, '确认版本'), findsOneWidget);
      api.fail = true;
      await tester.scrollUntilVisible(
        find.text('确认并保存'),
        400,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('确认并保存'));
      await tester.pumpAndSettle();
      expect(find.textContaining('版本冲突'), findsOneWidget);
      expect(api.writes, isEmpty);
      api.fail = false;
      await tester.tap(find.text('确认并保存'));
      await tester.pumpAndSettle();
      expect(api.writes.single['revision'], book('Txt').revision);
      expect(api.writes.single['title'], '确认版本');
      expect(api.writes.single['cover_data'], isNull);
      expect(api.writes.single['clear_cover'], false);
      expect(api.writes.single['metadata']['publisher'], '此版本出版社');
    },
  );
}
