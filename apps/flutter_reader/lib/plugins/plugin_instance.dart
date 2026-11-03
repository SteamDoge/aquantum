// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../data/reader_api.dart';
import 'plugin_api.dart';
import 'plugin_host.dart';
import 'plugin_runtime.dart';
import 'plugin_ui.dart';
import 'web_plugin_view.dart';
import '../dashboard/widget_registry.dart';

const pluginIcons = <String, IconData>{
  'extension': Icons.extension_outlined,
  'book': Icons.menu_book_outlined,
  'info': Icons.info_outline,
  'notes': Icons.notes_outlined,
  'search': Icons.search,
  'translate': Icons.translate_outlined,
};

class JavaScriptPlugin extends ChangeNotifier implements ReaderPlugin {
  @override
  final PluginManifest manifest;
  final String entry;
  final Set<String> platforms;
  final Map<String, String> dependencies;
  final Map<String, Uint8List> assets;
  final slots = <String, Map<String, dynamic>>{};
  String? packageDigest;
  PluginHostServices? hostServices;
  Set<PluginPermission> grants = {};
  PluginRuntime? runtime;
  PluginHostSession? session;
  final WebPluginLifetime lifetime = WebPluginLifetime();
  void Function()? onChanged;
  void Function(Object)? onFailure;
  bool active = false, activating = false;
  final _requestClock = Stopwatch()..start();
  int _requestWindow = 0, _requestCount = 0;
  JavaScriptPlugin._(
    this.manifest,
    this.entry,
    this.platforms,
    this.dependencies,
    this.assets,
  );
  factory JavaScriptPlugin.fromJson(
    Map<String, dynamic> json, {
    Map<String, Uint8List>? assets,
  }) {
    validate(json);
    return JavaScriptPlugin._(
      PluginManifest(
        id: json['id'],
        name: json['name'],
        version: json['version'],
        description: json['description'],
        author: json['author'],
        apiVersion: json['apiVersion'],
        permissions: (json['permissions'] as List)
            .map((p) => PluginPermission.values.byName(p))
            .toSet(),
      ),
      json['entry'],
      Set<String>.from(json['platforms']),
      Map<String, String>.from(json['dependencies'] ?? {}),
      Map.unmodifiable(assets ?? {}),
    );
  }
  static void validate(Map<String, dynamic> json) {
    const keys = {
      'schemaVersion',
      'runtime',
      'apiVersion',
      'id',
      'name',
      'version',
      'author',
      'description',
      'entry',
      'permissions',
      'platforms',
      'dependencies',
      'pages',
    };
    if (json.keys.any((k) => !keys.contains(k)) ||
        json['schemaVersion'] != 1 ||
        json['apiVersion'] != pluginApiVersion ||
        json['runtime'] != 'javascript-v1' ||
        json['id'] is! String ||
        !RegExp(
          r'^[a-z][a-z0-9_-]*(?:\.[a-z][a-z0-9_-]*)+$',
        ).hasMatch(json['id']) ||
        (json['id'] as String).length > 64 ||
        (json['id'] as String).startsWith('core.') ||
        (json['id'] as String).startsWith('builtin.') ||
        json['version'] is! String ||
        !RegExp(
          r'^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$',
        ).hasMatch(json['version']) ||
        (json['version'] as String).length > 32 ||
        ['name', 'author', 'description'].any(
          (k) =>
              json[k] is! String ||
              (json[k] as String).trim().isEmpty ||
              (json[k] as String).length > (k == 'description' ? 2000 : 120),
        ) ||
        json['entry'] is! String ||
        !RegExp(
          r'^[a-zA-Z0-9_][a-zA-Z0-9_/-]*\.(m?js)$',
        ).hasMatch(json['entry']) ||
        json['permissions'] is! List ||
        (json['permissions'] as List).any(
          (p) => !PluginPermission.values.any((v) => v.name == p),
        ) ||
        (json['permissions'] as List).toSet().length !=
            (json['permissions'] as List).length ||
        json['platforms'] is! List ||
        (json['platforms'] as List).isEmpty ||
        (json['platforms'] as List).any(
          (p) => !{'windows', 'android', 'ios', 'linux'}.contains(p),
        )) {
      throw const FormatException(
        '插件清单无效；仅支持 javascript-v1 与编译后的 JavaScript 入口',
      );
    }
    final dependencies = json['dependencies'] ?? {};
    if (dependencies is! Map ||
        dependencies.length > 32 ||
        dependencies.entries.any(
          (e) =>
              e.key is! String ||
              e.value is! String ||
              !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(e.value),
        )) {
      throw const FormatException('依赖必须指定插件ID和最低三段版本');
    }
    if (json['pages'] != null &&
        (json['pages'] is! List ||
            (json['pages'] as List).any(
              (p) => p is! String || !(p).endsWith('.html'),
            ))) {
      throw const FormatException('页面资源必须是 HTML 相对路径');
    }
  }

