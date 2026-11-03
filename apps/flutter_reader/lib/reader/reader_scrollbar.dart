// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';

import 'package:flutter/material.dart';

import 'reader_contract.dart';

/// The whole-book scrollbar of top-to-bottom reading, drawn like a browser's
/// overlay scrollbar.
///
/// It appears while the text scrolls, while it is dragged or hovered, and
/// fades after a short pause, so it never covers the page for long; hidden, it
/// takes no touches, and the right edge of the text scrolls as usual. The thumb
/// is as long as the share of the book on screen, kept between [minThumb] and
/// [maxThumb] so a long book still has a thumb a finger can catch and a short
/// one does not fill the track. The track always spans the whole book.
class ReaderScrollbar extends StatefulWidget {
  final ReaderScrollSource source;
  const ReaderScrollbar({super.key, required this.source});

  static const minThumb = 48.0;

  /// Upper bound as a share of the track.
  static const maxThumbShare = .25;
  static const visibleFor = Duration(milliseconds: 1200);

  /// Thumb length for a track of [track] pixels showing [viewport] of a book.
  static double thumbExtent(double track, double? viewport) {
    if (track <= 0) return 0;
    final upper = (track * maxThumbShare).clamp(
      minThumb.clamp(0.0, track),
      track,
    );
    final lower = minThumb.clamp(0.0, upper);
    final wanted = viewport == null ? lower : track * viewport.clamp(0.0, 1.0);
    return wanted.clamp(lower, upper);
  }

  /// Thumb travel (0 at the top, 1 at the bottom) for [metrics]. The top of a
  /// screen can only reach `1 - viewport`, as in a browser.
  static double travelOf(ReaderScrollMetrics metrics) {
    final reach = 1 - (metrics.viewport ?? 0).clamp(0.0, .999);
    return (metrics.fraction / reach).clamp(0.0, 1.0);
  }

  /// The book fraction a thumb at [travel] stands for.
  static double fractionOf(double travel, double? viewport) =>
      travel.clamp(0.0, 1.0) * (1 - (viewport ?? 0).clamp(0.0, .999));

  @override
  State<ReaderScrollbar> createState() => _ReaderScrollbarState();
}

class _ReaderScrollbarState extends State<ReaderScrollbar> {
  Timer? _hide, _send;
  bool _shown = false, _hovered = false;
  ReaderScrollMetrics? _last;

  /// Thumb travel while a finger or mouse holds it; the reader follows it
  /// rather than the other way round until the drag ends.
  double? _dragTravel;
  double _grab = 0;
  double? _pending;

  ReaderScrollMetrics get metrics => widget.source.metrics.value;

