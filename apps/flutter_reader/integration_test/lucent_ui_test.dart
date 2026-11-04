// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrintDone;
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/data/backup_preferences.dart';
import 'package:aquantum_reader/design/appearance.dart';
import 'package:aquantum_reader/design/theme.dart';
import 'package:aquantum_reader/main.dart';
import 'package:aquantum_reader/screens/book_details.dart';
import 'package:aquantum_reader/screens/book_metadata_screen.dart';
import 'qa_storage.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Lucent native appearance, live metadata, cover and backup round trip',
    (tester) async {
      await configureQaStorage();
      final previousPreferences = await preferenceSnapshot();
      addTearDown(() => applyPreferenceSnapshot(previousPreferences));
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('theme', 'light');
      await preferences.setString('appearance.palette.v1', 'lucent');
      final support = await getApplicationSupportDirectory();
      final supportPath = await support.resolveSymbolicLinks();
      final root = Directory(
        '$supportPath/qa-lucent-${DateTime.now().millisecondsSinceEpoch}',
      );
      await root.create(recursive: true);
      final api = RustReaderApi(root.path);
      final first = await api.call('snapshot');
      await api.call('import_files', {
        'target': first['catalog']['inbox'],
        'files': [
          for (final name in ['三体', '窗边笔记', '设计记录', '阅读计划'])
            {
              'name': '$name.txt',
              'data': base64Encode(
                utf8.encode(
                  List.generate(
                    80,
                    (i) => '原生UI验证第${i + 1}段：真实导入的独立测试文本，用于观察阅读画布和工具栏，不属于用户藏书。',
                  ).join('\n\n'),
                ),
              ),
            },
        ],
      });
      const capture = Key('lucent-native-capture');
      Future<void> wait(Finder finder) async {
        for (var n = 0; n < 600 && finder.evaluate().isEmpty; n++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(finder, findsWidgets);
        await tester.pumpAndSettle();
      }

      Future<void> reveal(Finder finder) async {
        if (finder.evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            finder,
            200,
            scrollable: find.byType(Scrollable).last,
          );
        }
        await tester.ensureVisible(finder.first);
        await tester.pumpAndSettle();
      }

      Future<void> screenshot(String name) async {
        await tester.pumpAndSettle();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(capture),
        );
        final image = await boundary.toImage(pixelRatio: 1);
        final png = await image.toByteData(format: ui.ImageByteFormat.png);
        final bytes = png!.buffer.asUint8List();
        final output = Directory(
          Platform.environment['AQ_SCREENSHOT_DIR'] ??
              '${support.path}/qa-screenshots',
        );
        await output.create(recursive: true);
        await File('${output.path}/$name.png').writeAsBytes(bytes);
        if (Platform.isAndroid) {
          final encoded = base64Encode(bytes);
          for (var i = 0; i < encoded.length; i += 512) {
            debugPrint(
              'QA_IMAGE:$name:${encoded.substring(i, (i + 512).clamp(0, encoded.length))}',
            );
          }
          await debugPrintDone;
        }
        image.dispose();
      }

      Future<void> launch(String key) async {
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: ReaderApp(key: ValueKey(key), api: api),
          ),
        );
        await wait(find.byKey(const ValueKey('nav-core.projects')));
      }

      await launch('initial');
      await tester.tap(find.byKey(const ValueKey('nav-core.projects')));
      await tester.pumpAndSettle();
      await screenshot('lucent-library');
      await tester.longPress(find.text('三体').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('详情'));
      await wait(find.byType(BookDetailsScreen));
      await screenshot('lucent-book');
      await reveal(find.text('封面与信息匹配'));
      await tester.tap(find.text('封面与信息匹配'));
      await wait(find.byType(BookMetadataScreen));
      await tester.tap(find.text('搜索候选'));
      final candidates = find.byWidgetPredicate(
        (w) =>
            w is ListTile &&
            w.key is ValueKey<String> &&
            (w.key as ValueKey<String>).value.startsWith('metadata-candidate-'),
      );
      await wait(candidates);
      await screenshot('lucent-matches');
      await tester.tap(candidates.first);
      await wait(find.text('使用此版本封面'));
      await reveal(find.text('使用此版本封面'));
      await tester.tap(find.text('使用此版本封面'));
      await wait(find.byType(Image));
      await reveal(find.text('确认并保存'));
      await screenshot('lucent-metadata');
      await tester.tap(find.text('确认并保存'));
      await wait(find.byType(BookDetailsScreen));
      expect(find.byType(BookMetadataScreen), findsNothing);
      final saved = await api.call('snapshot');
      final book = (saved['catalog']['books'] as List).firstWhere(
        (b) => b['metadata']['provider'] == 'Open Library',
      );
      expect(book['metadata']['cover'], isNotNull);
      expect(
        (await api.call('book_cover', {'book': book['id']})) as String,
        isNotEmpty,
      );
      final detailScroll = find
          .descendant(
            of: find.byType(BookDetailsScreen),
            matching: find.byType(Scrollable),
          )
          .first;
      tester.state<ScrollableState>(detailScroll).position.jumpTo(0);
      await tester.pumpAndSettle();
      await screenshot('lucent-book-saved');
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('nav-core.home')));
      await tester.pumpAndSettle();
      await screenshot('lucent-home');
      await tester.tap(find.byKey(const ValueKey('nav-core.me')));
      await tester.pumpAndSettle();
      await reveal(find.text('颜色主题'));
      await tester.tap(find.text('颜色主题'));
      await wait(find.byType(PaletteSettings));
      await tester.tap(find.text('纸境'));
      await tester.pumpAndSettle();
      expect(preferences.getString('appearance.palette.v1'), 'folio');
      await screenshot('lucent-appearance');
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      await launch('reopened');
      final paletteContext = tester.element(
        find.byKey(const ValueKey('nav-core.projects')),
      );
      expect(AqAppearance.maybeOf(paletteContext)!.palette, AqPalette.folio);
      final restoredSnapshot = await api.call('snapshot');
      expect(
        (restoredSnapshot['catalog']['books'] as List).firstWhere(
          (b) => b['id'] == book['id'],
        )['metadata']['cover']['sha256'],
        book['metadata']['cover']['sha256'],
      );
      final plan = await api.call('backup_prepare', {
        'device_preferences': await preferenceSnapshot(),
      });
      final backupPath =
          '$supportPath/lucent-${DateTime.now().millisecondsSinceEpoch}.aqb';
      await api.call('backup_run', {
        'task': plan['task'],
        'destination': backupPath,
      });
      final restore = await api.call('restore_prepare', {'source': backupPath});
      final recovered = await api.call('restore_run', {
        'task': restore['task'],
      });
      final recoveredApi = RustReaderApi(recovered['root']);
      final recoveredSnapshot = await recoveredApi.call('snapshot');
      final recoveredBook = (recoveredSnapshot['catalog']['books'] as List)
          .firstWhere((b) => b['id'] == book['id']);
      expect(
        recoveredBook['metadata']['cover']['sha256'],
        book['metadata']['cover']['sha256'],
      );
      expect(
        await recoveredApi.call('book_cover', {'book': book['id']}),
        await api.call('book_cover', {'book': book['id']}),
      );
      expect(recovered['device_preferences']['appearance.palette.v1'], 'folio');
      await File('${root.path}/native-result.json').writeAsString(
        jsonEncode({
          'book': book['id'],
          'provider': book['metadata']['provider'],
          'cover': book['metadata']['cover'],
          'backup': backupPath,
          'recovered': recovered['root'],
          'palette': 'folio',
        }),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
}
