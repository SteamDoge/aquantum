// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:aquantum_reader/reader/reader_contract.dart';
import 'package:aquantum_reader/reader/reader_panels.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:aquantum_reader/data/models.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/formats/document_reader.dart';
import 'package:aquantum_reader/reader/reader_shell.dart';
import 'package:aquantum_reader/screens/reader_screen.dart';
import 'package:aquantum_reader/widgets/reader_settings.dart';
import 'package:aquantum_reader/widgets/article_settings_panel.dart';
import 'package:aquantum_reader/widgets/comic_strip.dart';
import 'package:aquantum_reader/reader/continuous_progress.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webview_windows/webview_windows.dart';
import 'qa_storage.dart';

/// Long inputs use the real Rust store and production reader, including WebView.
/// Debug runs verify behavior only; timings are labelled by build mode.
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final allResults = <Map<String, dynamic>>[];
  for (final format
      in (Platform.environment['AQ_LONG_FORMATS'] ??
              'Txt,Markdown,Comic,Pdf,Epub,Fb2,Mobi,Azw3')
          .split(',')) {
    testWidgets('long $format scrolling, paging, reflow and resume', (
      tester,
    ) async {
      await configureQaStorage();
      final support = Platform.environment['AQ_TEST_SUPPORT']!;
      final fixtures = Platform.environment['AQ_LONG_FIXTURES']!;
      final result = <String, dynamic>{
        'format': format,
        'buildMode': kProfileMode ? 'profile' : 'debug',
        'steps': <String, dynamic>{},
      };
      final steps = result['steps'] as Map<String, dynamic>;
      final issues = <String>[];
      final timings = <ui.FrameTiming>[];
      void onTimings(List<ui.FrameTiming> frames) => timings.addAll(frames);
      binding.addTimingsCallback(onTimings);
      final timer = Stopwatch()..start();
      final capture = ValueKey('long-$format');
      final api = RustReaderApi('$support/$format');
      Book? book;
      ReaderShell shell() =>
          tester.widget<ReaderShell>(find.byType(ReaderShell));
      Future<void> waitFor(bool Function() condition, String reason) async {
        for (var i = 0; i < 600; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          if (condition()) return;
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        fail('$format timeout: $reason');
      }

      Future<void> settle() async {
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)),
        );
        await tester.pumpAndSettle(const Duration(milliseconds: 100));
      }

      Widget render({
        double width = 900,
        double height = 650,
        int initial = 0,
      }) => RepaintBoundary(
        key: capture,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            height: height,
            child: MaterialApp(
              home: ReaderScreen(
                api: api,
                book: book!,
                initialPosition: initial,
              ),
            ),
          ),
        ),
      );
      Future<void> ready() async {
        await waitFor(
          () =>
              find.byType(ReaderShell).evaluate().isNotEmpty &&
              shell().adapter.count > 0,
          'reader ready',
        );
        await settle();
        expect(tester.takeException(), isNull);
      }

      Future<void> snapshot(String name) async {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(capture),
        );
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$support/$format-$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      }

      Future<void> settings() async {
        if (find.byTooltip('阅读设置').hitTestable().evaluate().isEmpty) {
          final rect = tester.getRect(
            find.byKey(const ValueKey('reader-content-hit-region')),
          );
          await tester.tapAt(rect.topLeft + const Offset(90, 35));
          await settle();
        }
        await tester.tap(find.byTooltip('阅读设置').hitTestable());
        await settle();
      }

      Future<void> revealSetting(Finder target) async {
        if (target.evaluate().isEmpty) {
          final scrollable = find
              .descendant(
                of: find.byType(ReaderSettingsPanel).last,
                matching: find.byType(Scrollable),
              )
              .first;
          tester.state<ScrollableState>(scrollable).position.jumpTo(0);
          await settle();
          await tester.scrollUntilVisible(target, 160, scrollable: scrollable);
        }
        await tester.ensureVisible(target.last);
        await settle();
      }

      Future<void> tap(String label) async {
        final target = find.text(label);
        await revealSetting(target);
        await tester.tap(target.last);
        await settle();
      }

      Future<void> swatch(String label) async {
        final target = find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.label == label,
        );
        await revealSetting(target);
        await tester.tap(target.last);
        await settle();
      }

      Future<void> immersive() async {
        await tester.tap(find.byTooltip('关闭面板'));
        await settle();
        final overview = find.byKey(const ValueKey('reader-page-overview'));
        if (overview.hitTestable().evaluate().isNotEmpty) {
          await tester.tap(overview);
          await settle();
        }
      }

      try {
        final extension = {
          'Txt': 'txt',
          'Markdown': 'md',
          'Comic': 'cbz',
          'Pdf': 'pdf',
          'Epub': 'epub',
          'Fb2': 'fb2',
          'Azw3': 'azw3',
        }[format];
        final path = format == 'Mobi'
            ? Platform.environment['AQ_LONG_MOBI']!
            : '$fixtures/long.$extension';
        final file = File(path);
        result['inputBytes'] = await file.length();
        final inbox = (await api.call('snapshot'))['catalog']['inbox'];
        final plan = await api.call('preview_import', {
          'target': inbox,
          'paths': [path],
        });
        steps['importIssues'] = plan['issues'];
        await api.call('commit_import', {
          'task': plan['task'],
          'base_revision': plan['base_revision'],
          'target': plan['target'],
          'projects': [
            for (final p in plan['projects'])
              {'id': p['id'], 'name': p['name']},
          ],
          'books': [
            for (final b in plan['books'])
              {
                'id': b['id'],
                'title': b['title'],
                'project': b['project'],
                'resources': [for (final r in b['resources']) r['id']],
              },
          ],
          'skip_issues': false,
          'append': null,
        });
        book = LibrarySnapshot(
          Map<String, dynamic>.from(await api.call('snapshot')),
        ).books.single;
        expect(book.format, format);
        steps['importMs'] = timer.elapsedMilliseconds;
        await (ReaderPreferences()
              ..textPaged = false
              ..continuous = true)
            .save(bookId: book.id);
        if (format == 'Comic' || format == 'Pdf') {
          await api.call('resolve_book_direction', {
            'book': book.id,
            'inherit': false,
            'direction': 'TopToBottom',
          });
        }
        timer.reset();
        await tester.pumpWidget(render());
        await ready();
        steps['openMs'] = timer.elapsedMilliseconds;
        expect(shell().adapter.paged, isFalse);
        expect(shell().scroll, isNotNull);
        Future<dynamic> webState({bool listen = false}) async {
          if (find.byType(Webview).evaluate().isEmpty) return null;
          final controller = tester
              .widget<Webview>(find.byType(Webview))
              .controller;
          if (listen) {
            await tester.runAsync(
              () => controller.executeScript('''(() => {
              window.__longQA = {start:0, move:0, end:0, pointer:0, prevented:0};
              for (const {doc} of document.querySelector('foliate-view').renderer.getContents()) {
                for (const [name,key] of [['touchstart','start'],['touchmove','move'],['touchend','end'],['pointerdown','pointer']])
                  doc.addEventListener(name, e => {window.__longQA[key]++;if(e.defaultPrevented)window.__longQA.prevented++}, {passive:true});
              }
              return true;
            })()'''),
            );
          }
          return tester.runAsync(
            () => controller.executeScript('''(() => {
            const r=document.querySelector('foliate-view').renderer;
            return {scrolled:r.scrolled,start:r.start,end:r.end,size:r.size,viewSize:r.viewSize,input:window.__longQA,
              docs:r.getContents().map(({doc,index})=>({index,chars:doc.body.textContent.length,
                children:[...new Set([...doc.body.children].map(e=>e.tagName))],
                htmlTouch:getComputedStyle(doc.documentElement).touchAction,
                bodyTouch:getComputedStyle(doc.body).touchAction,
                bodyFont:getComputedStyle(doc.body).fontSize,
                firstDivFont:doc.querySelector('div') ? getComputedStyle(doc.querySelector('div')).fontSize : null,
                bodyOverflow:getComputedStyle(doc.body).overflow}))};
          })()'''),
          );
        }

        if (shell().adapter is DocumentReaderAdapter) {
          final doc = shell().adapter as DocumentReaderAdapter;
          steps['documentInfo'] = {
            'reflowable': doc.info!.paginated,
            'outline': doc.info!.outline.length,
          };
        }
        for (final fraction in [.1, .5, .9, .3, .75]) {
          timer.reset();
          shell().scroll!.seek(fraction);
          await waitFor(
            () =>
                (shell().scroll!.metrics.value.fraction - fraction).abs() < .06,
            'seek $fraction; actual ${shell().scroll!.metrics.value.fraction}',
          );
          await settle();
          steps['seek$fraction'] = {
            'ms': timer.elapsedMilliseconds,
            'actual': shell().scroll!.metrics.value.fraction,
          };
          if (fraction == .5) await snapshot('mid-long-paragraph');
        }
        await snapshot('deep-scroll');
        final rect = tester.getRect(
          find.byKey(const ValueKey('reader-content-hit-region')),
        );
        final beforeDrag = shell().scroll!.metrics.value.fraction;
        steps['webBeforeDrag'] = await webState(listen: true);
        for (var i = 0; i < 12; i++) {
          await tester.flingFrom(rect.center, const Offset(0, -180), 1600);
          await tester.pump(const Duration(milliseconds: 150));
        }
        await settle();
        steps['fling12'] = {
          'before': beforeDrag,
          'after': shell().scroll!.metrics.value.fraction,
        };
        steps['webAfterDrag'] = await webState();
        if (shell().scroll!.metrics.value.fraction <= beforeDrag) {
          issues.add('12 touch flings did not advance continuous content');
        }
        // Opening navigation at a deep location must reveal the active entry,
        // not the first page, and closing it must preserve the reading place.
        for (final thumbnails in [false, true]) {
          final tooltip = thumbnails ? '阅读视图与页面导航' : '目录与内容导航';
          if (find.byTooltip(tooltip).hitTestable().evaluate().isEmpty) {
            final area = tester.getRect(
              find.byKey(const ValueKey('reader-content-hit-region')),
            );
            await tester.tapAt(area.topLeft + const Offset(90, 35));
            await settle();
          }
          final tool = find.byTooltip(tooltip);
          await tester.tap(tool.hitTestable());
          await settle();
          final navigation = tester.widget<ReaderNavigationPanel>(
            find.byType(ReaderNavigationPanel).last,
          );
          final target = navigation.adapter;
          final outline = target is OutlineReaderAdapter
              ? target.outline
              : <ReaderLocation>[];
          final live = target is LiveReaderAdapter && target.liveSurface;
          int? active;
          if (outline.isEmpty || (thumbnails && !live)) {
            active = target.position;
          } else if (target is ActiveOutlineReaderAdapter) {
            active = target.activeOutlineIndex;
          } else {
            for (var i = 0; i < outline.length; i++) {
              if (outline[i].index <= target.position) active = i;
            }
          }
          expect(
            active,
            isNotNull,
            reason: '$format must identify its current navigation entry',
          );
          final item = find.byKey(
            ValueKey(
              thumbnails && !live
                  ? 'reader-navigation-thumbnail-$active'
                  : 'reader-navigation-item-$active',
            ),
          );
          expect(item.hitTestable(), findsOneWidget);
          await snapshot(thumbnails ? 'view-current' : 'navigation-current');
          steps[thumbnails ? 'viewCurrent' : 'navigationCurrent'] = active;
          await tester.tap(find.byTooltip('关闭面板'));
          await settle();
        }
        final beforeSettings = shell().scroll!.metrics.value.fraction;
        await settings();
        final fontSliders = tester
            .widgetList<Slider>(
              find.descendant(
                of: find.byType(ReaderSettingsPanel),
                matching: find.byType(Slider),
              ),
            )
            .toList();
        if (fontSliders.isNotEmpty) {
          timer.reset();
          fontSliders.first.onChanged!(
            (fontSliders.first.min + fontSliders.first.max) / 2,
          );
          await settle();
          steps['fontReflowMs'] = timer.elapsedMilliseconds;
          if (shell().adapter is DocumentReaderAdapter) {
            final expectedFont = tester
                .widget<ReaderSettingsPanel>(find.byType(ReaderSettingsPanel))
                .fontSize;
            final styled = await webState();
            steps['fontRuntime'] = {'expected': expectedFont, 'actual': styled};
            final documents = (styled as Map)['docs'] as List;
            for (final document in documents) {
              expect(
                double.parse(
                  (document['bodyFont'] as String).replaceAll('px', ''),
                ),
                closeTo(expectedFont, .1),
              );
              if (format == 'Mobi' || format == 'Azw3') {
                expect(
                  double.parse(
                    (document['firstDivFont'] as String).replaceAll('px', ''),
                  ),
                  closeTo(expectedFont, .1),
                );
              }
            }
          }
        }
        final articleSettings = find
            .byType(ArticleSettingsPanel)
            .evaluate()
            .isNotEmpty;
        if (articleSettings) {
          // Current Aa places its labelled swatches and reading mode together;
          // More is an advanced subpage rather than the former color tab.
          await swatch('夜间');
          await swatch('纸张');
          final values = tester
              .widget<ReaderSettingsPanel>(find.byType(ReaderSettingsPanel))
              .preferences;
          expect(values.dayBackground, 'paper');
          expect(values.nightBackground, 'dark');
          steps['articleBackgrounds'] = {
            'day': values.dayBackground,
            'night': values.nightBackground,
          };
        } else {
          await tap('更多');
          await tap('夜间');
          await tap('纸张');
          await tap('布局');
        }
        timer.reset();
        if (articleSettings) {
          await tap('左右翻页');
        } else {
          await tap('纵向连续阅读');
        }
        await immersive();
        await ready();
        steps['pageModeMs'] = timer.elapsedMilliseconds;
        expect(shell().adapter.paged, isTrue);
        steps['modePosition'] = {
          'beforeFraction': beforeSettings,
          'position': shell().adapter.position,
          'count': shell().adapter.count,
        };
        final start = shell().adapter.position;
        if (shell().adapter is DocumentReaderAdapter) {
          final doc = shell().adapter as DocumentReaderAdapter;
          final anchor = doc.anchor;
          final bounds = tester.getRect(
            find.byKey(const ValueKey('reader-content-hit-region')),
          );
          await tester.flingFrom(bounds.center, const Offset(-100, 0), 1600);
          await settle();
          await waitFor(
            () => doc.anchor != anchor,
            'horizontal touch swipe must advance the document',
          );
          steps['horizontalTouch'] = {'before': anchor, 'after': doc.anchor};
        } else {
          final bounds = tester.getRect(
            find.byKey(const ValueKey('reader-content-hit-region')),
          );
          await tester.flingFrom(bounds.center, const Offset(-100, 0), 1600);
          await settle();
          expect(shell().adapter.position, greaterThan(start));
        }
        await snapshot('paged');
        timer.reset();
        await tester.pumpWidget(render(width: 420, height: 650));
        await ready();
        steps['resizeMs'] = timer.elapsedMilliseconds;
        steps['narrowPosition'] = shell().adapter.position;
        await snapshot('narrow');
        await settings();
        if (find.byType(ArticleSettingsPanel).evaluate().isNotEmpty) {
          await tap('上下滚动');
        } else {
          await tap('纵向连续阅读');
        }
        await immersive();
        await ready();
        expect(shell().adapter.paged, isFalse);
        double? withinBefore;
        double comicWithin() {
          final ItemPositionsListener positions =
              (tester.state(find.byType(ComicStrip)) as dynamic).positions;
          return WeightedProgress.withinOf(
            WeightedProgress.firstVisible(positions.itemPositions.value)!,
          );
        }

        if (format == 'Comic') {
          shell().scroll!.seek(.75137);
          await settle();
          withinBefore = comicWithin();
          expect(withinBefore, greaterThan(.01));
          expect(withinBefore, lessThan(.99));
        }
        final savedFraction = shell().scroll!.metrics.value.fraction;
        final savedPosition = shell().adapter.position;
        final savedAnchor = shell().adapter is DocumentReaderAdapter
            ? (shell().adapter as DocumentReaderAdapter).anchor
            : null;
        await tester.pumpWidget(const SizedBox());
        await settle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 500)),
        );
        final saved = await api.call('snapshot');
        // PDF binds real page ids on first open. Reopen with the current core
        // book, exactly as a refreshed library does, not the import placeholder.
        book = LibrarySnapshot(Map<String, dynamic>.from(saved)).books.single;
        final catalog = saved['catalog'];
        final progress = (catalog['progress'] as List).cast<Map>().singleWhere(
          (p) => p['book'] == book!.id && p['actor'] == catalog['actor'],
        );
        steps['coreLocation'] = progress['location'];
        final location = progress['location'] as Map;
        final restoredInitial = location['Paragraph'] is Map
            ? location['Paragraph']['index'] as int
            : location['Page'] is Map
            ? book.pages.indexWhere((p) => p['id'] == location['Page']['page'])
            : 0;
        expect(restoredInitial, greaterThanOrEqualTo(0));
        timer.reset();
        await tester.pumpWidget(
          render(width: 420, height: 650, initial: restoredInitial),
        );
        await ready();
        final restored = shell().scroll!.metrics.value.fraction;
        if (format == 'Comic') {
          final withinAfter = comicWithin();
          steps['imageWithin'] = {'before': withinBefore, 'after': withinAfter};
          expect(
            withinAfter,
            closeTo(withinBefore!, .003),
            reason: 'resume must preserve the position inside an image',
          );
        }
        steps['reopen'] = {
          'ms': timer.elapsedMilliseconds,
          'before': savedFraction,
          'after': restored,
          'savedPosition': savedPosition,
          'restoredPosition': shell().adapter.position,
          'anchorBefore': savedAnchor,
          'anchorAfter': shell().adapter is DocumentReaderAdapter
              ? (shell().adapter as DocumentReaderAdapter).anchor
              : null,
        };
        expect(
          restored,
          closeTo(savedFraction, .005),
          reason: 'deep resume must retain reading location',
        );
        expect(tester.takeException(), isNull);
        result['issues'] = issues;
        expect(issues, isEmpty);
        result['passed'] = true;
        debugPrint('LONG_PASS: $format ${jsonEncode(steps)}');
      } catch (error, stack) {
        result['passed'] = false;
        result['error'] = '$error';
        result['stack'] = '$stack';
        debugPrint('LONG_FAIL: $format $error');
        rethrow;
      } finally {
        result['rssBytesEnd'] = ProcessInfo.currentRss;
        result['frames'] = timings.length;
        final frames =
            timings.map((f) => f.totalSpan.inMicroseconds / 1000).toList()
              ..sort();
        if (frames.isNotEmpty) {
          result['observedFrameTotalP95Ms'] =
              frames[((frames.length - 1) * .95).ceil()];
        }
        binding.removeTimingsCallback(onTimings);
        allResults.add(result);
        binding.reportData = {'results': allResults};
        await File(
          '$support/$format-result.json',
        ).writeAsString(const JsonEncoder.withIndent('  ').convert(result));
        await tester.pumpWidget(const SizedBox());
        await settle();
      }
    }, timeout: const Timeout(Duration(minutes: 8)));
  }
}
