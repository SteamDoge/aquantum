// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aquantum_reader/data/models.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/widgets/book_cover.dart';
import 'package:aquantum_reader/widgets/comic_page.dart';

Book comic(String id) => Book({
  'id': id,
  'project': 'inbox',
  'title': id,
  'format': 'Comic',
  'revision': 1,
  'pages': [
    {
      'id': '$id-page',
      'resource': {'id': '$id-resource', 'bytes': 1},
    },
  ],
});

class ImageApi implements ReaderApi {
  int reads = 0;
  Future<String> Function() response;
  ImageApi(this.response);
  @override
  Future<dynamic> call(String method, [Map<String, dynamic> args = const {}]) {
    expect(method, 'read_image');
    reads++;
    return response();
  }
}

void main() {
  test(
    'overlapping prefetch and visible reads share work; failures can retry',
    () async {
      final book = comic('inflight');
      final pending = Completer<String>();
      final api = ImageApi(() => pending.future);
      final first = ComicPage.load(api, book, 'inflight-page');
      final second = ComicPage.load(api, book, 'inflight-page');
      expect(api.reads, 1);
      pending.complete(base64Encode([1, 2, 3]));
      expect(identical(await first, await second), isTrue);
      final retryBook = comic('retry');
      api.response = () => Future.error(StateError('transient'));
      await expectLater(
        ComicPage.load(api, retryBook, 'retry-page'),
        throwsStateError,
      );
      api.response = () async => base64Encode([4, 5]);
      expect(await ComicPage.load(api, retryBook, 'retry-page'), [4, 5]);
      expect(api.reads, 3);
    },
  );

  test(
    'compressed cache evicts by bytes without changing large page content',
    () async {
      final bytes = Uint8List(12 * 1024 * 1024)..[0] = 42;
      final encoded = base64Encode(bytes);
      final api = ImageApi(() async => encoded);
      for (final id in ['budget-a', 'budget-b', 'budget-c']) {
        final data = await ComicPage.load(api, comic(id), '$id-page');
        expect(data, bytes);
      }
      expect(ComicPage.peek(comic('budget-a'), 'budget-a-page'), isNull);
      expect(
        ComicPage.peek(comic('budget-b'), 'budget-b-page')!.length,
        bytes.length,
      );
      expect(
        ComicPage.peek(comic('budget-c'), 'budget-c-page')!.length,
        bytes.length,
      );
    },
  );

  testWidgets('cover reuses reader bytes and follows a replaced book', (
    tester,
  ) async {
    const png =
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=';
    final api = ImageApi(() async => png);
    final first = comic('cover-first');
    await ComicPage.load(api, first, 'cover-first-page');
    Future<void> show(Book book) => tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 100,
          height: 120,
          child: BookCover(book: book, api: api),
        ),
      ),
    );
    await show(first);
    await tester.pumpAndSettle();
    expect(api.reads, 1);
    await show(comic('cover-next'));
    await tester.pumpAndSettle();
    expect(api.reads, 2);
  });
}
