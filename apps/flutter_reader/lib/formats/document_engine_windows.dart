// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';
import 'package:webview_windows/webview_windows.dart';

import 'document_engine.dart';
import 'document_engine_channel.dart';

/// Runs the vendored foliate-js page inside WebView2.
///
/// The page loads from a virtual host mapped onto an unpacked copy of the
/// bundled web assets rather than from `file://` or `loadStringContent`: the ES
/// plugins need a real origin so the page's `script-src 'self'` policy still
/// applies, and nothing can be reached outside those files.
class WindowsDocumentEngine extends ChannelDocumentEngine {
  WindowsDocumentEngine._(this._controller, DocumentChannel channel)
    : super(channel);

  static const host = 'aq.local';
  static const _entry = 'reader/index.html';

  /// The bundled files, in the order the page needs them. Flutter has no
  /// directory listing, so a missing name fails the unpack instead of leaving
  /// a page that fails at run time.
  static const files = [
    'reader/index.html',
    'reader/bridge.js',
    'reader/page_effects.js',
    'reader/book_security.js',
    'reader/managed_comic.js',
    'foliate/LICENSE',
    'foliate/THIRD_PARTY.md',
    'foliate/view.js',
    'foliate/epub.js',
    'foliate/epubcfi.js',
    'foliate/progress.js',
    'foliate/overlayer.js',
    'foliate/text-walker.js',
    'foliate/search.js',
    'foliate/paginator.js',
    'foliate/fixed-layout.js',
    'foliate/footnotes.js',
    'foliate/quote-image.js',
    'foliate/mobi.js',
    'foliate/fb2.js',
    'foliate/comic-book.js',
    'foliate/vendor/zip.js',
    'foliate/vendor/fflate.js',
  ];

  /// Bump when the bundled page changes, so an older copy is never reused.
  static const version = 11;

  static Future<String>? _unpacking;
  static bool _environmentReady = false;

  final WebviewController _controller;
  StreamSubscription<dynamic>? _messages;
  StreamSubscription<dynamic>? _errors;
  bool _closed = false;

  /// True when this platform has a browser control that can host the page.
  static bool get supported => Platform.isWindows;

  /// Creates the browser environment once per process: a second environment is
  /// the documented way to leak a browser process per book.
  static Future<void> ensureEnvironment() async {
    if (!Platform.isWindows) throw const DocumentEngineFailure('当前平台没有文档引擎');
    if (_environmentReady) return;
    final support = await getApplicationSupportDirectory();
    final profile = Directory('${support.path}/document-browser');
    await profile.create(recursive: true);
    await WebviewController.initializeEnvironment(userDataPath: profile.path);
    _environmentReady = true;
  }

  /// Directory holding the unpacked page for this build.
  static Future<String> unpacked() {
    final running = _unpacking;
    if (running != null) return running;
    final start = _unpack();
    _unpacking = start;
    unawaited(
      start.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          _unpacking = null;
        },
      ),
    );
    return start;
  }

  static Future<WindowsDocumentEngine> create() async {
    await ensureEnvironment();
    final root = await unpacked();
    final controller = WebviewController();
    await controller.initialize();
    await controller.setPopupWindowPolicy(WebviewPopupWindowPolicy.deny);
    await controller.addVirtualHostNameMapping(
      host,
      root,
      WebviewHostResourceAccessKind.allow,
    );
    final channel = DocumentChannel(
      (message) => controller.postWebMessage(message),
    );
    final engine = WindowsDocumentEngine._(controller, channel);
    engine._messages = controller.webMessage.listen((message) {
      // WebView2 delivers the page's JSON as a decoded value; every transport
      // ends in one string so both platforms share the framing.
      final text = message is String
          ? message
          : message is Map || message is List
          ? jsonEncode(message)
          : null;
      if (text != null) channel.receive(text);
    });
    // The page announces readiness by itself; a completed navigation that never
    // did means the page failed to load, so the screen must not wait forever.

    engine._errors = controller.onLoadError.listen((error) {
      channel.fail(error.name);
    });
    await controller.loadUrl('https://$host/$_entry');
    return engine;
  }

  /// Copies the bundled page into the application's support directory. The
  /// copy is derived from shipped assets, so it is not user data; a failed
  /// attempt keeps its staging directory as evidence instead of deleting it.
  static Future<String> _unpack() async {
    final support = await getApplicationSupportDirectory();
    final root = Directory('${support.path}/document-web/v$version');
    final complete = File('${root.path}/.complete');
    if (await complete.exists()) return root.path;
    final staging = Directory(
      '${support.path}/document-web/staging-$version-'
      '${DateTime.now().microsecondsSinceEpoch}',
    );
    await staging.create(recursive: true);
    for (final name in files) {
      final data = await rootBundle.load('web/$name');
      final target = File('${staging.path}/$name');
      await target.parent.create(recursive: true);
      await target.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    await root.parent.create(recursive: true);
    await File(
      '${staging.path}/.complete',
    ).writeAsString('$version', flush: true);
    if (await root.exists()) return staging.path;
    try {
      await staging.rename(root.path);
      return root.path;
    } on FileSystemException {
      if (await complete.exists()) return root.path;
      rethrow;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await closeChannel();
    await _messages?.cancel();
    await _errors?.cancel();
    await _controller.dispose();
  }

  @override
  Widget build(BuildContext context) => Webview(_controller);
}
