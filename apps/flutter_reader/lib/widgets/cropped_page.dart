// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';

/// Non-destructive trim for one page image.
///
/// The crop is a fraction per edge, so it stays correct at every screen size and
/// never rewrites image bytes. Clipping alone is not enough: the image is scaled
/// to the box first, so trimming the left edge must also shift the scaled child
/// left by the same fraction of the *scaled* width. [CroppedPage] therefore
/// oversizes the child to the untrimmed size and translates it by percentages of
/// that larger size, keeping the visible window exactly the kept region.
class CroppedPage extends StatelessWidget {
  final double left, top, right, bottom;
  final Widget child;

  /// Aspect ratio (width / height) of the *uncropped* page, when known. The
  /// visible window takes the cropped ratio so neighbouring slots stay stable.
  final double? aspectRatio;

  const CroppedPage({
    super.key,
    required this.child,
    this.left = 0,
    this.top = 0,
    this.right = 0,
    this.bottom = 0,
    this.aspectRatio,
  });

  /// True when nothing would change, so callers can skip the extra layout cost.
  bool get isIdentity =>
      left <= 0 && top <= 0 && right <= 0 && bottom <= 0 && aspectRatio == null;

  @override
  Widget build(BuildContext context) {
    if (isIdentity) return child;
    // Never let a corrupt record collapse the page to nothing.
    final width = (1 - left - right).clamp(.1, 1.0);
    final height = (1 - top - bottom).clamp(.1, 1.0);
    final ratio = aspectRatio == null ? null : aspectRatio! * width / height;
    Widget clipped = LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth.isFinite ? constraints.maxWidth : 0.0;
        final h = constraints.maxHeight.isFinite ? constraints.maxHeight : 0.0;
        return ClipRect(
          child: OverflowBox(
            alignment: Alignment.topLeft,
            minWidth: w / width,
            maxWidth: w / width,
            minHeight: h / height,
            maxHeight: h / height,
            child: Transform.translate(
              offset: Offset(-left * (w / width), -top * (h / height)),
              child: child,
            ),
          ),
        );
      },
    );
    if (ratio != null && ratio.isFinite && ratio > 0) {
      clipped = AspectRatio(aspectRatio: ratio, child: clipped);
    }
    return clipped;
  }
}
