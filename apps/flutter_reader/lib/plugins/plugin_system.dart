// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'plugin_manifest.dart';
import 'plugin_export.dart';

/// Explicit OS capabilities; every call rechecks the session grant.
class PluginSystemAccess {
  // A key/decryption failure must surface without silently erasing credentials.
  static const _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  );
  static String credentialPrefix(String id) => 'aq.plugin.${id.length}:$id:';

  /// Host-only maintenance after an explicit user request and instance shutdown.
  static Future<void> deleteCredentials(String id) async {
    const secure = _secure;
    final prefix = credentialPrefix(id);
    final keys = (await secure.readAll()).keys.where(
      (k) => k.startsWith(prefix),
    );
    for (final key in keys) {
      await secure.delete(key: key);
    }
  }

  static const methods = {
    'secrets.get',
    'secrets.set',
    'secrets.remove',
    'clipboard.read',
    'clipboard.write',
    'external.pick',
    'files.export',
  };
  final String pluginId;
  final void Function([PluginPermission? permission]) check;
  final Future<File> Function(Object?) resolveFile;
  PluginSystemAccess(this.pluginId, this.check, this.resolveFile);
  Future<dynamic> call(String method, Map<String, dynamic> args) async {
    check();
    switch (method) {
      case 'secrets.get':
      case 'secrets.set':
      case 'secrets.remove':
        check(PluginPermission.secureStorage);
        final key = args['key'];
        if (key is! String ||
            !RegExp(r'^[a-zA-Z0-9_.-]{1,80}$').hasMatch(key)) {
          throw const FormatException('凭据键无效');
        }
        final scoped = '${credentialPrefix(pluginId)}$key';
        const secure = _secure;
        if (method == 'secrets.get') {
          final value = await secure.read(key: scoped);
          check(PluginPermission.secureStorage);
          return value;
        }
        if (method == 'secrets.remove') {
          await secure.delete(key: scoped);
          return null;
        }
        final value = args['value'];
        if (value is! String || value.length > 8192) {
          throw const FormatException('凭据值过大');
        }
        await secure.write(key: scoped, value: value);
        check(PluginPermission.secureStorage);
        return null;
      case 'clipboard.read':
        check(PluginPermission.clipboard);
        final value = await Clipboard.getData('text/plain');
        check(PluginPermission.clipboard);
        return value?.text;
      case 'clipboard.write':
        check(PluginPermission.clipboard);
        final text = args['text'];
        if (text is! String || text.length > 64 * 1024) {
          throw const FormatException('剪贴板文本过大');
        }
        await Clipboard.setData(ClipboardData(text: text));
        check();
        return null;
      case 'external.pick':
        check(PluginPermission.externalFiles);
        final picked = await FilePicker.platform.pickFiles(
          allowMultiple: false,
          withReadStream: true,
          withData: false,
        );
        check(PluginPermission.externalFiles);
        if (picked == null || picked.files.isEmpty) return null;
        final file = picked.files.single;
        if (file.size > 16 * 1024 * 1024 || file.readStream == null) {
          throw StateError('所选文件超过16MiB或不可读取');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in file.readStream!) {
          check(PluginPermission.externalFiles);
          if (bytes.length + chunk.length > 16 * 1024 * 1024) {
            throw StateError('所选文件过大');
          }
          bytes.add(chunk);
        }
        return {'name': file.name, 'data': base64Encode(bytes.takeBytes())};
      case 'files.export':
        check(PluginPermission.externalFiles);
        final file = await resolveFile(args['name']);
        if (!await file.exists() || await file.length() > 16 * 1024 * 1024) {
          throw StateError('导出文件不存在或过大');
        }
        final result = await exportPluginBytes(
          file.uri.pathSegments.last,
          await file.readAsBytes(),
        );
        check();
        return {'saved': result};
      default:
        throw const FormatException('未知系统能力');
    }
  }
}
