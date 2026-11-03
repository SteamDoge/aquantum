// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../reader/reader_contract.dart';

/// One message the page pushes while no request is waiting: the current
/// location, one search hit, a link the book asked to open, or readiness.
class DocumentEvent {
  final String name;
  final Map<String, dynamic> detail;
  const DocumentEvent(this.name, this.detail);
  factory DocumentEvent.parse(Map<dynamic, dynamic> raw) => DocumentEvent(
    raw['event']?.toString() ?? '',
    raw['detail'] is Map
        ? Map<String, dynamic>.from(raw['detail'] as Map)
        : const {},
  );
}

/// What the shell and its adapter need from a document engine.
///
/// The engine lays out EPUB/MOBI/AZW3/FB2 exactly as the file declares and
/// reports a text anchor (CFI) for every position. It never reads a file or a
/// URL itself: the host hands it the managed bytes and owns every decision.
abstract class DocumentEngine {
  /// The page has loaded and can accept requests.
  Future<void> get ready;
  Stream<DocumentEvent> get events;

  /// What this document can actually be asked to do, once it is open.
  ReaderCapabilities get capabilities;

  /// Replaces the document; returns the engine's own description of the book.
  Future<DocumentInfo> open({
    required Uint8List bytes,
    required String name,
    required String format,
    String? anchor,
  });
  Future<void> goTo({String? anchor, int? page});

  /// Moves to a fractional position through the book (0..1). The engine turns
  /// it into the nearest page it can actually lay out.
  Future<void> goToFraction(double fraction);

  /// Shows the page the engine reports for the pointed location.
  Future<void> goToPoint(Offset point);

  Future<void> turn(int delta);
  Future<String> anchor();
  Future<List<DocumentHit>> search(String query, {int limit = 200});
  Future<void> close();

  /// Applies the display preferences the engine can honour. Unknown keys are
  /// ignored by the engine, so the shell may send its whole preference set.
  Future<void> style(Map<String, Object?> style);

  /// Paints the page into the widget tree, or a placeholder when inactive.
  Widget build(BuildContext context);
}

/// Header of the opened document, as the engine resolved it.
class DocumentInfo {
  final String title;
  final List<({String href, String title, int level})> outline;
  final bool paginated;
  final bool pageEffects;

  /// True when the document runs right-to-left, so the shell mirrors the turn
  /// axis instead of guessing from the file suffix.
  final bool vertical;
  final DocumentPosition location;
  const DocumentInfo({
    required this.title,
    required this.outline,
    required this.paginated,
    this.pageEffects = false,
    required this.vertical,
    required this.location,
  });
  static List<({String href, String title, int level})> _outline(Object? raw) {
    if (raw is! List) return const [];
    final rows = <({String href, String title, int level})>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final href = item['href'];
      final title = item['title'];
      if (href is! String || href.isEmpty || title is! String) continue;
      final level = item['level'];
      rows.add((
        href: href,
        title: title,
        level: level is int && level > 0 ? level : 1,
      ));
    }
    return rows;
  }

  factory DocumentInfo.parse(Map<dynamic, dynamic> raw) => DocumentInfo(
    title: raw['title']?.toString() ?? '',
    outline: _outline(raw['outline']),
    paginated: raw['paginated'] == true,
    pageEffects: raw['pageEffects'] == true,
    vertical: raw['vertical'] == true,
    location: DocumentPosition.parse(raw['location']),
  );
}

/// A location inside a laid-out document.
///
/// [anchor] is the engine's CFI: it survives font, window and page-size
/// changes, so it is the only permanent progress. [fraction] is how far the
/// reader is through the book and is only used for show and for the numeric
/// position the shell's slider and counters need.
class DocumentPosition {
  final String anchor;
  final String tocHref;
  final double fraction, section;
  final bool? atStart, atEnd;

  /// The table-of-contents label the engine resolved for this position.
  final String label;

  /// Share of the book on screen, from the engine's text-length locations
  /// (`next - current` of `total`), or `null` when it did not say.
  final double? viewport;
  const DocumentPosition({
    this.atStart,
    this.atEnd,
    this.anchor = '',
    this.tocHref = '',
    this.fraction = 0,
    this.section = 0,
    this.label = '',
    this.viewport,
  });
  factory DocumentPosition.parse(Object? raw) {
    if (raw is! Map) return const DocumentPosition();
    final fraction = raw['fraction'];
    final section = raw['section'];
    final viewport = raw['viewport'];
    return DocumentPosition(
      atStart: raw['atStart'] is bool ? raw['atStart'] as bool : null,
      atEnd: raw['atEnd'] is bool ? raw['atEnd'] as bool : null,
      anchor: raw['anchor']?.toString() ?? '',
      tocHref: raw['tocHref']?.toString() ?? '',
      fraction: fraction is num ? fraction.toDouble().clamp(0.0, 1.0) : 0,
      section: section is num ? section.toDouble() : 0,
      label: raw['label']?.toString() ?? '',
      viewport: viewport is num && viewport > 0
          ? viewport.toDouble().clamp(0.0, 1.0)
          : null,
    );
  }
}

class DocumentHit {
  final String anchor, label, excerpt;
  const DocumentHit(this.anchor, this.label, this.excerpt);
}

