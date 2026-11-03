// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'plugin_asset_server.dart';
import 'plugin_web_document.dart';
import 'package:webview_all_linux/webview_all_linux.dart' as linux;
import 'package:webview_platform_interface/webview_platform_interface.dart'
    as linux_api;
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart' as mobile;
import 'package:webview_windows/webview_windows.dart' as windows;
import '../formats/document_engine_windows.dart';
import 'plugin_api.dart';
import 'plugin_host.dart';

class WebPluginLifetime extends ChangeNotifier {
  bool active = false;
  void start() {
    active = true;
  }

  void stop() {
    active = false;
    notifyListeners();
  }
}

/// A sandboxed iframe executes plugin code; only an explicit RPC bridge reaches IO.
class WebPluginView extends StatefulWidget {
  final Map<String, Uint8List> assets;
  final PluginManifest manifest;
  final PluginHostServices? services;
  final WebPluginLifetime lifetime;
  final String entry;
  final Future<dynamic> Function(String, Map<String, dynamic>) dispatch;
  const WebPluginView({
    super.key,
    required this.assets,
    required this.manifest,
    required this.services,
    required this.lifetime,
    required this.entry,
    required this.dispatch,
  });
  @override
  State<WebPluginView> createState() => _WebPluginViewState();
}

class _WebPluginViewState extends State<WebPluginView> {
  windows.WebviewController? desktop;
  mobile.WebViewController? handheld;
  linux.LinuxWebViewController? penguin;
  PluginAssetServer? server;
  StreamSubscription<dynamic>? subscription;
  String? error;
  bool ready = false, closed = false, pluginReady = false;
  Timer? readinessTimer;
  bool started = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!started) {
      started = true;
      unawaited(open());
    } else if (ready && !closed) {
      unawaited(syncTheme());
    }
  }

  Future<void> syncTheme() async {
    final theme =
        widget.services?.theme?.call() ??
        {'brightness': Theme.of(context).brightness.name};
    final script =
        'window.aqReply(${jsonEncode({'kind': 'theme', 'value': theme})});';
    try {
      if (desktop != null) {
        await desktop!.executeScript(script);
      } else if (penguin != null) {
        await penguin!.runJavaScript(script);
      } else {
        await handheld?.runJavaScript(script);
      }
    } catch (_) {
      /* Navigation may have disposed this view. */
    }
  }

  @override
  void initState() {
    super.initState();
    widget.lifetime.addListener(revoked);
  }

  void revoked() {
    if (!widget.lifetime.active) {
      unawaited(close());
      if (mounted) {
        setState(() {
          ready = false;
          error = '插件已停用';
        });
      }
    }
  }

  Future<void> open() async {
    try {
      final services = widget.services;
      if (services == null) throw StateError('当前运行入口未配置插件服务');
      if (closed) {
        return;
      }
      if (!mounted) return;
      final dark = Theme.of(context).brightness == Brightness.dark;
      final assetServer = await PluginAssetServer.open(widget.assets);
      server = assetServer;
      if (closed) {
        await assetServer.close();
        return;
      }
      final origin = assetServer.origin;
      debugPrint('PLUGIN_RUNTIME: asset server started');
      final html = webPluginDocument(origin, dark, widget.entry);
      if (Platform.isWindows) {
        await WindowsDocumentEngine.ensureEnvironment();
        if (closed) return;
        final control = windows.WebviewController();
        desktop = control;
        await control.initialize();
        debugPrint('PLUGIN_RUNTIME: WebView initialized');
        if (closed) {
          await control.dispose();
          return;
        }
        await control.setPopupWindowPolicy(
          windows.WebviewPopupWindowPolicy.deny,
        );
        subscription = control.webMessage.listen(
          (message) => unawaited(
            receive(message is String ? message : jsonEncode(message)),
          ),
        );
        await control.loadStringContent(html);
        debugPrint('PLUGIN_RUNTIME: wrapper loaded');
      } else if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
        final control = mobile.WebViewController();
        handheld = control;
        await control.setJavaScriptMode(mobile.JavaScriptMode.unrestricted);
        await control.addJavaScriptChannel(
          'AQuantum',
          onMessageReceived: (message) => unawaited(receive(message.message)),
        );
        await control.setNavigationDelegate(
          mobile.NavigationDelegate(
            onNavigationRequest: (request) =>
                request.url == 'about:blank' ||
                    request.url.startsWith(origin) ||
                    request.url.startsWith('data:text/html')
                ? mobile.NavigationDecision.navigate
                : mobile.NavigationDecision.prevent,
          ),
        );
        await control.loadHtmlString(html);
      } else if (Platform.isLinux) {
        final control = linux.LinuxWebViewController(
          const linux_api.PlatformWebViewControllerCreationParams(),
        );
        penguin = control;
        await control.setJavaScriptMode(linux_api.JavaScriptMode.unrestricted);
        await control.addJavaScriptChannel(
          linux_api.JavaScriptChannelParams(
            name: 'AQuantum',
            onMessageReceived: (message) => unawaited(receive(message.message)),
          ),
        );
        await control.loadHtmlString(html);
      } else {
        throw UnsupportedError('当前平台没有插件加载器');
      }
      if (mounted && !closed) setState(() => ready = true);
      if (!pluginReady && !closed) {
        readinessTimer = Timer(const Duration(seconds: 20), () {
          if (mounted && !closed && !pluginReady) {
            setState(() => error = '插件页面未响应，请检查运行包入口与构建资源。');
            unawaited(close());
          }
        });
      }
    } catch (e) {
      debugPrint('PLUGIN_RUNTIME: startup failed $e');
      if (mounted && !closed) setState(() => error = '插件启动失败：$e');
    }
  }

  Future<void> receive(String raw) async {
    if (closed || raw.length > 24 * 1024 * 1024) return;
    dynamic id;
    Map<String, dynamic> result;
    try {
      final message = jsonDecode(raw) as Map<String, dynamic>;
      id = message['id'];
      debugPrint('PLUGIN_RUNTIME: host method ${message['method']}');
      if (id is! int ||
          message['method'] is! String ||
          message['args'] is! Map) {
        throw const FormatException('插件请求格式错误');
      }
      if (message['method'] == 'runtime.ready') {
        readinessTimer?.cancel();
        if (mounted) setState(() => pluginReady = true);
        await syncTheme();
      } else if (message['method'] == 'runtime.error') {
        readinessTimer?.cancel();
        final detail = message['args']['message'].toString();
        debugPrint('PLUGIN_RUNTIME: page error $detail');
        if (mounted) {
          setState(
            () => error =
                '插件页面执行失败：${detail.length > 2000 ? detail.substring(0, 2000) : detail}',
          );
        }
        await close();
        return;
      }
      final value = await widget.dispatch(
        message['method'],
        Map<String, dynamic>.from(message['args']),
      );
      result = {'id': id, 'value': value};
    } catch (e) {
      result = {'id': id, 'error': e.toString()};
    }
    if (closed) return;
    final script = 'window.aqReply(${jsonEncode(result)});';
    try {
      if (desktop != null) {
        await desktop!.executeScript(script);
      } else if (penguin != null) {
        await penguin!.runJavaScript(script);
      } else {
        await handheld?.runJavaScript(script);
      }
    } catch (_) {
      /* A disposed page cannot receive a reply. */
    }
  }

  Future<void> close() async {
    if (closed) return;
    closed = true;
    readinessTimer?.cancel();
    await subscription?.cancel();
    await server?.close(force: true);
    if (penguin != null) {
      await penguin!.dispose();
    }
    if (desktop?.value.isInitialized == true) await desktop!.dispose();
    if (handheld != null) {
      await handheld!.removeJavaScriptChannel('AQuantum');
      await handheld!.loadHtmlString('<html></html>');
    }
  }

  @override
  void dispose() {
    widget.lifetime.removeListener(revoked);
    unawaited(close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (error != null) return Center(child: SelectableText(error!));
    if (!ready) return const Center(child: CircularProgressIndicator());
    // HTML cannot read the host inset without a protocol change, so a
    // platform web page stays above the floating dock instead of under it.
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
      child: desktop != null
          ? windows.Webview(desktop!)
          : penguin != null
          ? linux.LinuxWebViewWidget(
              linux_api.PlatformWebViewWidgetCreationParams(
                controller: penguin!,
              ),
            ).build(context)
          : mobile.WebViewWidget(controller: handheld!),
    );
  }
}
