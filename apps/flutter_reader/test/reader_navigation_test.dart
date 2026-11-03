// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:aquantum_reader/data/models.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/screens/page_manager.dart';
import 'package:aquantum_reader/formats/document_engine.dart';
import 'package:aquantum_reader/formats/document_reader.dart';
import 'package:aquantum_reader/reader/reader_renderers.dart';
import 'package:aquantum_reader/widgets/reader_settings.dart';
import 'package:aquantum_reader/widgets/comic_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'document_engine_test.dart' as document_fixture;
import 'package:aquantum_reader/reader/reader_contract.dart';
import 'package:aquantum_reader/reader/reader_panels.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'reader_shell_test.dart' show FixtureAdapter, book, shell;

class LongNavigationAdapter extends FixtureAdapter
    implements OutlineReaderAdapter {
  final bool chapters;
  final built = <int>{};
  LongNavigationAdapter({this.chapters = false}) : super('long');
  @override
  int get count => 1000;
  @override
  List<ReaderLocation> get outline => chapters
      ? [
          for (var i = 0; i < count; i += 25)
            ReaderLocation('chapter:$i', '章节 $i', i),
        ]
      : [];
  @override
  ReaderLocation location(int index) =>
      ReaderLocation('page:$index', '第 ${index + 1} 页', index);
  @override
  int? resolveLocation(String id) {
    final index = int.tryParse(id.replaceFirst('page:', ''));
    return index != null && index >= 0 && index < count ? index : null;
  }

  @override
  Widget? buildThumbnail(BuildContext context, int index) {
    built.add(index);
    return Text('画面 $index');
  }
}

class PendingSearchAdapter extends LongNavigationAdapter {
  final pending = <Completer<List<ReaderSearchHit>>>[];
  @override
  ReaderCapabilities get capabilities => const ReaderCapabilities(search: true);
  @override
  Future<List<ReaderSearchHit>> search(String query) {
    final next = Completer<List<ReaderSearchHit>>();
    pending.add(next);
    return next.future;
  }
}

class ThumbnailApi implements ReaderApi {
  int reads = 0;
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (method == 'read_image') {
      reads++;
      return 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=';
    }
    return null;
  }
}

Widget panel(Widget child) => MaterialApp(
  home: Scaffold(
    body: Center(child: SizedBox(width: 375, height: 520, child: child)),
  ),
);

