// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:aquantum_reader/data/models.dart';
import 'package:aquantum_reader/formats/document_engine.dart';
import 'package:aquantum_reader/formats/document_reader.dart';
import 'package:aquantum_reader/reader/reader_contract.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A channel peer that records what the host posted and replays page replies.
class FakePage {
  final posts = <Map<String, dynamic>>[];
  late final DocumentChannel channel = DocumentChannel((message) async {
    posts.add(Map<String, dynamic>.from(jsonDecode(message) as Map));
  });
  Map<String, dynamic> get last => posts.last;
  void reply(int seq, Object? result) =>
      channel.receive(jsonEncode({'seq': seq, 'ok': true, 'result': result}));
  void fail(int seq, String error) =>
      channel.receive(jsonEncode({'seq': seq, 'ok': false, 'error': error}));
}

/// A stand-in engine: it answers with the positions a real page would report,
/// so the adapter's unit, position and target mapping can be tested without a
/// WebView.
class FakeEngine implements DocumentEngine {
  final _events = StreamController<DocumentEvent>.broadcast();
  final calls = <String>[];
  String? lastAnchor;
  double lastFraction = 0;
  bool opened = false;
  final openInfo = const DocumentInfo(
    title: '青柳随笔',
    outline: [
      (href: 'ch1.xhtml', title: '第一章', level: 1),
      (href: 'ch2.xhtml', title: '第二章', level: 1),
    ],
    paginated: true,
    vertical: false,
    location: DocumentPosition(
      anchor: 'epubcfi(/6/2!/4/2)',
      fraction: .25,
      section: 1,
      label: '第一章',
    ),
  );

  @override
  Future<void> get ready async {}
  @override
  Stream<DocumentEvent> get events => _events.stream;
  @override
  ReaderCapabilities get capabilities => DocumentEngineCapabilities.reflowable;
  @override
  Future<DocumentInfo> open({
    required Uint8List bytes,
    required String name,
    required String format,
    String? anchor,
  }) async {
    calls.add('open:$name:$format:${anchor ?? ''}');
    opened = true;
    return openInfo;
  }

  @override
  Future<void> goTo({String? anchor, int? page}) async {
    calls.add('goTo:${anchor ?? page}');
    lastAnchor = anchor;
  }

  @override
  Future<void> goToFraction(double fraction) async {
    calls.add('fraction:${fraction.toStringAsFixed(3)}');
    lastFraction = fraction;
  }

  @override
  Future<void> goToPoint(Offset point) async => calls.add('point');
  @override
  Future<void> turn(int delta) async => calls.add('turn:$delta');
  @override
  Future<String> anchor() async => 'epubcfi(/6/4!/4/2)';
  @override
  Future<List<DocumentHit>> search(String query, {int limit = 200}) async => [
    const DocumentHit('epubcfi(/6/2!/4/8)', '第一章', '……青柳……'),
  ];
  @override
  Future<void> close() async {
    await _events.close();
  }

  @override
  Future<void> style(Map<String, Object?> style) async =>
      calls.add('style:${style['theme']}');
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
  void relocate(DocumentPosition position) => _events.add(
    DocumentEvent('relocate', {
      'anchor': position.anchor,
      'fraction': position.fraction,
      'section': position.section,
      'label': position.label,
      'tocHref': position.tocHref,
      'atStart': position.atStart,
      'atEnd': position.atEnd,
    }),
  );
}

Book book() => Book({
  'id': 'epub-1',
  'project': 'inbox',
  'title': '青柳随笔',
  'format': 'Epub',
  'revision': 1,
  'pages': [
    {
      'id': 'p0',
      'resource': {'bytes': 12},
    },
  ],
  'capabilities': {
    'surfaces': ['document'],
  },
});

