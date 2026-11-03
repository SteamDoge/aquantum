// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'package:aquantum_reader/formats/reader_provider_preferences.dart';
import 'package:aquantum_reader/widgets/reader_settings.dart';
import 'package:aquantum_reader/screens/reader_defaults_screen.dart';
import 'package:aquantum_reader/reader/reader_panels.dart';
import 'package:aquantum_reader/reader/reader_renderers.dart';
import 'package:aquantum_reader/reader/text_pagination.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'reader_shell_test.dart' show book;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('format mode defaults and file overrides remain independent', () async {
    for (final format in [
      'Txt',
      'Epub',
      'Mobi',
      'Azw3',
      'Fb2',
      'Markdown',
      'Pdf',
      'Comic',
    ]) {
      final initial = ReaderPreferences();
      await initial.load(bookId: 'new-$format', format: format);
      expect(initial.textPaged, !{'Markdown', 'Pdf', 'Comic'}.contains(format));
      final own = ReaderPreferences()
        ..textPaged = initial.textPaged
        ..continuous = !initial.textPaged
        ..theme = 'dark';
      await own.save(bookId: 'own-$format');
      final original = (await SharedPreferences.getInstance()).getString(
        'reader-ui.v2.own-$format',
      );
      await ReaderProviderPreferences.savePaged(format, !initial.textPaged);
      final fresh = ReaderPreferences();
      await fresh.load(bookId: 'next-$format', format: format);
      expect(fresh.textPaged, !initial.textPaged);
      final restored = ReaderPreferences();
      await restored.load(bookId: 'own-$format', format: format);
      expect(restored.textPaged, initial.textPaged);
      expect(restored.theme, 'dark');
      expect(
        (await SharedPreferences.getInstance()).getString(
          'reader-ui.v2.own-$format',
        ),
        original,
      );
    }
  });
  test('shared legacy scroll never changes the TXT format mode', () async {
    SharedPreferences.setMockInitialValues({
      'reader-ui.v1': jsonEncode({
        'version': 1,
        'textPaged': false,
        'continuous': true,
        'theme': 'dark',
      }),
    });
    final settings = ReaderPreferences();
    await settings.load(bookId: 'fresh', format: 'Txt');
    expect(settings.textPaged, isTrue);
    expect(settings.theme, 'dark');
  });
  test('invalid global mode does not block a valid file preference', () async {
    final own = ReaderPreferences()..textPaged = false;
    await own.save(bookId: 'preserved');
    await (await SharedPreferences.getInstance()).setString(
      'reader-mode.v1.Txt',
      'invalid',
    );
    final restored = ReaderPreferences();
    await restored.load(bookId: 'preserved', format: 'Txt');
    expect(restored.textPaged, isFalse);
    expect(await ReaderProviderPreferences.paged('Txt'), isTrue);
  });
  testWidgets('reader selection saves format paging mode', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ReaderDefaultsScreen()));
    await tester.pumpAndSettle();
    final field = find.byWidgetPredicate(
      (w) =>
          w is DropdownButtonFormField<bool> &&
          (w.key as ValueKey).value.toString().startsWith(
            'reader-default-mode-Txt-',
          ),
    );
    await tester.tap(field);
    await tester.pumpAndSettle();
    await tester.tap(find.text('上下翻页（连续滚动）').last);
    await tester.pumpAndSettle();
    expect(await ReaderProviderPreferences.paged('Txt'), isFalse);
  });
  testWidgets('TXT navigation leading uses real page numbers', (tester) async {
    final paragraphs = [List.filled(200, '正文内容。').join()];
    final layout = TextPagination.layout(
      paragraphs: paragraphs,
      viewport: const Size(375, 700),
      style: const TextStyle(fontSize: 20),
      scaler: TextScaler.noScaling,
      direction: TextDirection.ltr,
      margin: 28,
      paragraphGap: 24,
    );
    final adapter = PagedTextReaderAdapter(
      book: book('Txt'),
      position: 0,
      status: '',
      content: (_) => const SizedBox(),
      onGo: (_) {},
      locked: () => false,
      layout: layout,
      paragraphs: paragraphs,
      rightToLeft: false,
      animatePageTurns: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReaderNavigationPanel(adapter: adapter, onSelect: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final tile = tester.widget<ListTile>(
      find.byKey(const ValueKey('reader-navigation-item-0')),
    );
    expect((tile.leading as Text).data, '第 1 页');
  });
}
