// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import 'plugin_manifest.dart';
export 'plugin_manifest.dart';
import '../features/feature_registry.dart';
import '../dashboard/widget_registry.dart';
import '../reader/reader_contract.dart';

/// Both installed declarations and trusted compiled plugins select host surfaces.
/// Installed JavaScript registers stable host surfaces and cannot inject Dart adapters.
class ReaderFormatRegistration {
  final String id, name, surface;
  final ReaderAdapter Function(ReaderAdapter)? create;
  const ReaderFormatRegistration({
    required this.id,
    required this.name,
    required this.surface,
    this.create,
  });
  ReaderAdapter adapt(ReaderAdapter base) {
    final result = create?.call(base) ?? base;
    if (result.documentId != base.documentId ||
        result.unit != base.unit ||
        result.count != base.count ||
        (base is PagedReaderAdapter) != (result is PagedReaderAdapter) ||
        (base is OutlineReaderAdapter) != (result is OutlineReaderAdapter)) {
      throw StateError('格式处理器必须保留文档身份、定位单位和可选接口');
    }
    for (final i in {
      if (base.count > 0) 0,
      if (base.count > 0) base.count - 1,
    }) {
      if (result.location(i).id != base.location(i).id) {
        throw StateError('格式处理器不能改写来源位置');
      }
    }
    return result;
  }
}

/// Internal host rendering contract. The third-party protocol is javascript-v1.
enum ExtensionPoint {
  search,
  fileHandler,
  textSelection,
  fileMenu,
  projectMenu,
  readerToolbar,
  readerSettings,
  readerNavigation,
  readerSearch,
  readerBookmarks,
  readerMore,
  contextAction,
  background,
}

enum ReaderCapability { selectableText, reflow, image, fixedLayout, ocrText }

class ExtensionContext {
  final String? bookId, projectId, format, selectedText;
  final Set<ReaderCapability> capabilities;
  const ExtensionContext({
    this.bookId,
    this.projectId,
    this.format,
    this.selectedText,
    this.capabilities = const {},
  });
}

/// Separate from workspace pages: an action never acquires a navigation slot.
class PluginAction {
  final String id, name;
  final IconData icon;
  final ExtensionPoint point;
  final Set<String> formats;
  final Set<ReaderCapability> requires;
  final Set<PluginPermission> permissions;
  final Future<String?> Function(ExtensionContext context) invoke;
  const PluginAction({
    required this.id,
    required this.name,
    required this.icon,
    required this.point,
    required this.invoke,
    this.formats = const {},
    this.requires = const {},
    this.permissions = const {},
  });
  bool matches(ExtensionContext context) =>
      (formats.isEmpty || formats.contains(context.format)) &&
      context.capabilities.containsAll(requires) &&
      (point != ExtensionPoint.textSelection ||
          (context.selectedText?.trim().isNotEmpty ?? false));
}

abstract interface class ReaderPlugin {
  PluginManifest get manifest;
  Future<void> activate(PluginRegistrar registrar);
  Future<void> deactivate();
}

/// A short-lived transaction, sealed after activation (including timeout).
/// Plugins cannot access the registry, navigation controller, or raw files.
class PluginRegistrar {
  final PluginManifest manifest;
  final List<AppFeature> _pages = [];
  final List<PluginAction> _actions = [];
  final List<DashboardDefinition> _widgets = [];
  final List<DashboardProvider> _providers = [];
  final List<ReaderFormatRegistration> _formats = [];
  bool _sealed = false;
  PluginRegistrar(this.manifest);
  List<AppFeature> get pages => List.unmodifiable(_pages);
  List<PluginAction> get actions => List.unmodifiable(_actions);
  List<DashboardDefinition> get widgets => List.unmodifiable(_widgets);
  List<DashboardProvider> get providers => List.unmodifiable(_providers);
  List<ReaderFormatRegistration> get formats => List.unmodifiable(_formats);
  void format(ReaderFormatRegistration value) {
    _check();
    if (!value.id.startsWith('${manifest.id}.format.') ||
        value.name.trim().isEmpty ||
        !{
          'document',
          'text',
          'markdown',
          'fixed_page',
          'image_page',
        }.contains(value.surface) ||
        _formats.any((item) => item.id == value.id) ||
        (value.create != null &&
            !manifest.permissions.contains(PluginPermission.documentText))) {
      throw ArgumentError('格式处理器编号、能力或权限无效');
    }
    _formats.add(value);
  }

  void widget(DashboardDefinition definition) {
    _check();
    if (definition.source != manifest.id ||
        !definition.id.startsWith('${manifest.id}.widget.')) {
      throw ArgumentError('组件编号须属于插件');
    }
    _widgets.add(definition);
  }

  void provider(DashboardProvider provider) {
    _check();
    if (provider.source != manifest.id ||
        !provider.id.startsWith('${manifest.id}.metric.')) {
      throw ArgumentError('数据编号须属于插件');
    }
    _providers.add(provider);
  }

  void page({
    required String id,
    required String name,
    required IconData icon,
    required WidgetBuilder builder,
    bool allowNavigation = true,
  }) {
    _check();
    if (!id.startsWith('${manifest.id}.page.')) {
      throw ArgumentError('页面编号须属于插件');
    }
    _pages.add(
      AppFeature(
        id: id,
        name: name,
        icon: icon,
        builder: builder,
        source: manifest.id,
        allowNavigation: allowNavigation,
      ),
    );
  }

  void action(PluginAction action) {
    _check();
    if (!action.id.startsWith('${manifest.id}.action.') ||
        action.name.trim().isEmpty ||
        !manifest.permissions.containsAll(action.permissions) ||
        (action.point == ExtensionPoint.textSelection &&
            !action.permissions.contains(PluginPermission.selectedText)) ||
        _actions.any((item) => item.id == action.id)) {
      throw ArgumentError('扩展编号、权限或操作声明无效');
    }
    _actions.add(action);
  }

  void _check() {
    if (_sealed) throw StateError('注册事务已结束');
  }

  void seal() => _sealed = true;
}
