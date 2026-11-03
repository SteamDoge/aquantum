// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:io';
import 'package:aquantum_reader/data/backup_preferences.dart';
import 'package:aquantum_reader/data/library_locations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'restored plugin bytes do not carry executable grants across a backup',
    () async {
      final source = {
        'theme': 'dark',
        'plugins.javascript.v1': jsonEncode({
          'version': 1,
          'plugins': {
            'community.test': {
              'installed': true,
              'enabled': true,
              'package_version': '1.0.0',
              'grants': ['network', 'documentText'],
            },
          },
        }),
      };
      final restored = restoredPreferenceSnapshot(source);
      final config = jsonDecode(
        restored['plugins.javascript.v1'],
      )['plugins']['community.test'];
      expect(config['enabled'], false);
      expect(config['grants'], isEmpty);
      expect(config['installed'], true);
      expect(config['package_version'], '1.0.0');
      expect(
        jsonDecode(
          source['plugins.javascript.v1']!,
        )['plugins']['community.test']['enabled'],
        true,
      );
      await applyPreferenceSnapshot(restored);
      final current = await preferenceSnapshot();
      expect(current['theme'], 'dark');
      expect(
        jsonDecode(
          current['plugins.javascript.v1'],
        )['plugins']['community.test']['enabled'],
        false,
      );
    },
  );
  TestWidgetsFlutterBinding.ensureInitialized();
  test('Windows restored-library checkpoints accept long paths', () async {
    if (!Platform.isWindows) return;
    final scratch = await Directory.systemTemp.createTemp('aq-long-');
    addTearDown(() => scratch.delete(recursive: true));
    var path = scratch.path;
    while (path.length < 245) {
      path += '/restored-library-depth';
    }
    await Directory(path).create(recursive: true);
    final checkpoint = await retainPreferenceSnapshot(path, {'theme': 'dark'});
    expect(checkpoint.length, greaterThan(260));
    expect(jsonDecode(await File(checkpoint).readAsString())['values'], {
      'theme': 'dark',
    });
  });
  setUp(
    () => SharedPreferences.setMockInitialValues({
      'theme': 'light',
      'reader-font-size': 20.0,
      'bookmarks': ['a', 'b'],
    }),
  );
  test(
    'verified restore selection survives restart and retains the prior preferences for rollback',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'aq-library-selection-',
      );
      addTearDown(() => root.delete(recursive: true));
      final recovered = Directory('${root.path}/recovered-libraries/verified');
      await recovered.create(recursive: true);
      await File('${recovered.path}/recovery.json').writeAsString(
        jsonEncode({'version': 1, 'task': 'verified', 'library': 'library'}),
      );
      final old = await preferenceSnapshot();
      final checkpoint = await retainPreferenceSnapshot(root.path, old);
      final locations = LibraryLocations(root.path);
      await applyPreferenceSnapshot({
        'theme': 'dark',
        'reader-font-size': 24.0,
      });
      await locations.select(
        recovered.path,
        previousRoot: root.path,
        previousPreferences: checkpoint,
      );
      expect(
        await LibraryLocations(root.path).current(),
        await recovered.resolveSymbolicLinks(),
      );
      final previous = await locations.rollbackData();
      expect(previous!['device_preferences'], old);
      await applyPreferenceSnapshot(
        Map<String, dynamic>.from(previous['device_preferences']),
      );
      expect(
        (await SharedPreferences.getInstance()).getString('theme'),
        'light',
      );
      expect(await File(checkpoint).exists(), isTrue);
      await expectLater(locations.resolve('../outside'), throwsFormatException);
      await expectLater(
        locations.resolve('recovered-libraries/missing'),
        throwsA(isA<FileSystemException>()),
      );
      expect(await locations.current(), await recovered.resolveSymbolicLinks());
    },
  );
  test(
    'startup rolls back interrupted preference writes but keeps committed selection settings',
    () async {
      final root = await Directory.systemTemp.createTemp('aq-switch-recovery-');
      addTearDown(() => root.delete(recursive: true));
      final recovered = await Directory(
        '${root.path}/recovered-libraries/verified',
      ).create(recursive: true);
      await File('${recovered.path}/recovery.json').writeAsString(
        jsonEncode({'version': 1, 'task': 'verified', 'library': 'library'}),
      );
      final locations = LibraryLocations(root.path);
      final original = await preferenceSnapshot();
      final checkpoint = await retainPreferenceSnapshot(root.path, original);
      final interrupted = await locations.beginSwitch(root.path, checkpoint);
      await applyPreferenceSnapshot({'theme': 'dark'});
      // Simulate exit after only some settings changed, before root commit.
      await LibraryLocations(root.path).recoverInterruptedSwitches();
      expect(await preferenceSnapshot(), original);
      expect(await locations.current(), root.path);
      expect(await File('$interrupted/intent.json').exists(), true);
      expect(await File('$interrupted/completed.json').exists(), true);
      final committed = await locations.beginSwitch(root.path, checkpoint);
      await applyPreferenceSnapshot({
        'theme': 'dark',
        'reader-font-size': 25.0,
      });
      await locations.select(
        recovered.path,
        previousRoot: root.path,
        previousPreferences: checkpoint,
      );
      // Exit after root commit but before its advisory completion receipt.
      await LibraryLocations(root.path).recoverInterruptedSwitches();
      expect((await preferenceSnapshot())['theme'], 'dark');
      expect(await locations.current(), await recovered.resolveSymbolicLinks());
      expect(await File('$committed/completed.json').exists(), true);
    },
  );
}
