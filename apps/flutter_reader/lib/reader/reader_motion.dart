// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/widgets.dart';

/// All native readers use the same bounded fling behavior.
const readerContinuousPhysics = ClampingScrollPhysics();

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
