// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import '../data/models.dart';
import '../data/reader_api.dart';
import '../reader/continuous_progress.dart';
import '../reader/reader_contract.dart';
import 'comic_page.dart';

/// Top-to-bottom comic: pages joined into one free scroll that can stop
/// anywhere, including across the join of two pictures.
class ComicStrip extends StatefulWidget {
  final ReaderApi api;
  final Book book;
  final int position, rotation;
  final ItemScrollController controller;
  final ValueChanged<int> onPosition;
  final double initialWithin;
  final void Function(int page, double within)? onAnchor;
  final bool seamless;
  final ValueChanged<bool>? onZoomChanged;

  /// Whole-book position by displayed picture height, for the scrollbar.
  final ValueChanged<ReaderScrollMetrics>? onMetrics;
  final ReaderSeekController? seek;

  /// Page id → insets, resolved once by the screen so scrolling never sends a
  /// native request per frame.
  final Map<String, Map<String, dynamic>>? crops;
  const ComicStrip({
    super.key,
    required this.api,
    required this.book,
    required this.position,
    required this.rotation,
    required this.controller,
    required this.onPosition,
    this.initialWithin = 0,
    this.onAnchor,
    this.seamless = false,
    this.onZoomChanged,
    this.onMetrics,
    this.seek,
    this.crops,
  });

  /// Gap between pages when they are not seamless, in logical pixels.
  static const gap = 12.0;

  /// A page's displayed height per unit of strip width. Pages not read yet
  /// take the average of those that were, or a portrait page when none was.
  static List<double> weights(
    Book book, {
    required int rotation,
    required bool seamless,
    required double width,
  }) {
    final known = <double>[];
    final ratios = <double?>[];
    for (final page in book.pages) {
      final ratio = ComicPage.ratioOf(book, page['id'] as String);
      ratios.add(ratio);
      if (ratio != null) known.add(ratio);
    }
    final fallback = known.isEmpty
        ? 1 / 1.414
        : known.reduce((a, b) => a + b) / known.length;
    final gapShare = seamless || width <= 0 ? 0.0 : gap / width;
    return [
      for (final ratio in ratios)
        // A quarter turn lays the picture on its side.
        (rotation.isOdd ? (ratio ?? fallback) : 1 / (ratio ?? fallback)) +
            gapShare,
    ];
  }

  @override
  State<ComicStrip> createState() => _ComicStripState();
}

class _ComicStripState extends State<ComicStrip> {
  final positions = ItemPositionsListener.create();
  final offsets = ScrollOffsetController();
  late final seeker = PositionedListSeeker(
    items: widget.controller,
    offsets: offsets,
    positions: positions,
  );
  WeightedProgress? _progress;
  Object? _progressKey;
  double width = 0;
  bool restoring = false;

  WeightedProgress get progress {
    final key = (
      ComicPage.ratioVersion,
      widget.rotation,
      widget.seamless,
      width,
      widget.book,
    );
    if (_progress == null || key != _progressKey) {
      _progressKey = key;
      _progress = WeightedProgress(
        ComicStrip.weights(
          widget.book,
          rotation: widget.rotation,
          seamless: widget.seamless,
          width: width,
        ),
      );
    }
    return _progress!;
  }

  @override
  void initState() {
    super.initState();
    positions.itemPositions.addListener(changed);
    widget.seek?.attach(seekTo);
    if (widget.initialWithin > 0) {
      restoring = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        seeker.jump(
          widget.position,
          widget.initialWithin,
          settled: () {
            if (mounted) {
              restoring = false;
              changed();
            }
          },
        );
      });
    }
  }

  @override
  void didUpdateWidget(covariant ComicStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.seek, widget.seek)) {
      oldWidget.seek?.detach(seekTo);
      widget.seek?.attach(seekTo);
    }
  }

  void seekTo(double fraction) {
    if (!widget.controller.isAttached) return;
    restoring = false;
    final (page, within) = progress.locate(fraction);
    seeker.jump(page, within);
  }

  void changed() {
    final value = positions.itemPositions.value;
    final metrics = progress.measure(value);
    if (metrics != null) widget.onMetrics?.call(metrics);
    if (restoring) return;
    final visible =
        value
            .where((p) => p.itemTrailingEdge > 0 && p.itemLeadingEdge < 1)
            .toList()
          ..sort((a, b) => a.index.compareTo(b.index));
    if (visible.isNotEmpty && visible.first.index != widget.position) {
      final index = visible.first.index;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && index != widget.position) widget.onPosition(index);
      });
    }
    if (visible.isNotEmpty && widget.onAnchor != null) {
      final page = visible.first.index;
      final within = WeightedProgress.withinOf(visible.first);
      widget.onAnchor?.call(page, within);
    }
  }

  @override
  void dispose() {
    widget.seek?.detach(seekTo);
    positions.itemPositions.removeListener(changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      seeker.viewportExtent = constraints.maxHeight;
      width = constraints.maxWidth;
      return ScrollablePositionedList.builder(
        initialScrollIndex: widget.position,
        itemCount: widget.book.pages.length,
        itemScrollController: widget.controller,
        scrollOffsetController: offsets,
        itemPositionsListener: positions,
        itemBuilder: (context, i) {
          final page = widget.book.pages[i]['id'] as String;
          return Padding(
            padding: EdgeInsets.only(
              bottom: widget.seamless ? 0 : ComicStrip.gap,
            ),
            child: RotatedBox(
              quarterTurns: widget.rotation,
              child: ComicPage(
                api: widget.api,
                book: widget.book,
                page: page,
                fitWidth: true,
                pageViewport: false,
                crop: widget.crops?[page],
                onZoomChanged: widget.onZoomChanged,
              ),
            ),
          );
        },
      );
    },
  );
}
