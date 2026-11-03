// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aquantum_reader/plugins/plugin_network.dart';
import 'package:flutter_test/flutter_test.dart';

class _Client extends Fake implements HttpClient {
  int calls = 0;
  bool closed = false;
  final int resets, status;
  final String? location;
  final Object? failure;
  _Client({this.resets = 0, this.status = 200, this.location, this.failure});
  @override
  set findProxy(String Function(Uri)? value) {}
  @override
  set connectionTimeout(Duration? value) {}
  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(Uri, String?, int?)? value,
  ) {}
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    calls++;
    if (failure != null) throw failure!;
    if (calls <= resets) {
      throw const SocketException('Connection reset by peer');
    }
    return _Request(status, location);
  }

  @override
  void close({bool force = false}) => closed = true;
}

class _Headers extends Fake implements HttpHeaders {
  final String? location;
  _Headers(this.location);
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}
  @override
  String? value(String name) => name == 'location' ? location : null;
}

class _Request extends Fake implements HttpClientRequest {
  final int status;
  final String? location;
  _Request(this.status, this.location);
  @override
  HttpHeaders get headers => _Headers(null);
  @override
  set followRedirects(bool value) {}
  @override
  set persistentConnection(bool value) {}
  @override
  Future<HttpClientResponse> close() async => _Response(status, location);
}

class _Response extends Stream<List<int>> implements HttpClientResponse {
  final int status;
  final String? location;
  _Response(this.status, this.location);
  @override
  int get statusCode => status;
  @override
  int get contentLength => 3;
  @override
  HttpHeaders get headers => _Headers(location);
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value([1, 2, 3]).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final uri = Uri.https('8.8.8.8', '/fixture');
  test('TLS certificate failures surface unchanged without retry', () async {
    final client = _Client(
      failure: const HandshakeException('certificate verification failed'),
    );
    await expectLater(
      fetchPublicHttps(uri, 100, httpClient: client),
      throwsA(isA<HandshakeException>()),
    );
    expect(client.calls, 1);
    expect(client.closed, isTrue);
  });
  test(
    'GET retries a reset and returns only the complete successful bytes',
    () async {
      final client = _Client(resets: 1);
      final data = await fetchPublicHttps(uri, 100, httpClient: client);
      expect(data, Uint8List.fromList([1, 2, 3]));
      expect(client.calls, 2);
      expect(client.closed, isTrue);
    },
  );
  test(
    'persistent resets stop at three attempts with actionable error',
    () async {
      final client = _Client(resets: 10);
      await expectLater(
        fetchPublicHttps(uri, 100, httpClient: client),
        throwsA(
          isA<PluginConnectionException>().having(
            (e) => e.host,
            'host',
            '8.8.8.8',
          ),
        ),
      );
      expect(client.calls, 3);
      expect(client.closed, isTrue);
    },
  );
  test('HTTP denial and size limits are not retried', () async {
    final denied = _Client(status: 403);
    await expectLater(
      fetchPublicHttps(uri, 100, httpClient: denied),
      throwsA(isA<PluginHttpException>()),
    );
    expect(denied.calls, 1);
    final oversized = _Client();
    await expectLater(
      fetchPublicHttps(uri, 2, httpClient: oversized),
      throwsFormatException,
    );
    expect(oversized.calls, 1);
  });
  test('retry still refuses location to a private address', () async {
    final client = _Client(
      resets: 1,
      status: 302,
      location: 'https://127.0.0.1/private',
    );
    await expectLater(
      fetchPublicHttps(uri, 100, httpClient: client),
      throwsFormatException,
    );
    expect(client.calls, 2);
  });
}