void main() {
  group('document channel', () {
    test('pairs each reply with its own request', () async {
      final page = FakePage();
      final first = page.channel.call('anchor');
      final second = page.channel.call('turn', {'delta': 1});
      expect(page.posts.map((post) => post['method']), ['anchor', 'turn']);
      expect(page.last['args'], {'delta': 1});
      // Replies may come back out of order; each still reaches its own waiter.
      page.reply(2, {'ok': 1});
      page.reply(1, {'anchor': 'epubcfi(/6/2)'});
      expect(await first, {'anchor': 'epubcfi(/6/2)'});
      expect(await second, {'ok': 1});
    });

    test('a failure message rejects only the request it names', () async {
      final page = FakePage();
      final failed = page.channel.call('open');
      final kept = page.channel.call('anchor');
      page.fail(1, '无法打开这本书：缺少 container.xml');
      await expectLater(
        failed,
        throwsA(
          isA<DocumentEngineFailure>().having(
            (e) => e.message,
            'message',
            '无法打开这本书：缺少 container.xml',
          ),
        ),
      );
      page.reply(2, {'anchor': 'epubcfi(/6/4)'});
      expect(await kept, {'anchor': 'epubcfi(/6/4)'});
    });

    test(
      'malformed and unsolicited messages never break the channel',
      () async {
        final page = FakePage();
        page.channel.receive('not json');
        page.channel.receive('[]');
        page.channel.receive('{"seq": 99, "ok": true, "result": {}}');
        final request = page.channel.call('anchor');
        page.reply(1, {'anchor': 'ok'});
        expect(await request, {'anchor': 'ok'});
      },
    );

    test('a silent page times out instead of hanging the reader', () async {
      final page = FakePage();
      final short = DocumentChannel(
        page.channel.post,
        timeout: const Duration(milliseconds: 20),
      );
      await expectLater(
        short.call('open'),
        throwsA(
          isA<DocumentEngineFailure>().having(
            (e) => e.message,
            'message',
            '文档引擎没有响应',
          ),
        ),
      );
      short.close();
    });

    test('closing fails every pending request exactly once', () async {
      final page = FakePage();
      final pending = page.channel.call('open');
      page.channel.close();
      await expectLater(pending, throwsA(isA<DocumentEngineFailure>()));
      await expectLater(
        page.channel.call('anchor'),
        throwsA(isA<DocumentEngineFailure>()),
      );
    });

    test('events arrive without a request and carry their detail', () async {
      final page = FakePage();
      final seen = <DocumentEvent>[];
      final subscription = page.channel.events.listen(seen.add);
      page.channel.receive(
        jsonEncode({
          'event': 'relocate',
          'detail': {'anchor': 'epubcfi(/6/8)', 'fraction': .5},
        }),
      );
      page.channel.loaded();
      await Future<void>.delayed(Duration.zero);
      expect(seen.map((event) => event.name), ['relocate', 'ready']);
      expect(seen.first.detail['fraction'], .5);
      await page.channel.ready;
      await subscription.cancel();
    });
  });

  group('document parsing', () {
    test('position keeps the anchor and clamps the fraction', () {
      const raw = <String, Object>{
        'anchor': 'epubcfi(/6/2!/4)',
        'fraction': 1.4,
        'section': 3.0,
        'label': '序',
      };
      final position = DocumentPosition.parse(raw);
      expect(position.anchor, 'epubcfi(/6/2!/4)');
      expect(position.fraction, 1);
      expect(position.section, 3);
      expect(position.label, '序');
      expect(DocumentPosition.parse(null).fraction, 0);
    });

    test('info drops outline rows it cannot navigate', () {
      final info = DocumentInfo.parse({
        'title': '书名',
        'paginated': true,
        'vertical': true,
        'location': {'anchor': 'epubcfi(/6/2)'},
        'outline': [
          {'href': 'a.xhtml', 'title': '甲', 'level': 2},
          {'href': '', 'title': '无目标'},
          {'title': '没有链接'},
          {'href': 'b.xhtml', 'title': '乙'},
        ],
      });
      expect(info.title, '书名');
      expect(info.paginated, isTrue);
      expect(info.vertical, isTrue);
      expect(info.outline.map((row) => row.href), ['a.xhtml', 'b.xhtml']);
      expect(info.outline.map((row) => row.level), [2, 1]);
    });
  });

  group('document adapter', () {
    test(
      'reports the book in tenths of a percent and never a page count',
      () async {
        final engine = FakeEngine();
        final adapter = DocumentReaderAdapter(book: book(), engine: engine);
        await adapter.open(
          Uint8List.fromList([1, 2, 3]),
          name: '青柳随笔.epub',
          format: 'Epub',
        );
        expect(adapter.unit, '%');
        expect(adapter.count, 1001);
        expect(adapter.position, 250);
        expect(adapter.liveSurface, isTrue);
        expect(adapter.status, '第一章 · 约 25%');
        expect(adapter.ready, isTrue);
        engine.relocate(
          const DocumentPosition(anchor: 'epubcfi(/6/4)', fraction: .5),
        );
        await Future<void>.delayed(Duration.zero);
        expect(adapter.position, 500);
        expect(adapter.status, '约 50%');
        adapter.dispose();
        await engine.close();
      },
    );

    test(
      'page boundaries remain usable while progress still rounds to zero',
      () async {
        final engine = FakeEngine();
        final adapter = DocumentReaderAdapter(book: book(), engine: engine);
        await adapter.open(Uint8List(3), name: 'a.epub', format: 'Epub');
        engine.relocate(
          const DocumentPosition(
            anchor: 'preface',
            fraction: 0,
            section: 1,
            atStart: false,
            atEnd: false,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(adapter.position, 0);
        expect(adapter.canTurnBackward, isTrue);
        expect(adapter.canTurnForward, isTrue);
        engine.relocate(
          const DocumentPosition(
            anchor: 'cover',
            fraction: 0,
            atStart: true,
            atEnd: false,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(adapter.canTurnBackward, isFalse);
        adapter.dispose();
        await engine.close();
      },
    );

    test('a slider move asks the engine for that fraction', () async {
      final engine = FakeEngine();
      final adapter = DocumentReaderAdapter(book: book(), engine: engine);
      await adapter.open(Uint8List(3), name: '青柳随笔.epub', format: 'Epub');
      adapter.goTo(600);
      await Future<void>.delayed(Duration.zero);
      expect(engine.calls, contains('fraction:0.600'));
      expect(adapter.interactionLocked, isFalse);
      adapter.dispose();
      await engine.close();
    });

    test('an outline entry navigates by href, not by its index', () async {
      final engine = FakeEngine();
      final adapter = DocumentReaderAdapter(book: book(), engine: engine);
      await adapter.open(Uint8List(3), name: 'a.epub', format: 'Epub');
      final chapter = adapter.outline[1];
      expect(chapter.label, '第二章');
      expect(chapter.index, 1);
      await adapter.goToLocation(chapter);
      expect(engine.lastAnchor, 'ch2.xhtml');
      expect(adapter.resolveLocation(adapter.location(420).id), 420);
      adapter.dispose();
      await engine.close();
    });

    test('a search hit carries the anchor the engine must jump to', () async {
      final engine = FakeEngine();
      final adapter = DocumentReaderAdapter(book: book(), engine: engine);
      await adapter.open(Uint8List(3), name: 'a.epub', format: 'Epub');
      final hits = await adapter.search('青柳');
      expect(hits.single.excerpt, '……青柳……');
      await adapter.goToLocation(hits.single.location);
      expect(engine.lastAnchor, 'epubcfi(/6/2!/4/8)');
      // A hit is not a linear position, so the shell must not fall back to it.
      expect(adapter.location(hits.single.location.index).index, 0);
      adapter.dispose();
      await engine.close();
    });

    test(
      'live scroll feedback preserves the stable anchor and avoids rebuilds',
      () async {
        final engine = FakeEngine();
        final adapter = DocumentReaderAdapter(book: book(), engine: engine);
        await adapter.open(Uint8List(3), name: 'a.epub', format: 'Epub');
        adapter.setContinuous(true);
        final anchor = adapter.anchor;
        var rebuilds = 0;
        adapter.addListener(() => rebuilds++);
        engine._events.add(
          const DocumentEvent('scroll-metrics', {
            'fraction': .7,
            'viewport': .02,
          }),
        );
        await Future<void>.delayed(Duration.zero);
        expect(adapter.scrollMetrics.value, const ReaderScrollMetrics(.7, .02));
        expect(adapter.anchor, anchor);
        expect(adapter.fraction, .25);
        expect(rebuilds, 0);
        engine._events.add(
          const DocumentEvent('scroll-metrics', {'fraction': 'bad'}),
        );
        await Future<void>.delayed(Duration.zero);
        expect(adapter.scrollMetrics.value.fraction, .7);
        adapter.setContinuous(false);
        engine._events.add(
          const DocumentEvent('scroll-metrics', {'fraction': .8}),
        );
        await Future<void>.delayed(Duration.zero);
        expect(adapter.scrollMetrics.value.fraction, .7);
        adapter.dispose();
        await engine.close();
      },
    );

    test('settling refreshes the anchor and keeps the fraction', () async {
      final engine = FakeEngine();
      final adapter = DocumentReaderAdapter(book: book(), engine: engine);
      await adapter.open(Uint8List(3), name: 'a.epub', format: 'Epub');
      await adapter.settle();
      expect(adapter.anchor, 'epubcfi(/6/4!/4/2)');
      expect(adapter.fraction, .25);
      adapter.dispose();
      await engine.close();
    });
  });
}
