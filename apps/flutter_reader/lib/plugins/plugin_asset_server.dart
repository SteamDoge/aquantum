// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'plugin_web_document.dart';

class PluginAssetServer {
  final HttpServer server;
  final String origin;
  PluginAssetServer._(this.server, this.origin);
  static Future<PluginAssetServer> open(Map<String, Uint8List> assets) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // Dart's server default is SAMEORIGIN. The host wrapper deliberately has a
    // different origin; its CSP and sandbox own framing instead.
    server.defaultResponseHeaders.removeAll('x-frame-options');
    final token = List.generate(
      24,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final origin = 'http://127.0.0.1:${server.port}/$token/';
    server.listen((request) async {
      try {
        final prefix = '/$token/';
        final path = request.uri.path;
        if (request.method != 'GET' || !path.startsWith(prefix)) {
          request.response.statusCode = 404;
          return;
        }
        final name = path.substring(prefix.length);
        final bytes = assets[name];
        if (bytes == null) {
          request.response.statusCode = 404;
          return;
        }
        final type = name.endsWith('.js') || name.endsWith('.mjs')
            ? 'text/javascript'
            : name.endsWith('.html')
            ? 'text/html'
            : name.endsWith('.css')
            ? 'text/css'
            : name.endsWith('.json')
            ? 'application/json'
            : name.endsWith('.svg')
            ? 'image/svg+xml'
            : name.endsWith('.png')
            ? 'image/png'
            : 'application/octet-stream';
        request.response.headers.set(
          'content-type',
          '$type${type.startsWith('text/') ? '; charset=utf-8' : ''}',
        );
        // Assets load inside the package's own iframe origin; cross-origin
        // response access has no consumer and is deliberately not enabled.
        request.response.headers.set('Cache-Control', 'no-store');
        request.response.headers.set(
          'Permissions-Policy',
          'camera=(), microphone=(), geolocation=(), clipboard-read=(), clipboard-write=(), usb=(), serial=()',
        );
        request.response.headers.set(
          'Content-Security-Policy',
          "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self' data:; connect-src 'none'; worker-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'self'; form-action 'none'",
        );
        if (name.endsWith('.html')) {
          // SDK precedes plugin scripts; base points at only this package's resources.
          request.response.write(
            '<!doctype html><base href="$origin"><meta name="viewport" content="width=device-width,initial-scale=1"><script>$pluginClientScript</script>',
          );
        }
        request.response.add(bytes);
      } finally {
        await request.response.close();
      }
    });
    return PluginAssetServer._(server, origin);
  }

  Future<void> close({bool force = true}) async {
    await server.close(force: force);
  }
}