  @override
  Future<void> activate(PluginRegistrar registrar) async {
    if (active) return;
    final services = hostServices;
    if (services == null) throw StateError('未配置插件宿主');
    activating = true;
    active = true;
    lifetime.start();
    session = await services.open(manifest, grants: grants);
    services.attach(this);
    runtime = PluginRuntime(
      services.runtimeApi ?? RustReaderApi(''),
      call,
      onFailure: (e) => onFailure?.call(e),
    );
    try {
      await runtime!.start({
        for (final e in assets.entries)
          if (e.key.endsWith('.js') || e.key.endsWith('.mjs'))
            e.key: utf8.decode(e.value),
      }, entry);
      await runtime!.invoke('activate');
      contribute(registrar);
    } catch (_) {
      await deactivate();
      rethrow;
    } finally {
      activating = false;
    }
  }

  Future<dynamic> invoke(String handler, dynamic payload) async {
    if (!active) throw StateError('插件已停用');
    return runtime!.invoke('invoke', handler: handler, payload: payload);
  }

  Future<dynamic> call(String method, Map<String, dynamic> args) async {
    if (!active) throw StateError('插件已停用');
    final now = _requestClock.elapsedMilliseconds;
    if (now - _requestWindow >= 1000) {
      _requestWindow = now;
      _requestCount = 0;
    }
    if (++_requestCount > 120) {
      final error = StateError('插件宿主调用超过每秒120次，实例已撤销');
      onFailure?.call(error);
      throw error;
    }
    if (method.startsWith('slots.')) {
      final id = args['id'];
      if (id is! String || !RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(id)) {
        throw const FormatException('扩展ID无效');
      }
      if (method == 'slots.remove') {
        slots.remove(id);
      } else if (method == 'slots.update') {
        if (!slots.containsKey(id)) throw StateError('扩展不存在');
        validatePluginUi(args['ui']);
        if (pluginUiHasEvents(args['ui']) && slots[id]!['handler'] is! String) {
          throw const FormatException('交互组件必须提供页面回调');
        }
        slots[id] = {...slots[id]!, 'ui': args['ui']};
      } else if (method == 'slots.register') {
        if (args.keys.any(
              (k) => !{
                'id',
                'name',
                'type',
                'icon',
                'navigation',
                'ui',
                'html',
                'handler',
                'pages',
                'surface',
              }.contains(k),
            ) ||
            args['handler'] != null &&
                (args['handler'] is! String ||
                    (args['handler'] as String).length > 128) ||
            args['navigation'] != null && args['navigation'] is! bool) {
          throw const FormatException('未知扩展属性或属性类型无效');
        }
        if (slots.containsKey(id) ||
            slots.length >= 64 ||
            args['name'] is! String ||
            (args['name'] as String).isEmpty ||
            (args['name'] as String).length > 80 ||
            !{
              'page',
              'settings',
              'readerMore',
              'readerToolbar',
              'textSelection',
              'fileMenu',
              'projectMenu',
              'search',
              'libraryAction',
              'fileAction',
              'dashboard',
              'format',
            }.contains(args['type'])) {
          throw const FormatException('扩展声明无效或重复');
        }
        if (args['type'] == 'page' ||
            args['type'] == 'settings' ||
            args['type'] == 'dashboard') {
          if (args['type'] == 'dashboard' && args['html'] != null) {
            throw const FormatException('主页组件使用原生UI描述');
          }
          if (args['html'] != null) {
            if (args['html'] is! String ||
                !assets.containsKey(args['html']) ||
                !(args['html'] as String).endsWith('.html')) {
              throw const FormatException('页面不在安装包内');
            }
          } else {
            validatePluginUi(args['ui']);
            if (pluginUiHasEvents(args['ui']) && args['handler'] is! String) {
              throw const FormatException('交互组件必须提供页面回调');
            }
          }
        } else if (args['type'] == 'format') {
          if (!{
            'document',
            'text',
            'markdown',
            'fixed_page',
            'image_page',
          }.contains(args['surface'])) {
            throw const FormatException('格式阅读面无效');
          }
        } else if (args['handler'] is! String) {
          throw const FormatException('操作缺少回调');
        }
        if (args['type'] == 'textSelection' &&
            !grants.contains(PluginPermission.selectedText)) {
          throw StateError('未授权选中文字');
        }
        slots[id] = Map.unmodifiable(args);
      } else {
        throw const FormatException('未知扩展方法');
      }
      notifyListeners();
      if (!activating) onChanged?.call();
      return null;
    }
    if (method.startsWith('services.') ||
        method.startsWith('events.') ||
        method.startsWith('tasks.')) {
      return hostServices!.route(this, method, args);
    }
    return session!.call(method, args);
  }

