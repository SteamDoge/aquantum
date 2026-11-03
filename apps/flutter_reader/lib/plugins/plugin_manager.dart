// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../features/feature_registry.dart';
import 'plugin_api.dart';
import 'plugin_package.dart';
import 'plugin_host.dart';
import 'plugin_data.dart';
import '../dashboard/widget_registry.dart';

enum PluginStatus { available, disabled, enabled, suspended, failed }

abstract interface class PluginStateStore {
  Future<String?> read();
  Future<void> write(String value);
}

class DevicePluginStore implements PluginStateStore {
  @override
  Future<String?> read() async => (await SharedPreferences.getInstance())
      .getString('plugins.javascript.v1');
  @override
  Future<void> write(String value) async {
    if (!await (await SharedPreferences.getInstance()).setString(
      'plugins.javascript.v1',
      value,
    )) {
      throw StateError('插件状态保存失败');
    }
  }
}

class PluginRecord {
  final ReaderPlugin implementation;
  PluginManifest get manifest => implementation.manifest;
  PluginStatus status = PluginStatus.available;
  String? error;
  Set<PluginPermission> grants = {};
  String source = '随附插件';
  List<PluginAction> actions = [];
  List<ReaderFormatRegistration> formats = [];
  PluginRecord(this.implementation);
}

/// Owns installed and compiled plugin consent, publication and revocation.
/// Executable pages use the separate WebView bridge; this manager is not a CPU sandbox.
class PluginManager extends ChangeNotifier {
  final FeatureRegistry features;
  final PluginStateStore store;
  final Duration timeout;
  final PluginHostServices? hostServices;
  final DashboardRegistry? dashboards;
  final Map<String, PluginRecord> _records = {};
  final Map<String, JavaScriptPlugin> _versions = {};
  Map<String, dynamic> _saved = {};
  Future<void> _pending = Future.value();
  String? loadError;
  bool ready = false, busy = false, _disposed = false;

  PluginManager(
    this.features,
    this.store, {
    Iterable<ReaderPlugin> bundled = const [],
    this.dashboards,
    this.hostServices,
    this.timeout = const Duration(seconds: 5),
  }) {
    for (final implementation in bundled) {
      final manifest = implementation.manifest;
      if (!RegExp(r'^[a-z][a-z0-9_.-]+$').hasMatch(manifest.id) ||
          manifest.id == 'core' ||
          manifest.name.trim().isEmpty ||
          !RegExp(
            r'^\d+\.\d+\.\d+(?:[-+][a-zA-Z0-9.-]+)?$',
          ).hasMatch(manifest.version) ||
          _records.containsKey(manifest.id)) {
        throw ArgumentError('插件清单或重复编号无效');
      }
      _records[manifest.id] = PluginRecord(implementation);
    }
  }
  List<PluginRecord> get records => List.unmodifiable(_records.values);
  PluginRecord record(String id) =>
      _records[id] ?? (throw StateError('此构建未包含该插件代码'));

  final List<String> packageErrors = [];
  int packageCount = 0, packageBytes = 0, incompleteBytes = 0;
  void setInventory(LoadedPluginPackages inventory) {
    for (final plugin in [...inventory.plugins, ...inventory.versions]) {
      _versions['${plugin.manifest.id}@${plugin.manifest.version}'] = plugin;
      if (plugin.packageDigest != null) {
        _versions[plugin.packageDigest!] = plugin;
      }
    }
    packageCount = inventory.packageCount;
    packageBytes = inventory.packageBytes;
    incompleteBytes = inventory.incompleteBytes;
    packageErrors.addAll(inventory.errors);
  }

  void restorePackage(ReaderPlugin implementation) {
    if (ready || _records.containsKey(implementation.manifest.id)) {
      throw StateError('插件目录已装配或编号重复');
    }
    _records[implementation.manifest.id] = PluginRecord(implementation);
  }

  void checkImport(JavaScriptPlugin plugin) {
    final old = _records[plugin.manifest.id];
    if (old != null && old.implementation is! JavaScriptPlugin) {
      throw StateError('不能替换随附代码插件');
    }
    if (old != null &&
        comparePluginVersions(plugin.manifest.version, old.manifest.version) <=
            0 &&
        old.status != PluginStatus.available) {
      throw StateError('该插件已安装；更新包版本须高于当前版本');
    }
    if (old != null &&
        comparePluginVersions(plugin.manifest.version, old.manifest.version) <
            0) {
      throw StateError('本版不允许插件降级，已有版本已保留');
    }
  }

