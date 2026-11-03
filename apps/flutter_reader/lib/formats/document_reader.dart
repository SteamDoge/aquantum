// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../reader/reader_contract.dart';
import 'document_engine.dart';
import 'document_engine_channel.dart';

/// The reader's view onto a document laid out by the bundled foliate engine.
///
/// A reflowed document has no fixed page count: the engine paginates the text
/// itself and reports a book-wide fraction plus a text anchor (a CFI). The
/// shell still needs one linear number, so `position`/`count` describe the book
/// in tenths of a percent — the slider, the counter and the page grid then all
/// mean the same thing. A CFI remains the only value ever stored as progress.
///
/// Chapter targets are not linear positions, so an outline entry keeps its own
/// `href` in its location id and the shell navigates it through
/// [goToLocation] rather than by index.
class DocumentReaderAdapter extends ChangeNotifier
    implements
        ReaderAdapter,
        PageTurnBoundaryReaderAdapter,
        PagedReaderAdapter,
        OutlineReaderAdapter,
        ActiveOutlineReaderAdapter,
        LocationReaderAdapter,
        LiveReaderAdapter {
  final Book book;
  final DocumentEngine engine;

  DocumentReaderAdapter({required this.book, required this.engine}) {
    _subscription = engine.events.listen(_onEvent);
  }

  static const _perMille = 1000;
  static const _anchorMarker = ':anchor:';
  static const _chapterMarker = ':toc:';

  late final StreamSubscription<DocumentEvent> _subscription;
  DocumentInfo? info;
  DocumentPosition _position = const DocumentPosition();
  String _status = '';
  bool busy = false;
  String? error;
  bool _locked = false, _disposed = false;
  List<ReaderLocation> _outline = const [];

  @override
  int? get activeOutlineIndex {
    final entries = info?.outline;
    if (entries == null || entries.isEmpty) return null;
    final byHref = entries.indexWhere(
      (entry) => entry.href == _position.tocHref,
    );
    if (byHref >= 0) return byHref;
    final byLabel = entries.indexWhere(
      (entry) => entry.title == _position.label,
    );
    return byLabel >= 0 ? byLabel : null;
  }

  /// Where an outline entry and a search hit point, in engine terms.
  final _targets = <String, String>{};

  @override
  String get documentId => book.id;
  @override
  String get title => info?.title.isNotEmpty == true ? info!.title : book.title;
  @override
  String get unit => book.isComic ? '页' : '%';
  @override
  int get position => count == 0
      ? 0
      : book.isComic
      ? _position.section.toInt().clamp(0, count - 1)
      : (_position.fraction * _perMille).round().clamp(0, _perMille);
  @override
  int get count => !ready
      ? 0
      : book.isComic
      ? book.pages.length
      : _perMille + 1;
  @override
  bool get paged => !continuous;
  @override
  bool get canTurnBackward =>
      ready && (book.isComic ? position > 0 : _position.atStart != true);
  @override
  bool get canTurnForward =>
      ready && (book.isComic ? position < count - 1 : _position.atEnd != true);
  bool continuous = false;
  @override
  bool get pageProgress => true;
  @override
  bool get rightToLeft => info?.vertical ?? false;
  @override
  bool get verticalTurn => continuous;
  @override
  bool get interactionLocked => _locked;
  @override
  bool get animatePageTurns => true;

  /// The browser surface is the whole book: the shell must not swap it for a
  /// page grid it cannot draw, so it stays mounted and pages turn in place.
  @override
  bool get liveSurface => true;
  @override
  ReaderCapabilities get capabilities => engine.capabilities;
  @override
  List<ReaderLocation> get outline => _outline;

  /// Whole-book position for the top-to-bottom scrollbar. The engine measures
  /// it by text length (section sizes), never by chapter count.
  final scrollMetrics = ValueNotifier(const ReaderScrollMetrics(0));
  late final scrollSource = ReaderScrollSource(
    metrics: scrollMetrics,
    seek: seekFraction,
  );
  bool _seeking = false;
  double? _pendingSeek;

  /// Moves to [fraction] of the book. While the engine is still laying out an
  /// earlier target only the latest one is kept, so a dragged scrollbar never
  /// queues a trail of jumps.
  void seekFraction(double fraction) {
    if (!ready || book.isComic) return;
    _pendingSeek = fraction.clamp(0.0, 1.0);
    if (_seeking) return;
    unawaited(_drainSeeks());
  }

  Future<void> _drainSeeks() async {
    _seeking = true;
    try {
      while (_pendingSeek != null && !_disposed) {
        final target = _pendingSeek!;
        _pendingSeek = null;
        try {
          await engine.goToFraction(target);
        } catch (e) {
          _status = '跳转失败：$e';
          notifyListeners();
        }
      }
    } finally {
      _seeking = false;
    }
  }

  void _publish() {
    if (_disposed) return;
    scrollMetrics.value = ReaderScrollMetrics(
      _position.fraction,
      _position.viewport,
    );
  }

  /// Whether the document is ready to be read.
  bool get ready => info != null;
  String get anchor => _position.anchor;
  double get fraction => _position.fraction;
  String get chapterLabel => _position.label;

  /// What the footer says: the chapter the reader is in and how far through
  /// the book that is, because a reflowed book has no stable page number.
  @override
  String get status {
    if (_status.isNotEmpty) return _status;
    if (error != null) return error!;
    final percent = (fraction * 100).round();
    return _position.label.isEmpty
        ? '约 $percent%'
        : '${_position.label} · 约 $percent%';
  }

  @override
  ReaderLocation location(int index) {
    if (book.isComic && book.pages.isNotEmpty) {
      final page = index.clamp(0, book.pages.length - 1);
      return ReaderLocation(
        'document:${book.id}$_anchorMarker${book.pages[page]['id']}',
        '第 ${page + 1} 页',
        page,
      );
    }
    if (index == position && anchor.isNotEmpty) {
      return ReaderLocation(
        'document:${book.id}$_anchorMarker$anchor',
        status,
        index,
      );
    }
    final clamped = index.clamp(0, _perMille);
    return ReaderLocation(
      'document:${book.id}:at:$clamped',
      '约 ${(clamped / _perMille * 100).round()}%',
      clamped,
    );
  }

  /// A stored position is a fraction, so any id this adapter produced resolves
  /// back to the percent it was taken at.
  @override
  int? resolveLocation(String id) {
    if (!id.startsWith('document:${book.id}:')) return null;
    final marker = 'document:${book.id}$_anchorMarker';
    if (id.startsWith(marker)) {
      if (!book.isComic) return position;
      final page = book.pages.indexWhere(
        (page) => page['id'] == id.substring(marker.length),
      );
      return page < 0 ? null : page;
    }
    final parts = id.split(':');
    return int.tryParse(parts.last)?.clamp(0, count - 1);
  }

  @override
  void goTo(int index) {
    if (count == 0 || _locked) return;
    if (book.isComic) {
      unawaited(
        _navigate(book.pages[index.clamp(0, count - 1)]['id'] as String),
      );
      return;
    }
    final target = index.clamp(0, _perMille) / _perMille;
    _locked = true;
    _status = '正在翻到 ${(target * 100).round()}%';
    notifyListeners();
    engine
        .goToFraction(target)
        .then<void>((_) {}, onError: (Object e) => _status = '跳转失败：$e')
        .whenComplete(() {
          if (_disposed) return;
          _locked = false;
          notifyListeners();
        });
  }

  /// Navigates to a location the shell selected. A chapter or search hit keeps
  /// its engine target; a linear location is a fraction of the book.
  @override
  Future<void> goToLocation(ReaderLocation location) async {
    final marker = 'document:${book.id}$_anchorMarker';
    final target = location.id.startsWith(marker)
        ? location.id.substring(marker.length)
        : _targets[location.id];
    if (target != null) return _navigate(target);
    goTo(location.index);
  }

  /// Jumps to a chapter by its href, as the engine resolves it.
  Future<void> goToHref(String href) => _navigate(href);

  Future<void> _navigate(String target) async {
    error = null;
    _locked = true;
    notifyListeners();
    try {
      await engine.goTo(anchor: target);
    } catch (e) {
      error = '$e';
    } finally {
      _locked = false;
      if (!_disposed) notifyListeners();
    }
  }

  @override
  Widget buildContent(BuildContext context) => engine.build(context);

  /// The engine keeps one browser surface showing one page, so it cannot
  /// rebuild an arbitrary page for the shell's grid.
  @override
  Widget? buildPage(BuildContext context, int index, {required bool preview}) =>
      null;

  @override
  Widget? buildThumbnail(BuildContext context, int index) => null;

  @override
  Future<List<ReaderSearchHit>> search(String query) async {
    if (!ready) return const [];
    final hits = await engine.search(query);
    return [
      for (final hit in hits) ReaderSearchHit(_hitLocation(hit), hit.excerpt),
    ];
  }

  /// A search hit becomes a location that carries its CFI, so the shell can
  /// hand it back through [goToLocation] without knowing about anchors.
  ReaderLocation _hitLocation(DocumentHit hit) {
    final id = 'document:${book.id}$_anchorMarker${hit.anchor}';
    _targets[id] = hit.anchor;
    return ReaderLocation(id, hit.label.isEmpty ? '文内位置' : hit.label, 0);
  }

  /// Opens the book body once the engine page is ready.
  Future<void> open(
    Uint8List bytes, {
    required String name,
    required String format,
    String? anchor,
  }) async {
    busy = true;
    error = null;
    _status = '正在排版';
    notifyListeners();
    try {
      _apply(
        await engine.open(
          bytes: bytes,
          name: name,
          format: format,
          anchor: anchor,
        ),
      );
    } catch (e) {
      error = '$e';
      _status = '';
      rethrow;
    } finally {
      busy = false;
      if (!_disposed) notifyListeners();
    }
  }

  Future<void> openImages({
    required Future<String> Function(String) readImage,
    String? anchor,
  }) async {
    final target = engine;
    if (target is! ChannelDocumentEngine) {
      throw const DocumentEngineFailure('当前引擎不支持图片书籍');
    }
    _apply(
      await target.openImages(
        name: book.title,
        pages: [for (final page in book.pages) page['id'] as String],
        readImage: readImage,
        anchor: anchor,
      ),
    );
  }

  void _apply(DocumentInfo opened) {
    if (_disposed) return;
    info = opened;
    _position = opened.location;
    _publish();
    _targets.clear();
    // The href is the chapter's real target; the map keeps it while the id
    // names the entry, so the outline panel navigates to the chapter and never
    // to a percentage of the book.
    _outline = [
      for (final (i, entry) in opened.outline.indexed)
        ReaderLocation('document:${book.id}$_chapterMarker$i', entry.title, i),
    ];
    for (final (i, entry) in opened.outline.indexed) {
      _targets['document:${book.id}$_chapterMarker$i'] = entry.href;
    }
    _status = '';
    notifyListeners();
  }

  void _onEvent(DocumentEvent event) {
    switch (event.name) {
      case 'scroll-metrics':
        // Visual feedback must not replace the last stable CFI or trigger
        // whole-shell rebuilds/progress writes on every native scroll frame.
        final fraction = event.detail['fraction'];
        final viewport = event.detail['viewport'];
        if (continuous && fraction is num && fraction.isFinite) {
          scrollMetrics.value = ReaderScrollMetrics(
            fraction.toDouble().clamp(0.0, 1.0),
            viewport is num && viewport.isFinite
                ? viewport.toDouble().clamp(0.0, 1.0)
                : null,
          );
        }
      case 'relocate':
        _position = DocumentPosition.parse(event.detail);
        _status = '';
        _publish();
        notifyListeners();
      case 'load-error':
        error = event.detail['error']?.toString() ?? '文档加载失败';
        _status = '';
        notifyListeners();
      case 'external-link':
        final href = event.detail['href']?.toString() ?? '';
        if (href.isNotEmpty) _status = '书内链接：$href';
        notifyListeners();
    }
  }

  /// Makes the engine's own location the saved one after a page turn.
  Future<void> settle() async {
    if (book.isComic) return;
    try {
      final anchor = await engine.anchor();
      if (anchor.isEmpty || anchor == _position.anchor) return;
      _position = DocumentPosition(
        anchor: anchor,
        fraction: _position.fraction,
        section: _position.section,
        label: _position.label,
        tocHref: _position.tocHref,
        viewport: _position.viewport,
      );
      notifyListeners();
    } catch (_) {
      // A settled read that cannot read the anchor keeps the last one.
    }
  }

  void setContinuous(bool value) {
    continuous = value && info?.paginated == true;
    notifyListeners();
  }

  void setStatus(String value) {
    _status = value;
    notifyListeners();
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _subscription.cancel();
    scrollMetrics.dispose();
    super.dispose();
  }
}
