// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/plugins/plugin_host.dart';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:aquantum_reader/features/feature_registry.dart';
import 'package:aquantum_reader/plugins/plugin_manager.dart';
import 'package:aquantum_reader/plugins/plugin_package.dart';
import 'package:aquantum_reader/navigation/navigation_preferences.dart';

Map<String, dynamic> pluginJson({String version = '1.0.0'}) => {
  'schemaVersion': 1,
  'runtime': 'javascript-v1',
  'apiVersion': 1,
  'id': 'community.reading',
  'name': '阅读清单',
  'author': 'SDK regression fixture',
  'version': version,
  'description': '用户编写的本地阅读清单页面。',
  'entry': 'main.js',
  'permissions': [],
  'platforms': ['windows', 'android', 'linux', 'ios'],
};
const fixtureScript =
    "export async function activate(ctx) { await ctx.slots.register({type:'page',id:'checklist',name:'阅读清单',icon:'book',ui:{type:'text',text:'记录想读的内容，按照自己的节奏阅读。'}}); }";

PluginHostServices testServices() {
  final root = Directory.systemTemp.createTempSync('aq-plugin-test-');
  addTearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });
  return PluginHostServices(
    api: _EmptyApi(),
    onImported: () {},
    storagePath: root.path,
  );
}

class _EmptyApi implements ReaderApi {
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async => throw StateError('Unexpected test API: $method');
}

Uint8List pluginZip({
  Map<String, dynamic>? json,
  Map<String, List<int>> extra = const {},
}) {
  final archive = Archive();
  for (final entry in {
    pluginManifestName: utf8.encode(jsonEncode(json ?? pluginJson())),
    'main.js': utf8.encode(fixtureScript),
    ...extra,
  }.entries) {
    archive.add(ArchiveFile(entry.key, entry.value.length, entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

FeatureRegistry testRegistry() => FeatureRegistry([
  for (final id in [
    'core.home',
    'core.projects',
    'core.plugins',
    'core.settings',
    'core.storage',
    'core.history',
    'core.me',
  ])
    AppFeature(
      id: id,
      name: id,
      icon: Icons.book_outlined,
      builder: (_) => Text(id),
    ),
]);

class MemoryNavigationStore implements NavigationStore {
  final Map<NavigationProfile, String> saved = {};
  bool fail = false;
  @override
  Future<String?> read(NavigationProfile profile) async => saved[profile];
  @override
  Future<void> write(NavigationProfile profile, String value) async {
    if (fail) throw StateError('disk unavailable');
    saved[profile] = value;
  }
}

class MemoryPluginStore implements PluginStateStore {
  String? saved;
  bool fail = false;
  @override
  Future<String?> read() async => saved;
  @override
  Future<void> write(String value) async {
    if (fail) throw StateError('disk unavailable');
    saved = value;
  }
}

class MemoryPackages implements PluginPackageStore {
  final List<Uint8List> copies = [];
  @override
  Future<LoadedPluginPackages> load() async {
    final selected = <String, JavaScriptPlugin>{};
    for (final bytes in copies) {
      final plugin = await inspectPluginZip(bytes);
      selected[plugin.manifest.id] = plugin;
    }
    return LoadedPluginPackages(selected.values.toList(), []);
  }

  @override
  Future<void> retain(Uint8List bytes) async =>
      copies.add(Uint8List.fromList(bytes));
}
