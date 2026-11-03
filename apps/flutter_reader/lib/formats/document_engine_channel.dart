// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';

import '../reader/reader_contract.dart';
import 'document_engine.dart';

/// Platform hosts only transport messages and mount the browser. All document
/// commands and notifications use this single protocol implementation.
abstract class ChannelDocumentEngine implements DocumentEngine {
  ChannelDocumentEngine(this.channel);
  final DocumentChannel channel;
  bool fixedLayout = false, comic = false, pageEffects = false;
  StreamSubscription<DocumentEvent>? _imageRequests;
  @override
  Future<void> get ready => channel.ready;
  @override
  Stream<DocumentEvent> get events => channel.events;
  @override
  ReaderCapabilities get capabilities => comic
      ? DocumentEngineCapabilities.comic
      : fixedLayout
      ? DocumentEngineCapabilities.fixed
      : pageEffects
      ? DocumentEngineCapabilities.reflowable
      : ReaderCapabilities(
          settings: DocumentEngineCapabilities.reflowable.settings.difference({
            ReaderSetting.turnEffect,
          }),
          search: true,
          navigationLabel: '目录',
        );

  @override
  Future<DocumentInfo> open({
    required Uint8List bytes,
    required String name,
    required String format,
    String? anchor,
  }) async {
    final info = DocumentInfo.parse(
      await channel.call('open', {
        'bytes': base64Encode(bytes),
        'name': name,
        'format': format,
        if (anchor != null && anchor.isNotEmpty) 'anchor': anchor,
      }),
    );
    fixedLayout = !info.paginated;
    pageEffects = info.pageEffects;
    return info;
  }

  /// CBZ imports already own stable, editable image pages in the core. Foliate
  /// asks for only the visible page, without rebuilding or retaining an archive.
  Future<DocumentInfo> openImages({
    required String name,
    required List<String> pages,
    required Future<String> Function(String id) readImage,
    String? anchor,
  }) async {
    comic = true;
    await _imageRequests?.cancel();
    final allowed = pages.toSet();
    _imageRequests = events.listen((event) async {
      if (event.name != 'image-request') return;
      final id = event.detail['id']?.toString() ?? '';
      try {
        if (!allowed.contains(id)) {
          throw const DocumentEngineFailure('图片不属于当前书籍');
        }
        final data = await readImage(id);
        await channel.call('image', {'id': id, 'data': data});
      } catch (e) {
        try {
          await channel.call('image', {'id': id, 'error': '$e'});
        } catch (_) {}
      }
    });
    final info = DocumentInfo.parse(
      await channel.call('open', {
        'name': name,
        'format': 'Comic',
        'images': pages,
        if (anchor != null && anchor.isNotEmpty) 'anchor': anchor,
      }),
    );
    fixedLayout = true;
    return info;
  }

  @override
  Future<void> goTo({String? anchor, int? page}) async {
    await channel.call('goTo', {
      if (anchor != null && anchor.isNotEmpty) 'anchor': anchor,
      'page': ?page,
    });
  }

  @override
  Future<void> goToFraction(double fraction) async {
    await channel.call('goTo', {'fraction': fraction.clamp(0.0, 1.0)});
  }

  @override
  Future<void> goToPoint(Offset point) async {
    await channel.call('point', {'x': point.dx, 'y': point.dy});
  }

  @override
  Future<void> turn(int delta) async {
    await channel.call('turn', {'delta': delta});
  }

  @override
  Future<String> anchor() async =>
      (await channel.call('anchor'))['anchor']?.toString() ?? '';
  @override
  Future<List<DocumentHit>> search(String query, {int limit = 200}) async {
    if (query.trim().isEmpty || comic) return const [];
    final result = await channel.call('search', {
      'query': query,
      'limit': limit.clamp(1, 500),
    });
    final hits = result['hits'];
    if (hits is! List) return const [];
    return [
      for (final hit in hits)
        if (hit is Map && hit['anchor'] is String)
          DocumentHit(
            hit['anchor'],
            hit['label']?.toString() ?? '',
            hit['excerpt']?.toString() ?? '',
          ),
    ].where((hit) => hit.anchor.isNotEmpty).toList();
  }

  @override
  Future<void> style(Map<String, Object?> style) async {
    await channel.call('style', Map<String, dynamic>.from(style));
  }

  Future<void> closeChannel() async {
    try {
      await channel.call('close').timeout(const Duration(milliseconds: 500));
    } catch (_) {}
    await _imageRequests?.cancel();
    channel.close();
  }
}
