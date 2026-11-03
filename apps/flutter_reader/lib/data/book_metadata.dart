// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class BookMatch {
  final String title, author, publisher, isbn, summary, sourceId;
  final int? coverId;
  const BookMatch({
    required this.title,
    required this.author,
    this.publisher = '',
    this.isbn = '',
    this.summary = '',
    required this.sourceId,
    this.coverId,
  });
  Map<String, dynamic> get metadata => {
    'author': author,
    'publisher': publisher,
    'isbn': isbn,
    'summary': summary,
    'provider': 'Open Library',
    'source_id': sourceId,
  };
}

/// Public bibliographic queries run only after the user presses Search.
/// Edition fields are fetched together: never combine a work's unrelated
/// editions into a fabricated ISBN/publisher/cover combination.
class BookMetadataSource {
  final HttpClient client;
  BookMetadataSource({HttpClient? client}) : client = client ?? HttpClient() {
    this.client.connectionTimeout = const Duration(seconds: 15);
    this.client.userAgent = 'AQuantumReader/0.0.12 (book metadata lookup)';
  }
  void close() => client.close(force: true);
  Future<Uint8List> read(Uri uri, int limit, [int redirects = 0]) async {
    if (uri.scheme != 'https' ||
        !(uri.host == 'openlibrary.org' ||
            uri.host == 'covers.openlibrary.org' ||
            uri.host == 'archive.org' ||
            uri.host.endsWith('.archive.org'))) {
      throw const FormatException('书目源跳转到了不支持的地址');
    }
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 15));
    request.followRedirects = false;
    final response = await request.close().timeout(const Duration(seconds: 20));
    if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
      final location = response.headers.value(HttpHeaders.locationHeader);
      await response.drain<void>().timeout(const Duration(seconds: 5));
      if (location == null || redirects >= 4) {
        throw const FormatException('书目源跳转无效');
      }
      return read(uri.resolve(location), limit, redirects + 1);
    }
    if (response.statusCode != 200) {
      await response.drain<void>().timeout(const Duration(seconds: 5));
      throw HttpException('书目源返回 ${response.statusCode}，请稍后重试');
    }
    if (response.contentLength > limit) {
      await response.listen(null).cancel();
      throw const FormatException('书目源响应过大');
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response.timeout(const Duration(seconds: 20))) {
      bytes.add(chunk);
      if (bytes.length > limit) throw const FormatException('书目源响应过大');
    }
    return bytes.takeBytes();
  }

  Future<Map<String, dynamic>> json(Uri uri) async {
    final data = jsonDecode(utf8.decode(await read(uri, 2 * 1024 * 1024)));
    if (data is! Map<String, dynamic>) throw const FormatException('书目源数据无效');
    return data;
  }

  Future<List<BookMatch>> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty || trimmed.length > 256) {
      throw const FormatException('请输入书名、作者或ISBN（最多256字）');
    }
    final result = await json(
      Uri.https('openlibrary.org', '/search.json', {
        // The current service rejects bare q shorter than three characters;
        // short CJK book titles remain valid through its title field.
        trimmed.runes.length < 3 ? 'title' : 'q': trimmed,
        'limit': '10',
        'lang': 'zh',
        'fields': 'key,title,author_name,editions,editions.key,editions.title',
      }),
    );
    final docs = result['docs'];
    if (docs is! List) throw const FormatException('书目源未返回有效候选');
    final matches = <BookMatch>[];
    for (final doc in docs.whereType<Map>()) {
      final editions = doc['editions'];
      final editionDocs = editions is Map ? editions['docs'] : null;
      final edition = editionDocs is List && editionDocs.isNotEmpty
          ? editionDocs.first
          : null;
      final key = edition is Map ? edition['key'] : null;
      final title = edition is Map ? edition['title'] : null;
      if (key is! String ||
          !RegExp(r'^/books/OL[0-9]+M$').hasMatch(key) ||
          title is! String) {
        continue;
      }
      matches.add(
        BookMatch(
          title: title,
          author: strings(doc['author_name']).join('、'),
          sourceId: key,
        ),
      );
    }
    return matches;
  }

  Future<BookMatch> detail(BookMatch match) async {
    if (!RegExp(r'^/books/OL[0-9]+M$').hasMatch(match.sourceId)) {
      throw const FormatException('书目编号无效');
    }
    final item = await json(
      Uri.https('openlibrary.org', '${match.sourceId}.json'),
    );
    final authorNames = <String>[];
    final authors = item['authors'];
    if (authors is List) {
      if (authors.length > 12) throw const FormatException('此版本作者过多，请手动核对信息');
      for (final author in authors.whereType<Map>()) {
        final key = author['key'];
        if (key is! String || !RegExp(r'^/authors/OL[0-9]+A$').hasMatch(key)) {
          continue;
        }
        final record = await json(Uri.https('openlibrary.org', '$key.json'));
        if (record['name'] is String) authorNames.add(record['name'] as String);
      }
    }
    final isbn = strings(item['isbn_13']);
    final fallbackIsbn = strings(item['isbn_10']);
    final description = item['description'];
    final summary = description is String
        ? description
        : description is Map && description['value'] is String
        ? description['value'] as String
        : '';
    final covers = item['covers'];
    final cover = covers is List
        ? covers.whereType<int>().where((id) => id > 0).firstOrNull
        : null;
    return BookMatch(
      title: item['title'] is String ? item['title'] : match.title,
      author: authorNames.join('、'),
      publisher: strings(item['publishers']).join('、'),
      isbn: isbn.firstOrNull ?? fallbackIsbn.firstOrNull ?? '',
      summary: summary,
      sourceId: match.sourceId,
      coverId: cover,
    );
  }

  Future<Uint8List> cover(int id) {
    if (id <= 0) throw const FormatException('封面编号无效');
    return read(
      Uri.https('covers.openlibrary.org', '/b/id/$id-L.jpg', {
        'default': 'false',
      }),
      8 * 1024 * 1024,
    );
  }

  static List<String> strings(dynamic value) =>
      value is List ? value.whereType<String>().toList() : [];
}
