// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:aquantum_reader/data/models.dart';
import 'package:aquantum_reader/reader/reader_contract.dart';
import 'package:aquantum_reader/reader/reader_renderers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Book textBook() => Book({
  'id': 'book-outline',
  'project': 'inbox',
  'title': '带目录的文本',
  'format': 'txt',
  'revision': 7,
  'pages': [
    {
      'id': 'p0',
      'resource': {'id': 'res-1', 'bytes': 1},
    },
  ],
});

TextReaderAdapter adapter(List<ReaderOutlineEntry> entries) =>
    TextReaderAdapter(
      book: textBook(),
      position: 0,
      status: 'ok',
      content: (_) => const SizedBox(),
      onGo: (_) {},
      locked: () => false,
      paragraphs: const ['第一章 起风', '正文。', '第二章 归途'],
      entries: entries,
    );

void main() {
  test('a missing or malformed outline degrades to no outline', () {
    expect(ReaderOutlineEntry.parse(null), isEmpty);
    expect(ReaderOutlineEntry.parse('not a list'), isEmpty);
    expect(
      ReaderOutlineEntry.parse([
        {'index': '0', 'title': '被忽略'},
        {'index': -1, 'title': '被忽略'},
        {'index': 3, 'title': ''},
        'garbage',
      ]),
      isEmpty,
    );
  });

  test('parsed entries keep their heading level and a default one', () {
    final entries = ReaderOutlineEntry.parse([
      {'index': 0, 'title': '第一章 起风', 'level': 1},
      {'index': 2, 'title': '小节', 'level': 3},
      {'index': 1, 'title': '无级别'},
    ]);
    expect(entries.map((e) => e.title), ['第一章 起风', '小节', '无级别']);
    expect(entries.map((e) => e.level), [1, 3, 1]);
    expect(entries.map((e) => e.index), [0, 2, 1]);
  });

  test('the adapter exposes headings and jumps to their paragraph', () {
    final a = adapter(const [
      ReaderOutlineEntry(0, '第一章 起风', 1),
      ReaderOutlineEntry(2, '第二章 归途', 1),
    ]);
    expect(a, isA<OutlineReaderAdapter>());
    expect(a.outline.length, 2);
    expect(a.capabilities.navigationLabel, '目录');
    final target = a.outline[1];
    expect(target.index, 2);
    expect(target.label, '第二章 归途');
    // The outline id must resolve through the same path as a location id, so a
    // tapped heading and a saved bookmark agree.
    expect(a.resolveLocation(target.id), 2);
    expect(target.id, a.location(2).id);
  });

  test('outline entries outside the paragraph range are dropped', () {
    final a = adapter(const [
      ReaderOutlineEntry(0, '在范围内', 1),
      ReaderOutlineEntry(9, '越界', 1),
    ]);
    expect(a.outline.length, 1);
    expect(a.outline.single.label, '在范围内');
  });

  test('without headings the panel keeps numbered paragraphs', () {
    final a = adapter(const []);
    expect(a.outline, isEmpty);
    expect(a.capabilities.navigationLabel, '内容导航（段落）');
    expect(a.count, 3);
  });
}
