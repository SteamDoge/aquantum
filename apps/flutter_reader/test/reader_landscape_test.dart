// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'package:aquantum_reader/reader/reader_shell.dart';
import 'package:aquantum_reader/widgets/reader_settings.dart';
import 'package:aquantum_reader/reader/text_pagination.dart';
import 'package:aquantum_reader/reader/reader_page_overview.dart';
import 'package:aquantum_reader/reader/reader_toolbar.dart';
import 'package:aquantum_reader/screens/reader_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'reader_shell_test.dart' show book;
import 'reader_modes_test.dart' show ComicApi;
import 'library_test.dart' show TestApi;

class LongTextApi extends TestApi {
  final source = List.filled(
    160,
    '窗口按实际宽度排版，长段落也必须跨真实页面。 mixed words 😀 ',
  ).join();
  @override
  Future<dynamic> call(String method, [Map<String, dynamic> args = const {}]) =>
      method == 'read_text'
      ? Future.value({
          'paragraphs': [source],
        })
      : super.call(method, args);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'real line pagination preserves every source character across reflow',
    () {
      TestWidgetsFlutterBinding.ensureInitialized();
      final paragraphs = [
        List.filled(90, '中文 mixed words 😀👩‍💻 é 文本。').join(),
        '含换行\n第二行\n\n第四行，结尾。',
        List.filled(80, 'another long paragraph with real wrapping. ').join(),
      ];
      for (final viewport in [
        const Size(375, 812),
        const Size(812, 375),
        const Size(1280, 720),
      ]) {
        final layout = TextPagination.layout(
          paragraphs: paragraphs,
          viewport: viewport,
          style: const TextStyle(fontSize: 20, height: 1.8),
          scaler: TextScaler.noScaling,
          direction: TextDirection.ltr,
          margin: 28,
          paragraphGap: 24,
        );
        expect(layout.pages.length, greaterThan(1));
        for (var p = 0; p < paragraphs.length; p++) {
          expect(
            [
              for (final page in layout.pages)
                for (final f in page.fragments)
                  if (f.paragraph == p) f.text,
            ].join(),
            paragraphs[p],
          );
        }
        for (var i = 0; i < layout.pages.length; i++) {
          final anchor = layout.pages[i].anchor;
          expect(layout.pageFor(anchor.paragraph, anchor.start), i);
          if (anchor.text.isNotEmpty) {
            expect(
              anchor.text.codeUnitAt(0),
              isNot(inInclusiveRange(0xdc00, 0xdfff)),
            );
          }
        }
      }
    },
  );
  testWidgets(
    'scrolling uses only a persistent top toolbar on desktop and phone landscape',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final platform in [TargetPlatform.windows, TargetPlatform.android]) {
        await tester.pumpWidget(
          MaterialApp(
            key: ValueKey(platform),
            theme: ThemeData(platform: platform),
            home: ReaderScreen(
              api: TestApi(),
              book: book('Txt'),
              initialPosition: 0,
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (find.byTooltip('阅读设置').hitTestable().evaluate().isEmpty) {
          await tester.tapAt(const Offset(200, 100));
          await tester.pumpAndSettle();
        }
        // Scrolling and paging share one bottom controller, so the toolbar
        // stays where it always is and the slider is always reachable.
        expect(find.byType(Slider), findsOneWidget);
        // The toolbar rides above the controller in the same bottom column, so
        // a phone landscape keeps both reachable in one place.
        if (platform == TargetPlatform.android) {
          expect(
            tester
                .getCenter(find.byKey(const ValueKey('reader-action-settings')))
                .dy,
            lessThan(tester.view.physicalSize.height * 3 / 4),
          );
        } else {
          expect(
            tester
                .getCenter(find.byKey(const ValueKey('reader-action-settings')))
                .dy,
            lessThan(90),
          );
        }
        expect(
          tester.getSize(find.byType(ReaderToolbar)).width,
          greaterThanOrEqualTo(tester.view.physicalSize.width - 56),
        );
        await tester.pump(const Duration(seconds: 5));
        if (platform == TargetPlatform.windows) {
          expect(find.byTooltip('阅读设置').hitTestable(), findsOneWidget);
        }
        await tester.tapAt(const Offset(500, 300));
        await tester.pumpAndSettle();
        expect(find.byTooltip('阅读设置').hitTestable(), findsNothing);
        tester.view.physicalSize = const Size(812, 375);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'paged text keeps source anchors after swipe, resize and reopening',
    (tester) async {
      tester.view.physicalSize = const Size(812, 375);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await (ReaderPreferences()..textPaged = true).save();
      final api = LongTextApi();
      Widget app(String key) => MaterialApp(
        key: ValueKey(key),
        theme: ThemeData(platform: TargetPlatform.windows),
        home: ReaderScreen(
          api: api,
          book: book('Txt'),
          initialPosition: api.position,
        ),
      );
      await tester.pumpWidget(app('first'));
      await tester.pumpAndSettle();
      final first = tester.widget<PagedTextReader>(
        find.byType(PagedTextReader, skipOffstage: false),
      );
      expect(first.layout.pages.length, greaterThan(3));
      final overview = tester.widget<ReaderPageOverview>(
        find.byType(ReaderPageOverview),
      );
      expect(overview.adapter.count, first.layout.pages.length);
      await tester.drag(
        find.byKey(const ValueKey('reader-page-overview')),
        const Offset(-500, 0),
      );
      await tester.pumpAndSettle();
      final prefs = await SharedPreferences.getInstance();
      final anchor = jsonDecode(
        prefs.getString('reader-text-anchor.v1.test-Txt')!,
      );
      expect(anchor['offset'], greaterThan(0));
      expect(
        api.position,
        0,
      ); // Several visual pages belong to the same source paragraph.
      tester.view.physicalSize = const Size(1280, 720);
      await tester.pumpAndSettle();
      final layout = tester
          .widget<PagedTextReader>(
            find.byType(PagedTextReader, skipOffstage: false),
          )
          .layout;
      final shell = tester.widget<ReaderShell>(find.byType(ReaderShell));
      final expected = layout.pageFor(0, anchor['offset']);
      expect(shell.adapter.position, expected);
      // The page paper in the overview has the same source viewport and text layout.
      final preview = tester.widget<ReaderPageOverview>(
        find.byType(ReaderPageOverview),
      );
      expect(preview.pageSize, const Size(1280, 720));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await tester.pumpWidget(app('reopen'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ReaderShell>(find.byType(ReaderShell)).adapter.position,
        expected,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'paged comic overview scales real pages, shows neighbours and swipes to saved page',
    (tester) async {
      // RC007 persists reader axes per book; isolate this case from the
      // preceding mode-switch tests that intentionally save continuous mode.
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'reader-ui.v2.test-Comic-overview',
        jsonEncode({
          'version': 1,
          'lineHeight': 1.9,
          'paragraphGap': 24,
          'margin': 28,
          'font': 'serif',
          'theme': 'system',
          'dock': 'top',
          'continuous': false,
          'textPaged': false,
          'rotation': 0,
          'pageAnimation': true,
          'seamless': false,
          'rightToLeft': false,
          'fit': 'page',
          'weight': 400,
        }),
      );
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = ComicApi();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          home: ReaderScreen(
            api: api,
            book: book('Comic', id: 'test-Comic-overview'),
            initialPosition: 1,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ReaderPageOverview), findsOneWidget);
      final viewport = tester.getRect(
        find.byKey(const ValueKey('reader-page-overview')),
      );
      final centre = tester.getRect(
        find.byKey(const ValueKey('reader-overview-page-1')),
      );
      expect(centre.width, lessThan(viewport.width));
      expect(
        find.byKey(const ValueKey('reader-overview-page-0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('reader-overview-page-2')),
        findsOneWidget,
      );
      await tester.drag(
        find.byKey(const ValueKey('reader-page-overview')),
        const Offset(-700, 0),
      );
      await tester.pumpAndSettle();
      expect(api.position, 2);
      await tester.tap(find.byKey(const ValueKey('reader-overview-page-2')));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderPageOverview), findsNothing);
      expect(find.byTooltip('阅读设置').hitTestable(), findsNothing);
      expect(api.position, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
