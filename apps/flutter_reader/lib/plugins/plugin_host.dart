// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import '../data/reader_api.dart';
import '../data/models.dart';
import '../dashboard/dashboard_data.dart';
import 'plugin_manifest.dart';
import 'plugin_network.dart';
import 'plugin_broker.dart';
import 'plugin_instance.dart';
import 'plugin_storage.dart';
import 'plugin_system.dart';

/// Explicit ports; plugins never receive ReaderApi or filesystem paths.
class PluginHostServices {
  final broker = PluginBroker();
  final logs = <String, List<String>>{};
  final ReaderApi? runtimeApi;
  final Future<void> Function(String)? onOpenBook;
  final Future<void> Function(String, String, Uint8List)? onOpenFile;
  final Future<void> Function(String)? onOpenPage;
  final Future<void> Function(String)? onMessage;
  final Map<String, dynamic> Function()? theme;
  Map<String, dynamic>? currentReader;
  void attach(JavaScriptPlugin plugin) => broker.attach(plugin);
  void detach(String id) => broker.detach(id);
  Future<dynamic> route(
    JavaScriptPlugin plugin,
    String method,
    Map<String, dynamic> args,
  ) => broker.route(plugin, method, args);
  final ReaderApi api;
  final void Function() onImported;
  final String? storagePath;
  final void Function(String pluginId, String method)? onRequest;
  final Future<String> Function()? storageRoot;
  final Future<Uint8List> Function(Uri, int) fetch;
  PluginHostServices({
    required this.api,
    required this.onImported,
    this.storagePath,
    this.onRequest,
    this.storageRoot,
    this.fetch = fetchPublicHttps,
    this.runtimeApi,
    this.onOpenBook,
    this.onOpenFile,
    this.onOpenPage,
    this.onMessage,
    this.theme,
  });
  Future<PluginHostSession> open(
    PluginManifest manifest, {
    Set<PluginPermission>? grants,
  }) async {
    final root = storagePath ?? await storageRoot?.call();
    if (root == null) throw StateError('宿主未配置插件存储根');
    // Platform support paths may contain OS aliases (Android /data/user/0).
    // Canonicalize only the host-configured base; plugin-owned links remain denied.
    final base = await Directory(root).create(recursive: true);
    final canonical = await base.resolveSymbolicLinks();
    return PluginHostSession(
      manifest,
      this,
      Directory('$canonical/${manifest.id}/files'),
      grants ?? manifest.permissions,
    );
  }
}

class PluginHostSession {
  final Set<PluginPermission> grants;
  final PluginManifest manifest;
  final PluginHostServices services;
  final Directory root;
  bool active = true;
  int _pending = 0;
  final Set<HttpClient> _clients = {};
  late final storage = PluginStorage(root, _check);
  late final system = PluginSystemAccess(manifest.id, _check, storage.file);
  Future<void> _mutations = Future.value();
  int _queued = 0;
  PluginHostSession(this.manifest, this.services, this.root, this.grants);
  void close() {
    active = false;
    for (final client in _clients) {
      client.close(force: true);
    }
    _clients.clear();
  }

  void _check([PluginPermission? permission]) {
    if (!active) throw StateError('插件已停用');
    if (permission != null &&
        (!manifest.permissions.contains(permission) ||
            !grants.contains(permission))) {
      throw StateError('插件未获 ${permission.name} 权限');
    }
  }

  Future<dynamic> call(String method, Map<String, dynamic> args) async {
    const mutations = {
      'storage.write',
      'settings.set',
      'data.set',
      'files.mkdir',
      'files.remove',
      'files.rename',
      'archive.create',
      'download.save',
    };
    if (!mutations.contains(method)) return _call(method, args);
    _check();
    if (_queued >= 16) throw StateError('插件写入队列已满');
    _queued++;
    final operation = _mutations.then((_) => _call(method, args));
    _mutations = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    try {
      return await operation;
    } finally {
      _queued--;
    }
  }