  Future<void> importPackage(
    JavaScriptPlugin declaration,
    PluginPackageStore packages,
    List<int> bytes, {
    String source = '本地 ZIP',
  }) => _run(() async {
    final plugin = await inspectPluginZip(Uint8List.fromList(bytes));
    if (plugin.manifest.id != declaration.manifest.id ||
        plugin.manifest.version != declaration.manifest.version ||
        (declaration.packageDigest != null &&
            declaration.packageDigest != plugin.packageDigest)) {
      throw const FormatException('安装预览与包内容不一致');
    }
    checkImport(plugin);
    final previous = _records[plugin.manifest.id]?.implementation;
    if (previous is JavaScriptPlugin) {
      _versions[previous.packageDigest ??
              '${previous.manifest.id}@${previous.manifest.version}'] =
          previous;
    }
    await packages.retain(Uint8List.fromList(bytes));
    packageCount++;
    packageBytes += bytes.length;
    await _persist(
      plugin.manifest.id,
      installed: true,
      enabled: false,
      grants: {},
      version: plugin.manifest.version,
      source: source,
      packageDigest: plugin.packageDigest,
    );
    final old = _records[plugin.manifest.id];
    if (old != null) await _deactivate(old);
    _records[plugin.manifest.id] = PluginRecord(plugin)
      ..status = PluginStatus.disabled
      ..source = source;
  });

  Future<void> load() async {
    try {
      final encoded = await store.read();
      if (encoded != null) {
        final data = jsonDecode(encoded);
        if (data is! Map || data['version'] != 1 || data['plugins'] is! Map) {
          throw const FormatException('无法读取插件配置，已保留原配置并停止自动启用');
        }
        _saved = Map<String, dynamic>.from(data['plugins']);
      }
      final ordered = <MapEntry<String, PluginRecord>>[];
      final visited = <String>{};
      void visit(String id) {
        if (!visited.add(id)) return;
        final item = _records[id];
        if (item == null) return;
        if (item.implementation is JavaScriptPlugin) {
          for (final dependency
              in (item.implementation as JavaScriptPlugin).dependencies.keys) {
            visit(dependency);
          }
        }
        ordered.add(MapEntry(id, item));
      }

      for (final id in _records.keys) {
        visit(id);
      }
      for (final entry in ordered) {
        final config = _saved[entry.key];
        if (config is! Map || config['installed'] != true) continue;
        var record = entry.value;
        if (record.implementation is JavaScriptPlugin &&
            (config['package_version'] != record.manifest.version ||
                (config['package_sha256'] != null &&
                    config['package_sha256'] !=
                        (record.implementation as JavaScriptPlugin)
                            .packageDigest))) {
          final committed = config['package_sha256'] != null
              ? _versions[config['package_sha256']]
              : _versions['${entry.key}@${config['package_version']}'];
          if (committed == null ||
              committed.manifest.id != entry.key ||
              committed.manifest.version != config['package_version']) {
            record.error = '已确认版本的安装包不可用，未启用未提交的新版本';
            record.status = PluginStatus.failed;
            continue;
          }
          record = PluginRecord(committed);
          _records[entry.key] = record;
        }
        record.source =
            config['source'] as String? ??
            (record.implementation is JavaScriptPlugin
                ? '本地 ZIP（旧记录）'
                : '随附插件');
        record.status = PluginStatus.disabled;
        record.grants = PluginPermission.values
            .where((p) => (config['grants'] as List? ?? []).contains(p.name))
            .toSet();
        // A retained newer ZIP may come from a failed transaction. Never
        // inherit a previous version's enablement or permission approval.
        if (config['enabled'] == true &&
            config['package_version'] == record.manifest.version) {
          await _activate(record);
          if (record.status == PluginStatus.failed) {
            await _persist(
              entry.key,
              installed: true,
              enabled: false,
              grants: record.grants,
            );
          }
        }
      }
    } catch (error) {
      loadError = error.toString();
    }
    ready = true;
    _notify();
  }

  Future<void> install(String id) => _run(() async {
    final item = record(id);
    if (item.manifest.apiVersion != pluginApiVersion) {
      throw StateError('插件 API 版本不兼容');
    }
    if (item.status != PluginStatus.available) throw StateError('插件已安装');
    await _persist(id, installed: true, enabled: false, grants: {});
    item.status = PluginStatus.disabled;
  });

  Future<void> enable(String id, Set<PluginPermission> grants) =>
      _run(() async {
        final item = record(id);
        if (item.status == PluginStatus.available) throw StateError('请先安装插件');
        if (item.status == PluginStatus.enabled) return;
        if (!grants.containsAll(item.manifest.permissions)) {
          throw StateError('尚未授权插件所需权限');
        }
        final accepted = grants.intersection(item.manifest.permissions);
        await _persist(id, installed: true, enabled: true, grants: accepted);
        item.grants = accepted;
        await _activate(item);
        if (item.status == PluginStatus.failed) {
          await _persist(id, installed: true, enabled: false, grants: accepted);
          throw StateError(item.error!);
        }
      });

