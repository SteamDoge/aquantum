// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/plugins/plugin_api.dart';
import 'package:aquantum_reader/plugins/plugin_host.dart';
import 'package:aquantum_reader/plugins/plugin_package.dart';
import 'plugin_fixtures.dart';
import 'package:aquantum_reader/plugins/plugin_asset_server.dart';

void main() {
  test(
    'retained versions stay available without exhausting live storage quotas',
    () async {
      final created = await Directory.systemTemp.createTemp(
        'aq-rc013-history-',
      );
      final root = Directory(await created.resolveSymbolicLinks());
      addTearDown(() => root.delete(recursive: true));
      final services = PluginHostServices(
        api: ImportApi(),
        onImported: () {},
        storagePath: root.path,
      );
      final session = await services.open(
        const PluginManifest(
          id: 'community.quota',
          name: 'Quota',
          version: '1.0.0',
          description: '',
          permissions: {PluginPermission.derivedFiles},
        ),
      );
      addTearDown(session.close);
      await session.call('settings.set', {'key': 'value', 'value': 'first'});
      final history = File(
        '${root.path}/community.quota/config/settings.json.100.previous',
      );
      final retained = await history.open(mode: FileMode.write);
      await retained.truncate(8 * 1024 * 1024);
      await retained.close();
      await session.call('settings.set', {'key': 'value', 'value': 'latest'});
      expect(await session.call('settings.get', {'key': 'value'}), 'latest');
      expect(await history.length(), 8 * 1024 * 1024);
      final fileHistory = File(
        '${root.path}/community.quota/files/old.txt.100.previous',
      );
      await fileHistory.parent.create(recursive: true);
      final old = await fileHistory.open(mode: FileMode.write);
      await old.truncate(256 * 1024 * 1024);
      await old.close();
      await session.call('storage.write', {
        'name': 'live.txt',
        'data': base64Encode([1, 2, 3]),
      });
      final files = await session.call('files.list', {}) as List;
      expect(files.map((e) => e['name']), ['live.txt']);
      expect(await fileHistory.length(), 256 * 1024 * 1024);
      await expectLater(
        session.call('storage.write', {
          'name': 'bypass.1.previous',
          'data': '',
        }),
        throwsFormatException,
      );
    },
  );
  test(
    'single JS protocol rejects old protocols, native and wasm payloads',
    () async {
      final plugin = await inspectPluginZip(pluginZip());
      expect(plugin.assets['main.js'], isNotNull);
      for (final runtime in ['web-v1', 'declarative-v1', 'dart']) {
        await expectLater(
          inspectPluginZip(
            pluginZip(json: {...pluginJson(), 'runtime': runtime}),
          ),
          throwsFormatException,
        );
      }
      for (final name in ['main.dll', 'test.wasm', 'native.dart', 'test.exe']) {
        await expectLater(
          inspectPluginZip(
            pluginZip(
              extra: {
                name: [1, 2, 3],
              },
            ),
          ),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'HTML resources cannot bypass host-controlled network or spawn workers',
    () async {
      final server = await PluginAssetServer.open({
        'page.html': Uint8List.fromList(utf8.encode('<h1>Plugin</h1>')),
      });
      addTearDown(server.close);
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final response = await (await client.getUrl(
        Uri.parse('${server.origin}page.html'),
      )).close();
      final policy = response.headers.value('content-security-policy')!;
      expect(policy, contains("connect-src 'none'"));
      expect(policy, contains("worker-src 'none'"));
      expect(policy, isNot(contains('unsafe-eval')));
      expect(response.headers.value('access-control-allow-origin'), isNull);
      expect(await utf8.decoder.bind(response).join(), contains('window.aq='));
      for (final suffix in [
        '../private.txt',
        '%2e%2e%2fprivate.txt',
        'missing.js',
      ]) {
        final denied = await (await client.getUrl(
          Uri.parse('${server.origin}$suffix'),
        )).close();
        expect(denied.statusCode, 404);
        await denied.drain<void>();
      }
    },
  );
  test(
    'module files, archive, import, permission denial, isolation and revocation use real bytes',
    () async {
      final createdRoot = await Directory.systemTemp.createTemp(
        'aq-module-host-',
      );
      final root = Directory(await createdRoot.resolveSymbolicLinks());
      final api = ImportApi();
      var refreshes = 0;
      final services = PluginHostServices(
        api: api,
        onImported: () => refreshes++,
        storagePath: root.path,
        fetch: (uri, limit) async =>
            Uint8List.fromList(utf8.encode('downloaded content')),
      );
      const manifest = PluginManifest(
        id: 'community.one',
        name: 'One',
        version: '1.0.0',
        description: '',
        permissions: {
          PluginPermission.derivedFiles,
          PluginPermission.libraryImport,
          PluginPermission.network,
        },
      );
      final session = await services.open(manifest);
      final second = await services.open(
        const PluginManifest(
          id: 'community.two',
          name: 'Two',
          version: '1.0.0',
          description: '',
          permissions: {PluginPermission.derivedFiles},
        ),
      );
      await session.call('storage.write', {
        'name': 'sample.txt',
        'data': base64Encode(utf8.encode('real module bytes')),
      });
      expect(
        await File(
          '${root.path}/community.one/files/sample.txt',
        ).readAsString(),
        'real module bytes',
      );
      expect(await second.call('storage.read', {'name': 'sample.txt'}), null);
      await session.call('library.import', {'name': 'sample.txt'});
      expect(api.files.single['name'], 'sample.txt');
      expect(
        utf8.decode(base64Decode(api.files.single['data'])),
        'real module bytes',
      );
      expect(refreshes, 1);
      await session.call('download.save', {
        'name': 'network.txt',
        'url': 'https://example.org/file',
      });
      expect(
        await File(
          '${root.path}/community.one/files/network.txt',
        ).readAsString(),
        'downloaded content',
      );
      await session.call('archive.create', {
        'name': 'sample.cbz',
        'files': ['sample.txt', 'network.txt'],
      });
      final archive = ZipDecoder().decodeBytes(
        await File('${root.path}/community.one/files/sample.cbz').readAsBytes(),
      );
      expect(archive.length, 2);
      for (final name in [
        '../escape.txt',
        'C:\\escape.txt',
        '/escape.txt',
        'a/../b.txt',
      ]) {
        await expectLater(
          session.call('storage.read', {'name': name}),
          throwsFormatException,
        );
      }
      await expectLater(
        second.call('network.get', {'url': 'https://example.org'}),
        throwsStateError,
      );
      session.close();
      await expectLater(
        session.call('library.import', {'name': 'sample.txt'}),
        throwsStateError,
      );
      expect(
        await File('${root.path}/community.one/files/sample.txt').exists(),
        true,
      );
      second.close();
    },
  );
}

class ImportApi implements ReaderApi {
  List<Map<String, dynamic>> files = [];
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (method == 'snapshot') {
      return {
        'catalog': {
          'inbox': 'inbox',
          'projects': [],
          'books': [],
          'progress': [],
          'actor': 'test',
        },
      };
    }
    if (method == 'preview_import') {
      files = (args['files'] as List).cast<Map<String, dynamic>>();
      return {
        'task': 'task-1',
        'base_revision': 0,
        'target': 'inbox',
        'issues': [],
        'projects': [],
        'books': [
          {
            'id': 'book-1',
            'title': 'sample',
            'project': 'inbox',
            'resources': [
              {'id': 'resource-1'},
            ],
          },
        ],
      };
    }
    if (method == 'commit_import') {
      return {
        'books': ['book-1'],
      };
    }
    throw StateError('Unexpected method $method');
  }
}
