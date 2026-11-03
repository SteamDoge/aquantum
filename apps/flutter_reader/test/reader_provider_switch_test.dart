// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:aquantum_reader/formats/reader_provider_preferences.dart';
import 'package:aquantum_reader/main.dart';
import 'library_test.dart' show TestApi;
import 'package:aquantum_reader/data/models.dart';
import 'package:aquantum_reader/formats/reader_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('provider dismisses once before changing the surface', (
    tester,
  ) async {
    final book = Book({
      'id': 'switch-markdown',
      'project': 'inbox',
      'title': 'Markdown',
      'format': 'Markdown',
      'revision': 1,
      'pages': <Map<String, dynamic>>[],
    });
    var calls = 0;
    var disposedBeforeSelect = false;
    String? selection;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                builder: (_) => ReaderProviderPanel(
                  book: book,
                  onSelect: (id) async {
                    disposedBeforeSelect = find
                        .byType(ReaderProviderPanel, skipOffstage: false)
                        .evaluate()
                        .isEmpty;
                    selection = id;
                    calls++;
                  },
                ),
              ),
              child: const Text('打开选择'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开选择'));
    await tester.pumpAndSettle();
    final tile = tester.widget<ListTile>(
      find.ancestor(of: find.text('纯文字阅读'), matching: find.byType(ListTile)),
    );
    tile.onTap!();
    tile.onTap!();
    expect(
      calls,
      0,
      reason: 'the sheet must finish its reverse animation first',
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(calls, 1);
    expect(disposedBeforeSelect, isTrue);
    expect(selection, 'core.text');
    expect(find.text('打开选择'), findsOneWidget);
  });

  testWidgets(
    'software settings save format choices without changing book settings',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'reader-format.v1.old-book': 'core.markdown',
        'reader-ui.v2.old-book': 'preserved',
      });
      await tester.pumpWidget(ReaderApp(api: TestApi()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-core.me')));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('设置'),
        160,
        scrollable: find.byType(Scrollable).last,
      );
      await tester.ensureVisible(find.text('设置').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('阅读器选择'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-default-Markdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('纯文字阅读').last);
      await tester.pumpAndSettle();
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(ReaderProviderPreferences.key('Markdown')),
        'core.text',
      );
      expect(prefs.getString('reader-ui.v2.old-book'), 'preserved');
      expect(prefs.getString('reader-format.v1.old-book'), 'core.markdown');
      for (final id in ['old-book', 'new-book']) {
        final book = Book({
          'id': id,
          'project': 'inbox',
          'title': id,
          'format': 'Markdown',
          'revision': 1,
          'pages': <Map<String, dynamic>>[],
        });
        expect(await ReaderProviderPreferences.read(book), 'core.text');
      }
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('阅读器选择'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<ListTile>(
              find.byKey(const ValueKey('reader-default-Markdown')),
            )
            .subtitle,
        isA<Text>(),
      );
      expect(find.text('纯文字阅读'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