  Future<void> disable(String id) => _run(() async {
    final item = record(id);
    if (item.status == PluginStatus.available) return;
    await _persist(id, installed: true, enabled: false, grants: item.grants);
    await _deactivate(item);
    item.status = PluginStatus.disabled;
  });

  Future<PluginData> data() async {
    final host = hostServices;
    final root = host?.storagePath ?? await host?.storageRoot?.call();
    if (root == null) throw StateError('未配置插件数据目录');
    return PluginData(root);
  }

  List<JavaScriptPlugin> previousVersions(String id) =>
      _versions.values
          .toSet()
          .where(
            (p) =>
                p.manifest.id == id &&
                comparePluginVersions(
                      p.manifest.version,
                      record(id).manifest.version,
                    ) <
                    0,
          )
          .toList()
        ..sort(
          (a, b) =>
              comparePluginVersions(b.manifest.version, a.manifest.version),
        );
  Future<void> rollback(String id) => _run(() async {
    final versions = previousVersions(id);
    if (versions.isEmpty) throw StateError('没有保留的旧版本');
    final previous = versions.first;
    final current = record(id);
    await _persist(
      id,
      installed: true,
      enabled: false,
      grants: {},
      version: previous.manifest.version,
      packageDigest: previous.packageDigest,
    );
    await _deactivate(current);
    _records[id] = PluginRecord(previous)
      ..status = PluginStatus.disabled
      ..source = current.source;
  });
  Future<void> suspend() => _run(() async {
    for (final item in records.where((r) => r.status == PluginStatus.enabled)) {
      if (item.implementation is JavaScriptPlugin) {
        try {
          await (item.implementation as JavaScriptPlugin)
              .lifecycle('suspend')
              .timeout(const Duration(milliseconds: 500));
        } catch (_) {
          /* Revocation below remains mandatory. */
        }
      }
      await _deactivate(item);
      item.status = PluginStatus.suspended;
    }
  });
  Future<void> resume() => _run(() async {
    for (final item in records.where(
      (r) => r.status == PluginStatus.suspended,
    )) {
      await _activate(item);
    }
  });

  Future<void> uninstall(String id) => _run(() async {
    final item = record(id);
    await _persist(id, installed: false, enabled: false, grants: {});
    await _deactivate(item);
    item.grants = {};
    item.status = PluginStatus.available;
    // Derived user data is deliberately not deleted here.
  });

  Future<void> _activate(PluginRecord item) async {
    final registrar = PluginRegistrar(item.manifest);
    try {
      if (item.implementation is JavaScriptPlugin) {
        final plugin = item.implementation as JavaScriptPlugin;
        plugin.hostServices = hostServices;
        plugin.grants = Set.unmodifiable(item.grants);
        plugin.onFailure = (error) => unawaited(
          _run(() async {
            if (item.status != PluginStatus.enabled) return;
            await _deactivate(item);
            item.status = PluginStatus.failed;
            item.error = error.toString();
            await _persist(
              item.manifest.id,
              installed: true,
              enabled: false,
              grants: item.grants,
            );
          }).catchError((Object _, StackTrace _) {}),
        );
        plugin.onChanged = () {
          if (item.status != PluginStatus.enabled) return;
          final update = PluginRegistrar(item.manifest);
          try {
            plugin.contribute(update);
            update.seal();
            item.actions = update.actions;
            item.formats = update.formats;
            dashboards?.publish(
              item.manifest.id,
              update.widgets,
              update.providers,
            );
            features.publishPlugin(item.manifest.id, update.pages);
            _notify();
          } catch (error) {
            plugin.onFailure?.call(error);
          }
        };
        if (!plugin.platforms.contains(Platform.operatingSystem)) {
          throw StateError('插件不支持当前平台');
        }
        for (final dependency in plugin.dependencies.entries) {
          final provider = _records[dependency.key];
          if (provider == null ||
              provider.status != PluginStatus.enabled ||
              comparePluginVersions(
                    provider.manifest.version,
                    dependency.value,
                  ) <
                  0 ||
              provider.manifest.version.split('.').first !=
                  dependency.value.split('.').first) {
            throw StateError('依赖 ${dependency.key} 缺失、未启用或版本不兼容');
          }
        }
      }

      if (item.manifest.apiVersion != pluginApiVersion ||
          !item.grants.containsAll(item.manifest.permissions)) {
        throw StateError('API 不兼容或权限不足，插件未启用');
      }
      await item.implementation.activate(registrar).timeout(timeout);
      registrar.seal();
      if (_disposed) {
        await _deactivate(item);
        return;
      }
      item.actions = registrar.actions;
      item.formats = registrar.formats;
      dashboards?.publish(
        item.manifest.id,
        registrar.widgets,
        registrar.providers,
      );
      item.status = PluginStatus.enabled;
      features.publishPlugin(item.manifest.id, registrar.pages);
      item.error = null;
    } catch (error) {
      registrar.seal();
      await _deactivate(item);
      item.status = PluginStatus.failed;
      item.error = error.toString();
    }
  }