/// The setting surface a document engine can actually honour.
///
/// A reflowable book is laid out by the engine, so font size, family, spacing
/// and margins are real controls. A fixed-layout book draws its own pages, so
/// offering those switches would be a control that does nothing; only the
/// theme, fit, direction, animation and scrolling switches belong there.
abstract final class DocumentEngineCapabilities {
  static const reflowable = ReaderCapabilities(
    settings: {
      ReaderSetting.fontSize,
      ReaderSetting.fontFamily,
      ReaderSetting.lineHeight,
      ReaderSetting.paragraphGap,
      ReaderSetting.margin,
      ReaderSetting.theme,
      ReaderSetting.animation,
      ReaderSetting.continuous,
      ReaderSetting.turnEffect,
    },
    search: true,
    searchExplanation: '',
    navigationLabel: '目录',
  );

  static const fixed = ReaderCapabilities(
    settings: {ReaderSetting.theme, ReaderSetting.fit},
    search: true,
    searchExplanation: '',
    navigationLabel: '目录',
  );
  static const comic = ReaderCapabilities(
    settings: {ReaderSetting.theme, ReaderSetting.fit},
    search: false,
    searchExplanation: '图片漫画没有可搜索正文；OCR 尚未实现。',
    navigationLabel: '页面',
  );
}

/// One request/reply pair over the host channel.
///
/// A host implementation only has to carry a JSON string in each direction and
/// report readiness; the framing stays here so both platforms share it and a
/// stray or failed reply can never be mistaken for another request's answer.
class DocumentChannel {
  /// How long a single request may wait. Shortened only in tests, so a silent
  /// page cannot make a test wait the full reader timeout.
  final Duration timeout;
  final Future<void> Function(String message) post;
  final Completer<void> _ready = Completer<void>();
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final StreamController<DocumentEvent> _events =
      StreamController<DocumentEvent>.broadcast();
  int _next = 0;
  bool _closed = false;
  Future<void> get ready => _ready.future.timeout(
    timeout,
    onTimeout: () {
      throw const DocumentEngineFailure('文档页面未就绪');
    },
  );
  Stream<DocumentEvent> get events => _events.stream;

  DocumentChannel(this.post, {this.timeout = const Duration(seconds: 30)});

  /// Marks the page as loaded. Safe to call more than once.
  void loaded() {
    if (_closed) return;
    if (!_ready.isCompleted) _ready.complete();
    _events.add(const DocumentEvent('ready', {}));
  }

  /// Handles one message from the page: a reply when it carries `seq`,
  /// otherwise a notification. Malformed text is dropped, never thrown.
  void receive(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final message = Map<String, dynamic>.from(decoded);
    final seq = message['seq'];
    if (seq is int) {
      final waiter = _pending.remove(seq);
      if (waiter == null || waiter.isCompleted) return;
      if (message['ok'] == true) {
        final result = message['result'];
        waiter.complete(
          result is Map
              ? Map<String, dynamic>.from(result)
              : <String, dynamic>{'value': result},
        );
      } else {
        waiter.completeError(
          DocumentEngineFailure(message['error']?.toString() ?? '文档操作失败'),
        );
      }
      return;
    }
    if (message['event'] == 'ready') {
      loaded();
      return;
    }
    if (message['event'] == 'load-error') {
      fail((message['detail'] as Map?)?['error']?.toString() ?? '文档加载失败');
      return;
    }
    if (message['event'] != null && !_events.isClosed) {
      _events.add(DocumentEvent.parse(message));
    }
  }

  Future<Map<String, dynamic>> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (_closed) throw const DocumentEngineFailure('文档引擎已关闭');
    final seq = ++_next;
    final waiter = Completer<Map<String, dynamic>>();
    _pending[seq] = waiter;
    try {
      await post(jsonEncode({'seq': seq, 'method': method, 'args': args}));
    } catch (error) {
      _pending.remove(seq);
      rethrow;
    }
    return waiter.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(seq);
        throw const DocumentEngineFailure('文档引擎没有响应');
      },
    );
  }

  void fail(String message) {
    final failure = DocumentEngineFailure(message);
    if (!_ready.isCompleted) {
      _ready.completeError(failure);
      _ready.future.ignore();
    }
    for (final waiter in _pending.values) {
      if (!waiter.isCompleted) waiter.completeError(failure);
    }
    _pending.clear();
    if (!_events.isClosed) {
      _events.add(DocumentEvent('load-error', {'error': message}));
    }
  }

  /// Fails every waiter so an opening screen never waits forever.
  void close() {
    _closed = true;
    for (final waiter in _pending.values) {
      if (!waiter.isCompleted) {
        waiter.completeError(const DocumentEngineFailure('文档引擎已关闭'));
      }
    }
    _pending.clear();
    if (!_ready.isCompleted) {
      _ready.completeError(const DocumentEngineFailure('文档引擎已关闭'));
      // The error is delivered to whoever awaited it; an unawaited engine may
      // never ask, and that must not become an unhandled error.
      _ready.future.ignore();
    }
    if (!_events.isClosed) _events.close();
  }
}

class DocumentEngineFailure implements Exception {
  final String message;
  const DocumentEngineFailure(this.message);
  @override
  String toString() => message;
}
