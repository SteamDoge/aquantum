// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';

import 'package:aquantum_reader/widgets/comic_page.dart';
import 'package:aquantum_reader/widgets/cropped_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Builds the smallest PNG header that `decodeImageRatio` can read.
Uint8List pngHeader(int width, int height) {
  final data = Uint8List(24);
  data.setRange(0, 4, const [0x89, 0x50, 0x4E, 0x47]);
  final view = ByteData.sublistView(data);
  view.setUint32(16, width);
  view.setUint32(20, height);
  return data;
}

void main() {
  testWidgets('crop samples the intended central color bands', (tester) async {
    const capture = ValueKey('crop-pixels');
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: RepaintBoundary(
            key: capture,
            child: SizedBox(
              width: 100,
              height: 40,
              child: CroppedPage(
                left: .25,
                right: .25,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: ColoredBox(color: Color(0xffff0000))),
                    Expanded(child: ColoredBox(color: Color(0xff00ff00))),
                    Expanded(child: ColoredBox(color: Color(0xff0000ff))),
                    Expanded(child: ColoredBox(color: Color(0xffffff00))),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final colors = await tester.runAsync(() async {
      final image = await tester
          .renderObject<RenderRepaintBoundary>(find.byKey(capture))
          .toImage(pixelRatio: 1);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final values = [
        bytes!.getUint32((20 * 100 + 10) * 4),
        bytes.getUint32((20 * 100 + 90) * 4),
      ];
      image.dispose();
      return values;
    });
    expect(colors, [0x00ff00ff, 0x0000ffff]);
  });
  test('header decode reads PNG sizes without decoding pixels', () {
    expect(decodeImageRatio(pngHeader(1200, 1600)), closeTo(0.75, 1e-9));
  });

  test('unknown header bytes yield no ratio instead of a guess', () {
    expect(decodeImageRatio(Uint8List.fromList([1, 2, 3, 4])), isNull);
    expect(decodeImageRatio(Uint8List(0)), isNull);
  });

  testWidgets('identity crop draws the child unchanged', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 100,
            height: 100,
            child: CroppedPage(child: ColoredBox(color: Colors.black)),
          ),
        ),
      ),
    );
    expect(find.byType(ClipRect), findsNothing);
  });

  testWidgets('crop keeps the visible window at the cropped ratio', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 100,
            height: 100,
            child: CroppedPage(
              // Keep 50% of the width and 80% of the height.
              left: 0.25,
              right: 0.25,
              top: 0.1,
              bottom: 0.1,
              aspectRatio: 1,
              child: ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );
    // The child is oversized to the untrimmed size so the kept region still
    // maps 1:1 onto the visible box.
    final oversize = tester
        .widget<OverflowBox>(find.byType(OverflowBox))
        .maxWidth!;
    expect(oversize, closeTo(200, 1e-6));
    // The page slot takes the cropped ratio so neighbours do not jump.
    final ratio = tester.widget<AspectRatio>(find.byType(AspectRatio));
    expect(ratio.aspectRatio, closeTo(1 * 0.5 / 0.8, 1e-6));
  });

  testWidgets('an absurd record cannot collapse the page to zero', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 100,
            height: 100,
            child: CroppedPage(
              left: 0.9,
              right: 0.9,
              child: ColoredBox(color: Colors.black),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    final oversize = tester
        .widget<OverflowBox>(find.byType(OverflowBox))
        .maxWidth!;
    expect(oversize.isFinite, isTrue);
    expect(oversize, closeTo(1000, 1e-6));
  });
}
