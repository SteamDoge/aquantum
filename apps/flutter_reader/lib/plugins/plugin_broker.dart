// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import 'dart:convert';
import 'plugin_instance.dart';
import 'plugin_manifest.dart';

/// Host-owned registrations; plugin IDs never come from request arguments.
class PluginBroker {
  final instances = <String, JavaScriptPlugin>{};
  final _services =
      <String, ({String owner, String version, String handler})>{};
  final _events =
      <
        String,
        List<({String owner, String handler, int priority, bool hook})>
      >{};
  final _edges = <String, String>{};
  final _emitting = <String>{};
  final _tasks = <String, String>{};
  int _sequence = 0;
  void attach(JavaScriptPlugin plugin) {
    if (instances.containsKey(plugin.manifest.id)) throw StateError('插件实例重复');
    instances[plugin.manifest.id] = plugin;
  }

  void detach(String owner) {
    instances.remove(owner);
    _services.removeWhere((_, s) => s.owner == owner);
    for (final listeners in _events.values) {
      listeners.removeWhere((l) => l.owner == owner);
    }
    _tasks.removeWhere((_, value) => value == owner);
    _edges.remove(owner);
  }

  void _permission(JavaScriptPlugin plugin, PluginPermission permission) {
    if (!plugin.active || !plugin.grants.contains(permission)) {
      throw StateError('未获 ${permission.name} 权限');
    }
  }

  Future<dynamic> route(
    JavaScriptPlugin plugin,
    String method,
    Map<String, dynamic> args,
  ) async {
    final owner = plugin.manifest.id;
    if (instances[owner] != plugin || !plugin.active) {
      throw StateError('插件身份已撤销');
    }
    final name = args['name'];
    if (name != null && (name is! String || name.length > 128)) {
      throw const FormatException('服务或事件名称过长');
    }
    if (method == 'events.emit' &&
            jsonEncode(args['data']).length > 128 * 1024 ||
        method == 'services.call' &&
            jsonEncode(args['args']).length > 512 * 1024) {
      throw const FormatException('插件消息数据超限');
    }
    switch (method) {
      case 'services.provide':
        _permission(plugin, PluginPermission.services);
        if (name is! String ||
            !name.startsWith('$owner.') ||
            !RegExp(r'^[a-z][a-z0-9_.-]{2,95}$').hasMatch(name) ||
            _services.containsKey(name) ||
            _services.values.where((s) => s.owner == owner).length >= 32 ||
            args['version'] is! String ||
            !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(args['version']) ||
            args['handler'] is! String) {
          throw const FormatException('服务名称、版本或回调无效');
        }
        _services[name] = (
          owner: owner,
          version: args['version'],
          handler: args['handler'],
        );
        return null;
      case 'services.discover':
        _permission(plugin, PluginPermission.services);
        return [
          for (final entry in _services.entries)
            {
              'name': entry.key,
              'version': entry.value.version,
              'pluginId': entry.value.owner,
            },
        ];
      case 'services.call':
        _permission(plugin, PluginPermission.services);
        final service = _services[name];
        if (service == null || instances[service.owner]?.active != true) {
          throw StateError('服务不存在或已停用');
        }
        if (!plugin.dependencies.containsKey(service.owner)) {
          throw StateError('服务调用须声明对提供者的依赖');
        }
        if (args['version'] != null &&
            args['version'].toString().split('.').first !=
                service.version.split('.').first) {
          throw StateError('服务接口主版本不兼容');
        }
        var cursor = service.owner;
        final visited = <String>{owner};
        while (true) {
          if (!visited.add(cursor)) throw StateError('拒绝循环服务调用');
          final next = _edges[cursor];
          if (next == null) break;
          cursor = next;
        }
        if (_edges.containsKey(owner)) throw StateError('同一插件服务调用正在执行');
        _edges[owner] = service.owner;
        try {
          final result = await instances[service.owner]!
              .invoke(service.handler, args['args'])
              .timeout(const Duration(seconds: 10));
          if (!plugin.active) throw StateError('调用方已停用');
          return result;
        } finally {
          _edges.remove(owner);
        }
      case 'events.on':
      case 'events.hook':
        if (name is! String ||
            args['handler'] is! String ||
            _events.values
                    .expand((v) => v)
                    .where((l) => l.owner == owner)
                    .length >=
                64) {
          throw const FormatException('事件订阅无效');
        }
        _eventPermission(plugin, name);
        if (method == 'events.hook' &&
            !{'library.beforeImport', '$owner.hook'}.contains(name)) {
          throw StateError('宿主未开放此 Hook');
        }
        final priority = args['priority'] ?? 0;
        if (priority is! int || priority.abs() > 100) {
          throw const FormatException('Hook优先级须在-100至100');
        }
        (_events[name] ??= []).add((
          owner: owner,
          handler: args['handler'],
          priority: priority,
          hook: method == 'events.hook',
        ));
        return null;
      case 'events.emit':
        if (name is! String || !name.startsWith('$owner.')) {
          throw StateError('只能发布自己命名空间的事件');
        }
        return emit(name, args['data']);
      case 'tasks.run':
        if (_tasks.values.where((v) => v == owner).length >= 4 ||
            args['handler'] is! String) {
          throw StateError('任务数量或回调无效');
        }
        final id = '$owner.task.${++_sequence}';
        _tasks[id] = owner;
        unawaited(
          plugin
              .invoke(args['handler'], {'taskId': id})
              .then<void>(
                (_) {
                  _tasks.remove(id);
                },
                onError: (Object e, StackTrace _) {
                  _tasks.remove(id);
                  plugin.onFailure?.call(e);
                },
              ),
        );
        return id;
      case 'tasks.cancel':
        final id = args['id'];
        if (_tasks[id] != owner) throw StateError('任务不存在');
        // Cancelling arbitrary JS requires terminating its owned runtime.
        scheduleMicrotask(
          () => plugin.onFailure?.call(StateError('任务已取消，插件实例已撤销')),
        );
        return null;
      default:
        throw const FormatException('未知插件消息服务');
    }
  }

  void _eventPermission(JavaScriptPlugin plugin, String name) {
    if (name.startsWith('reader.selection')) {
      _permission(plugin, PluginPermission.selectedText);
    } else if (name.startsWith('reader.')) {
      _permission(plugin, PluginPermission.documentText);
    } else if (name.startsWith('library.') || name.startsWith('file.')) {
      _permission(plugin, PluginPermission.libraryRead);
    } else if (!{
          'theme.changed',
          'settings.changed',
          'plugin.enabled',
          'plugin.disabled',
          'app.suspend',
          'app.resume',
        }.contains(name) &&
        !name.startsWith('${plugin.manifest.id}.')) {
      throw StateError('此事件未开放');
    }
  }

  Future<dynamic> emit(String name, dynamic data) async {
    if (!_emitting.add(name)) throw StateError('递归事件已阻止');
    try {
      final listeners = [...?_events[name]]
        ..sort((a, b) {
          final priority = b.priority.compareTo(a.priority);
          return priority != 0 ? priority : a.owner.compareTo(b.owner);
        });
      for (final listener in listeners) {
        final plugin = instances[listener.owner];
        if (plugin?.active != true) continue;
        try {
          _eventPermission(plugin!, name);
          final result = await plugin
              .invoke(listener.handler, data)
              .timeout(const Duration(seconds: 2));
          if (listener.hook && result is Map && result['cancel'] == true) {
            return {'cancel': true, 'reason': result['reason']?.toString()};
          }
        } catch (error) {
          plugin?.onFailure?.call(error);
        }
      }
      return null;
    } finally {
      _emitting.remove(name);
    }
  }
}
