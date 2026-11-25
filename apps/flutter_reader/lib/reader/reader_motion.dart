// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/widgets.dart';

/// All native readers use the same bounded fling behavior. Its spline is
/// Android's OverScroller fling, the one MJ PDF uses: same friction, same
/// 50..8000 px/s fling window, each axis decelerating on its own, and no
/// flywheel (a new touch stops the old fling instead of adding to it).
const readerContinuousPhysics = ClampingScrollPhysics();

/// Smallest top-to-bottom zoom, relative to fit-width. MJ PDF stops at the
/// same half width; further out the pages turn into thumbnails.
const readerMinZoom = .5;

/// A pinch released within this share of fit-width lands exactly on it.
/// Lifting two fingers moves the zoom by a few percent, so 8% catches a
/// page meant to fill the screen, while a deliberate zoom that trims the
/// usual 5-10% page margins or shows the surroundings stays as released.
const readerFitSnap = .08;

/// The zoom a released pinch settles on. Only zoom ever snaps; continuous
/// reading keeps its scroll position wherever the reader left it.
double readerSettleZoom(double zoom, double fit) =>
    fit > 0 && (zoom / fit - 1).abs() <= readerFitSnap ? fit : zoom;

/// PageView's release decision, also usable by a native transform viewport.
/// Zoomed content pans freely; only an unzoomed horizontal page snaps.
class ReaderPageScrollPhysics extends PageScrollPhysics {
  final bool Function() canSnap;
  const ReaderPageScrollPhysics({required this.canSnap, super.parent});

  @override
  ReaderPageScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      ReaderPageScrollPhysics(canSnap: canSnap, parent: buildParent(ancestor));

  // pdfrx otherwise returns before asking physics to settle a slow drag.
  @override
  double get minFlingVelocity => 0;

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if (position.axis != Axis.horizontal || !canSnap()) {
      return readerContinuousPhysics.createBallisticSimulation(
        position,
        velocity,
      );
    }
    return super.createBallisticSimulation(position, velocity);
  }
}
