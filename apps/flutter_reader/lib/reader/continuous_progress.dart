// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import 'reader_contract.dart';

/// Whole-book position of a list reader measured by content length.
///
/// Each item (a paragraph, a Markdown block, a comic page) carries a weight —
/// its characters or its displayed height — so a long chapter counts for more
/// than a short one and the position never means "item N of M". Items that are
/// not laid out are known only by weight, which is why the list can be sought
/// anywhere without loading the book in between.
class WeightedProgress {
  WeightedProgress(Iterable<double> weights) {
    var sum = 0.0;
    for (final weight in weights) {
      final value = weight.isFinite && weight > 0 ? weight : 1.0;
      _starts.add(sum);
      _weights.add(value);
      sum += value;
    }
    total = sum;
  }

  final _starts = <double>[];
  final _weights = <double>[];
  late final double total;

  int get length => _weights.length;

  /// Share of the book before [within] (0–1) of item [index].
  double fractionAt(int index, double within) {
    if (length == 0 || total <= 0) return 0;
    final i = index.clamp(0, length - 1);
    return ((_starts[i] + within.clamp(0.0, 1.0) * _weights[i]) / total).clamp(
      0.0,
      1.0,
    );
  }

  /// The item and the share of it at [fraction] of the book.
  (int, double) locate(double fraction) {
    if (length == 0 || total <= 0) return (0, 0);
    final target = fraction.clamp(0.0, 1.0) * total;
    var low = 0, high = length - 1;
    while (low < high) {
      final middle = (low + high + 1) >> 1;
      if (_starts[middle] <= target) {
        low = middle;
      } else {
        high = middle - 1;
      }
    }
    final within = ((target - _starts[low]) / _weights[low]).clamp(0.0, 1.0);
    return (low, within);
  }

  /// The viewport's place in the book from the list's laid-out items, or
  /// `null` while nothing is laid out.
  ReaderScrollMetrics? measure(Iterable<ItemPosition> positions) {
    final visible =
        positions
            .where(
              (p) =>
                  p.itemTrailingEdge > 0 &&
                  p.itemLeadingEdge < 1 &&
                  p.index >= 0 &&
                  p.index < length,
            )
            .toList()
          ..sort((a, b) => a.index.compareTo(b.index));
    if (visible.isEmpty || total <= 0) return null;
    final first = visible.first;
    var shown = 0.0;
    for (final p in visible) {
      final height = p.itemTrailingEdge - p.itemLeadingEdge;
      if (height <= 0) continue;
      final part =
          (math.min(p.itemTrailingEdge, 1.0) -
              math.max(p.itemLeadingEdge, 0.0)) /
          height;
      shown += part.clamp(0.0, 1.0) * _weights[p.index];
    }
    return ReaderScrollMetrics(
      fractionAt(first.index, withinOf(first)),
      (shown / total).clamp(0.0, 1.0),
    );
  }

  /// How far the top of the viewport is into [position] (0–1).
  static double withinOf(ItemPosition position) {
    final height = position.itemTrailingEdge - position.itemLeadingEdge;
    if (height <= 0) return 0;
    return (-position.itemLeadingEdge / height).clamp(0.0, 1.0);
  }

  /// The first item whose body reaches into the viewport.
  static ItemPosition? firstVisible(Iterable<ItemPosition> positions) {
    ItemPosition? best;
    for (final p in positions) {
      if (p.itemTrailingEdge <= 0 || p.itemLeadingEdge >= 1) continue;
      if (best == null || p.index < best.index) best = p;
    }
    return best;
  }
}

/// Moves a positioned list to any point inside an item, not only its start.
///
/// The list can only align an item's leading edge inside the viewport, so a
/// seek lands on the item first and, once it is laid out, scrolls on by the
/// requested share of its measured height. Every new seek supersedes the
/// pending second step of an older one, so a dragged scrollbar never fights
/// itself.
class PositionedListSeeker {
  PositionedListSeeker({
    required this.items,
    required this.offsets,
    required this.positions,
  });

  final ItemScrollController items;
  final ScrollOffsetController offsets;
  final ItemPositionsListener positions;

  /// The list's own height in logical pixels, refreshed by its layout.
  double viewportExtent = 0;
  int _ticket = 0;

  void jump(int index, double within, {VoidCallback? settled}) {
    if (!items.isAttached) {
      settled?.call();
      return;
    }
    final ticket = ++_ticket;
    // The list publishes item positions after its own layout; the second step
    // waits for that report, so it never measures the layout before the jump.
    void laidOut() {
      positions.itemPositions.removeListener(laidOut);
      if (ticket != _ticket) return;
      unawaited(_refine(ticket, index, within, settled));
    }

    positions.itemPositions.addListener(laidOut);
    items.jumpTo(index: index);
  }

  Future<void> _refine(
    int ticket,
    int index,
    double within,
    VoidCallback? settled,
  ) async {
    ItemPosition? item;
    for (final p in positions.itemPositions.value) {
      if (p.index == index) item = p;
    }
    if (item != null && viewportExtent > 0) {
      final height = item.itemTrailingEdge - item.itemLeadingEdge;
      // Scroll on until the top of the viewport is [within] into the item,
      // from wherever the list put the item (its padding included).
      final pixels = (item.itemLeadingEdge + within * height) * viewportExtent;
      if (pixels.abs() > .5) {
        await offsets.animateScroll(
          offset: pixels,
          duration: const Duration(milliseconds: 1),
        );
      }
    }
    if (ticket == _ticket) settled?.call();
  }
}
