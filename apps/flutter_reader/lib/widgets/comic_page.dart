// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../data/models.dart';
import '../data/reader_api.dart';
import 'cropped_page.dart';
import '../reader/reader_image_viewport.dart';

/// One comic page image with its optional non-destructive trim.
///
/// [crop] is a fraction per edge (0–1). It is applied while drawing only: the
/// imported bytes, the page order and the stored file are untouched, so turning
/// the trim off restores the original picture exactly.
class ComicPage extends StatefulWidget {
  final ReaderApi api;
  final Book book;
  final String page;
  final bool fitWidth;
  final bool interactive;
  final bool pageViewport;
  final Map<String, dynamic>? crop;
  final ValueChanged<bool>? onZoomChanged;
  const ComicPage({
    super.key,
    required this.api,
    required this.book,
    required this.page,
    this.fitWidth = false,
    this.interactive = true,
    this.pageViewport = true,
    this.crop,
    this.onZoomChanged,
  });
  @override
  State<ComicPage> createState() => _ComicPageState();

  /// Recently read page bytes, shared by the reader, its page overview and
  /// thumbnails so one page is fetched and base64-decoded once, not once per
  /// widget that shows it. Only finished reads are kept, and failures never
  /// are, so a retry always reaches the core. Entries are compressed files.
  static final _recent = <String, Uint8List>{};
  static const _recentLimit = 12;
  static const _recentByteLimit = 32 * 1024 * 1024;
  static int _recentBytes = 0;
  static final _pending = Expando<Map<String, Future<Uint8List>>>();

  static final _sourceKeys = Expando<Map<String, String>>();
  static String _key(Book book, String page) {
    final keys = _sourceKeys[book] ??= {
      for (final item in book.pages)
        item['id'] as String:
            '${book.id}:${item['resource']['id'] ?? book.revision}:${item['id']}',
    };
    return keys[page] ?? '${book.id}:${book.revision}:$page';
  }

  /// Width / height of every page read so far, from the file header. A
  /// continuous strip uses them to weigh pages by their real displayed
  /// height; pages not read yet are estimated until they are.
  static final _ratios = <String, double>{};

  /// Bumped whenever a new ratio is learned.
  static int ratioVersion = 0;
  static double? ratioOf(Book book, String page) => _ratios[_key(book, page)];
  static void _learn(String key, Uint8List data) {
    if (_ratios.containsKey(key)) return;
    final ratio = decodeImageRatio(data);
    if (ratio == null) return;
    _ratios[key] = ratio;
    ratioVersion++;
  }

  /// Bytes already read for [page], if any; lets a turn paint without a frame
  /// of loading indicator when the page was prefetched.
  static Uint8List? peek(Book book, String page) => _recent[_key(book, page)];

  static Future<Uint8List> load(ReaderApi api, Book book, String page) {
    final key = _key(book, page);
    final cached = _recent.remove(key);
    if (cached != null) {
      _recent[key] = cached;
      return Future.value(cached);
    }
    final pending = _pending[api] ??= {};
    return pending[key] ??= _load(api, book, page, key).whenComplete(() {
      pending.remove(key);
    });
  }

  static Future<Uint8List> _load(
    ReaderApi api,
    Book book,
    String page,
    String key,
  ) async {
    final value = await api.call('read_image', {'book': book.id, 'page': page});
    final data = base64Decode((value as String).split(',').last);
    _learn(key, data);
    // Large pages remain readable at original quality; only optional retained
    // compressed bytes are bounded. Do not evict useful pages for an oversize one.
    if (data.lengthInBytes <= _recentByteLimit) {
      _recentBytes -= _recent.remove(key)?.lengthInBytes ?? 0;
      _recent[key] = data;
      _recentBytes += data.lengthInBytes;
      while (_recent.length > _recentLimit || _recentBytes > _recentByteLimit) {
        _recentBytes -= _recent.remove(_recent.keys.first)!.lengthInBytes;
      }
    }
    return data;
  }

  /// Starts reading [page] before it is shown, so a turn does not wait for it.
  static void prefetch(ReaderApi api, Book book, String page) =>
      unawaited(load(api, book, page).then((_) {}, onError: (Object _) {}));
}

class _ComicPageState extends State<ComicPage> {
  final transformation = TransformationController();
  @override
  void dispose() {
    transformation.dispose();
    super.dispose();
  }

  double edge(String key) =>
      (widget.crop?[key] as num?)?.toDouble().clamp(0.0, 1.0) ?? 0.0;

  late final Future<Uint8List> bytes = ComicPage.load(
    widget.api,
    widget.book,
    widget.page,
  );