void main() {
  test(
    'comic geometry follows resource identity across preference revisions',
    () async {
      Book imageBook(int revision, String resource) => Book({
        'id': 'geometry',
        'project': 'inbox',
        'title': 'geometry',
        'format': 'Comic',
        'revision': revision,
        'pages': [
          {
            'id': 'geometry-page',
            'resource': {
              'id': resource,
              'bytes': 1,
              'original_name': 'image.png',
            },
          },
        ],
      });
      final api = ThumbnailApi();
      final before = imageBook(1, 'same-image');
      await ComicPage.load(api, before, 'geometry-page');
      final changedPreferences = imageBook(2, 'same-image');
      expect(ComicPage.ratioOf(changedPreferences, 'geometry-page'), 1);
      await ComicPage.load(api, changedPreferences, 'geometry-page');
      expect(api.reads, 1);
      expect(
        ComicPage.ratioOf(imageBook(3, 'new-image'), 'geometry-page'),
        isNull,
      );
    },
  );
  testWidgets(
    'page management opens at the reading page and stays lazy with large text',
    (tester) async {
      final api = ThumbnailApi();
      final source = Book({
        'id': 'managed',
        'project': 'inbox',
        'title': '管理页',
        'format': 'Comic',
        'revision': 1,
        'pages': [
          for (var i = 0; i < 1000; i++)
            {
              'id': 'managed-$i',
              'resource': {'original_name': '较长的页面名称 $i', 'bytes': 1},
            },
        ],
      });
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!,
          ),
          home: SizedBox(
            width: 375,
            child: PageManagerScreen(api: api, book: source, initialPage: 872),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('当前阅读页').hitTestable(), findsOneWidget);
      expect(
        find
            .byWidgetPredicate(
              (w) => w is ListTile && w.key == const ValueKey('managed-872'),
            )
            .hitTestable(),
        findsOneWidget,
      );
      expect(api.reads, lessThan(60));
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'opening many bookmarks reveals the current bookmark without building all rows',
    (tester) async {
      final adapter = LongNavigationAdapter()..current = 872;
      SharedPreferences.setMockInitialValues({
        'reader-bookmarks.v1.${adapter.documentId}': jsonEncode({
          'version': 1,
          'items': [
            for (var i = 0; i < 1000; i++) {'id': 'page:$i', 'label': '书签 $i'},
          ],
        }),
      });
      await tester.pumpWidget(shell(adapter, desktop: true));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('书签'));
      await tester.pumpAndSettle();
      expect(find.text('书签 872').hitTestable(), findsOneWidget);
      expect(find.byType(ListTile).evaluate().length, lessThan(60));
    },
  );
  test(
    'text searches and bookmarks retain the character inside a paragraph',
    () async {
      (int, int)? visited;
      final text = '${'前文' * 2000}目标词${'后文' * 1000}';
      final adapter = TextReaderAdapter(
        book: book('Txt'),
        position: 0,
        status: '',
        content: (_) => const SizedBox.shrink(),
        onGo: (_) {},
        locked: () => false,
        paragraphs: [text],
        currentOffset: 3500,
        onGoToText: (p, o) => visited = (p, o),
      );
      final bookmark = adapter.location(0);
      await adapter.goToLocation(bookmark);
      expect(visited, (0, 3500));
      final hits = await adapter.search('目标词');
      await adapter.goToLocation(hits.single.location);
      expect(visited, (0, 4000));
      await adapter.goToLocation(const ReaderLocation('paragraph:1:0', '', 0));
      expect(visited, (
        0,
        0,
      ), reason: 'legacy paragraph bookmarks still resolve');
    },
  );
  for (final invalid in <Object>['{', '{"version":99}', '[]', 42]) {
    test(
      'unreadable preferences $invalid allow reading and cannot be overwritten',
      () async {
        SharedPreferences.setMockInitialValues({
          'reader-ui.v2.damaged': invalid,
        });
        final prefs = ReaderPreferences();
        await prefs.load(bookId: 'damaged', format: 'Pdf');
        expect(prefs.continuous, isTrue);
        expect(prefs.warning, isNotNull);
        await expectLater(prefs.save(bookId: 'damaged'), throwsFormatException);
        expect(
          (await SharedPreferences.getInstance()).get('reader-ui.v2.damaged'),
          invalid,
        );
        await prefs.save(bookId: 'other');
      },
    );
  }
  test(
    'document outline follows href rather than permille progress or duplicate labels',
    () async {
      final engine = document_fixture.FakeEngine();
      final adapter = DocumentReaderAdapter(
        book: document_fixture.book(),
        engine: engine,
      );
      await adapter.open(Uint8List(0), name: '', format: 'Epub');
      engine.relocate(
        const DocumentPosition(
          fraction: .99,
          section: 1,
          label: '第一章',
          tocHref: 'ch2.xhtml',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(adapter.activeOutlineIndex, 1);
      adapter.dispose();
      await engine.close();
    },
  );
  for (final thumbnails in [false, true]) {
    testWidgets(
      'opening ${thumbnails ? 'thumbnails' : 'pages'} reveals the current page without building the whole book',
      (tester) async {
        final adapter = LongNavigationAdapter()..current = 872;
        ReaderLocation? selected;
        await tester.pumpWidget(
          panel(
            ReaderNavigationPanel(
              adapter: adapter,
              thumbnails: thumbnails,
              onSelect: (where) => selected = where,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(thumbnails ? '873' : '第 873 页').hitTestable(),
          findsOneWidget,
        );
        if (thumbnails) expect(adapter.built.length, lessThan(60));
        await tester.tap(find.text(thumbnails ? '873' : '第 873 页'));
        expect(selected?.index, 872);
      },
    );
  }
  testWidgets('outline opens at the chapter containing the current page', (
    tester,
  ) async {
    final adapter = LongNavigationAdapter(chapters: true)..current = 882;
    await tester.pumpWidget(
      panel(ReaderNavigationPanel(adapter: adapter, onSelect: (_) {})),
    );
    await tester.pumpAndSettle();
    expect(find.text('章节 875').hitTestable(), findsOneWidget);
    final row = tester.widget<ListTile>(
      find.ancestor(of: find.text('章节 875'), matching: find.byType(ListTile)),
    );
    expect(row.selected, isTrue);
  });
  testWidgets(
    'editing a query invalidates pending results and clears stale hits',
    (tester) async {
      final adapter = PendingSearchAdapter();
      await tester.pumpWidget(
        panel(ReaderSearchPanel(adapter: adapter, onSelect: (_) {})),
      );
      await tester.enterText(find.byType(TextField), 'old');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'new');
      adapter.pending.first.complete([
        const ReaderSearchHit(ReaderLocation('old', '旧位置', 0), '过期结果'),
      ]);
      await tester.pumpAndSettle();
      expect(find.text('过期结果'), findsNothing);
    },
  );
}