  Future<dynamic> _call(String method, Map<String, dynamic> args) async {
    _check();
    services.onRequest?.call(manifest.id, method);
    if (_pending >= 4) throw StateError('同时最多四个宿主请求');
    _pending++;
    try {
      if (PluginSystemAccess.methods.contains(method)) {
        return await system.call(method, args);
      }
      switch (method) {
        case 'settings.get':
        case 'settings.set':
        case 'data.get':
        case 'data.set':
          final key = args['key'];
          if (key is! String ||
              !RegExp(r'^[a-zA-Z0-9_.-]{1,80}$').hasMatch(key)) {
            throw const FormatException('设置键无效');
          }
          final file = await storage.configuration(
            area: method.startsWith('data.') ? 'data' : 'config',
          );
          final values = await file.exists()
              ? Map<String, dynamic>.from(jsonDecode(await file.readAsString()))
              : <String, dynamic>{};
          _check();
          if (method.endsWith('.get')) return values[key];
          values[key] = args['value'];
          final encoded = jsonEncode(values);
          if (utf8.encode(encoded).length > 256 * 1024) {
            throw StateError('插件配置超过256KiB');
          }
          // History is retained and remains exportable, but cannot consume the
          // quota of the current configuration and permanently disable writes.
          final staging = File(
            '${file.path}.${DateTime.now().microsecondsSinceEpoch}.part',
          );
          await staging.writeAsString(encoded, flush: true);
          _check();
          if (await file.exists()) {
            await file.rename(
              '${file.path}.${DateTime.now().microsecondsSinceEpoch}.previous',
            );
          }
          await staging.rename(file.path);
          return null;
        case 'logger.write':
          final message = args['message'];
          if (message is! String || message.length > 4000) {
            throw const FormatException('日志过长');
          }
          final logs = services.logs.putIfAbsent(manifest.id, () => []);
          if (logs.length >= 200) logs.removeAt(0);
          logs.add(
            '${DateTime.now().toIso8601String()} ${args['level']} $message',
          );
          return null;
        case 'ui.theme':
          return services.theme?.call() ?? {'brightness': 'light'};
        case 'ui.show':
          final message = args['message'];
          if (message is! String ||
              message.length > 4000 ||
              services.onMessage == null) {
            throw StateError('无效提示或宿主界面不可用');
          }
          await services.onMessage!(message);
          _check();
          return null;
        case 'ui.open':
          final id = args['id'];
          if (id is! String ||
              !id.startsWith('${manifest.id}.page.') ||
              services.onOpenPage == null) {
            throw StateError('只能打开自己的插件页面');
          }
          await services.onOpenPage!(id);
          _check();
          return null;
        case 'reader.current':
          _check(PluginPermission.documentText);
          return services.currentReader;
        case 'library.list':
          _check(PluginPermission.libraryRead);
          final snapshot = LibrarySnapshot(
            Map<String, dynamic>.from(await services.api.call('snapshot')),
          );
          _check(PluginPermission.libraryRead);
          return [
            for (final book in snapshot.books)
              {
                'id': book.id,
                'title': book.title,
                'format': book.format,
                'projectId': book.project,
              },
          ];
        case 'statistics.read':
          _check(PluginPermission.libraryRead);
          final data = DashboardData(
            LibrarySnapshot(
              Map<String, dynamic>.from(await services.api.call('snapshot')),
            ),
          );
          _check(PluginPermission.libraryRead);
          return {
            'todayMs': data.today,
            'yearMs': data.yearTime,
            'yearBooks': data.yearBooks,
            'completedBooks': data.completedBooks,
            'streak': data.streak,
            'fileCount': data.library.books.length,
            'projectCount': data.library.projects.length - 1,
          };
        case 'files.open':
          if (services.onOpenFile == null) throw StateError('宿主阅读器入口不可用');
          final file = await storage.file(args['name']);
          if (!await file.exists() || await file.length() > 16 * 1024 * 1024) {
            throw StateError('阅读文件不存在或过大');
          }
          final content = await file.readAsBytes();
          _check(PluginPermission.derivedFiles);
          await services.onOpenFile!(
            manifest.id,
            file.uri.pathSegments.last,
            content,
          );
          return {'opened': true};
        case 'files.mkdir':
          final directory = Directory((await storage.file(args['name'])).path);
          _check(PluginPermission.derivedFiles);
          await directory.create(recursive: true);
          _check();
          return null;
        case 'files.remove':
          final file = await storage.file(args['name']);
          if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file) {
            throw StateError('只允许删除普通文件；目录必须先清空');
          }
          _check(PluginPermission.derivedFiles);
          await file.delete();
          return null;
        case 'files.rename':
          final source = await storage.file(args['name']);
          final target = await storage.file(args['target']);
          if (await FileSystemEntity.type(source.path, followLinks: false) !=
                  FileSystemEntityType.file ||
              await FileSystemEntity.type(target.path, followLinks: false) !=
                  FileSystemEntityType.notFound) {
            throw StateError('源须为普通文件且目标不得存在');
          }
          await target.parent.create(recursive: true);
          _check(PluginPermission.derivedFiles);
          await source.rename(target.path);
          return null;
        case 'storage.usage':
          await storage.configuration();
          var bytes = 0;
          await for (final entity in root.parent.list(
            recursive: true,
            followLinks: false,
          )) {
            if (entity is File) bytes += await entity.length();
          }
          return {'bytes': bytes};
        case 'runtime.ready':
          return {'ready': true};
        case 'runtime.error':
          return null;
        case 'crypto.md5':
          final text = args['text'];
          if (text is! String || text.length > 4096) {
            throw const FormatException('摘要输入过长');
          }
          return md5.convert(utf8.encode(text)).toString();
        case 'archive.create':
          final output = await storage.file(args['name']);
          final names = args['files'];
          if (names is! List || names.isEmpty || names.length > 512) {
            throw const FormatException('归档需要1至512个文件');
          }
          final archive = Archive();
          var total = 0;
          for (final name in names) {
            final file = await storage.file(name);
            total += await file.length();
            if (total > 16 * 1024 * 1024) {
              throw const FormatException('归档输入超过16MiB');
            }
            final bytes = await file.readAsBytes();
            archive.addFile(ArchiveFile(name as String, bytes.length, bytes));
          }
          await storage.write(output, ZipEncoder().encode(archive));
          return {'name': args['name'], 'files': names.length};
        case 'host.info':
          return {
            'apiVersion': 1,
            'runtime': 'javascript-v1',
            'pluginId': manifest.id,
            'permissions': grants.map((p) => p.name).toList(),
          };
        case 'storage.list':
        case 'files.list':
          _check(PluginPermission.derivedFiles);
          await storage.file('probe');
          final result = <Map<String, dynamic>>[];
          final path = args['path'] ?? '';
          final directory = path == ''
              ? root
              : Directory((await storage.file(path)).path);
          await for (final entry in directory.list(followLinks: false)) {
            if (PluginStorage.retainedVersion(entry.path)) continue;
            if (entry is File) {
              result.add({
                'name': entry.uri.pathSegments.last,
                'bytes': await entry.length(),
              });
            } else if (entry is Directory) {
              result.add({
                'name': entry.uri.pathSegments.where((p) => p.isNotEmpty).last,
                'directory': true,
              });
            }
          }
          return result;
        case 'storage.read':
          final file = await storage.file(args['name']);
          if (!await file.exists()) return null;
          if (await file.length() > 16 * 1024 * 1024) {
            throw StateError('文件超过16MiB');
          }
          return base64Encode(await file.readAsBytes());
        case 'storage.write':
          final file = await storage.file(args['name']);
          final bytes = _bytes(args['data']);
          await storage.write(file, bytes);
          return {'name': args['name'], 'bytes': bytes.length};
        case 'network.get':
          _check(PluginPermission.network);
          final bytes = await _fetch(
            Uri.parse(args['url'] as String),
            16 * 1024 * 1024,
          );
          _check(PluginPermission.network);
          return {'data': base64Encode(bytes), 'bytes': bytes.length};
        case 'download.save':
          _check(PluginPermission.network);
          final file = await storage.file(args['name']);
          final bytes = await _fetch(
            Uri.parse(args['url'] as String),
            16 * 1024 * 1024,
          );
          _check(PluginPermission.network);
          await storage.write(file, bytes);
          return {'name': args['name'], 'bytes': bytes.length};
        case 'library.import':
          _check(PluginPermission.libraryImport);
          final file = await storage.file(args['name']);
          if (!await file.exists() || await file.length() > 16 * 1024 * 1024) {
            throw StateError('文件不存在或超过16MiB');
          }
          final data = base64Encode(await file.readAsBytes());
          final hook = await services.broker.emit('library.beforeImport', {
            'name': args['name'],
            'bytes': await file.length(),
          });
          if (hook is Map && hook['cancel'] == true) {
            throw StateError(hook['reason']?.toString() ?? '插件Hook取消了导入');
          }
          _check(PluginPermission.libraryImport);
          final snapshot = LibrarySnapshot(
            Map<String, dynamic>.from(await services.api.call('snapshot')),
          );
          _check(PluginPermission.libraryImport);
          final plan = Map<String, dynamic>.from(
            await services.api.call('preview_import', {
              'target': snapshot.inbox,
              'files': [
                {'name': args['name'], 'data': data},
              ],
            }),
          );
          if ((plan['issues'] as List).isNotEmpty) {
            throw StateError('导入预览存在异常：${(plan['issues'] as List).join('；')}');
          }
          _check(PluginPermission.libraryImport);
          final result = await services.api.call('commit_import', {
            'task': plan['task'],
            'base_revision': plan['base_revision'],
            'target': plan['target'],
            'projects': [
              for (final project in plan['projects'])
                {'id': project['id'], 'name': project['name']},
            ],
            'books': [
              for (final book in plan['books'])
                {
                  'id': book['id'],
                  'title': book['title'],
                  'project': book['project'],
                  'resources': [
                    for (final resource in book['resources']) resource['id'],
                  ],
                },
            ],
            'skip_issues': false,
            'append': null,
          });
          services.onImported();
          unawaited(
            services.broker
                .emit('file.imported', {
                  'pluginId': manifest.id,
                  'name': args['name'],
                  'books': result['books'],
                })
                .catchError((Object _) => null),
          );
          unawaited(
            services.broker
                .emit('library.changed', {
                  'reason': 'pluginImport',
                  'books': result['books'],
                })
                .catchError((Object _) => null),
          );
          return result;
        default:
          throw const FormatException('未知插件服务');
      }
    } finally {
      _pending--;
    }
  }

  Future<Uint8List> _fetch(Uri uri, int limit) async {
    if (services.fetch != fetchPublicHttps) return services.fetch(uri, limit);
    final client = HttpClient();
    _clients.add(client);
    try {
      return await fetchPublicHttps(uri, limit, httpClient: client);
    } finally {
      _clients.remove(client);
      client.close(force: true);
    }
  }

  Uint8List _bytes(Object? value) {
    if (value is! String || value.length > 24 * 1024 * 1024) {
      throw const FormatException('文件数据过大');
    }
    final bytes = base64Decode(value);
    if (bytes.length > 16 * 1024 * 1024) {
      throw const FormatException('文件超过16MiB');
    }
    return bytes;
  }
}
