// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:aquantum_reader/design/widgets.dart';
import 'package:aquantum_reader/formats/pdf_reader.dart';
import 'package:aquantum_reader/formats/pdf_scroll_layout.dart';
import 'package:aquantum_reader/reader/reader_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx/pdfrx.dart';

/// Portrait pages, so a phone-shaped view shows more than one of them.
Uint8List portraitPdf(int count) {
  final objects = <String>[
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Count $count /Kids [${List.generate(count, (i) => '${3 + i * 2} 0 R').join(' ')}] >>',
  ];
  for (var i = 0; i < count; i++) {
    const stream = '0 0 0 rg 30 300 240 60 re f';
    objects.add(
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 420] /Contents ${4 + i * 2} 0 R >>',
    );
    objects.add('<< /Length ${stream.length} >>\nstream\n$stream\nendstream');
  }
  final output = StringBuffer('%PDF-1.7\n');
  final offsets = <int>[];
  for (var i = 0; i < objects.length; i++) {
    offsets.add(output.length);
    output.write('${i + 1} 0 obj\n${objects[i]}\nendobj\n');
  }
  final xref = output.length;
  output.write('xref\n0 ${offsets.length + 1}\n0000000000 65535 f \n');
  for (final offset in offsets) {
    output.write('${offset.toString().padLeft(10, '0')} 00000 n \n');
  }
  output.write(
    'trailer\n<< /Size ${offsets.length + 1} /Root 1 0 R >>\nstartxref\n$xref\n%%EOF\n',
  );
  return Uint8List.fromList(utf8.encode(output.toString()));
}

const view = Size(400, 800);

