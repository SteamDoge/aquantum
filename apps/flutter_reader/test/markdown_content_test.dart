// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:aquantum_reader/data/models.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/formats/markdown_content.dart';
import 'package:aquantum_reader/formats/markdown_document.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

class _States implements ReaderApi {
  final Map<String, Map<String, dynamic>> values = {};
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (method == 'document_interactions') return values.values.toList();
    if (method == 'set_document_interaction') {
      final key = '${args['kind']}:${args['node']}';
      final record = {
        ...args,
        'actor': 'actor',
        'revision': (args['revision'] as int) + 1,
      };
      values[key] = record;
      return record;
    }
    throw StateError(method);
  }
}

final book = Book({
  'id': 'book',
  'project': 'inbox',
  'title': 'MD',
  'format': 'Markdown',
  'revision': 1,
  'pages': [
    {
      'id': 'page',
      'resource': {'id': 'source', 'bytes': 1},
    },
  ],
});
void main() {
  test(
    'syntax ranges preserve fenced blank lines, nested tasks and duplicate identities',
    () {
      const source =
          '# Heading\n\n- [ ] duplicate\n  - [x] nested\n- [ ] duplicate\n\n```dart\nfirst();\n\nsecond();\n```\n\n<details>\n<summary>Details</summary>\n\ninside\n\n</details>';
      final first = MarkdownDocument.parse(source);
      final again = MarkdownDocument.parse(source);
      expect(
        first.blocks
            .map((b) => b.source)
            .any((s) => s.contains('first();\n\nsecond();')),
        isTrue,
      );
      expect(first.blocks.last.source, contains('</details>'));
      expect(first.blocks.first.level, 1);
      final tasks = first.blocks.expand((b) => b.tasks).toList();
      expect(tasks.length, 3);
      expect(tasks.toSet().length, 3);
      expect(again.blocks.expand((b) => b.tasks), tasks);
    },
  );
  testWidgets(
    'duplicate tasks toggle independently and restore without editing Markdown',
    (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const source = '- [ ] duplicate\n- [ ] duplicate';
      final document = MarkdownDocument.parse(source);
      final api = _States();
      Widget content() => MaterialApp(
        home: Scaffold(
          body: MarkdownContent(
            key: UniqueKey(),
            api: api,
            book: book,
            document: document,
            controller: ItemScrollController(),
            position: 0,
            onPosition: (_) {},
            onSelectionActive: (_) {},
            fontSize: 20,
            lineHeight: 1.6,
            margin: 20,
          ),
        ),
      );
      await tester.pumpWidget(content());
      await tester.pumpAndSettle();
      expect(find.byType(Checkbox), findsNWidgets(2));
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).first).value,
        isTrue,
      );
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).last).value,
        isFalse,
      );
      await tester.pumpWidget(content());
      await tester.pumpAndSettle();
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).first).value,
        isTrue,
      );
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).last).value,
        isFalse,
      );
      expect(document.source, source);
      expect(tester.takeException(), isNull);
    },
  );
}
