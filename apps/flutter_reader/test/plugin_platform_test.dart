// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:aquantum_reader/plugins/plugin_export.dart';
import 'package:aquantum_reader/plugins/plugin_reader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:aquantum_reader/plugins/plugin_api.dart';
import 'package:aquantum_reader/plugins/plugin_manager.dart';
import 'package:aquantum_reader/plugins/plugin_package.dart';
import 'package:aquantum_reader/plugins/plugin_data.dart';
import 'plugin_fixtures.dart';

Future<JavaScriptPlugin> install(
  PluginManager manager,
  String id,
  String source, {
  List<String> permissions = const [],
  Map<String, String> dependencies = const {},
  String version = '1.0.0',
}) async {
  final bytes = pluginZip(
    json: {
      ...pluginJson(version: version),
      'id': id,
      'permissions': permissions,
      'dependencies': dependencies,
    },
    extra: {'main.js': utf8.encode(source)},
  );
  final plugin = await inspectPluginZip(bytes);
  await manager.importPackage(plugin, MemoryPackages(), bytes);
  await manager.enable(id, plugin.manifest.permissions);
  return manager.record(id).implementation as JavaScriptPlugin;
}

void main() {
  test(
    'desktop export writes actual bytes and preserves the selected previous file',
    () async {
      final root = await Directory.systemTemp.createTemp('aq-plugin-export-');
      addTearDown(() => root.delete(recursive: true));
      final file = File('${root.path}/export.txt');
      await file.writeAsString('original user bytes');
      FilePicker.platform = _ExportPicker(file.path);
      expect(
        await exportPluginBytes(
          'export.txt',
          Uint8List.fromList(utf8.encode('exported plugin bytes')),
        ),
        true,
      );
      expect(await file.readAsString(), 'exported plugin bytes');
      final retained = await root
          .list()
          .where((e) => e.path.endsWith('.previous'))
          .single;
      expect(await File(retained.path).readAsString(), 'original user bytes');
    },
  );
  test(
    'direct plugin reader keeps the source bytes outside the main library',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'aq-plugin-direct-read-',
      );
      addTearDown(() => root.delete(recursive: true));
      final original = Uint8List.fromList(
        utf8.encode('Plugin direct reader.\n\nActual private reading bytes.'),
      );
      final session = await PluginReaderSession.open(
        root.path,
        'private.txt',
        original,
      );
      final value = await session.api.call('read_text', {
        'book': session.book.id,
      });
      expect(jsonEncode(value), contains('Actual private reading bytes.'));
      expect(utf8.decode(original), contains('Actual private reading bytes.'));
      await session.api.call('save_progress', {
        'book': session.book.id,
        'index': 1,
      });
      final reopened = await PluginReaderSession.open(
        root.path,
        'private.txt',
        original,
      );
      expect(
        reopened.book.id,
        session.book.id,
        reason: 'The same private file must retain its reading identity',
      );
      expect(reopened.position, 1);
      final other = await PluginReaderSession.open(
        root.path,
        'private.txt',
        original,
        scope: 'other.plugin',
      );
      expect(other.book.id, isNot(session.book.id));
      expect(other.position, 0);
    },
  );
  test(
    'real headless SDK package runs JS services and events without any HTML or page',
    () async {
      final registry = testRegistry();
      final host = testServices();
      final manager = PluginManager(
        registry,
        MemoryPluginStore(),
        hostServices: host,
      );
      addTearDown(() {
        manager.dispose();
        registry.dispose();
      });
      await manager.load();
      final bytes = await File(
        '../../plugin-sdk/examples/headless/dist/example.headless-1.0.1.aqplugin.zip',
      ).readAsBytes();
      final package = await inspectPluginZip(bytes);
      expect(package.assets.keys.any((k) => k.endsWith('.html')), isFalse);
      await manager.importPackage(package, MemoryPackages(), bytes);
      await manager.enable(package.manifest.id, package.manifest.permissions);
      expect(
        registry.all.where((p) => p.source == package.manifest.id),
        isEmpty,
      );
      final running =
          manager.record(package.manifest.id).implementation
              as JavaScriptPlugin;
      expect(
        (await running.call('services.discover', {})) as List,
        hasLength(1),
      );
      await host.broker.emit('theme.changed', {'brightness': 'dark'});
      expect(
        await manager.invoke(
          'example.headless.action.status',
          const ExtensionContext(),
        ),
        contains('1 次'),
      );
      await manager.disable(package.manifest.id);
      expect(host.broker.instances, isEmpty);
      expect(
        manager.actions(ExtensionPoint.readerMore, const ExtensionContext()),
        isEmpty,
      );
      await expectLater(
        running.call('services.discover', {}),
        throwsStateError,
      );
    },
  );
  test(
    'native UI callbacks update state and survive disable reinstall and runtime recreation',
    () async {
      final registry = testRegistry();
      final host = testServices();
      final manager = PluginManager(
        registry,
        MemoryPluginStore(),
        hostServices: host,
      );
      addTearDown(() {
        manager.dispose();
        registry.dispose();
      });
      await manager.load();
      final bytes = await File(
        '../../plugin-sdk/examples/native/dist/example.native-1.0.1.aqplugin.zip',
      ).readAsBytes();
      final package = await inspectPluginZip(bytes);
      await manager.importPackage(package, MemoryPackages(), bytes);
      await manager.enable(package.manifest.id, {});
      final running =
          manager.record(package.manifest.id).implementation
              as JavaScriptPlugin;
      await running.invoke(running.slots['home']!['handler'], {
        'event': 'increment',
      });
      expect(running.slots['home']!['ui']['children'][1]['text'], '已完成 1 项');
      await manager.uninstall(package.manifest.id);
      await manager.install(package.manifest.id);
      await manager.enable(package.manifest.id, {});
      expect(running.slots['home']!['ui']['children'][1]['text'], '已完成 1 项');
    },
  );
  test(
    'JS cross-plugin services enforce dependencies, ownership, versions and revocation',
    () async {
      final registry = testRegistry();
      final host = testServices();
      final manager = PluginManager(
        registry,
        MemoryPluginStore(),
        hostServices: host,
      );
      addTearDown(() {
        manager.dispose();
        registry.dispose();
      });
      await manager.load();
      await install(
        manager,
        'test.provider',
        "export async function activate(ctx){await ctx.services.provide('test.provider.echo','1.0.0',payload=>({echo:payload}));}",
        permissions: ['services'],
      );
      final consumer = await install(
        manager,
        'test.consumer',
        "export async function activate(ctx){await ctx.slots.register({type:'readerMore',id:'echo',name:'Echo'},()=>ctx.services.call('test.provider.echo','actual JavaScript',{version:'1.0.0'}));}",
        permissions: ['services'],
        dependencies: {'test.provider': '1.0.0'},
      );
      expect(
        await consumer.call('services.call', {
          'name': 'test.provider.echo',
          'args': 'value',
          'version': '1.0.0',
        }),
        {'echo': 'value'},
      );
      await expectLater(
        consumer.call('services.provide', {
          'name': 'test.provider.forged',
          'version': '1.0.0',
          'handler': 'fake',
        }),
        throwsFormatException,
      );
      await expectLater(
        consumer.call('services.call', {
          'name': 'test.provider.echo',
          'args': null,
          'version': '2.0.0',
        }),
        throwsStateError,
      );
      await manager.disable('test.provider');
      await expectLater(
        consumer.call('services.call', {
          'name': 'test.provider.echo',
          'args': null,
        }),
        throwsStateError,
      );
    },
  );
  test(
    'real JS failure revokes only its plugin; healthy plugins keep running',
    () async {
      final registry = testRegistry();
      final host = testServices();
      final manager = PluginManager(
        registry,
        MemoryPluginStore(),
        hostServices: host,
      );
      addTearDown(() {
        manager.dispose();
        registry.dispose();
      });
      await manager.load();
      final healthy = await install(
        manager,
        'test.healthy',
        "export async function activate(ctx){await ctx.slots.register({type:'readerMore',id:'ok',name:'OK'},()=>42);}",
      );
      final broken = await install(
        manager,
        'test.broken',
        "export async function activate(ctx){await ctx.slots.register({type:'readerMore',id:'loop',name:'Loop'},async()=>{await Promise.resolve();while(true){}});}",
      );
      await expectLater(
        manager.invoke('test.broken.action.loop', const ExtensionContext()),
        throwsA(isA<Exception>()),
      );
      expect(manager.record(broken.manifest.id).status, PluginStatus.failed);
      expect(
        await manager.invoke(
          'test.healthy.action.ok',
          const ExtensionContext(),
        ),
        '42',
      );
      expect(healthy.active, isTrue);
    },
  );
  test(
    'private file backup restore rejects cross-plugin identity and preserves previous bytes',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'aq-plugin-data-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final data = PluginData(root.path);
      final directory = await data.directory('test.storage');
      final file = File('${directory.path}/files/nested/sample.txt');
      await file.parent.create(recursive: true);
      await file.writeAsString('original bytes');
      final backup = await data.backup('test.storage');
      await file.writeAsString('new bytes');
      await expectLater(
        data.restore('test.other', backup),
        throwsFormatException,
      );
      await data.restore('test.storage', backup);
      expect(await file.readAsString(), 'original bytes');
      final retained = await file.parent
          .list()
          .where((e) => e.path.endsWith('.previous'))
          .toList();
      expect(retained, hasLength(1));
      expect(await File(retained.single.path).readAsString(), 'new bytes');
      await data.deleteData('test.storage');
      expect(await file.exists(), isFalse);
    },
  );
}

class _ExportPicker extends FilePicker {
  final String path;
  _ExportPicker(this.path);
  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async => path;
}
