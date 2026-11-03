// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:aquantum_reader/reader/text_pagination.dart';
import 'package:aquantum_reader/screens/reader_screen.dart';
import 'package:aquantum_reader/widgets/reader_settings.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'reader_landscape_test.dart' show LongTextApi;
import 'reader_shell_test.dart' show book;

/// The shared pre-RC007 record as the last comic reader left it: continuous
/// strip, seamless, fit width, right-to-left and a text scroll choice.
String legacyRecord() => jsonEncode({
  'version': 1,
  'lineHeight': 2.2,
  'paragraphGap': 30,
  'margin': 32,
  'font': 'system',
  'theme': 'paper',
  'dock': 'top',
  'continuous': true,
  'textPaged': false,
  'rotation': 1,
  'pageAnimation': true,
  'seamless': true,
  'rightToLeft': true,
  'fit': 'width',
  'weight': 500,
});

void main() {
  group('legacy reader-ui.v1 fallback', () {
    setUp(
      () => SharedPreferences.setMockInitialValues({
        'reader-ui.v1': legacyRecord(),
      }),
    );

    test('carries only the visual axis into another format', () async {
      final epub = ReaderPreferences();
      await epub.load(bookId: 'new-epub', format: 'Epub');
      // Visual settings follow the reader everywhere.
      expect(epub.theme, 'paper');
      expect(epub.lineHeight, 2.2);
      expect(epub.font, 'system');
      expect(epub.weight, 500);
      // The comic's layout must not turn a new EPUB into a scroll.
      expect(epub.continuous, isFalse);
      expect(epub.textPaged, isTrue);
      expect(epub.rightToLeft, isFalse);
      expect(epub.rotation, 0);

      final markdown = ReaderPreferences();
      await markdown.load(bookId: 'new-md', format: 'Markdown');
      expect(markdown.textPaged, isFalse, reason: 'Markdown default scroll');

      final pdf = ReaderPreferences();
      await pdf.load(bookId: 'new-pdf', format: 'Pdf');
      expect(pdf.fit, 'width');
      expect(pdf.seamless, isFalse);
      expect(pdf.continuous, isTrue);
    });

    test('keeps an explicit legacy choice for the same kind of book', () async {
      final comic = ReaderPreferences();
      await comic.load(bookId: 'old-comic', format: 'Comic');
      expect(comic.continuous, isTrue);
      expect(comic.seamless, isTrue);
      expect(comic.rotation, 1);

      final text = ReaderPreferences();
      await text.load(bookId: 'old-txt', format: 'Txt');
      expect(
        text.textPaged,
        isTrue,
        reason: 'shared legacy mode cannot override format default',
      );
    });

    test(
      'a book with its own record is never mixed with the legacy one',
      () async {
        final own = ReaderPreferences()
          ..theme = 'dark'
          ..continuous = false
          ..textPaged = true;
        await own.save(bookId: 'book');
        final restored = ReaderPreferences();
        await restored.load(bookId: 'book', format: 'Comic');
        expect(restored.theme, 'dark');
        expect(restored.continuous, isFalse);
        expect(restored.textPaged, isTrue);
      },
    );
  });

  test('pageFor finds every fragment and steps over unpainted paragraphs', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final paragraphs = [
      List.filled(60, '第一段文字。').join(),
      '',
      List.filled(90, 'second paragraph words ').join(),
      '短段。',
    ];
    final layout = TextPagination.layout(
      paragraphs: paragraphs,
      viewport: const Size(375, 500),
      style: const TextStyle(fontSize: 20, height: 1.6),
      scaler: TextScaler.noScaling,
      direction: TextDirection.ltr,
      margin: 28,
      paragraphGap: 24,
    );
    expect(layout.pages.length, greaterThan(2));
    for (var i = 0; i < layout.pages.length; i++) {
      for (final f in layout.pages[i].fragments) {
        expect(layout.pageFor(f.paragraph, f.start), i);
        expect(layout.pageFor(f.paragraph, f.end - 1), i);
      }
    }
    // The empty paragraph paints nothing: it lands where reading continues,
    // never on the last page of the book.
    expect(layout.pageFor(1), layout.pageFor(2));
    expect(layout.pageFor(-1), 0);
    expect(layout.pageFor(99), layout.pages.length - 1);
    // An offset past the end resolves to the paragraph's last page.
    final lastOfFirst = layout.pages.lastIndexWhere(
      (p) => p.fragments.any((f) => f.paragraph == 0),
    );
    expect(layout.pageFor(0, 1 << 20), lastOfFirst);
  });

  testWidgets(
    'a rebuild after a page change never snaps a page being dragged',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = LongTextApi();
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderScreen(api: api, book: book('Txt'), initialPosition: 0),
        ),
      );
      await tester.pumpAndSettle();
      final paged = find.byType(PagedTextReader);
      expect(paged, findsOneWidget, reason: 'TXT opens paged by default');
      PageController controller() => tester
          .widget<PageView>(
            find.descendant(of: paged, matching: find.byType(PageView)),
          )
          .controller!;
      expect(controller().page, 0);

      // Drive the view's own scroll position the way a finger does. This keeps
      // the case independent of which widget wins the gesture arena on top of
      // selectable text (see S-011 for the touch path on real devices).
      final position = controller().position;
      Offset at = const Offset(300, 400);
      final drag = position.drag(DragStartDetails(globalPosition: at), () {});
      Future<void> move(double dx) async {
        at += Offset(dx, 0);
        drag.update(
          DragUpdateDetails(
            globalPosition: at,
            delta: Offset(dx, 0),
            primaryDelta: dx,
          ),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }

      for (var i = 0; i < 12; i++) {
        await move(-20);
      }
      // Past half a page the view reports page 1; the reader saves it and
      // rebuilds. Let those frames and post-frame callbacks run.
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      final during = controller().page!;
      expect(during, greaterThan(.5));
      expect(during, lessThan(1), reason: 'the finger still holds the page');
      await move(-20);
      expect(
        controller().page!,
        greaterThan(during),
        reason: 'the drag keeps following the finger',
      );
      drag.end(DragEndDetails(primaryVelocity: 0));
      await tester.pumpAndSettle();
      expect(controller().page, 1);
      expect(api.position, 0, reason: 'page 1 still starts in paragraph 0');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );

  // S-011: a touch swipe that begins on selectable words must turn the page.
  // The selectable text's drag recognizer (a RawGestureDetector) always uses
  // the framework's 18px slop, while the PageView uses the device slop that
  // Android reports (about 8dp), so on a phone the PageView claims the swipe
  // first. The default test view reports no device slop, which made both 18px
  // and let the deeper text win; give the view an Android-like slop instead.
  Future<PageController> openPagedText(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(375, 812);
    tester.view.devicePixelRatio = 1;
    tester.view.gestureSettings = const ui.GestureSettings(
      physicalTouchSlop: 8,
    );
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetGestureSettings);
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
    final paged = find.byType(PagedTextReader);
    expect(paged, findsOneWidget);
    return tester
        .widget<PageView>(
          find.descendant(of: paged, matching: find.byType(PageView)),
        )
        .controller!;
  }

  Offset onWords(WidgetTester tester) => tester.getCenter(
    find
        .descendant(
          of: find.byType(PagedTextReader),
          matching: find.byType(SelectableText),
        )
        .first,
  );

  testWidgets('a touch swipe that starts on the words turns the page', (
    tester,
  ) async {
    final controller = await openPagedText(tester);
    final gesture = await tester.startGesture(
      onWords(tester),
      kind: PointerDeviceKind.touch,
    );
    // Small steps, as a finger reports them, so the two slops are crossed in
    // their real order.
    for (var i = 0; i < 75; i++) {
      await gesture.moveBy(const Offset(-4, 0));
      await tester.pump(const Duration(milliseconds: 8));
    }
    expect(controller.page, greaterThan(.3), reason: 'the page follows');
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.page, 1);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  testWidgets('a long press on the words still starts a selection', (
    tester,
  ) async {
    await openPagedText(tester);
    await tester.longPressAt(onWords(tester));
    await tester.pumpAndSettle();
    final editable = tester.state<EditableTextState>(
      find.byType(EditableText).first,
    );
    expect(editable.textEditingValue.selection.isCollapsed, isFalse);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });
}
