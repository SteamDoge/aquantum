// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show debugPrintDone;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:aquantum_reader/main.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/data/backup_preferences.dart';
import 'package:aquantum_reader/navigation/liquid_navigation_dock.dart';
import 'package:aquantum_reader/reader/reader_shell.dart';
import 'package:aquantum_reader/reader/reader_page_overview.dart';
import 'qa_storage.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'Android real IME keeps dock hidden and actual landscape keeps real pages',
    (tester) async {
      await configureQaStorage();
      final previous = await preferenceSnapshot();
      addTearDown(() async {
        await SystemChrome.setPreferredOrientations([]);
        await applyPreferenceSnapshot(previous);
      });
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      final support = await getApplicationSupportDirectory();
      final supportPath = await support.resolveSymbolicLinks();
      final root = Directory(
        '$supportPath/qa-ime-${DateTime.now().millisecondsSinceEpoch}',
      );
      await root.create(recursive: true);
      final api = RustReaderApi(root.path);
      final snapshot = await api.call('snapshot');
      await api.call('import_files', {
        'target': snapshot['catalog']['inbox'],
        'files': [
          {
            'name': '横屏与键盘.txt',
            'data': base64Encode(
              utf8.encode(
                List.generate(
                  160,
                  (i) =>
                      '第${i + 1}段。${List.filled(30, '用于验证实际横屏画布与真实相邻书页。').join()}',
                ).join('\n\n'),
              ),
            ),
          },
        ],
      });
      const capture = Key('native-ime-capture');
      final observations = <String, dynamic>{};
      Future<void> until(bool Function() condition, String description) async {
        for (var i = 0; i < 300 && !condition(); i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(condition(), isTrue, reason: description);
        await tester.pumpAndSettle();
      }

      Future<void> screenshot(String name) async {
        await tester.pumpAndSettle();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(capture),
        );
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = (await image.toByteData(
          format: ui.ImageByteFormat.png,
        ))!.buffer.asUint8List();
        final encoded = base64Encode(bytes);
        for (var i = 0; i < encoded.length; i += 512) {
          debugPrint(
            'QA_IMAGE:$name:${encoded.substring(i, (i + 512).clamp(0, encoded.length))}',
          );
        }
        await debugPrintDone;
        image.dispose();
      }

      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: ReaderApp(api: api),
        ),
      );
      await until(
        () => find
            .byKey(const ValueKey('nav-core.projects'))
            .evaluate()
            .isNotEmpty,
        'library navigation',
      );
      await tester.tap(find.byKey(const ValueKey('nav-core.projects')));
      await tester.pumpAndSettle();
      final dockBefore = tester.getRect(find.byType(LiquidNavigationDock));
      await tester.tap(find.byType(TextField).first);
      await until(
        () => tester.view.viewInsets.bottom > 0,
        'native Android IME must actually open',
      );
      observations['keyboardPhysicalInset'] = tester.view.viewInsets.bottom;
      debugPrint('NATIVE_IME_OPEN:${jsonEncode(observations)}');
      expect(find.byType(LiquidNavigationDock), findsNothing);
      await screenshot('lucent-keyboard');
      FocusManager.instance.primaryFocus?.unfocus();
      await SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      await until(
        () =>
            tester.view.viewInsets.bottom == 0 &&
            find.byType(LiquidNavigationDock).evaluate().isNotEmpty,
        'dock returns after native IME closes',
      );
      expect(tester.getRect(find.byType(LiquidNavigationDock)), dockBefore);
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
      ]);
      await until(
        () => tester.view.physicalSize.width > tester.view.physicalSize.height,
        'actual Android landscape metrics',
      );
      observations['landscapePhysicalWidth'] = tester.view.physicalSize.width;
      observations['landscapePhysicalHeight'] = tester.view.physicalSize.height;
      await tester.ensureVisible(find.text('横屏与键盘').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('横屏与键盘').last);
      await until(
        () => find.byType(ReaderShell).evaluate().isNotEmpty,
        'landscape reader',
      );
      final region = tester.getRect(
        find.byKey(const ValueKey('reader-content-hit-region')),
      );
      await tester.tapAt(region.topLeft + const Offset(100, 40));
      await until(
        () => find.byType(ReaderPageOverview).evaluate().isNotEmpty,
        'landscape shows the true paged overview',
      );
      expect(find.byTooltip('阅读设置').hitTestable(), findsOneWidget);
      expect(find.byTooltip('下一页').hitTestable(), findsOneWidget);
      await screenshot('lucent-phone-landscape');
      final before = tester
          .widget<ReaderShell>(find.byType(ReaderShell))
          .adapter
          .position;
      await tester.tap(find.byTooltip('下一页'));
      await until(
        () =>
            tester
                .widget<ReaderShell>(find.byType(ReaderShell))
                .adapter
                .position >
            before,
        'native page turn settles on the next source page',
      );
      observations['pageAdvance'] = true;
      expect(tester.takeException(), isNull);
      await File(
        '${root.path}/native-ime-result.json',
      ).writeAsString(jsonEncode(observations));
      debugPrint('NATIVE_IME_RESULT:${jsonEncode(observations)}');
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
    skip: !Platform.isAndroid,
  );
}
