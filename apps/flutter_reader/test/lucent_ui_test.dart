// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aquantum_reader/design/theme.dart';
import 'package:aquantum_reader/design/widgets.dart';
import 'package:aquantum_reader/design/appearance.dart';
import 'package:aquantum_reader/widgets/book_cover.dart';
import 'reader_shell_test.dart' show book;
import 'reader_landscape_test.dart' show LongTextApi;
import 'reader_shell_test.dart' show ScrollingAdapter, shell;

void main() {
  testWidgets('continuous toolbar overlays the unchanged document canvas', (
    tester,
  ) async {
    for (final desktop in [false, true]) {
      await tester.pumpWidget(shell(ScrollingAdapter(), desktop: desktop));
      await tester.pumpAndSettle();
      final document = find.byWidgetPredicate(
        (w) => w is ColoredBox && w.color == const Color(0xffeeeeee),
      );
      final before = tester.getRect(document);
      await tester.tapAt(before.center);
      await tester.pumpAndSettle();
      expect(tester.getRect(document), before);
      await tester.tapAt(before.center);
      await tester.pumpAndSettle();
      expect(tester.getRect(document), before);
      expect(find.byType(Slider), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }
  });
  test('overview backdrop follows article paper rather than chrome', () {
    for (final paper in [
      Colors.white,
      const Color(0xfff1e8ce),
      const Color(0xffdbe6d6),
    ]) {
      expect(
        readerOverviewBackground(paper).computeLuminance(),
        lessThan(paper.computeLuminance()),
      );
      expect(readerPaperEdge(paper).computeLuminance(), greaterThan(.5));
    }
    for (final paper in [
      const Color(0xff111111),
      const Color(0xff262626),
      const Color(0xff1c2833),
    ]) {
      expect(
        readerOverviewBackground(paper).computeLuminance(),
        greaterThan(paper.computeLuminance()),
      );
      expect(readerPaperEdge(paper).computeLuminance(), lessThan(.25));
    }
  });
  testWidgets('shared palette and book graphics survive narrow 200% text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final palette in AqPalette.values) {
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          AqAppearance(
            palette: palette,
            onChanged: (_) async {},
            child: MaterialApp(
              theme: readerTheme(brightness, palette: palette),
              home: MediaQuery(
                data: const MediaQueryData(
                  size: Size(320, 900),
                  textScaler: TextScaler.linear(2),
                ),
                child: Scaffold(
                  body: ListView(
                    padding: const EdgeInsets.all(22),
                    children: [
                      AqPageHeading(
                        '资料库',
                        actions: [
                          IconButton(
                            onPressed: () {},
                            icon: const Icon(Icons.add),
                          ),
                        ],
                      ),
                      const PaletteSettings(),
                      SizedBox(
                        width: 104,
                        height: 146,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: SizedBox(
                            width: 104,
                            height: 146,
                            child: BookCover(
                              book: book('Txt'),
                              api: LongTextApi(),
                            ),
                          ),
                        ),
                      ),
                      const AqCapsule(child: Text('阅读工具')),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$palette $brightness');
      }
    }
  });
  testWidgets(
    'failed palette persistence keeps the previous selection and reports error',
    (tester) async {
      await tester.pumpWidget(
        AqAppearance(
          palette: AqPalette.lucent,
          onChanged: (_) async => throw StateError('disk full'),
          child: MaterialApp(
            theme: readerTheme(Brightness.light),
            home: const Scaffold(body: PaletteSettings()),
          ),
        ),
      );
      await tester.tap(find.text('纸境'));
      await tester.pumpAndSettle();
      expect(find.textContaining('主题保存失败'), findsOneWidget);
      final selected = tester
          .widgetList<Semantics>(find.byType(Semantics))
          .where((w) => w.properties.selected == true);
      expect(selected.length, 1);
    },
  );
}