void main() {
  group('fit snap', () {
    test('settles on fit-width only inside the range', () {
      expect(readerSettleZoom(1.07, 1), 1);
      expect(readerSettleZoom(.93, 1), 1);
      expect(readerSettleZoom(1.09, 1), 1.09);
      expect(readerSettleZoom(.9, 1), .9);
      expect(readerSettleZoom(.5, 1), .5);
    });

    test('snaps the zoom, centres the column and keeps the focal row', () {
      const document = Size(300, 9000);
      final fit = view.width / document.width;
      // Zoomed in by 6%, panned sideways, focal row inside a page.
      final zoom = fit * 1.06;
      final pinched = Matrix4.diagonal3Values(zoom, zoom, zoom)
        ..setTranslationRaw(-9, -2000, 0);
      const focalY = 300.0;
      final row = (focalY + 2000) / zoom;
      final target = pdfFitSnap(
        pinched,
        view: view,
        document: document,
        focalY: focalY,
      )!;
      expect(target.getMaxScaleOnAxis(), closeTo(fit, 1e-9));
      expect(target.getTranslation().x, 0);
      // The same document row stays under the fingers: no page alignment.
      expect(focalY - target.getTranslation().y, closeTo(row * fit, 1e-6));
      final pageTop = (row / 432).floor() * 432.0;
      expect((row - pageTop).abs(), greaterThan(20));
    });

    test('leaves zooms outside the range and an exact fit alone', () {
      const document = Size(300, 9000);
      final fit = view.width / document.width;
      for (final factor in [.6, .9, 1.1, 2.0]) {
        final zoom = fit * factor;
        expect(
          pdfFitSnap(
            Matrix4.diagonal3Values(zoom, zoom, zoom),
            view: view,
            document: document,
            focalY: 400,
          ),
          isNull,
        );
      }
      expect(
        pdfFitSnap(
          Matrix4.diagonal3Values(fit, fit, fit)..setTranslationRaw(0, -50, 0),
          view: view,
          document: document,
          focalY: 400,
        ),
        isNull,
      );
    });

    test('continuous release physics never snaps to pages', () {
      final metrics = FixedScrollMetrics(
        minScrollExtent: 0,
        maxScrollExtent: 9000,
        pixels: 1234,
        viewportDimension: 800,
        axisDirection: AxisDirection.down,
        devicePixelRatio: 1,
      );
      expect(
        readerContinuousPhysics.createBallisticSimulation(metrics, 0),
        isNull,
      );
      final page = ReaderPageScrollPhysics(canSnap: () => false);
      expect(page.createBallisticSimulation(metrics, 0), isNull);
    });
  });

  test('continuous layout gaps only between pages, column centred', () {
    final layout = continuousPdfLayout(const [
      Size(300, 420),
      Size(200, 100),
      Size(300, 420),
    ], gap: 12);
    expect(layout.documentSize, const Size(300, 420 + 12 + 100 + 12 + 420));
    expect(layout.pageLayouts[0], const Rect.fromLTWH(0, 0, 300, 420));
    expect(layout.pageLayouts[1], const Rect.fromLTWH(50, 432, 200, 100));
    expect(layout.pageLayouts[2].top, 544);
    final seamless = continuousPdfLayout(const [
      Size(300, 420),
      Size(300, 420),
    ], gap: 0);
    expect(seamless.pageLayouts[1].top, 420);
    expect(pdfFitWidth(view, layout), view.width / 300);
  });

  testWidgets('gap and outside share one canvas colour in every palette', (
    tester,
  ) async {
    for (final theme in ['white', 'paper', 'dark']) {
      final paper = pdfPaper(theme, Brightness.light);
      final canvas = readerGapColor(paper);
      final key = GlobalKey();
      // A zoomed-out column: two white pages with a transparent gap, and
      // transparent space on both sides, exactly what the viewer paints.
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 100,
                height: 100,
                child: ColoredBox(
                  color: canvas,
                  child: pdfPalette(
                    theme,
                    Brightness.light,
                    const Stack(
                      children: [
                        Positioned(
                          left: 25,
                          top: 0,
                          width: 50,
                          height: 45,
                          child: ColoredBox(color: Colors.white),
                        ),
                        Positioned(
                          left: 25,
                          top: 55,
                          width: 50,
                          height: 45,
                          child: ColoredBox(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final pixels = await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage();
        final data = await image.toByteData();
        image.dispose();
        return data!;
      });
      Color at(int x, int y) {
        final i = (y * 100 + x) * 4;
        return Color.fromARGB(
          pixels!.getUint8(i + 3),
          pixels.getUint8(i),
          pixels.getUint8(i + 1),
          pixels.getUint8(i + 2),
        );
      }

      bool near(Color a, Color b) =>
          ((a.r - b.r).abs() + (a.g - b.g).abs() + (a.b - b.b).abs()) * 255 < 4;
      final gap = at(50, 50), outside = at(5, 20), page = at(50, 20);
      expect(near(gap, outside), isTrue, reason: theme);
      expect(near(gap, canvas), isTrue, reason: '$theme $gap $canvas');
      expect(
        near(page, paper == const Color(0xff111111) ? Colors.black : paper),
        isTrue,
        reason: '$theme $page',
      );
      expect(near(page, gap), isFalse, reason: theme);
    }
  });

  group('continuous PDF viewer', () {
    late PdfDocument document;
    setUpAll(() async {
      final root = await Directory.systemTemp.createTemp('aq-pdf-scroll-');
      Pdfrx.cacheDirectoryPath = root.path;
      await pdfrxFlutterInitialize();
      document = await PdfDocument.openData(
        portraitPdf(30),
        sourceName: 'scroll.pdf',
      );
    });
    tearDownAll(() async {
      await document.dispose();
    });

    Future<PdfViewerController> pumpViewer(
      WidgetTester tester, {
      bool seamless = false,
      Size size = view,
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final controller = PdfViewerController();
      var pinched = false;
      var focalY = 0.0;
      await tester.pumpWidget(
        MaterialApp(
          home: PdfViewer(
            PdfDocumentRefDirect(document, autoDispose: false),
            controller: controller,
            params: PdfViewerParams(
              margin: 0,
              pageDropShadow: null,
              backgroundColor: Colors.transparent,
              scrollPhysics: readerContinuousPhysics,
              scrollPhysicsScale: readerContinuousPhysics,
              sizeDelegateProvider: const PdfScrollSizing(),
              layoutPages: (pages, _) => continuousPdfLayout([
                for (final page in pages) Size(page.width, page.height),
              ], gap: seamless ? 0 : 12),
              behaviorControlParams: const PdfViewerBehaviorControlParams(
                enableLowResolutionPagePreview: false,
              ),
              onInteractionStart: (_) => pinched = false,
              onInteractionUpdate: (details) {
                if (details.pointerCount > 1) {
                  pinched = true;
                  focalY = details.localFocalPoint.dy;
                }
              },
              onInteractionEnd: (_) {
                if (!pinched) return;
                Future.microtask(() {
                  final target = pdfFitSnap(
                    controller.value,
                    view: controller.viewSize,
                    document: controller.layout.documentSize,
                    focalY: focalY,
                  );
                  if (target != null) {
                    controller.goTo(target, duration: Duration.zero);
                  }
                });
              },
            ),
          ),
        ),
      );
      for (var i = 0; i < 20 && !controller.isReady; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
      // Let the viewer's trailing page loading run out before measuring.
      for (var i = 0; i < 3; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 150));
      }
      expect(controller.isReady, isTrue);
      return controller;
    }

    /// A slow upward crawl (~60 px/s) with a thumb's sideways tremor, after
    /// the pan slop is cleared. Returns the translation after every frame.
    Future<(List<double>, List<double>)> trembleDrag(
      WidgetTester tester,
      PdfViewerController c,
    ) async {
      final gesture = await tester.startGesture(const Offset(200, 600));
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump(const Duration(milliseconds: 16));
      final xs = <double>[], ys = <double>[];
      for (var i = 0; i < 90; i++) {
        await gesture.moveBy(Offset(i.isEven ? 1.5 : -1.5, -1));
        await tester.pump(const Duration(milliseconds: 16));
        final t = c.value.getTranslation();
        xs.add(t.x);
        ys.add(t.y);
      }
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 500));
      return (xs, ys);
    }

    double fit(PdfViewerController c) =>
        view.width / c.layout.documentSize.width;

    Future<void> pinch(WidgetTester tester, double from, double to) async {
      const center = Offset(200, 400);
      final a = await tester.startGesture(center - Offset(from / 2, 0));
      final b = await tester.startGesture(center + Offset(from / 2, 0));
      const steps = 12;
      for (var i = 1; i <= steps; i++) {
        final span = from + (to - from) * i / steps;
        await a.moveTo(center - Offset(span / 2, 0));
        await b.moveTo(center + Offset(span / 2, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await a.up();
      await b.up();
      for (var i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
    }

    testWidgets('opens at fit-width with the page edge to edge', (
      tester,
    ) async {
      final c = await pumpViewer(tester);
      expect(c.currentZoom, closeTo(fit(c), 1e-6));
      expect(c.value.getTranslation().x, closeTo(0, 1e-6));
      expect(c.minScale, closeTo(fit(c) * readerMinZoom, 1e-6));
    });

    testWidgets('a wide window can still zoom out to a whole page', (
      tester,
    ) async {
      final c = await pumpViewer(tester, size: const Size(1600, 900));
      final fitWidth = 1600 / c.layout.documentSize.width;
      expect(c.currentZoom, closeTo(fitWidth, 1e-6));
      expect(c.minScale, closeTo(900 / 420, 1e-6));
      expect(c.minScale, lessThan(fitWidth * readerMinZoom));
    });

    // Note: a pinch starts only after its span moves past the scale slop, so
    // the zoom a pinch reaches is to / (from ± 36), not to / from.
    testWidgets('zooms out below fit-width with the column centred', (
      tester,
    ) async {
      final c = await pumpViewer(tester);
      await pinch(tester, 300, 150); // about 0.57 of fit
      final zoom = c.currentZoom;
      expect(zoom, lessThan(fit(c) * .9));
      expect(zoom, greaterThanOrEqualTo(fit(c) * readerMinZoom - 1e-6));
      final width = c.layout.documentSize.width * zoom;
      expect(c.value.getTranslation().x, closeTo((view.width - width) / 2, .5));
      // A deeper pinch stops at the minimum instead of shrinking further.
      await pinch(tester, 300, 40);
      expect(c.currentZoom, closeTo(fit(c) * readerMinZoom, 1e-3));
    });

    testWidgets('a pinch released near fit-width settles exactly on it', (
      tester,
    ) async {
      final c = await pumpViewer(tester);
      await pinch(tester, 200, 250); // about +6%: settles on fit-width
      expect(c.currentZoom, closeTo(fit(c), 1e-6));
      expect(c.value.getTranslation().x, closeTo(0, 1e-6));
      await pinch(tester, 200, 156); // about -5% from fit: settles too
      expect(c.currentZoom, closeTo(fit(c), 1e-6));
      await pinch(tester, 200, 284); // about +20%: a deliberate zoom stays
      expect(c.currentZoom / fit(c), closeTo(1.2, .02));
    });

    testWidgets('a slow trembling drag at fit-width stays on its column', (
      tester,
    ) async {
      final c = await pumpViewer(tester);
      final (xs, ys) = await trembleDrag(tester, c);
      expect(xs.every((x) => x.abs() < 1e-6), isTrue, reason: '$xs');
      for (var i = 1; i < ys.length; i++) {
        expect(ys[i], lessThanOrEqualTo(ys[i - 1] + 1e-9));
      }
      expect(ys.first - ys.last, closeTo(89, 1));
    });

    testWidgets('above fit-width the same drag shakes sideways', (
      tester,
    ) async {
      // The jitter mechanism: past fit-width the page pans freely in 2D, so
      // a thumb's tremor moves it sideways on every frame. The fit snap keeps
      // near-fit pinches out of this state.
      final c = await pumpViewer(tester);
      await pinch(tester, 200, 284);
      final (xs, ys) = await trembleDrag(tester, c);
      var reversals = 0;
      for (var i = 2; i < xs.length; i++) {
        if ((xs[i] - xs[i - 1]) * (xs[i - 1] - xs[i - 2]) < 0) reversals++;
      }
      expect(reversals, greaterThan(40));
      expect(ys.first, greaterThan(ys.last));
    });
  });
}
