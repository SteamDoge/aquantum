// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:aquantum_reader/data/reader_api.dart';
import 'package:aquantum_reader/plugins/plugin_package.dart';
import 'package:aquantum_reader/plugins/plugin_host.dart';
import 'package:aquantum_reader/plugins/plugin_manager.dart';
import 'package:aquantum_reader/plugins/plugin_reader.dart';
import 'package:aquantum_reader/plugins/plugin_asset_server.dart';
import 'package:aquantum_reader/plugins/plugin_web_document.dart';
import '../test/plugin_fixtures.dart';

void main() {
  test(
    'real independent ZIP browser business against actual JS actors and Rust library',
    () async {
      final projects = Platform.environment['PLUGIN_PROJECTS'];
      if (projects == null) throw StateError('Set PLUGIN_PROJECTS');
      final output = Directory(
        '../../output/playwright/plugin-business-${DateTime.now().millisecondsSinceEpoch}',
      );
      await output.create(recursive: true);
      final api = RustReaderApi('${output.absolute.path}/library');
      await api.call('snapshot');
      final opened = <String>[];
      final services = PluginHostServices(
        api: api,
        onImported: () {},
        storagePath: '${output.absolute.path}/plugins',
        onOpenFile: (pluginId, name, bytes) async {
          final reader = await PluginReaderSession.open(
            '${output.absolute.path}/direct-read',
            name,
            bytes,
            scope: pluginId,
          );
          final value = reader.book.isComic
              ? await reader.api.call('read_image', {
                  'book': reader.book.id,
                  'page': reader.book.pages.first['id'],
                })
              : await reader.api.call('read_text', {'book': reader.book.id});
          if (jsonEncode(value).length < 20) {
            throw StateError('Empty direct reader content');
          }
          opened.add(name);
        },
        theme: () => {'brightness': 'light'},
      );
      final registry = testRegistry();
      final manager = PluginManager(
        registry,
        MemoryPluginStore(),
        hostServices: services,
      );
      await manager.load();
      final assets = <String, PluginAssetServer>{};
      for (final path in [
        '$projects/bookstore_module/dist/community.bookstore-0.3.0.aqplugin.zip',
        '$projects/jmcomic_module/dist/jmcomic.console-0.3.1.aqplugin.zip',
      ]) {
        final bytes = await File(path).readAsBytes();
        final inspected = await inspectPluginZip(bytes);
        await manager.importPackage(
          inspected,
          FilePluginPackageStore('${output.path}/packages'),
          bytes,
        );
        await manager.enable(
          inspected.manifest.id,
          inspected.manifest.permissions,
        );
        final plugin =
            manager.record(inspected.manifest.id).implementation
                as JavaScriptPlugin;
        assets[plugin.manifest.id] = await PluginAssetServer.open(
          plugin.assets,
        );
      }
      final finished = Completer<void>();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 18766);
      server.listen((request) async {
        try {
          final id =
              request.uri.queryParameters['plugin'] ?? 'community.bookstore';
          if (request.uri.path == '/rpc') {
            final message = jsonDecode(await utf8.decoder.bind(request).join());
            dynamic value;
            String? error;
            try {
              value =
                  await (manager.record(id).implementation as JavaScriptPlugin)
                      .call(
                        message['method'],
                        Map<String, dynamic>.from(message['args']),
                      );
            } catch (e) {
              error = e.toString();
            }
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode({'id': message['id'], 'value': value, 'error': error}),
            );
          } else if (request.uri.path == '/finish') {
            final snapshot = await api.call('snapshot');
            final books = snapshot['catalog']['books'] as List;
            if (books.length < 2 || opened.length < 2) {
              throw StateError(
                'Expected actual imports and separate direct reader sessions',
              );
            }
            final readable = <Map<String, dynamic>>[];
            for (final book in books) {
              final value = book['format'] == 'Comic'
                  ? await api.call('read_image', {
                      'book': book['id'],
                      'page': book['pages'][0]['id'],
                    })
                  : await api.call('read_text', {'book': book['id']});
              if (jsonEncode(value).length < 20) {
                throw StateError('Empty imported content');
              }
              readable.add({
                'id': book['id'],
                'format': book['format'],
                'readerCharacters': jsonEncode(value).length,
              });
            }
            await File(
              '${output.path}/snapshot.json',
            ).writeAsString(jsonEncode(snapshot));
            await File('${output.path}/readability.json').writeAsString(
              jsonEncode({'books': readable, 'directRead': opened}),
            );
            request.response.write('complete');
            finished.complete();
          } else {
            var html =
                webPluginDocument(
                  assets[id]!.origin,
                  false,
                  'index.html',
                ).replaceFirst(
                  "script-src 'unsafe-inline';",
                  "script-src 'unsafe-inline'; connect-src 'self';",
                );
            html = html.replaceFirst(
              '<script>',
              '<script>window.AQuantum={postMessage:async(raw)=>{const r=await fetch("/rpc?plugin=$id",{method:"POST",body:raw});window.aqReply(await r.json());}};',
            );
            request.response.headers.contentType = ContentType.html;
            request.response.write(html);
          }
        } catch (e) {
          request.response.statusCode = 500;
          request.response.write('$e');
        } finally {
          await request.response.close();
        }
      });
      await File('../../.tools/plugin-browser-info.json').writeAsString(
        jsonEncode({
          'url': 'http://127.0.0.1:18766',
          'output': output.absolute.path,
        }),
      );
      stdout.writeln('PLUGIN_BROWSER_READY ${output.absolute.path}');
      try {
        await finished.future.timeout(const Duration(minutes: 20));
      } finally {
        for (final record in manager.records) {
          await manager.disable(record.manifest.id);
        }
        for (final asset in assets.values) {
          await asset.close();
        }
        await server.close(force: true);
        manager.dispose();
        registry.dispose();
      }
    },
    timeout: const Timeout(Duration(minutes: 22)),
  );
}
