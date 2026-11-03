// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'plugin_package.dart';
import 'plugin_network.dart';
export 'plugin_network.dart';

/// No package code is executed. All hops use bounded, pinned public HTTPS.
class PluginDownload {
  final Uint8List bytes;
  final JavaScriptPlugin plugin;
  final String source, releaseNotes, digest;
  PluginDownload(this.bytes, this.plugin, this.source, this.releaseNotes)
    : digest = sha256.convert(bytes).toString();
}

class PluginSource {
  final Uri uri;
  final String? owner, repo, tag;
  bool get githubReleaseDiscovery => owner != null;
  const PluginSource._(this.uri, this.owner, this.repo, this.tag);
  factory PluginSource.parse(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment ||
        uri.port != 443) {
      throw const FormatException('请输入无凭据的 HTTPS 仓库、Release 或 ZIP 链接');
    }
    final p = uri.pathSegments.where((s) => s.isNotEmpty).toList();
    if (uri.host.toLowerCase() == 'github.com' &&
        p.length >= 2 &&
        (p.length == 2 ||
            (p.length >= 3 &&
                p[2] == 'releases' &&
                (p.length == 3 ||
                    (p.length == 4 && p[3] == 'latest') ||
                    (p.length >= 5 && p[3] == 'tag'))))) {
      final repo = p[1].replaceFirst(RegExp(r'\.git$'), '');
      if (![p[0], repo].every(
        (s) =>
            RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(s) && s != '.' && s != '..',
      )) {
        throw const FormatException('GitHub 仓库路径无效');
      }
      return PluginSource._(
        uri,
        p[0],
        repo,
        p.length >= 5 ? p.skip(4).join('/') : null,
      );
    }
    if (!uri.path.toLowerCase().endsWith('.zip')) {
      throw const FormatException('仅支持 GitHub 仓库、Release 页面或 HTTPS ZIP');
    }
    return PluginSource._(uri, null, null, null);
  }
}

class PluginDownloader {
  final PluginFetch fetch;
  PluginDownloader({PluginFetch? fetch}) : fetch = fetch ?? fetchPublicHttps;
  Future<PluginDownload> inspect(String input) async {
    final source = PluginSource.parse(input);
    var uri = source.uri;
    var notes = '';
    String? expectedDigest;
    if (source.githubReleaseDiscovery) {
      final base =
          'https://api.github.com/repos/${source.owner}/${source.repo}';
      final endpoint = source.tag == null
          ? 'latest'
          : 'tags/${Uri.encodeComponent(source.tag!)}';
      Map<String, dynamic>? release;
      try {
        release = await jsonObject(Uri.parse('$base/releases/$endpoint'));
      } on PluginHttpException catch (e) {
        if (e.status != 404 || source.tag != null) rethrow;
      }
      if (release == null) {
        throw const FormatException('仓库没有已发布的插件 ZIP；请先独立构建并发布安装包。');
      }
      if (release['draft'] != false || release['assets'] is! List) {
        throw const FormatException('Release 信息无效');
      }
      final assets = (release['assets'] as List)
          .whereType<Map>()
          .where(
            (a) =>
                a['name'] is String &&
                (a['name'] as String).toLowerCase().endsWith('.zip'),
          )
          .toList();
      final preferred = assets
          .where((a) => (a['name'] as String).endsWith('.aqplugin.zip'))
          .toList();
      final chosen = preferred.isNotEmpty ? preferred : assets;
      if (chosen.length != 1 ||
          chosen.single['browser_download_url'] is! String) {
        throw const FormatException(
          '没有唯一的插件 ZIP；请提供具体 Release ZIP 资源链接（推荐 .aqplugin.zip）',
        );
      }
      uri = PluginSource.parse(chosen.single['browser_download_url']).uri;
      final digest = chosen.single['digest'];
      if (digest is String && digest.startsWith('sha256:')) {
        expectedDigest = digest.substring(7).toLowerCase();
      }
      notes = 'Release ${release['tag_name']}\n${release['body'] ?? ''}';
    }
    final bytes = await fetch(uri, pluginZipLimit);
    if (expectedDigest != null &&
        sha256.convert(bytes).toString() != expectedDigest) {
      throw const FormatException('Release 安装包 SHA-256 与声明不一致');
    }
    return PluginDownload(
      bytes,
      await inspectPluginZip(bytes),
      source.uri.toString(),
      notes,
    );
  }

  Future<Map<String, dynamic>> jsonObject(Uri uri) async {
    final data = jsonDecode(utf8.decode(await fetch(uri, 512 * 1024)));
    if (data is! Map<String, dynamic>) {
      throw const FormatException('远端返回无效 JSON');
    }
    return data;
  }
}
