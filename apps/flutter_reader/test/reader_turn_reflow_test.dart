// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aquantum_reader/screens/reader_screen.dart';
import 'package:aquantum_reader/reader/reader_shell.dart';
import 'package:aquantum_reader/reader/reader_renderers.dart';
import 'reader_landscape_test.dart' show LongTextApi;
import 'reader_shell_test.dart' show book;

void main() {
  testWidgets(
    'page intent survives replaced controls and a reflow during animation',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(393, 852);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderScreen(
            api: LongTextApi(),
            book: book('Txt'),
            initialPosition: 0,
          ),
        ),
      );
      await tester.pumpAndSettle();
      PagedTextReaderAdapter adapter() =>
          tester.widget<ReaderShell>(find.byType(ReaderShell)).adapter
              as PagedTextReaderAdapter;
      final old = adapter();
      expect(old.count, greaterThan(3));
      final staleTarget = old.layout.pages[2].anchor;
      tester.view.physicalSize = const Size(812, 375);
      await tester.pumpAndSettle();
      expect(adapter().layout, isNot(same(old.layout)));
      // A pointer started on the former layout before a resize committed.
      old.goTo(2);
      await tester.pumpAndSettle();
      expect(
        adapter().position,
        adapter().layout.pageFor(staleTarget.paragraph, staleTarget.start),
      );
      expect(adapter().position, greaterThan(0));
      final current = adapter();
      final target = current.layout.pages[current.position + 1].anchor;
      current.goTo(current.position + 1);
      // Replace the PageView before its 180ms turn can settle.
      tester.view.physicalSize = const Size(393, 852);
      await tester.pumpAndSettle();
      expect(
        adapter().position,
        adapter().layout.pageFor(target.paragraph, target.start),
      );
      expect(adapter().position, greaterThan(0));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      old.goTo(1);
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
