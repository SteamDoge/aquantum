// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:aquantum_reader/formats/pdf_paged_layout.dart';
import 'package:aquantum_reader/reader/reader_motion.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'PDF page release uses the same PageScrollPhysics trajectory as PageView',
    () {
      final physics = ReaderPageScrollPhysics(canSnap: () => true);
      final metrics = FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 1600,
        pixels: 80,
        viewportDimension: 400,
        axisDirection: AxisDirection.right,
        devicePixelRatio: 1,
      );
      for (final velocity in [0.0, 10.0, 1500.0, -1500.0]) {
        final actual = physics.createBallisticSimulation(metrics, velocity)!;
        final expected = const PageScrollPhysics().createBallisticSimulation(
          metrics,
          velocity,
        )!;
        for (final t in [0.0, .05, .15, .5, 2.0]) {
          expect(actual.x(t), closeTo(expected.x(t), 1e-9));
        }
      }
      expect(
        physics.createBallisticSimulation(metrics, 1500)!.x(5),
        closeTo(400, .01),
      );
      expect(
        physics.createBallisticSimulation(metrics, 0)!.x(5),
        closeTo(0, .01),
      );
    },
  );
  test(
    'continuous PDF and zoomed page use the native readers clamping inertia',
    () {
      for (final axis in [AxisDirection.down, AxisDirection.right]) {
        final metrics = FixedScrollMetrics(
          minScrollExtent: 0,
          maxScrollExtent: 9000,
          pixels: 400,
          viewportDimension: 600,
          axisDirection: axis,
          devicePixelRatio: 1,
        );
        final actual = ReaderPageScrollPhysics(
          canSnap: () => false,
        ).createBallisticSimulation(metrics, 1800)!;
        final expected = readerContinuousPhysics.createBallisticSimulation(
          metrics,
          1800,
        )!;
        expect(actual.x(.15), closeTo(expected.x(.15), 1e-9));
        expect(actual.x(.15), greaterThan(400));
      }
    },
  );
  test(
    'mixed-size PDF pages retain aspect ratio in one viewport slot per page',
    () {
      const sizes = [Size(300, 600), Size(900, 300), Size(500, 500)];
      for (final rtl in [false, true]) {
        final layout = pagedPdfLayout(
          sizes,
          viewport: const Size(400, 700),
          margin: 12,
          rightToLeft: rtl,
        );
        expect(layout.documentSize, const Size(1200, 700));
        for (var i = 0; i < 3; i++) {
          final page = layout.pageLayouts[i];
          expect(page.width / page.height, closeTo(sizes[i].aspectRatio, 1e-9));
          expect(page.center.dx, (rtl ? 2 - i : i) * 400 + 200);
          expect(page.width, lessThanOrEqualTo(376));
          expect(page.height, lessThanOrEqualTo(676));
        }
      }
    },
  );
}