  @override
  void initState() {
    super.initState();
    _last = metrics;
    widget.source.metrics.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant ReaderScrollbar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.source.metrics, widget.source.metrics)) {
      oldWidget.source.metrics.removeListener(_changed);
      widget.source.metrics.addListener(_changed);
      _last = metrics;
    }
  }

  @override
  void dispose() {
    widget.source.metrics.removeListener(_changed);
    _hide?.cancel();
    _send?.cancel();
    super.dispose();
  }

  void _changed() {
    final next = metrics;
    final moved =
        _last == null || (next.fraction - _last!.fraction).abs() > 1e-6;
    _last = next;
    if (!mounted) return;
    if (moved) _reveal();
    setState(() {});
  }

  void _reveal() {
    _hide?.cancel();
    if (!_shown) setState(() => _shown = true);
    _hide = Timer(ReaderScrollbar.visibleFor, () {
      if (!mounted || _dragTravel != null || _hovered) return;
      setState(() => _shown = false);
    });
  }

  void _seek(double travel) {
    _pending = ReaderScrollbar.fractionOf(travel, metrics.viewport);
    // A drag moves many times a frame; the reader follows at a steady pace
    // and always ends exactly where the thumb was let go.
    _send ??= Timer(const Duration(milliseconds: 60), _flush);
  }

  void _flush() {
    _send?.cancel();
    _send = null;
    final target = _pending;
    _pending = null;
    if (target != null) widget.source.seek(target);
  }

  void _start(Offset local, double track, double thumb) {
    final top = ReaderScrollbar.travelOf(metrics) * (track - thumb);
    final onThumb = local.dy >= top && local.dy <= top + thumb;
    // Grabbing the thumb keeps it under the finger; pressing the track moves
    // the thumb's middle there first, as a browser does.
    _grab = onThumb ? local.dy - top : thumb / 2;
    _move(local, track, thumb);
  }

  void _move(Offset local, double track, double thumb) {
    final room = track - thumb;
    final travel = room <= 0
        ? 0.0
        : ((local.dy - _grab) / room).clamp(0.0, 1.0);
    setState(() => _dragTravel = travel);
    _reveal();
    _seek(travel);
  }

  void _end() {
    _flush();
    setState(() => _dragTravel = null);
    _reveal();
  }

  void _step(double delta) {
    final travel = (ReaderScrollbar.travelOf(metrics) + delta).clamp(0.0, 1.0);
    widget.source.seek(ReaderScrollbar.fractionOf(travel, metrics.viewport));
    _reveal();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final active = _dragTravel != null || _hovered;
    final percent = (metrics.fraction * 100).round();
    return LayoutBuilder(
      builder: (context, constraints) {
        final track = constraints.maxHeight;
        final thumb = ReaderScrollbar.thumbExtent(track, metrics.viewport);
        final travel = _dragTravel ?? ReaderScrollbar.travelOf(metrics);
        final top = travel * (track - thumb);
        return MouseRegion(
          opaque: false,
          hitTestBehavior: HitTestBehavior.translucent,
          onEnter: (_) {
            setState(() => _hovered = true);
            _reveal();
          },
          onExit: (_) {
            setState(() => _hovered = false);
            _reveal();
          },
          child: Semantics(
            key: const ValueKey('reader-scrollbar'),
            label: '整本书阅读进度',
            value: '$percent%',
            increasedValue: '${(percent + 5).clamp(0, 100)}%',
            decreasedValue: '${(percent - 5).clamp(0, 100)}%',
            slider: true,
            onIncrease: () => _step(.05),
            onDecrease: () => _step(-.05),
            textDirection: Directionality.of(context),
            child: IgnorePointer(
              ignoring: !_shown,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: (d) =>
                    _start(d.localPosition, track, thumb),
                onVerticalDragUpdate: (d) =>
                    _move(d.localPosition, track, thumb),
                onVerticalDragEnd: (_) => _end(),
                onVerticalDragCancel: _end,
                onTapUp: (d) {
                  _start(d.localPosition, track, thumb);
                  _end();
                },
                child: AnimatedOpacity(
                  opacity: _shown ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: Stack(
                    children: [
                      Positioned(
                        key: const ValueKey('reader-scrollbar-thumb'),
                        right: 3,
                        top: top,
                        height: thumb,
                        width: active ? 8 : 5,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: colors.onSurface.withValues(
                              alpha: active ? .62 : .42,
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Whole-book position for a renderer that only knows "item N of M" (a fixed
/// page book, for now). Each page counts the same, which is honest for pages of
/// one size and the best available until the renderer reports more.
class IndexScrollSource {
  IndexScrollSource(this._seekIndex);
  final void Function(int index) _seekIndex;
  final metrics = ValueNotifier(const ReaderScrollMetrics(0));
  int _count = 0;

  void update(int position, int count) {
    _count = count;
    if (count <= 0) return;
    metrics.value = ReaderScrollMetrics(
      (position / count).clamp(0.0, 1.0),
      1 / count,
    );
  }

  late final source = ReaderScrollSource(
    metrics: metrics,
    seek: (fraction) {
      if (_count <= 0) return;
      _seekIndex((fraction * _count).floor().clamp(0, _count - 1));
    },
  );

  void dispose() => metrics.dispose();
}
