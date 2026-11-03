// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'package:aquantum_reader/screens/reader_screen.dart';
import 'package:aquantum_reader/reader/reader_shell.dart';
import 'package:aquantum_reader/widgets/reader_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'reader_modes_test.dart' show ComicApi;
import 'reader_shell_test.dart' show book;

class SettingsMatrixApi extends ComicApi {
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (method == 'read_text') {
      return {
        'source': '# 标题\n\n段落正文。\n\n第二段。',
        'paragraphs': ['# 标题', '段落正文。', '第二段。'],
      };
    }
    if (method == 'document_interactions') return <dynamic>[];
    if (method == 'effective_gap') return {'value': 'Gapped', 'source': null};
    if (method == 'effective_direction') {
      return {'value': direction, 'source': null};
    }
    if (method == 'resolve_book_direction') {
      direction = args['direction'];
      return null;
    }
    return super.call(method, args);
  }
}

void main() {
  for (final format in ['Txt', 'Markdown', 'Comic']) {
    testWidgets(
      '$format actual settings controls survive round trips and reopen',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = const Size(1000, 1200);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final api = SettingsMatrixApi();
        Future<void> open() async {
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(platform: TargetPlatform.windows),
              home: ReaderScreen(
                api: api,
                book: book(format),
                initialPosition: 0,
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        Future<void> tap(String label) async {
          final target = find.text(label).last;
          await tester.ensureVisible(target);
          await tester.pumpAndSettle();
          await tester.tap(target);
          await tester.pumpAndSettle();
          if (find.byType(TabBar).evaluate().isEmpty &&
              find.text('更多').hitTestable().evaluate().isNotEmpty) {
            await tester.ensureVisible(find.text('更多').last);
            await tester.tap(find.text('更多').last);
            await tester.pumpAndSettle();
          }
          debugPrint(
            'SETTING_MATRIX: $format $label continuous=${tester.widget<ReaderSettingsPanel>(find.byType(ReaderSettingsPanel).last).preferences.continuous} settings=${tester.widget<ReaderSettingsPanel>(find.byType(ReaderSettingsPanel).last).capabilities.settings}',
          );
          expect(tester.takeException(), isNull, reason: label);
        }

        await open();
        await tester.tap(find.byTooltip('阅读设置').hitTestable());
        await tester.pumpAndSettle();
        if (format == 'Txt') {
          await tester.tap(find.text('更多'));
          await tester.pumpAndSettle();
        }
        ReaderPreferences p() => tester
            .widget<ReaderSettingsPanel>(find.byType(ReaderSettingsPanel).last)
            .preferences;
        if (format == 'Comic') {
          for (var i = 0; i < 4; i++) {
            await tap('纵向连续阅读');
          }
          await tap('无缝');
          await tap('有缝');
          await tap('无缝');
          await tap('纵向连续阅读');
          await tap('适应页面');
          await tap('适应宽度');
          for (var i = 0; i < 4; i++) {
            await tap('旋转 · ${p().rotation * 90}°');
          }
        } else {
          for (final mode in ['上下滚动', '左右翻页', '上下滚动', '左右翻页']) {
            await tap(mode);
          }
          await tap('系统字体');
          await tap('衬线字体');
          final sliders = tester
              .widgetList<Slider>(
                find.descendant(
                  of: find.byType(ReaderSettingsPanel),
                  matching: find.byType(Slider),
                ),
              )
              .toList();
          for (final slider in sliders) {
            slider.onChanged!((slider.min + slider.max) / 2);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          }
        }
        await tap('从右到左');
        await tap('从左到右');
        await tap('更多');
        for (final theme in ['纸张', '夜间', '跟随应用', '纸张']) {
          await tap(theme);
        }
        for (var i = 0; i < 4; i++) {
          await tap('页面切换动画');
        }
        for (final dock in ['下', '左', '右', '隐藏', '上']) {
          await tap(dock);
        }
        expect(p().theme, 'paper');
        expect(p().dock, 'top');
        expect(p().rightToLeft, isFalse);
        await p().save(bookId: 'test-$format');
        final before = (await SharedPreferences.getInstance()).getString(
          'reader-ui.v2.test-$format',
        );
        await tester.tap(find.byTooltip('关闭面板'));
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
        await open();
        expect(find.byType(ReaderShell), findsOneWidget);
        final restored = ReaderPreferences();
        await restored.load(bookId: 'test-$format', format: format);
        await restored.save(bookId: 'test-$format');
        final after = (await SharedPreferences.getInstance()).getString(
          'reader-ui.v2.test-$format',
        );
        expect(jsonDecode(after!), jsonDecode(before!));
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
