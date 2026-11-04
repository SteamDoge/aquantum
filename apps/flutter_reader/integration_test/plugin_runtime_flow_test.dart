// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'plugin_runtime_fixtures.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:aquantum_reader/plugins/plugin_system.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/plugins/plugin_package.dart';
import 'package:aquantum_reader/plugins/plugin_host.dart';
import 'package:aquantum_reader/plugins/plugin_manager.dart';
import '../test/plugin_fixtures.dart';
import 'qa_storage.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native executable plugin code writes and imports through the same public bridge',
    (tester) async {
      await configureQaStorage();
      const secure = FlutterSecureStorage();
      final owned = '${PluginSystemAccess.credentialPrefix('test.clear')}probe';
      final other =
          '${PluginSystemAccess.credentialPrefix('test.clear.child')}probe';
      await secure.write(key: owned, value: 'owned');
      await secure.write(key: other, value: 'other');
      try {
        await PluginSystemAccess.deleteCredentials('test.clear');
        expect(await secure.read(key: owned), isNull);
        expect(await secure.read(key: other), 'other');
        debugPrint('SECURE_NAMESPACE_DELETE_PASS');
      } finally {
        await secure.delete(key: owned);
        await secure.delete(key: other);
      }
      final support = await getApplicationSupportDirectory();
      final root = Directory(
        '${support.path}/plugin-native-${DateTime.now().millisecondsSinceEpoch}',
      );
      final api = RustReaderApi(root.path);
      await api.call('snapshot');
      final json = pluginJson()
        ..['permissions'] = ['derivedFiles', 'libraryImport', 'secureStorage'];
      const html =
          '''<html><meta charset="utf-8"><h1>外部代码原生自检</h1><div id="result">执行中</div><script>
  (async()=>{try{await aq.call('secrets.set',{key:'native-test',value:'native-keystore-roundtrip'});if(await aq.call('secrets.get',{key:'native-test'})!=='native-keystore-roundtrip')throw Error('Secure storage roundtrip failed');await aq.call('secrets.remove',{key:'native-test'});await aq.call('storage.write',{name:'external-runtime.txt',data:aq.encode('Native plugin text.\\nInstalled code runs separately from host.')} );await aq.call('library.import',{name:'external-runtime.txt'});await aq.call('storage.write',{name:'complete.txt',data:aq.encode('passed')});document.getElementById('result').textContent='通过';}catch(e){document.getElementById('result').textContent=e.message;await aq.call('storage.write',{name:'error.txt',data:aq.encode(e.message)});}})();
  </script></html>''';
      final bytes = pluginZip(
        json: json,
        extra: {
          'index.html': utf8.encode(html),
          'main.js': utf8.encode(
            "export async function activate(ctx){await ctx.slots.register({id:'checklist',name:'执行自检',type:'page',html:'index.html'});}",
          ),
        },
      );
      final packages = FilePluginPackageStore('${root.path}/packages');
      final plugin = await inspectPluginZip(bytes);
      final features = testRegistry();
      final services = PluginHostServices(
        api: api,
        onImported: () {},
        storagePath: '${root.path}/plugin-data',
      );
      final manager = PluginManager(
        features,
        MemoryPluginStore(),
        hostServices: services,
      );
      await manager.load();
      expect(manager.records, isEmpty);
      final headlessBytes = pluginZip(
        json: {
          ...pluginJson(),
          'id': 'test.nativeheadless',
          'permissions': ['services'],
        },
        extra: {
          'main.js': utf8.encode(
            "export async function activate(ctx){await ctx.storage.set('native',true);await ctx.events.on('theme.changed',()=>ctx.storage.set('event',true));await ctx.services.provide('test.nativeheadless.echo','1.0.0',payload=>payload);}",
          ),
        },
      );
      final headless = await inspectPluginZip(headlessBytes);
      await manager.importPackage(headless, packages, headlessBytes);
      await manager.enable(headless.manifest.id, headless.manifest.permissions);
      final runningHeadless =
          manager.record(headless.manifest.id).implementation
              as JavaScriptPlugin;
      expect(
        runningHeadless.assets.keys.any((p) => p.endsWith('.html')),
        false,
      );
      expect(
        features.all.where((p) => p.source == headless.manifest.id),
        isEmpty,
      );
      await services.broker.emit('theme.changed', {'brightness': 'dark'});
      expect(await runningHeadless.call('data.get', {'key': 'event'}), true);
      expect(
        (await runningHeadless.call('services.discover', {})) as List,
        hasLength(1),
      );
      await manager.disable(headless.manifest.id);
      expect(services.broker.instances, isEmpty);
      debugPrint(
        'HEADLESS_NATIVE_PASS: JS/service/event/private-state/revoke; no HTML',
      );
      await manager.importPackage(plugin, packages, bytes);
      await manager.enable(plugin.manifest.id, plugin.manifest.permissions);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: features['community.reading.page.checklist']!.builder,
            ),
          ),
        ),
      );
      final complete = File(
        '${root.path}/plugin-data/community.reading/files/complete.txt',
      );
      for (var i = 0; i < 120; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 500)),
        );
        await tester.pump();
        if (await tester.runAsync(complete.exists) == true) break;
      }
      final error = File(
        '${root.path}/plugin-data/community.reading/files/error.txt',
      );
      if (await tester.runAsync(error.exists) == true) {
        debugPrint(
          'PLUGIN_ERROR: ${await tester.runAsync(error.readAsString)}',
        );
      }
      debugPrint(
        'PLUGIN_UI: ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).join(' / ')}',
      );
      expect(await tester.runAsync(complete.exists), true);
      final snapshot = await tester.runAsync(() => api.call('snapshot'));
      expect((snapshot['catalog']['books'] as List).length, 1);
      await manager.disable(plugin.manifest.id);
      expect(features['community.reading.page.checklist'], isNull);
      debugPrint(
        'PLUGIN_UI: ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).join(' / ')}',
      );
      expect(await tester.runAsync(complete.exists), true);
      await tester.pumpWidget(const SizedBox.shrink());
      manager.dispose();
      features.dispose();
      final packageBytes = <List<int>>[];
      for (final kind in ['BOOKSTORE', 'JMCOMIC']) {
        final encoded = kind == 'BOOKSTORE'
            ? const String.fromEnvironment('BOOKSTORE_ZIP')
            : const String.fromEnvironment('JMCOMIC_ZIP');
        final path = kind == 'BOOKSTORE'
            ? const String.fromEnvironment('BOOKSTORE_ZIP_PATH')
            : const String.fromEnvironment('JMCOMIC_ZIP_PATH');
        packageBytes.add(
          Platform.isWindows && path.isNotEmpty
              ? await tester.runAsync(() => File(path).readAsBytes()) ?? []
              : base64Decode(
                  encoded.isNotEmpty
                      ? encoded
                      : externalPluginZipBase64[kind == 'BOOKSTORE' ? 0 : 1],
                ),
        );
      }
      for (final rawBytes in packageBytes) {
        final encoded = base64Encode(rawBytes);
        expect(
          encoded,
          isNotEmpty,
          reason: 'Provide the two independently built ZIPs via DefineFile',
        );
        final bytes = base64Decode(encoded);
        final imported = await inspectPluginZip(bytes);
        final calls = <String>[];
        final registry = testRegistry();
        final externalServices = PluginHostServices(
          api: api,
          onImported: () {},
          storagePath: '${root.path}/plugin-data',
          onRequest: (_, method) => calls.add(method),
        );
        final externalManager = PluginManager(
          registry,
          MemoryPluginStore(),
          hostServices: externalServices,
        );
        await externalManager.load();
        expect(externalManager.records, isEmpty);
        await externalManager.importPackage(imported, packages, bytes);
        await externalManager.enable(
          imported.manifest.id,
          imported.manifest.permissions,
        );
        final page = registry['${imported.manifest.id}.page.home']!;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: Builder(builder: page.builder)),
          ),
        );
        for (var i = 0; i < 60 && !calls.contains('storage.read'); i++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 500)),
          );
          await tester.pump();
        }
        expect(
          calls,
          contains('storage.read'),
          reason:
              'Original ZIP JavaScript must execute through the native bridge',
        );
        await externalManager.disable(imported.manifest.id);
        expect(registry[page.id], isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        externalManager.dispose();
        registry.dispose();
        debugPrint(
          'ORIGINAL_PLUGIN_ZIP_NATIVE_PASS: ${imported.manifest.id} digest=${imported.packageDigest}',
        );
      }
      debugPrint(
        'PLUGIN_NATIVE_PASS: code/storage/import/revoke; ${root.path}',
      );
    },
  );
}
