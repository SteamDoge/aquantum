// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:io';
import 'package:aquantum_reader/data/models.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/reader/reader_shell.dart';
import 'package:aquantum_reader/screens/reader_screen.dart';
import 'package:aquantum_reader/widgets/reader_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'qa_storage.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  for (final format in ['Txt', 'Pdf']) {
    testWidgets('$format stable navigation and unreadable settings recovery', (
      tester,
    ) async {
      await configureQaStorage();
      final support = Platform.environment['AQ_TEST_SUPPORT']!;
      final api = RustReaderApi('$support/$format');
      final original = '${'前文' * 12000}唯一目标词${'后文' * 3000}';
      final path = format == 'Txt'
          ? '$support/anchor.txt'
          : '${Platform.environment['AQ_LONG_FIXTURES']!}/long.pdf';
      if (format == 'Txt') await File(path).writeAsString(original);
      final inbox = (await api.call('snapshot'))['catalog']['inbox'];
      final plan = await api.call('preview_import', {
        'target': inbox,
        'paths': [path],
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
      ReaderShell shell() =>
          tester.widget<ReaderShell>(find.byType(ReaderShell));
      Future<void> waitFor(bool Function() condition) async {
        for (var i = 0; i < 600; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          if (condition()) return;
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
        }
        fail('$format anchor/recovery timeout');
      }

      Future<void> settle() async {
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 350)),
        );
        await tester.pumpAndSettle();
      }

      Future<void> show() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpWidget(
          MaterialApp(
            home: ReaderScreen(
              api: api,
              book: book,
              initialPosition: format == 'Pdf' ? 350 : 0,
            ),
          ),
        );
        await waitFor(
          () =>
              find.byType(ReaderShell).evaluate().isNotEmpty &&
              shell().adapter.count > 0,
        );
        await settle();
      }

      Future<void> open(String tooltip) async {
        if (find.byTooltip(tooltip).hitTestable().evaluate().isEmpty) {
          final area = tester.getRect(
            find.byKey(const ValueKey('reader-content-hit-region')),
          );
          await tester.tapAt(area.topLeft + const Offset(90, 35));
          await settle();
        }
        await tester.tap(find.byTooltip(tooltip).hitTestable());
        await settle();
      }

      final settings = ReaderPreferences()
        ..textPaged = false
        ..continuous = true;
      await settings.save(bookId: book.id);
      await show();
      if (format == 'Txt') {
        if (!tester.testTextInput.isRegistered) {
          tester.testTextInput.register();
          addTearDown(tester.testTextInput.unregister);
        }
        await open('搜索');
        await tester.enterText(find.byType(TextField), '唯一目标词');
        await tester.tap(find.byTooltip('开始搜索'));
        await settle();
        await tester.tap(find.byType(ListTile).first);
        await settle();
        final target = shell().scroll!.metrics.value.fraction;
        expect(target, greaterThan(.7));
        await open('书签');
        await tester.tap(find.text('添加当前位置书签'));
        await settle();
        final encoded = (await SharedPreferences.getInstance()).getString(
          'reader-bookmarks.v1.${book.id}',
        )!;
        expect(jsonDecode(encoded)['items'][0]['id'], contains(':0:'));
        await tester.tap(find.byTooltip('关闭面板'));
        await settle();
        shell().scroll!.seek(.05);
        await settle();
        expect(shell().scroll!.metrics.value.fraction, lessThan(.2));
        await open('书签');
        await tester.tap(find.byType(ListTile).first);
        await settle();
        expect(shell().scroll!.metrics.value.fraction, closeTo(target, .02));
        expect(await File(path).readAsString(), original);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await settle();
      final prefs = await SharedPreferences.getInstance();
      final key = 'reader-ui.v2.${book.id}';
      const corrupt = '{"version":999,"keep":"do-not-overwrite"}';
      await prefs.setString(key, corrupt);
      await show();
      await open('阅读设置');
      expect(find.textContaining('原记录保留'), findsWidgets);
      await tester.tap(find.text('更多').last);
      await settle();
      await tester.tap(find.text('纸张'));
      await settle();
      expect(prefs.getString(key), corrupt);
      expect(tester.takeException(), isNull);
      binding.reportData = {
        ...?binding.reportData,
        format: {
          'unreadableSettingsOpened': true,
          'corruptBytesRetained': true,
          if (format == 'Txt') 'searchAndBookmarkCharacterRestored': true,
        },
      };
      await tester.pumpWidget(const SizedBox.shrink());
      await settle();
    }, timeout: const Timeout(Duration(minutes: 4)));
  }
}
