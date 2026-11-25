// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';
import '../reader/reader_motion.dart';

/// Top-to-bottom PDF: one column centred on the widest page, with [gap] only
/// between pages. Fit-width therefore puts the widest page edge to edge, and
/// the canvas colour shows only in the gaps and around a zoomed-out column.
PdfPageLayout continuousPdfLayout(List<Size> sizes, {required double gap}) {
  final width = sizes.fold(0.0, (w, size) => math.max(w, size.width));
  final pages = <Rect>[];
  var y = 0.0;
  for (final size in sizes) {
    if (pages.isNotEmpty) y += gap;
    pages.add(
      Rect.fromLTWH((width - size.width) / 2, y, size.width, size.height),
    );
    y += size.height;
  }
  return PdfPageLayout(pageLayouts: pages, documentSize: Size(width, y));
}

/// Zoom at which the document column exactly fills the viewport width.
double pdfFitWidth(Size view, PdfPageLayout? layout) =>
    layout == null || layout.documentSize.width <= 0
    ? 0
    : view.width / layout.documentSize.width;

/// The view a released pinch settles on. Inside the fit range the zoom
/// becomes exactly fit-width with the column centred and the document row
/// under [focalY] kept where it is; null leaves the pinch result alone.
Matrix4? pdfFitSnap(
  Matrix4 value, {
  required Size view,
  required Size document,
  required double focalY,
}) {
  final zoom = value.getMaxScaleOnAxis();
  final fit = document.width > 0 ? view.width / document.width : 0.0;
  final target = readerSettleZoom(zoom, fit);
  final x = value.getTranslation().x;
  if (target != fit || ((zoom - fit).abs() < 1e-9 && x.abs() < 1e-6)) {
    return null;
  }
  final row = (focalY - value.getTranslation().y) / zoom;
  final height = document.height * fit;
  final y = height <= view.height
      ? (view.height - height) / 2
      : (focalY - row * fit).clamp(view.height - height, 0.0);
  return Matrix4.diagonal3Values(fit, fit, fit)..setTranslationRaw(0, y, 0);
}

/// Continuous PDF zoom range: from [readerMinZoom] of fit-width (or a whole
/// page, if that is smaller) upwards, opening at fit-width. A rotation or window resize keeps a page that was
/// at fit-width at the new fit-width instead of at its old absolute zoom.
class PdfScrollSizing extends PdfViewerSizeDelegateProvider {
  const PdfScrollSizing();

  @override
  PdfViewerSizeDelegate create() => _PdfScrollSizeDelegate();

  @override
  bool operator ==(Object other) => other is PdfScrollSizing;

  @override
  int get hashCode => (PdfScrollSizing).hashCode;
}

class _PdfScrollSizeDelegate extends PdfViewerSizeDelegateLegacy {
  _PdfScrollSizeDelegate()
    : super(
        maxScale: 8,
        minScale: .1,
        useAlternativeFitScaleAsMinScale: false,
        onePassRenderingScaleThreshold: 200 / 72,
        calculateInitialZoom: (_, controller, _, _) =>
            pdfFitWidth(controller.viewSize, controller.layout),
      );

  @override
  PdfViewerLayoutMetrics calculateMetrics({
    required Size viewSize,
    required PdfPageLayout? layout,
    required int? pageNumber,
    required double pageMargin,
    required EdgeInsets? boundaryMargin,
  }) {
    final metrics = super.calculateMetrics(
      viewSize: viewSize,
      layout: layout,
      pageNumber: pageNumber,
      pageMargin: pageMargin,
      boundaryMargin: boundaryMargin,
    );
    final fit = pdfFitWidth(viewSize, layout);
    if (fit <= 0) return metrics;
    return PdfViewerLayoutMetrics(
      // A wide window may need less than half of fit-width to show a whole
      // page; that floor, the previous minimum, stays reachable.
      minScale: math.min(
        fit * readerMinZoom,
        metrics.alternativeFitScale ?? double.infinity,
      ),
      maxScale: math.max(metrics.maxScale, fit),
      coverScale: metrics.coverScale,
      alternativeFitScale: metrics.alternativeFitScale,
    );
  }

  @override
  void onLayoutUpdate({
    required PdfViewerLayoutSnapshot oldState,
    required PdfViewerLayoutSnapshot newState,
    required double currentZoom,
    required Rect oldVisibleRect,
    required int? anchorPageNumber,
    required bool isLayoutChanged,
    required bool isViewSizeChanged,
  }) {
    final oldFit = pdfFitWidth(oldState.viewSize, oldState.layout);
    final newFit = pdfFitWidth(newState.viewSize, newState.layout);
    // The legacy delegate re-fits a page that sat at its minimum scale;
    // here fit-width plays that role.
    final fitted =
        oldFit > 0 && newFit > 0 && (currentZoom / oldFit - 1).abs() < 1e-3;
    PdfViewerLayoutSnapshot withMin(PdfViewerLayoutSnapshot s, double min) =>
        PdfViewerLayoutSnapshot(
          viewSize: s.viewSize,
          layout: s.layout,
          minScale: min,
          coverScale: s.coverScale,
          alternativeFitScale: s.alternativeFitScale,
        );
    super.onLayoutUpdate(
      oldState: fitted ? withMin(oldState, currentZoom) : oldState,
      newState: fitted ? withMin(newState, newFit) : newState,
      currentZoom: currentZoom,
      oldVisibleRect: oldVisibleRect,
      anchorPageNumber: anchorPageNumber,
      isLayoutChanged: isLayoutChanged,
      isViewSizeChanged: isViewSizeChanged,
    );
  }
}
