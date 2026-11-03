// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aquantum_reader/plugins/plugin_api.dart';
import 'package:aquantum_reader/plugins/plugin_manager.dart';
import 'package:aquantum_reader/plugins/plugin_package.dart';
import 'plugin_fixtures.dart';

void main() {
  test(
    'real ZIP imports disabled, enables actual pages, updates and uninstalls without deleting copies',
    () async {
      final features = testRegistry();
      final store = MemoryPluginStore();
      final packages = MemoryPackages();
      final manager = PluginManager(
        features,
        store,
        hostServices: testServices(),
      );
      await manager.load();
      final zip = pluginZip();
      final original = Uint8List.fromList(zip);
      final plugin = await inspectPluginZip(zip);
      await manager.importPackage(plugin, packages, zip);
      expect(manager.record(plugin.manifest.id).status, PluginStatus.disabled);
      expect(features['community.reading.page.checklist'], isNull);
      await manager.enable(plugin.manifest.id, {});
      expect(features['community.reading.page.checklist'], isNotNull);
      final otherFeatures = testRegistry();
      final reopened = PluginManager(
        otherFeatures,
        store,
        hostServices: testServices(),
      );
      reopened.restorePackage((await packages.load()).plugins.single);
      await reopened.load();
      expect(reopened.records.single.status, PluginStatus.enabled);
      expect(otherFeatures['community.reading.page.checklist'], isNotNull);
      final update = pluginZip(json: pluginJson(version: '1.1.0'));
      await manager.importPackage(
        await inspectPluginZip(update),
        packages,
        update,
      );
      expect(manager.records.single.manifest.version, '1.1.0');
      expect(manager.records.single.status, PluginStatus.disabled);
      expect(features['community.reading.page.checklist'], isNull);
      expect(() => manager.checkImport(plugin), throwsStateError);
      await manager.uninstall(plugin.manifest.id);
      expect(manager.records.single.status, PluginStatus.available);
      expect(packages.copies.length, 2);
      expect(zip, original);
      reopened.dispose();
      otherFeatures.dispose();
      manager.dispose();
      features.dispose();
    },
  );

  test(
    'failed persistence leaves the active version and registry intact',
    () async {
      final features = testRegistry();
      final store = MemoryPluginStore();
      final packages = MemoryPackages();
      final manager = PluginManager(
        features,
        store,
        hostServices: testServices(),
      );
      await manager.load();
      final zip = pluginZip();
      final plugin = await inspectPluginZip(zip);
      await manager.importPackage(plugin, packages, zip);
      await manager.enable(plugin.manifest.id, {});
      store.fail = true;
      final update = pluginZip(json: pluginJson(version: '2.0.0'));
      await expectLater(
        manager.importPackage(await inspectPluginZip(update), packages, update),
        throwsStateError,
      );
      expect(manager.records.single.status, PluginStatus.enabled);
      expect(manager.records.single.manifest.version, '1.0.0');
      expect(features['community.reading.page.checklist'], isNotNull);
      expect(packages.copies.length, 2);
      manager.dispose();
      features.dispose();
    },
  );

  test(
    'file package repository retains versions and reopens a real imported ZIP',
    () async {
      final parent = await Directory.systemTemp.createTemp(
        'aq-plugin-package-',
      );
      addTearDown(() => parent.delete(recursive: true));
      final store = FilePluginPackageStore('${parent.path}/packages');
      final zip = pluginZip();
      await store.retain(zip);
      final loaded = await store.load();
      expect(loaded.plugins.single.manifest.id, 'community.reading');
      expect(loaded.errors, isEmpty);
      final retained = await store.root
          .list(recursive: true, followLinks: false)
          .where((entity) => entity.path.endsWith('package.zip'))
          .single;
      expect(await File(retained.path).readAsBytes(), zip);
      final pending = await store.root.createTemp('failed-');
      await File('${pending.path}/package.zip.part').writeAsBytes([1, 2, 3]);
      final inventory = await store.load();
      expect(inventory.packageCount, 1);
      expect(inventory.packageBytes, zip.length);
      expect(inventory.incompleteBytes, 3);
      expect(inventory.errors, hasLength(1));
      expect(await File('${pending.path}/package.zip.part').readAsBytes(), [
        1,
        2,
        3,
      ]);
    },
  );

  test(
    'ZIP rejects paths, executable payloads, incompatible manifests and corrupt CRC',
    () async {
      for (final name in [
        '../escape',
        '/absolute',
        'C:\\escape',
        'native.dll',
        'aquantum.plugin.json/child',
      ]) {
        await expectLater(
          inspectPluginZip(
            pluginZip(
              extra: {
                name: [1, 2, 3],
              },
            ),
          ),
          throwsA(isA<Exception>()),
        );
      }
      for (final patch in [
        {'apiVersion': 99},
        {'runtime': 'javascript'},
        {'id': 'core.hijack'},
        {
          'permissions': ['rootAccess'],
        },
      ]) {
        await expectLater(
          inspectPluginZip(pluginZip(json: {...pluginJson(), ...patch})),
          throwsA(isA<Exception>()),
        );
      }
      final bad = pluginZip();
      final view = ByteData.sublistView(bad);
      final central = findSignature(bad, 0x02014b50);
      view.setUint32(
        central + 16,
        view.getUint32(central + 16, Endian.little) ^ 1,
        Endian.little,
      );
      await expectLater(inspectPluginZip(bad), throwsA(isA<Exception>()));
    },
  );

  test(
    'ZIP rejects duplicate entries, declared oversize, forged expansion and invalid bytes',
    () async {
      final zip = pluginZip();
      final view = ByteData.sublistView(zip);
      final central = findSignature(zip, 0x02014b50),
          eocd = findSignature(zip, 0x06054b50);
      final duplicate = Uint8List.fromList([
        ...zip.sublist(0, eocd),
        ...zip.sublist(central, eocd),
        ...zip.sublist(eocd),
      ]);
      final dupView = ByteData.sublistView(duplicate);
      final dupEnd = duplicate.length - 22;
      dupView.setUint16(dupEnd + 8, 2, Endian.little);
      dupView.setUint16(dupEnd + 10, 2, Endian.little);
      dupView.setUint32(dupEnd + 12, (eocd - central) * 2, Endian.little);
      await expectLater(inspectPluginZip(duplicate), throwsA(isA<Exception>()));
      final oversize = Uint8List.fromList(zip);
      ByteData.sublistView(
        oversize,
      ).setUint32(central + 24, pluginManifestLimit + 1, Endian.little);
      await expectLater(inspectPluginZip(oversize), throwsA(isA<Exception>()));
      // Actual compressed output is larger than both claimed sizes. The decoder
      // must stop at the small declared size instead of allocating the full output.
      view.setUint32(central + 24, 1, Endian.little);
      view.setUint32(22, 1, Endian.little);
      await expectLater(inspectPluginZip(zip), throwsA(isA<Exception>()));
      await expectLater(
        inspectPluginZip(Uint8List(100)),
        throwsA(isA<Exception>()),
      );
    },
  );

  test(
    'permission gating, context filters, callback failure and cleanup revoke every capability',
    () async {
      final features = testRegistry();
      final implementation = FailingActionPlugin();
      final manager = PluginManager(
        features,
        MemoryPluginStore(),
        bundled: [implementation],
      );
      await manager.load();
      await manager.install(implementation.manifest.id);
      await expectLater(
        manager.enable(implementation.manifest.id, {}),
        throwsStateError,
      );
      await manager.enable(implementation.manifest.id, {
        PluginPermission.selectedText,
      });
      expect(
        manager.actions(ExtensionPoint.textSelection, const ExtensionContext()),
        isEmpty,
      );
      const context = ExtensionContext(
        format: 'Txt',
        selectedText: 'selected',
        capabilities: {ReaderCapability.selectableText},
      );
      expect(manager.actions(ExtensionPoint.textSelection, context).length, 1);
      await expectLater(
        manager.invoke('test.failure.action.run', context),
        throwsStateError,
      );
      expect(manager.records.single.status, PluginStatus.failed);
      expect(features['test.failure.page.home'], isNull);
      expect(manager.actions(ExtensionPoint.textSelection, context), isEmpty);
      manager.dispose();
      features.dispose();
    },
  );
}

int findSignature(Uint8List bytes, int signature) {
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i <= bytes.length - 4; i++) {
    if (data.getUint32(i, Endian.little) == signature) return i;
  }
  throw StateError('fixture signature missing');
}

class FailingActionPlugin implements ReaderPlugin {
  @override
  PluginManifest get manifest => const PluginManifest(
    id: 'test.failure',
    name: 'Failure fixture',
    version: '1.0.0',
    description: 'Lifecycle regression fixture',
    permissions: {PluginPermission.selectedText},
  );
  @override
  Future<void> activate(PluginRegistrar registrar) async {
    registrar.page(
      id: 'test.failure.page.home',
      name: 'Test',
      icon: Icons.book,
      builder: (_) => const Text('Test'),
    );
    registrar.action(
      PluginAction(
        id: 'test.failure.action.run',
        name: 'Test',
        icon: Icons.book,
        point: ExtensionPoint.textSelection,
        requires: {ReaderCapability.selectableText},
        formats: {'Txt'},
        permissions: {PluginPermission.selectedText},
        invoke: (_) async => throw StateError('plugin callback failed'),
      ),
    );
  }

  @override
  Future<void> deactivate() async => throw StateError('cleanup failed');
}
