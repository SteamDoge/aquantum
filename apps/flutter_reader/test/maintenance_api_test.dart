// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:io';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'native task control bypasses the data queue and canceled backup resumes',
    () async {
      final library = Platform.environment['AQ_RUST_LIB'];
      expect(
        library,
        isNotNull,
        reason: 'Use scripts/check.ps1 for the real Rust bridge',
      );
      final temp = await Directory.systemTemp.createTemp('aq-maintenance-ffi-');
      addTearDown(() => temp.delete(recursive: true));
      final api = RustReaderApi('${temp.path}/app', libraryPath: library);
      await api.call('snapshot');
      // A sparse orphan is intentional test data. No user resources are touched.
      final source = await File(
        '${temp.path}/app/library/objects/22222222-2222-4222-8222-222222222222.part',
      ).open(mode: FileMode.write);
      await source.setPosition(64 * 1024 * 1024 - 1);
      await source.writeByte(1);
      await source.close();
      final plan = await api.call('backup_prepare', {'device_preferences': {}});
      final task = plan['task'];
      final destination = '${temp.path}/copy.aqb';
      final running = api.call('backup_run', {
        'task': task,
        'destination': destination,
      });
      final stopped = expectLater(running, throwsA(isA<ReaderFailure>()));
      // If control calls used the ordinary FIFO, this would run after successful
      // completion and the expectation above would fail.
      await api.call('task_cancel', {'kind': 'backup', 'task': task});
      await stopped;
      expect(await File(destination).exists(), false);
      expect(
        (await api.call('task_status', {
          'kind': 'backup',
          'task': task,
        }))['phase'],
        'stopped',
      );
      await api.call('task_resume', {'kind': 'backup', 'task': task});
      await api.call('backup_run', {'task': task, 'destination': destination});
      expect(await File(destination).exists(), true);
      expect(
        (await api.call('task_status', {
          'kind': 'backup',
          'task': task,
        }))['phase'],
        'completed',
      );
    },
  );
}
