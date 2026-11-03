// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'document_engine.dart';
import 'document_engine_channel.dart';

/// A local HTTPS origin is served from APK assets by Android's WebViewClient.
/// There is no HTTP listener, network permission, or file:// module origin.
class AndroidDocumentEngine extends ChannelDocumentEngine {
  AndroidDocumentEngine._(super.channel);
  static bool get supported => Platform.isAndroid;
  MethodChannel? _native;
  bool _closed = false;
  static AndroidDocumentEngine create() {
    late final AndroidDocumentEngine engine;
    final channel = DocumentChannel((message) async {
      if (engine._closed || engine._native == null) {
        throw const DocumentEngineFailure('文档视图尚未连接');
      }
      await engine._native!.invokeMethod<void>('post', message);
    });
    engine = AndroidDocumentEngine._(channel);
    return engine;
  }

  Future<void> _created(int id) async {
    if (_closed) return;
    final native = MethodChannel('cn.aquantum/document/$id');
    _native = native;
    native.setMethodCallHandler((call) async {
      if (_closed) return;
      if (call.method == 'message' && call.arguments is String) {
        channel.receive(call.arguments as String);
      }
    });
    try {
      await native.invokeMethod<void>('load');
    } catch (e) {
      channel.fail('$e');
    }
  }

  @override
  Widget build(BuildContext context) => AndroidView(
    key: ObjectKey(this),
    viewType: 'cn.aquantum/document',
    layoutDirection: TextDirection.ltr,
    onPlatformViewCreated: _created,
  );
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final native = _native;
    _native = null;
    await closeChannel();
    if (native != null) {
      try {
        await native.invokeMethod<void>('close');
      } catch (_) {}
      native.setMethodCallHandler(null);
    }
  }
}