  void contribute(PluginRegistrar registrar) {
    for (final slot in slots.values) {
      final type = slot['type'];
      if (type == 'format') {
        registrar.format(
          ReaderFormatRegistration(
            id: '${manifest.id}.format.${slot['id']}',
            name: slot['name'],
            surface: slot['surface'],
          ),
        );
      } else if (type == 'dashboard') {
        final pages = slot['pages'];
        if (pages is! List ||
            pages.isEmpty ||
            pages.any((p) => !{'home', 'statistics'}.contains(p))) {
          throw const FormatException('组件页面无效');
        }
        registrar.widget(
          DashboardDefinition(
            id: '${manifest.id}.widget.${slot['id']}',
            name: slot['name'],
            source: manifest.id,
            icon: pluginIcons[slot['icon']] ?? Icons.extension_outlined,
            pages: pages.map((p) => DashboardPage.values.byName(p)).toSet(),
            render: (context, data, config, metrics) => SizedBox(
              height: 240,
              // A page embedded in a card never meets the floating dock.
              child: MediaQuery.removePadding(
                context: context,
                removeBottom: true,
                child: PluginNativePage(plugin: this, slotId: slot['id']),
              ),
            ),
          ),
        );
      } else if (type == 'page' || type == 'settings') {
        registrar.page(
          id: '${manifest.id}.page.${slot['id']}',
          name: slot['name'],
          icon: pluginIcons[slot['icon']] ?? Icons.extension_outlined,
          allowNavigation: slot['navigation'] != false && type != 'settings',
          builder: (_) => slot['html'] != null
              ? WebPluginView(
                  assets: assets,
                  manifest: manifest,
                  services: hostServices,
                  lifetime: lifetime,
                  entry: slot['html'],
                  dispatch: call,
                )
              : PluginNativePage(plugin: this, slotId: slot['id']),
        );
      } else {
        final point = switch (type) {
          'libraryAction' || 'fileAction' => ExtensionPoint.fileMenu,
          _ => ExtensionPoint.values.byName(type),
        };
        registrar.action(
          PluginAction(
            id: '${manifest.id}.action.${slot['id']}',
            name: slot['name'],
            icon: pluginIcons[slot['icon']] ?? Icons.extension_outlined,
            point: point,
            permissions: type == 'textSelection'
                ? {PluginPermission.selectedText}
                : {},
            invoke: (context) async {
              final result = await invoke(slot['handler'], {
                'bookId': context.bookId,
                'projectId': context.projectId,
                'format': context.format,
                if (type == 'textSelection')
                  'selectedText': context.selectedText,
              });
              return result?.toString();
            },
          ),
        );
      }
    }
  }

  Future<void> lifecycle(String name) async {
    if (active) await runtime?.invoke('lifecycle', name: name);
  }

  @override
  Future<void> deactivate({bool force = false}) async {
    if (!active && runtime == null) return;
    // Revoke all host resources before awaiting plugin cleanup.
    active = false;
    lifetime.stop();
    session?.close();
    hostServices?.detach(manifest.id);
    slots.clear();
    notifyListeners();
    final engine = runtime;
    runtime = null;
    if (!force && engine != null && !engine.closed) {
      try {
        await engine.invoke(
          'deactivate',
          timeout: const Duration(milliseconds: 500),
        );
      } catch (_) {
        /* Host ownership is already revoked. */
      }
    }
    await engine?.close();
  }
}
