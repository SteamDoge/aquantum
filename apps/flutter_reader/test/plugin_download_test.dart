// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:aquantum_reader/plugins/plugin_download.dart';
import 'package:aquantum_reader/plugins/plugin_manager.dart';
import 'package:aquantum_reader/plugins/plugin_package.dart';
import 'package:aquantum_reader/plugins/plugin_api.dart';
import 'plugin_fixtures.dart';

void main() {
  test('source parser distinguishes repos, tagged releases and assets', () {
    expect(
      PluginSource.parse('https://github.com/team/reader.git').repo,
      'reader',
    );
    expect(
      PluginSource.parse(
        'https://github.com/team/reader/releases/tag/v1.2.3',
      ).tag,
      'v1.2.3',
    );
    expect(
      PluginSource.parse(
        'https://github.com/team/reader/releases/download/v1/a.zip',
      ).githubReleaseDiscovery,
      false,
    );
    for (final input in [
      'http://example.com/a.zip',
      'https://u:p@example.com/a.zip',
      'https://example.com:8443/a.zip',
      'https://github.com/team/reader/tree/main',
    ]) {
      expect(() => PluginSource.parse(input), throwsFormatException);
    }
  });
  test('public download rejects local, mapped and private addresses', () async {
    for (final host in [
      '127.0.0.1',
      '10.1.2.3',
      '172.16.1.1',
      '192.168.1.1',
      '169.254.169.254',
      '100.64.0.1',
      '::1',
      '::ffff:127.0.0.1',
      'fd00::1',
    ]) {
      expect(publicPluginAddress(InternetAddress(host)), false, reason: host);
    }
    expect(publicPluginAddress(InternetAddress('8.8.8.8')), true);
    await expectLater(
      fetchPublicHttps(Uri.parse('https://127.0.0.1/a.zip'), 100),
      throwsFormatException,
    );
  });
  test(
    'GitHub discovery uses exact release asset, notes and actual manifest version',
    () async {
      final requests = <String>[];
      final downloader = PluginDownloader(
        fetch: (uri, limit) async {
          requests.add(uri.toString());
          if (uri.host == 'api.github.com') {
            return Uint8List.fromList(
              utf8.encode(
                jsonEncode({
                  'draft': false,
                  'tag_name': 'v1.0.0',
                  'body': 'release notes',
                  'assets': [
                    {
                      'name': 'reader.aqmodule.zip',
                      'browser_download_url':
                          'https://github.com/team/reader/releases/download/v1.0.0/reader.aqmodule.zip',
                    },
                  ],
                }),
              ),
            );
          }
          return pluginZip();
        },
      );
      final result = await downloader.inspect(
        'https://github.com/team/reader/releases/tag/v1.0.0',
      );
      expect(requests.first, endsWith('/releases/tags/v1.0.0'));
      expect(result.plugin.manifest.version, '1.0.0');
      expect(result.releaseNotes, contains('release notes'));
      expect(result.digest.length, 64);
    },
  );
  test(
    'source-only repo imports root declaration and never executes sources',
    () async {
      final requests = <String>[];
      final downloader = PluginDownloader(
        fetch: (uri, _) async {
          requests.add(uri.toString());
          if (uri.path.endsWith('/releases/latest')) {
            throw const PluginHttpException(404);
          }
          if (uri.host == 'api.github.com') {
            return Uint8List.fromList(utf8.encode('{"default_branch":"main"}'));
          }
          return Uint8List.fromList(utf8.encode(jsonEncode(pluginJson())));
        },
      );
      await expectLater(
        downloader.inspect('https://github.com/team/reader'),
        throwsFormatException,
      );
      expect(requests.length, 1);
      expect(requests.any((url) => url.contains('zipball')), false);
    },
  );
  test(
    'failed state commit restores prior installed version after real restart',
    () async {
      final temp = await Directory.systemTemp.createTemp('aq-plugin-rollback-');
      addTearDown(() => temp.delete(recursive: true));
      final packages = FilePluginPackageStore(temp.path);
      final state = MemoryPluginStore();
      final registry = testRegistry();
      final manager = PluginManager(
        registry,
        state,
        hostServices: testServices(),
      );
      await manager.load();
      final old = pluginZip(),
          newer = pluginZip(json: pluginJson(version: '2.0.0'));
      await manager.importPackage(
        await inspectPluginZip(old),
        packages,
        old,
        source: 'https://github.com/team/reader',
      );
      await manager.enable('community.reading', {});
      state.fail = true;
      await expectLater(
        manager.importPackage(await inspectPluginZip(newer), packages, newer),
        throwsStateError,
      );
      state.fail = false;
      final inventory = await packages.load();
      final reopenedRegistry = testRegistry();
      final reopened = PluginManager(
        reopenedRegistry,
        state,
        hostServices: testServices(),
      );
      for (final plugin in inventory.plugins) {
        reopened.restorePackage(plugin);
      }
      reopened.setInventory(inventory);
      await reopened.load();
      expect(reopened.records.single.manifest.version, '1.0.0');
      expect(reopened.records.single.status, PluginStatus.enabled);
      expect(reopened.records.single.source, 'https://github.com/team/reader');
      expect(inventory.packageCount, 2);
      manager.dispose();
      reopened.dispose();
      registry.dispose();
      reopenedRegistry.dispose();
    },
  );
  test(
    'declarative translation actions require permission and revoke together',
    () async {
      final json = pluginJson()..['permissions'] = ['selectedText'];
      final bytes = pluginZip(
        json: json,
        extra: {
          'main.js': utf8.encode(
            "export async function activate(ctx){ await ctx.slots.register({id:'translate',type:'textSelection',name:'测试翻译'}, ({selectedText}) => selectedText==='hello' ? '你好' : '未知词条'); }",
          ),
        },
      );
      final plugin = await inspectPluginZip(bytes);
      final registry = testRegistry();
      final manager = PluginManager(
        registry,
        MemoryPluginStore(),
        hostServices: testServices(),
      );
      await manager.load();
      await manager.importPackage(plugin, MemoryPackages(), bytes);
      await expectLater(
        manager.enable(plugin.manifest.id, {}),
        throwsStateError,
      );
      await manager.enable(plugin.manifest.id, {PluginPermission.selectedText});
      const context = ExtensionContext(
        selectedText: 'hello',
        capabilities: {ReaderCapability.selectableText},
      );
      final actions = manager.actions(ExtensionPoint.textSelection, context);
      expect(await manager.invoke(actions.single.id, context), contains('你好'));
      await manager.disable(plugin.manifest.id);
      expect(manager.actions(ExtensionPoint.textSelection, context), isEmpty);
      await expectLater(
        manager.invoke(actions.single.id, context),
        throwsStateError,
      );
      manager.dispose();
      registry.dispose();
    },
  );
}
