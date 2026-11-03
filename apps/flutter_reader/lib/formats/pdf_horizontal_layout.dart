// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:pdfrx/pdfrx.dart';

/// 未裁边 PDF 在「左到右 / 右到左」阅读时使用的横向页面条带。
///
/// pdfrx 会把可见区域裁在文档边界内，首尾页因此无法被移到视口中心。这里在
/// 文档两端按当前视口补对称留白，使第一页与最后一页在初始（cover）缩放下也能
/// 居中；留白同时参与文档宽度，缩放仍由页高决定。
///
/// 版面先按左到右排布，[rightToLeft] 为真时整条镜像；两端留白按同一顺序
/// 计算，镜像后依旧各自贴近对应页，因此首尾页都能居中。
PdfPageLayout horizontalPdfLayout(
  List<Size> pageSizes, {
  required double margin,
  required Size viewport,
  required bool rightToLeft,
}) {
  if (pageSizes.isEmpty) {
    return PdfPageLayout(pageLayouts: const [], documentSize: Size.zero);
  }
  final docHeight =
      pageSizes.fold<double>(0, (h, page) => math.max(h, page.height)) +
      margin * 2;
  final cover = viewport.height > 0 && docHeight > 0
      ? viewport.height / docHeight
      : 1.0;
  // 半视口对应的文档宽度减去页边距与半页宽，即让页中心落在视口中心所需的
  // 两端留白；页本身已足够宽（留白为负）时不补。
  double pad(double pageWidth) =>
      math.max(0, viewport.width / (2 * cover) - margin - pageWidth / 2);
  final padStart = pad(pageSizes.first.width);
  final padEnd = pad(pageSizes.last.width);

  var x = padStart + margin;
  final layouts = <Rect>[];
  for (final page in pageSizes) {
    layouts.add(
      Rect.fromLTWH(x, (docHeight - page.height) / 2, page.width, page.height),
    );
    x += page.width + margin;
  }
  final total = x + padEnd;
  final documentSize = Size(total, docHeight);
  if (!rightToLeft) {
    return PdfPageLayout(pageLayouts: layouts, documentSize: documentSize);
  }
  return PdfPageLayout(
    pageLayouts: [
      for (final rect in layouts)
        Rect.fromLTWH(
          documentSize.width - rect.right,
          rect.top,
          rect.width,
          rect.height,
        ),
    ],
    documentSize: documentSize,
  );
}

/// 把 [page] 的中心水平移到视口中心，保留纵向平移与缩放。
///
/// 页宽在当前缩放下已超出视口时返回 null：此时用户通常是放大后自由平移，
/// 强行吸附会打断阅读。
Matrix4? horizontalCenterMatrix({
  required Matrix4 current,
  required Size viewport,
  required Rect page,
  required double zoom,
}) {
  if (zoom <= 0 || viewport.width <= 0 || viewport.height <= 0) return null;
  if (page.width * zoom > viewport.width + 1) return null;
  final translation = current.getTranslation();
  return current.clone()..setTranslationRaw(
    viewport.width / 2 - page.center.dx * zoom,
    translation.y,
    0,
  );
}

/// 视口中心横向距离最近的页；布局为空时返回 -1。
int nearestHorizontalPage(List<Rect> pages, Rect visible) {
  var best = -1;
  var bestDistance = double.infinity;
  for (var i = 0; i < pages.length; i++) {
    final distance = (pages[i].center.dx - visible.center.dx).abs();
    if (distance < bestDistance) {
      bestDistance = distance;
      best = i;
    }
  }
  return best;
}
