// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/screens/storage_cleanup.dart';
import 'package:aquantum_reader/screens/storage_maintenance.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _StorageApi implements ReaderApi {
  final Set<String> done = {};
  List<Map<String, dynamic>> tasks = [];
  List<String>? confirmed;
  final List<String> deleted = [];
  final items = [
    {'key': 'first', 'category': 'unreferenced', 'bytes': 24},
    {'key': 'second', 'category': 'incomplete', 'bytes': 32},
  ];
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    switch (method) {
      case 'cleanup_state':
        return {
          'plan': {'items': items, 'protected_resources': 12},
          'completed': done.toList(),
          'confirmed': confirmed == null ? null : {'keys': confirmed},
        };
      case 'cleanup_confirm':
        confirmed = (args['keys'] as List).cast<String>();
        return null;
      case 'cleanup_step':
        final key = args['key'] as String;
        if (!confirmed!.contains(key)) throw StateError('not confirmed');
        deleted.add(key);
        done.add(key);
        return null;
      case 'storage_overview':
        return {
          'usage': {
            'original_bytes': 1024,
            'retained_unreferenced_bytes': 24,
            'incomplete_bytes': 32,
          },
          'available_bytes': 1024 * 1024,
          'pinned_resources': 4,
          'books': [],
          'projects': [],
        };
      case 'storage_tasks':
        return tasks;
      default:
        throw StateError(method);
    }
  }
}

void main() {
  testWidgets(
    'task controls follow restart capability and keep discarded restore terminal',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _StorageApi()
        ..tasks = [
          {
            'task': 'failed',
            'kind': 'backup',
            'phase': 'error',
            'restart': 'resume',
            'discardable': true,
          },
          {
            'task': 'given-up',
            'kind': 'restore',
            'phase': 'discarded',
            'restart': 'none',
            'discardable': false,
          },
          {
            'task': 'partial-discard',
            'kind': 'restore',
            'phase': 'discarding',
            'restart': 'none',
            'discardable': true,
          },
        ];
      await tester.pumpWidget(
        MaterialApp(home: StorageMaintenanceScreen(api: api)),
      );
      await tester.pumpAndSettle();
      expect(find.byTooltip('继续任务'), findsOneWidget);
      expect(find.byTooltip('放弃任务'), findsNWidgets(2));
      expect(find.text('恢复 · 已放弃'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'manual cleanup is empty until selected, confirms exactly that scope and keeps remaining files',
    (tester) async {
      final api = _StorageApi();
      await tester.pumpWidget(
        MaterialApp(
          home: StorageCleanupScreen(api: api, task: 'task'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '确认清理所选'))
            .onPressed,
        isNull,
      );
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认清理所选'));
      await tester.pumpAndSettle();
      expect(api.deleted, isEmpty);
      expect(find.textContaining('永久删除所选 1 个文件'), findsOneWidget);
      await tester.tap(find.text('清理所选文件'));
      await tester.pumpAndSettle();
      expect(api.confirmed, ['first']);
      expect(api.deleted, ['first']);
      expect(api.done.contains('second'), isFalse);
      expect(find.text('已选 1 项 · 已完成 1 项 · 剩余 0 项'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('storage and cleanup stay usable in large-text landscape', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(812, 375);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final api = _StorageApi();
    await tester.pumpWidget(
      MaterialApp(
        home: StorageCleanupScreen(api: api, task: 'task'),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(
      MaterialApp(home: StorageMaintenanceScreen(api: api)),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
