// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:aquantum_reader/screens/reader_defaults_screen.dart';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:aquantum_reader/data/models.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/formats/document_reader.dart';
import 'package:aquantum_reader/formats/document_screen.dart';
import 'package:aquantum_reader/formats/reader_provider.dart';
import 'package:aquantum_reader/reader/reader_shell.dart';
import 'package:aquantum_reader/screens/reader_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webview_windows/webview_windows.dart';
import 'qa_storage.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real comic reader switches replace rather than stack', (
    tester,
  ) async {
    await configureQaStorage();
    final support = Platform.environment['AQ_TEST_SUPPORT']!;
    final fixtures = Platform.environment['AQ_LONG_FIXTURES']!;
    final api = RustReaderApi('$support/library');
    final inbox = (await api.call('snapshot'))['catalog']['inbox'];
    final plan = await api.call('preview_import', {
      'target': inbox,
      'paths': ['$fixtures/long.cbz'],
    });
    await api.call('commit_import', {
      'task': plan['task'],
      'base_revision': plan['base_revision'],
      'target': plan['target'],
      'projects': [
        for (final p in plan['projects']) {'id': p['id'], 'name': p['name']},
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
    var exits = 0;
    final book = LibrarySnapshot(
      Map<String, dynamic>.from(await api.call('snapshot')),
    ).books.single;
    Future<void> waitFor(bool Function() condition) async {
      for (var i = 0; i < 600; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        if (condition()) return;
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      fail('reader switch timed out');
    }

    ReaderShell shell() => tester.widget<ReaderShell>(find.byType(ReaderShell));
    Future<void> ready({required bool foliate}) async {
      await waitFor(
        () =>
            find.byType(ReaderShell).evaluate().length == 1 &&
            shell().adapter.count > 0 &&
            (shell().adapter is DocumentReaderAdapter) == foliate &&
            find
                .byType(ReaderProviderPanel, skipOffstage: false)
                .evaluate()
                .isEmpty,
      );
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(ReaderShell, skipOffstage: false), findsOneWidget);
      expect(
        find.byType(ReaderScreen, skipOffstage: false).evaluate().length,
        1,
      );
      expect(
        find
            .byType(DocumentReaderScreen, skipOffstage: false)
            .evaluate()
            .length,
        foliate ? 1 : 0,
      );
      expect(tester.takeException(), isNull);
    }

    Future<void> capture(String name) async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('capture')),
      );
      final image = await boundary.toImage(pixelRatio: 1);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      await File('$support/$name.png').writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    }

    var settingsCaptures = 0;
    Future<void> select(String title) async {
      await tester.tap(find.text('软件设置'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reader-default-Comic')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(title).last);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await capture('software-settings-${++settingsCaptures}');
      await tester.pageBack();
      await tester.pumpAndSettle();
    }

    Future<void> closeReader() async {
      await tester.pageBack();
      await waitFor(
        () => find.text('测试书库').hitTestable().evaluate().isNotEmpty,
      );
      await tester.pumpAndSettle();
      expect(find.byType(ReaderShell, skipOffstage: false), findsNothing);
      expect(
        find.byType(DocumentReaderScreen, skipOffstage: false),
        findsNothing,
      );
    }

    await tester.pumpWidget(
      RepaintBoundary(
        key: const ValueKey('capture'),
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () async {
                        final library = LibrarySnapshot(
                          Map<String, dynamic>.from(await api.call('snapshot')),
                        );
                        if (!context.mounted) return;
                        await Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => ReaderScreen(
                              api: api,
                              book: book,
                              initialPosition: library.position(book),
                            ),
                          ),
                        );
                        exits++;
                      },
                      child: const Text('测试书库'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const ReaderDefaultsScreen(),
                        ),
                      ),
                      child: const Text('软件设置'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('测试书库'));
    await ready(foliate: false);
    final verified = <int>[];
    for (var round = 0; round < 3; round++) {
      final first = 18 + round * 20;
      shell().adapter.goTo(first);
      await waitFor(() => shell().adapter.position == first);
      await closeReader();
      await select('Foliate 漫画阅读');
      await tester.tap(find.text('测试书库'));
      await ready(foliate: true);
      expect(shell().adapter.position, first);
      final web = tester.widget<Webview>(find.byType(Webview)).controller;
      final geometry = await tester.runAsync(
        () => web.executeScript('''(() => {
        const renderer = document.querySelector('foliate-view').renderer;
        return { scrollbar: getComputedStyle(renderer).scrollbarWidth,
          pages: renderer.getContents().map(({doc}) => ({
            x: doc.documentElement.scrollWidth - doc.documentElement.clientWidth,
            y: doc.documentElement.scrollHeight - doc.documentElement.clientHeight,
            display: getComputedStyle(doc.querySelector('img')).display
          })) };
      })()'''),
      );
      expect(geometry['scrollbar'], 'none');
      expect(geometry['pages'], isNotEmpty);
      for (final page in geometry['pages']) {
        expect(page['x'], lessThanOrEqualTo(1));
        expect(page['y'], lessThanOrEqualTo(1));
        expect(page['display'], 'block');
      }
      final target = first + 3;
      shell().adapter.goTo(target);
      await waitFor(() => shell().adapter.position == target);
      if (round == 2) await capture('foliate-final');
      await closeReader();
      await select('图片阅读');
      await tester.tap(find.text('测试书库'));
      await ready(foliate: false);
      expect(shell().adapter.position, target);
      verified.add(target);
      if (round == 2) await capture('native-final');
    }
    await closeReader();
    expect(exits, 7);
    await capture('back-library');
    binding.reportData = {
      'switchRounds': 3,
      'verifiedPages': verified,
      'backFromBothEngines': true,
      'softwareSettings': true,
      'managedComicNoOverflowOrBrowserTracks': true,
      'routeCompletedOnlyOnExit': exits == 7,
    };
    await tester.pumpWidget(const SizedBox.shrink());
  }, timeout: const Timeout(Duration(minutes: 5)));
  testWidgets('software Markdown choice restores independent task state', (
    tester,
  ) async {
    await configureQaStorage();
    final support = Platform.environment['AQ_TEST_SUPPORT']!;
    final api = RustReaderApi('$support/markdown-library');
    const original =
        '# Settings switch\n\n- [ ] saved task\n\nRead-only content stays unchanged.\n';
    final source = File('$support/settings-switch.md');
    await source.writeAsString(original);
    final inbox = (await api.call('snapshot'))['catalog']['inbox'];
    final plan = await api.call('preview_import', {
      'target': inbox,
      'paths': [source.path],
    });
    await api.call('commit_import', {
      'task': plan['task'],
      'base_revision': plan['base_revision'],
      'target': plan['target'],
      'projects': [
        for (final p in plan['projects']) {'id': p['id'], 'name': p['name']},
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
    final book = LibrarySnapshot(
      Map<String, dynamic>.from(await api.call('snapshot')),
    ).books.single;
    Future<void> settle() async {
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
    }

    Future<void> choose(String title) async {
      await tester.pumpWidget(const MaterialApp(home: ReaderDefaultsScreen()));
      await settle();
      await tester.tap(find.byKey(const ValueKey('reader-default-Markdown')));
      await settle();
      await tester.tap(find.text(title).last);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(
        MaterialApp(
          home: ReaderScreen(api: api, book: book, initialPosition: 0),
        ),
      );
      await settle();
    }

    await choose('Markdown 阅读');
    expect(find.byType(Checkbox), findsOneWidget);
    await tester.tap(find.byType(Checkbox));
    await settle();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    await choose('纯文字阅读');
    expect(find.byType(Checkbox), findsNothing);
    expect(find.byType(ReaderShell, skipOffstage: false), findsOneWidget);
    await choose('Markdown 阅读');
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    expect(await source.readAsString(), original);
    binding.reportData = {
      ...?binding.reportData,
      'markdownTaskPreserved': true,
      'markdownSourceUnchanged': true,
    };
    await tester.pumpWidget(const SizedBox.shrink());
  }, timeout: const Timeout(Duration(minutes: 3)));
}
