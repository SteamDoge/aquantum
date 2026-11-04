// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'qa_storage.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:aquantum_reader/data/backup_preferences.dart';
import 'package:aquantum_reader/data/library_locations.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/main.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native cleanup, backup, isolated restore, restart and rollback', (
    tester,
  ) async {
    await configureQaStorage();
    final previous = await preferenceSnapshot();
    addTearDown(() => applyPreferenceSnapshot(previous));
    await applyPreferenceSnapshot({'theme': 'light', 'reader-font-size': 21.0});
    final support = await getApplicationSupportDirectory();
    final root = await Directory(
      '${support.path}/qa-maintenance-${DateTime.now().microsecondsSinceEpoch}',
    ).create();
    final app = await Directory('${root.path}/app').create();
    final exports = await Directory('${root.path}/exports').create();
    final picker = MaintenancePicker(exports.path);
    final originalPicker = FilePicker.platform;
    FilePicker.platform = picker;
    addTearDown(() => FilePicker.platform = originalPicker);
    final api = RustReaderApi(app.path);
    final inbox = (await api.call('snapshot'))['catalog']['inbox'];
    await api.call('import_files', {
      'target': inbox,
      'files': [
        {
          'name': 'Offline.txt',
          'data': base64Encode(utf8.encode('first\n\nsecond')),
        },
      ],
    });
    final book = (await api.call('snapshot'))['catalog']['books'][0]['id'];
    await api.call('add_note', {
      'book': book,
      'index': 1,
      'text': 'Before backup',
    });
    final orphan = File(
      '${app.path}/library/objects/11111111-1111-4111-8111-111111111111.part',
    );
    await orphan.writeAsString('failed temporary bytes');
    final locations = LibraryLocations(app.path);
    const capture = Key('maintenance-capture');
    Future<void> until(Finder finder) async {
      for (var i = 0; i < 200 && finder.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        finder,
        findsWidgets,
        reason:
            tester
                .widgetList<Text>(find.byType(Text))
                .map((t) => t.data)
                .join(' | ') +
            tester
                .widgetList<SelectableText>(find.byType(SelectableText))
                .map((t) => t.data)
                .join(' | '),
      );
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> tap(String text) async {
      final finder = find.text(text);
      if (finder.evaluate().isEmpty) {
        await tester.scrollUntilVisible(
          finder,
          180,
          scrollable: find.byType(Scrollable).last,
        );
      }
      await tester.ensureVisible(finder.first);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(finder.first);
      await tester.pump(const Duration(milliseconds: 300));
    }

    Future<void> mount(String active) async {
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: ReaderApp(
            key: ValueKey(active),
            api: RustReaderApi(active),
            libraryLocations: locations,
          ),
        ),
      );
      await until(find.byKey(const ValueKey('nav-core.me')));
    }

    Future<void> storage() async {
      await tester.tap(find.byKey(const ValueKey('nav-core.me')));
      await tester.pump(const Duration(milliseconds: 300));
      await tap('存储管理');
      await tap('手动清理、任务与备份恢复');
      await until(find.text('存储维护与备份'));
    }

    Future<void> screenshot(String name) async {
      await tester.pump(const Duration(milliseconds: 300));
      final bitmap = await tester
          .renderObject<RenderRepaintBoundary>(find.byKey(capture))
          .toImage(pixelRatio: 1);
      final bytes = await bitmap.toByteData(format: ui.ImageByteFormat.png);
      final folder = await Directory(
        Platform.environment['AQ_SCREENSHOT_DIR'] ?? '${root.path}/captures',
      ).create(recursive: true);
      await File(
        '${folder.path}/$name.png',
      ).writeAsBytes(bytes!.buffer.asUint8List());
      bitmap.dispose();
    }

    await mount(app.path);
    await storage();
    await tap('手动清理预览');
    await until(find.byType(CheckboxListTile));
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      false,
    );
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump(const Duration(milliseconds: 300));
    await screenshot('rc005-cleanup-confirm');
    await tap('确认清理所选');
    await until(find.text('确认手动清理？'));
    expect(await orphan.exists(), true);
    await tap('清理所选文件');
    await until(find.textContaining('已选 1 项 · 已完成 1 项'));
    expect(await orphan.exists(), false);
    expect((await api.call('snapshot'))['catalog']['notes'].length, 1);
    await tap('保留任务，返回');
    await tap('创建备份');
    await until(find.text('创建资料库备份？'));
    await tap('开始备份');
    await until(find.textContaining('备份已校验并保存：'));
    final backups = await exports
        .list()
        .where((e) => e.path.endsWith('.aqb'))
        .toList();
    expect(backups, hasLength(1));
    picker.backup = backups.single.path;
    await api.call('add_note', {
      'book': book,
      'index': 0,
      'text': 'After backup',
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme', 'dark');
    await prefs.setDouble('reader-font-size', 29);
    await screenshot('rc005-backup-completed');
    await tap('恢复备份');
    await until(find.text('使用已恢复的资料库？'));
    expect((await api.call('snapshot'))['catalog']['notes'].length, 2);
    await tap('切换到恢复副本');
    await until(find.byKey(const ValueKey('nav-core.me')));
    final restored = await locations.current();
    expect(restored, isNot(app.path));
    final restoredApi = RustReaderApi(restored);
    expect((await restoredApi.call('snapshot'))['catalog']['notes'].length, 1);
    expect(
      (await restoredApi.call('read_text', {'book': book}))['paragraphs'],
      ['first', 'second'],
    );
    expect(prefs.getString('theme'), 'light');
    expect(prefs.getDouble('reader-font-size'), 21);
    expect((await api.call('snapshot'))['catalog']['notes'].length, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
    await mount(await LibraryLocations(app.path).current());
    await storage();
    await screenshot('rc005-restored-library');
    await tap('恢复回退');
    await until(find.text('返回恢复前的资料库？'));
    await tap('回退资料库');
    await until(find.byKey(const ValueKey('nav-core.me')));
    expect(
      LibraryLocations(app.path).normalized(await locations.current()),
      LibraryLocations(app.path).normalized(await app.resolveSymbolicLinks()),
    );
    expect(prefs.getString('theme'), 'dark');
    expect(prefs.getDouble('reader-font-size'), 29);
    expect((await api.call('snapshot'))['catalog']['notes'].length, 2);
    expect((await restoredApi.call('snapshot'))['catalog']['notes'].length, 1);
    expect(await File(picker.backup!).exists(), true);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 300));
  });
}

class MaintenancePicker extends FilePicker {
  final String destination;
  String? backup;
  MaintenancePicker(this.destination);
  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    String? initialDirectory,
    bool lockParentWindow = false,
  }) async => destination;
  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async => FilePickerResult([
    PlatformFile(
      name: 'backup.aqb',
      size: await File(backup!).length(),
      path: backup,
    ),
  ]);
}
