// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import '../data/reader_api.dart';

/// JS actors live on Rust-owned OS threads; FFI runs outside Flutter's UI isolate.
class PluginRuntime {
  final ReaderApi api;
  final Future<dynamic> Function(String, Map<String, dynamic>) host;
  final void Function(Object)? onFailure;
  final _waiting = <int, Completer<dynamic>>{};
  int? _handle;
  int _sequence = 0;
  bool closed = false;
  PluginRuntime(this.api, this.host, {this.onFailure});

  Future<void> start(Map<String, String> sources, String entry) async {
    final result = await api.call('plugin_runtime', {
      'operation': 'create',
      'sources': sources,
      'entry': entry,
    });
    _handle = result['handle'] as int;
    if (closed) await _destroy();
  }

  Future<dynamic> invoke(
    String kind, {
    String? handler,
    dynamic payload,
    String? name,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (closed || _handle == null) throw StateError('插件运行时已停止');
    final id = ++_sequence;
    final completion = Completer<dynamic>();
    _waiting[id] = completion;
    unawaited(
      _dispatch({
        'kind': kind,
        'id': id,
        'handler': handler,
        'payload': payload,
        'name': name,
      }),
    );
    try {
      return await completion.future.timeout(
        timeout,
        onTimeout: () {
          final error = TimeoutException('插件任务超时，运行实例已终止');
          unawaited(close());
          onFailure?.call(error);
          throw error;
        },
      );
    } finally {
      _waiting.remove(id);
    }
  }

  Future<void> _dispatch(dynamic command) async {
    if (closed) return;
    try {
      final messages =
          await api.call('plugin_runtime', {
                'operation': 'dispatch',
                'handle': _handle,
                'command': command,
              })
              as List;
      if (closed) return;
      for (final message in messages) {
        if (message['kind'] == 'result') {
          final waiter = _waiting[message['id']];
          if (waiter == null || waiter.isCompleted) continue;
          message['error'] == null
              ? waiter.complete(message['value'])
              : waiter.completeError(StateError(message['error']));
        } else if (message['kind'] == 'host') {
          unawaited(_serve(Map<String, dynamic>.from(message)));
        }
      }
    } catch (error) {
      for (final waiting in _waiting.values) {
        if (!waiting.isCompleted) waiting.completeError(error);
      }
      unawaited(close());
      onFailure?.call(error);
    }
  }

  Future<void> _serve(Map<String, dynamic> message) async {
    dynamic value;
    String? error;
    try {
      value = await host(
        message['method'] as String,
        Map<String, dynamic>.from(message['args']),
      );
    } catch (e) {
      error = e.toString();
    }
    if (!closed) {
      await _dispatch({
        'kind': 'reply',
        'id': message['id'],
        'value': value,
        'error': error,
      });
    }
  }

  Future<void> _destroy() async {
    final handle = _handle;
    _handle = null;
    if (handle != null) {
      await api.call('plugin_runtime', {
        'operation': 'destroy',
        'handle': handle,
      });
    }
  }

  Future<void> close() async {
    if (closed && _handle == null) return;
    closed = true;
    for (final waiting in _waiting.values) {
      if (!waiting.isCompleted) waiting.completeError(StateError('插件运行时已停止'));
    }
    await _destroy();
  }
}