  /// Page ratio from the already decoded picture, so the trimmed window can
  /// keep the cropped aspect instead of the original one.
  double? ratio;
  void rememberRatio(Uint8List data) {
    final size = decodeImageRatio(data);
    if (size != ratio) {
      ratio = size;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && size != null) setState(() {});
      });
    }
  }

  /// Thumbnails and page previews never zoom, so they decode at the width
  /// they occupy instead of the full scan resolution (a 3000px page is ~36MB
  /// decoded); a trimmed page is decoded wide enough for its visible window.
  ImageProvider _decodeSize(BuildContext context, Uint8List data) {
    final provider = MemoryImage(data);
    if (widget.interactive || _width == null) return provider;
    final visible = (1 - edge('left') - edge('right')).clamp(.1, 1.0);
    final pixels = _width! * MediaQuery.devicePixelRatioOf(context) / visible;
    return ResizeImage.resizeIfNeeded(pixels.ceil(), null, provider);
  }

  double? _width;

  // Only non-interactive pages measure their width; an interactive page keeps
  // its original tree so zoom and pan behave exactly as before.
  @override
  Widget build(BuildContext context) => widget.interactive
      ? _content(context)
      : LayoutBuilder(
          builder: (context, constraints) {
            _width = constraints.hasBoundedWidth && constraints.maxWidth > 0
                ? constraints.maxWidth
                : null;
            return _content(context);
          },
        );

  Widget _content(BuildContext context) => FutureBuilder<Uint8List>(
    future: bytes,
    initialData: ComicPage.peek(widget.book, widget.page),
    builder: (context, result) {
      if (result.hasError) return Center(child: Text('图片读取失败：${result.error}'));
      if (!result.hasData) {
        return SizedBox(
          height: widget.fitWidth ? MediaQuery.sizeOf(context).height : null,
          child: const Center(child: CircularProgressIndicator()),
        );
      }
      rememberRatio(result.data!);
      final image = Image(
        image: _decodeSize(context, result.data!),
        fit: widget.fitWidth ? BoxFit.fitWidth : BoxFit.contain,
        width: widget.fitWidth ? MediaQuery.sizeOf(context).width : null,
        semanticLabel: '${widget.book.title} 漫画页面',
        errorBuilder: (_, _, _) =>
            const Center(child: Text('图片损坏或格式无法解码。原始副本已保留。')),
      );
      final content = Center(
        child: CroppedPage(
          left: edge('left'),
          top: edge('top'),
          right: edge('right'),
          bottom: edge('bottom'),
          aspectRatio: widget.fitWidth && widget.pageViewport ? null : ratio,
          child: image,
        ),
      );
      return Padding(
        padding: EdgeInsets.all(widget.fitWidth ? 0 : 12),
        child: !widget.interactive
            ? content
            : widget.pageViewport
            ? InteractiveViewer(
                constrained: !widget.fitWidth,
                transformationController: transformation,
                onInteractionUpdate: (_) => widget.onZoomChanged?.call(
                  transformation.value.getMaxScaleOnAxis() > 1.01,
                ),
                minScale: 1,
                maxScale: 5,
                child: content,
              )
            : ReaderImageViewport(
                controller: transformation,
                onZoomChanged: widget.onZoomChanged,
                child: content,
              ),
      );
    },
  );
}

/// Width / height of a PNG, JPEG, GIF or BMP header, or `null` when unknown.
///
/// Reading the header directly avoids a second decode just to learn the size.
double? decodeImageRatio(Uint8List data) {
  int? width, height;
  if (data.length >= 24 &&
      data[0] == 0x89 &&
      data[1] == 0x50 &&
      data[2] == 0x4E &&
      data[3] == 0x47) {
    final header = ByteData.sublistView(data);
    width = header.getUint32(16);
    height = header.getUint32(20);
  } else if (data.length >= 10 &&
      data[0] == 0x47 &&
      data[1] == 0x49 &&
      data[2] == 0x46) {
    final header = ByteData.sublistView(data);
    width = header.getUint16(6, Endian.little);
    height = header.getUint16(8, Endian.little);
  } else if (data.length >= 26 && data[0] == 0x42 && data[1] == 0x4D) {
    final header = ByteData.sublistView(data);
    width = header.getInt32(18, Endian.little).abs();
    height = header.getInt32(22, Endian.little).abs();
  } else if (data.length >= 4 && data[0] == 0xFF && data[1] == 0xD8) {
    var offset = 2;
    while (offset + 9 < data.length) {
      if (data[offset] != 0xFF) {
        offset++;
        continue;
      }
      final marker = data[offset + 1];
      if (marker == 0xD8 ||
          marker == 0x01 ||
          (marker >= 0xD0 && marker <= 0xD7)) {
        offset += 2;
        continue;
      }
      final length = (data[offset + 2] << 8) | data[offset + 3];
      final isStartOfFrame =
          marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (isStartOfFrame) {
        height = (data[offset + 5] << 8) | data[offset + 6];
        width = (data[offset + 7] << 8) | data[offset + 8];
        break;
      }
      if (length < 2) break;
      offset += 2 + length;
    }
  }
  if (width == null || height == null || width <= 0 || height <= 0) return null;
  return width / height;
}
