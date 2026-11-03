// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

abstract interface class ReaderApi {
  Future<dynamic> call(String method, [Map<String, dynamic> args = const {}]);
}

class RustReaderApi implements ReaderApi {
  final String root;
  final String libraryPath;
  Future<void> _pending = Future<void>.value();
  RustReaderApi(this.root, {String? libraryPath})
    : libraryPath =
          libraryPath ??
          Platform.environment['AQ_RUST_LIB'] ??
          (Platform.isWindows
              ? '${File(Platform.resolvedExecutable).parent.path}/aq_bridge.dll'
              : 'libaq_bridge.so');

  @override
  Future<dynamic> call(String method, [Map<String, dynamic> args = const {}]) {
    // Job status/cancel only touch append-only task metadata. They must reach a
    // running native job without waiting behind it in the mutation queue.
    if (method == 'task_status' ||
        method == 'task_cancel' ||
        method == 'plugin_runtime') {
      return _call(method, args);
    }
    // One app instance queues native sessions so rapid page changes and notes
    // cannot race their catalog revisions. A failed call does not poison the queue.
    final result = _pending.then((_) => _call(method, args));
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> get idle => _pending;

  Future<dynamic> _call(String method, Map<String, dynamic> args) async {
    // Encode before dispatch; the isolate opens the ABI and releases both allocations.
    final request = jsonEncode({'root': root, 'method': method, 'args': args});
    final path = libraryPath;
    // The reply is parsed in the worker too: page images arrive as multi-MB
    // base64 strings, and decoding them on the UI isolate costs frames during
    // page turns. Isolate.run hands the parsed map back without copying.
    final envelope = await Isolate.run(
      () => jsonDecode(_invoke(path, request)) as Map<String, dynamic>,
    );
    if (envelope['ok'] != true) {
      throw ReaderFailure(envelope['error']?.toString() ?? '操作失败');
    }
    return envelope['data'];
  }
}

typedef _InvokeNative = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _InvokeDart = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);

String _invoke(String path, String request) {
  final DynamicLibrary library;
  try {
    library = DynamicLibrary.open(path);
  } catch (error) {
    throw ReaderFailure(
      '无法加载原生阅读核心。源码测试请先运行 scripts/check.ps1，或构建 aq-bridge 并设置 AQ_RUST_LIB。详情：$error',
    );
  }
  final invoke = library.lookupFunction<_InvokeNative, _InvokeDart>(
    'aq_invoke_json',
  );
  final free = library.lookupFunction<_FreeNative, _FreeDart>('aq_free_json');
  final input = request.toNativeUtf8();
  Pointer<Utf8>? output;
  try {
    output = invoke(input);
    return output.toDartString();
  } finally {
    calloc.free(input);
    if (output != null) free(output);
  }
}

class ReaderFailure implements Exception {
  final String message;
  ReaderFailure(this.message);
  @override
  String toString() => message;
}