  Future<void> _deactivate(PluginRecord item) async {
    if (item.implementation is JavaScriptPlugin) {
      final plugin = item.implementation as JavaScriptPlugin;
      plugin.onChanged = null;
      plugin.onFailure = null;
    }
    // Revoke before awaiting cleanup, even if the plugin never completes it.
    item.actions = [];
    item.formats = [];
    dashboards?.revoke(item.manifest.id);
    if (!_disposed) features.revokePlugin(item.manifest.id);
    try {
      await item.implementation.deactivate().timeout(timeout);
    } catch (error) {
      item.error = '插件停止时报告错误：$error';
    }
  }

  List<ReaderFormatRegistration> readerFormats(Set<String> surfaces) => [
    for (final item in records)
      if (item.status == PluginStatus.enabled)
        for (final format in item.formats)
          if (surfaces.contains(format.surface)) format,
  ];

  List<PluginAction> actions(ExtensionPoint point, ExtensionContext context) =>
      [
        for (final item in _records.values)
          if (item.status == PluginStatus.enabled)
            for (final action in item.actions)
              if (action.point == point &&
                  action.matches(context) &&
                  item.grants.containsAll(action.permissions))
                action,
      ];

  Future<String?> invoke(String id, ExtensionContext context) async {
    for (final item in _records.values) {
      final matches = item.actions.where((action) => action.id == id);
      if (item.status != PluginStatus.enabled || matches.isEmpty) continue;
      final action = matches.single;
      if (!action.matches(context) ||
          !item.grants.containsAll(action.permissions)) {
        throw StateError('当前内容不满足操作能力或权限');
      }
      try {
        // Do not disclose selection text to actions without that permission.
        final scoped = ExtensionContext(
          bookId: context.bookId,
          projectId: context.projectId,
          format: context.format,
          capabilities: Set.unmodifiable(context.capabilities),
          selectedText:
              action.permissions.contains(PluginPermission.selectedText)
              ? context.selectedText
              : null,
        );
        final result = await action.invoke(scoped).timeout(timeout);
        if (item.status != PluginStatus.enabled ||
            !item.actions.contains(action)) {
          throw StateError('操作期间插件已停用');
        }
        return result;
      } catch (error) {
        // Serialize failure revocation with user lifecycle changes.
        await _run(() async {
          if (item.status != PluginStatus.enabled) return;
          await _deactivate(item);
          item.status = PluginStatus.failed;
          item.error = error.toString();
          await _persist(
            item.manifest.id,
            installed: true,
            enabled: false,
            grants: item.grants,
          );
        });
        rethrow;
      }
    }
    throw StateError('此插件操作已撤销');
  }

  Future<void> _persist(
    String id, {
    required bool installed,
    required bool enabled,
    required Set<PluginPermission> grants,
    String? version,
    String? source,
    String? packageDigest,
  }) async {
    final next = {
      ..._saved,
      id: {
        if (_saved[id] is Map) ...Map<String, dynamic>.from(_saved[id]),
        'installed': installed,
        'enabled': enabled,
        'package_version': version ?? record(id).manifest.version,
        'grants': grants.map((p) => p.name).toList(),
        'source': ?source,
        'package_sha256': ?packageDigest,
      },
    };
    await store.write(jsonEncode({'version': 1, 'plugins': next}));
    _saved = next;
  }

  Future<void> _run(Future<void> Function() action) {
    final operation = _pending.then((_) async {
      if (_disposed) throw StateError('插件管理器已关闭');
      if (!ready || loadError != null) {
        throw StateError(loadError ?? '插件配置仍在读取');
      }
      busy = true;
      _notify();
      try {
        await action();
      } finally {
        busy = false;
        _notify();
      }
    });
    _pending = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final item in _records.values) {
      item.actions = [];
      item.formats = [];
      dashboards?.revoke(item.manifest.id);
      features.revokePlugin(item.manifest.id);
      if (item.status == PluginStatus.enabled) {
        if (item.implementation is JavaScriptPlugin) {
          final plugin = item.implementation as JavaScriptPlugin;
          plugin.onFailure = null;
          plugin.onChanged = null;
          unawaited(
            plugin
                .deactivate(force: true)
                .catchError((Object _, StackTrace _) {}),
          );
          continue;
        }
        unawaited(
          Future<void>.sync(
            item.implementation.deactivate,
          ).timeout(timeout).catchError((Object _, StackTrace _) {}),
        );
      }
    }
    super.dispose();
  }
}
