// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'dart:async';

bool publicPluginAddress(InternetAddress address) {
  final b = address.rawAddress;
  if (b.length == 4) {
    return !(b[0] == 0 ||
        b[0] == 10 ||
        b[0] == 127 ||
        b[0] >= 224 ||
        (b[0] == 169 && b[1] == 254) ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && (b[1] == 168 || b[1] == 0)) ||
        (b[0] == 100 && b[1] >= 64 && b[1] <= 127) ||
        (b[0] == 198 &&
            (b[1] == 18 || b[1] == 19 || b[1] == 51 && b[2] == 100)) ||
        (b[0] == 203 && b[1] == 0 && b[2] == 113));
  }
  // Accept globally routed IPv6 only, excluding mapped IPv4 and local ranges.
  if (b.length != 16 || (b[0] & 0xe0) != 0x20) return false;
  if (b[0] == 0x20 && b[1] == 0x02) return false;
  if (b[0] == 0x20 &&
      b[1] == 0x01 &&
      ((b[2] == 0 && b[3] <= 0x2f) || (b[2] == 0x0d && b[3] == 0xb8))) {
    return false;
  }
  return true;
}

typedef PluginFetch = Future<Uint8List> Function(Uri uri, int limit);

class PluginHttpException implements Exception {
  final int status;
  const PluginHttpException(this.status);
  @override
  String toString() => '插件下载失败（HTTP $status）';
}

class PluginConnectionException implements Exception {
  final String host;
  final Object cause;
  const PluginConnectionException(this.host, this.cause);
  @override
  String toString() => '无法连接 $host：连接被重置或中断，已尝试3次。请稍后重试，或在插件设置中检查站点与网络。';
}

Future<Uint8List> fetchPublicHttps(
  Uri uri,
  int limit, {
  HttpClient? httpClient,
  bool allowFakeIpDns = true,
}) async {
  final client = httpClient ?? HttpClient();
  client.findProxy = (_) => 'DIRECT';
  client.connectionTimeout = const Duration(seconds: 15);
  var ended = false;
  try {
    Future<Uint8List> read(int attempt) async {
      var target = uri;
      for (var redirects = 0; redirects <= 5; redirects++) {
        if (ended) throw StateError('网络请求已结束');
        if (target.scheme != 'https' ||
            target.port != 443 ||
            target.userInfo.isNotEmpty ||
            target.host.isEmpty) {
          throw const FormatException('下载重定向必须保持公开 HTTPS');
        }
        var addresses = await InternetAddress.lookup(target.host);
        if (!allowFakeIpDns && target.host == 'dns.google') {
          addresses = [InternetAddress('8.8.8.8')];
        }
        // VPN Fake-IP ranges are never connected to. Resolve the original DNS
        // name over authenticated public HTTPS, then apply the same IP policy.
        // Literal addresses and all other private ranges remain hard failures.
        if (allowFakeIpDns &&
            InternetAddress.tryParse(target.host) == null &&
            addresses.isNotEmpty &&
            addresses.every((a) {
              final b = a.rawAddress;
              return b.length == 4 && b[0] == 198 && {18, 19}.contains(b[1]) ||
                  b.length == 16 &&
                      b[0] == 0x20 &&
                      b[1] == 1 &&
                      b[2] == 0 &&
                      b[3] == 2;
            })) {
          final answer = jsonDecode(
            utf8.decode(
              await fetchPublicHttps(
                Uri.https('dns.google', '/resolve', {
                  'name': target.host,
                  'type': 'A',
                  'edns_client_subnet': '0.0.0.0/0',
                }),
                64 * 1024,
                allowFakeIpDns: false,
              ),
            ),
          );
          if (answer is! Map ||
              answer['Status'] != 0 ||
              answer['TC'] == true ||
              answer['Answer'] is! List) {
            throw const FormatException('公开HTTPS DNS解析失败');
          }
          addresses = [
            for (final record in answer['Answer'])
              if (record is Map &&
                  record['type'] == 1 &&
                  record['data'] is String)
                InternetAddress(record['data']),
          ];
        }
        if (addresses.isEmpty || !addresses.every(publicPluginAddress)) {
          throw const FormatException('禁止下载本机或私有网络资源');
        }
        if (ended) throw StateError('网络请求已结束');
        // Pin the validated address so a second DNS lookup cannot rebind it.
        final hostname = target.host;
        client.connectionFactory = (_, _, _) async {
          final task = await Socket.startConnect(
            addresses[attempt % addresses.length],
            443,
          );
          return ConnectionTask.fromSocket<Socket>(
            task.socket.then(
              (socket) => SecureSocket.secure(socket, host: hostname),
            ),
            task.cancel,
          );
        };
        final request = await client.getUrl(target);
        request.persistentConnection = false;
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.userAgentHeader,
          'AQuantum-Reader-Plugin/1',
        );
        request.headers.set(
          HttpHeaders.acceptHeader,
          'application/vnd.github+json, application/zip, */*',
        );
        final response = await request.close();
        if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null) throw const FormatException('重定向缺少地址');
          target = target.resolve(location);
          continue;
        }
        if (response.statusCode != 200) {
          throw PluginHttpException(response.statusCode);
        }
        if (response.contentLength > limit) {
          throw const FormatException('插件下载超过大小限制');
        }
        final result = BytesBuilder(copy: false);
        await for (final chunk in response) {
          if (result.length + chunk.length > limit) {
            throw const FormatException('插件下载超过大小限制');
          }
          result.add(chunk);
        }
        return result.takeBytes();
      }
      throw const FormatException('插件下载重定向过多');
    }

    Future<Uint8List> attempts() async {
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          return await read(attempt);
        } on SocketException catch (error) {
          if (attempt == 2) {
            throw PluginConnectionException(uri.host, error);
          }
        } on HttpException catch (error) {
          if (attempt == 2) {
            throw PluginConnectionException(uri.host, error);
          }
        }
        // GET only, bounded retries. Security, TLS certificate, HTTP status and
        // size failures are never turned into a retry or a successful result.
        await Future<void>.delayed(Duration(milliseconds: 250 * (attempt + 1)));
      }
      throw StateError('网络请求未完成');
    }

    return await attempts().timeout(
      const Duration(seconds: 45),
      onTimeout: () => throw TimeoutException('连接 ${uri.host} 超时，请检查站点与网络'),
    );
  } finally {
    ended = true;
    client.close(force: true);
  }
}
