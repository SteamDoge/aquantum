// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:aquantum_reader/formats/pdf_horizontal_layout.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const viewport = Size(1000, 400);
  const page = Size(300, 200);

  group('horizontalPdfLayout', () {
    test('pads both ends so the first and last page centre at cover scale', () {
      final layout = horizontalPdfLayout(
        const [page, page, page],
        margin: 12,
        viewport: viewport,
        rightToLeft: false,
      );
      final cover = 400 / (200 + 24);
      expect(layout.documentSize, const Size(1184, 224));
      expect(layout.pageLayouts.first.center.dx, closeTo(500 / cover, 0.001));
      expect(
        layout.pageLayouts.last.center.dx,
        closeTo(layout.documentSize.width - 500 / cover, 0.001),
      );
      expect(layout.pageLayouts[1].left - layout.pageLayouts[0].right, 12);
      expect(layout.pageLayouts[2].left - layout.pageLayouts[1].right, 12);
    });

    test('mirrors the strip for right-to-left reading', () {
      final layout = horizontalPdfLayout(
        const [page, page, page],
        margin: 12,
        viewport: viewport,
        rightToLeft: true,
      );
      final cover = 400 / (200 + 24);
      expect(layout.documentSize, const Size(1184, 224));
      // 第一页排到最右，但到右边界仍是半视口的留白。
      expect(
        layout.documentSize.width - layout.pageLayouts.first.center.dx,
        closeTo(500 / cover, 0.001),
      );
      expect(layout.pageLayouts.last.center.dx * cover, closeTo(500, 0.001));
      expect(cv(layout.pageLayouts), [-1, -1]);
    });

    test('adds no padding when pages already fill the viewport width', () {
      final layout = horizontalPdfLayout(
        const [Size(1200, 200)],
        margin: 12,
        viewport: viewport,
        rightToLeft: false,
      );
      expect(layout.pageLayouts.single.left, 12);
      expect(layout.documentSize, const Size(1224, 224));
    });

    test('keeps pages vertically centred inside the tallest page strip', () {
      final layout = horizontalPdfLayout(
        const [Size(300, 200), Size(300, 400)],
        margin: 10,
        viewport: viewport,
        rightToLeft: false,
      );
      expect(layout.documentSize.height, 420);
      expect(layout.pageLayouts[0].top, 110);
      expect(layout.pageLayouts[1].top, 10);
    });

    test('returns an empty layout for an empty document', () {
      final layout = horizontalPdfLayout(
        const [],
        margin: 12,
        viewport: viewport,
        rightToLeft: false,
      );
      expect(layout.pageLayouts, isEmpty);
      expect(layout.documentSize, Size.zero);
    });
  });

  group('horizontalCenterMatrix', () {
    test('centres the page horizontally and keeps the vertical pan', () {
      final current = Matrix4.identity()..setTranslationRaw(0, -30, 0);
      final matrix = horizontalCenterMatrix(
        current: current,
        viewport: viewport,
        page: const Rect.fromLTWH(100, 0, 300, 200),
        zoom: 1,
      );
      expect(matrix, isNotNull);
      expect(matrix!.getTranslation().x, 250);
      expect(matrix.getTranslation().y, -30);
      expect(matrix.getTranslation().z, 0);
    });

    test('keeps the current zoom untouched', () {
      final current = Matrix4.diagonal3Values(2, 2, 1)
        ..setTranslationRaw(10, 20, 0);
      final matrix = horizontalCenterMatrix(
        current: current,
        viewport: viewport,
        page: const Rect.fromLTWH(0, 0, 300, 200),
        zoom: 2,
      );
      expect(matrix!.getMaxScaleOnAxis(), 2);
      expect(matrix.getTranslation().x, 200);
      expect(matrix.getTranslation().y, 20);
    });

    test('returns null once the page is wider than the viewport', () {
      expect(
        horizontalCenterMatrix(
          current: Matrix4.identity(),
          viewport: viewport,
          page: const Rect.fromLTWH(0, 0, 1200, 200),
          zoom: 1,
        ),
        isNull,
      );
    });

    test('returns null for a non-positive zoom or viewport', () {
      expect(
        horizontalCenterMatrix(
          current: Matrix4.identity(),
          viewport: viewport,
          page: const Rect.fromLTWH(0, 0, 300, 200),
          zoom: 0,
        ),
        isNull,
      );
      expect(
        horizontalCenterMatrix(
          current: Matrix4.identity(),
          viewport: Size.zero,
          page: const Rect.fromLTWH(0, 0, 300, 200),
          zoom: 1,
        ),
        isNull,
      );
    });
  });

  group('nearestHorizontalPage', () {
    final pages = [
      const Rect.fromLTWH(0, 0, 300, 200),
      const Rect.fromLTWH(312, 0, 300, 200),
      const Rect.fromLTWH(624, 0, 300, 200),
    ];

    test('picks the page whose centre is closest to the viewport centre', () {
      expect(
        nearestHorizontalPage(pages, const Rect.fromLTWH(0, 0, 1000, 400)),
        1,
      );
      expect(
        nearestHorizontalPage(pages, const Rect.fromLTWH(-400, 0, 1000, 400)),
        0,
      );
      expect(
        nearestHorizontalPage(pages, const Rect.fromLTWH(400, 0, 1000, 400)),
        2,
      );
    });

    test('returns -1 when the layout is empty', () {
      expect(nearestHorizontalPage(const [], Rect.zero), -1);
    });
  });
}

/// 相邻页中心的水平间距符号，用来确认右到左时版面确实被镜像。
List<int> cv(List<Rect> pages) => [
  for (var i = 1; i < pages.length; i++)
    pages[i].center.dx.compareTo(pages[i - 1].center.dx),
];
