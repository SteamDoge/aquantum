// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

/// Each PDF page gets one viewport-wide slot, exactly like PageView. Page
/// rectangles preserve their original aspect ratio, including mixed sizes.
PdfPageLayout pagedPdfLayout(
  List<Size> sizes, {
  required Size viewport,
  required double margin,
  required bool rightToLeft,
}) {
  if (sizes.isEmpty || viewport.isEmpty) {
    return PdfPageLayout(pageLayouts: const [], documentSize: Size.zero);
  }
  final width = viewport.width;
  final height = viewport.height;
  return PdfPageLayout(
    pageLayouts: [
      for (var i = 0; i < sizes.length; i++)
        () {
          final size = sizes[i];
          final scale = math.min(
            math.max(1, width - 2 * margin) / size.width,
            math.max(1, height - 2 * margin) / size.height,
          );
          final index = rightToLeft ? sizes.length - 1 - i : i;
          return Rect.fromLTWH(
            index * width + (width - size.width * scale) / 2,
            (height - size.height * scale) / 2,
            size.width * scale,
            size.height * scale,
          );
        }(),
    ],
    documentSize: Size(width * sizes.length, height),
  );
}

/// Unit scale keeps one layout slot equal to one Flutter viewport.
double pdfPagedInitialZoom(
  PdfDocument document,
  PdfViewerController controller,
  double fit,
  double cover,
) => 1;
