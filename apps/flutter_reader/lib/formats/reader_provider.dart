// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';

import '../reader/reader_contract.dart';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../plugins/plugin_api.dart';
import '../plugins/plugin_manager.dart';

List<ReaderFormatRegistration> readerProviders(
  Book book,
  PluginManager? plugins,
) => [
  for (final surface in [
    'document',
    'markdown',
    'text',
    'fixed_page',
    'image_page',
  ])
    if (book.capabilities.surfaces.contains(surface))
      ReaderFormatRegistration(
        id: 'core.$surface',
        name: switch (surface) {
          'document' => '文档阅读',
          'markdown' => 'Markdown 阅读',
          'text' => '纯文字阅读',
          'fixed_page' => 'PDF 阅读',
          _ => '图片阅读',
        },
        surface: surface,
      ),
  ...?plugins?.readerFormats(book.capabilities.surfaces),
];

ReaderFormatRegistration selectedProvider(
  Book book,
  PluginManager? plugins,
  String? id,
) {
  final available = readerProviders(book, plugins);
  return available.firstWhere((p) => p.id == id, orElse: () => available.first);
}

class ReaderProviderPanel extends StatefulWidget {
  final Book book;
  final PluginManager? plugins;
  final String? selected;
  final Future<void> Function(String) onSelect;
  final FutureOr<void> Function()? openFoliate;
  final bool foliateSelected;
  const ReaderProviderPanel({
    super.key,
    required this.book,
    this.plugins,
    this.selected,
    required this.onSelect,
    this.openFoliate,
    this.foliateSelected = false,
  });
  @override
  State<ReaderProviderPanel> createState() => _ReaderProviderPanelState();
}

class _ReaderProviderPanelState extends State<ReaderProviderPanel> {
  bool selecting = false;
  @override
  Widget build(BuildContext context) {
    final current = selectedProvider(
      widget.book,
      widget.plugins,
      widget.selected,
    );
    final onSelect = widget.onSelect;
    return ListView(
      children: [
        if (widget.openFoliate != null || widget.foliateSelected)
          ListTile(
            title: const Text('Foliate 漫画阅读'),
            subtitle: const Text('使用当前页序；图片旋转在图片阅读器中调整'),
            trailing: widget.foliateSelected ? const Icon(Icons.check) : null,
            onTap: widget.openFoliate == null
                ? null
                : () => _select(context, widget.openFoliate!),
          ),
        for (final provider in readerProviders(widget.book, widget.plugins))
          ListTile(
            title: Text(provider.name),
            trailing: !widget.foliateSelected && provider.id == current.id
                ? const Icon(Icons.check)
                : null,
            onTap: () => _select(context, () => onSelect(provider.id)),
          ),
      ],
    );
  }

  // Finish removing the sheet before replacing a reader or rebuilding its
  // surface. A second tap during dismissal must not pop the reader itself.
  Future<void> _select(
    BuildContext context,
    FutureOr<void> Function() select,
  ) async {
    final route = ModalRoute.of(context);
    if (selecting || route == null || !route.isCurrent) return;
    selecting = true;
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.pop(context);
    await route.completed;
    await WidgetsBinding.instance.endOfFrame;
    try {
      await select();
    } catch (e) {
      if (messenger?.mounted == true) {
        messenger!.showSnackBar(SnackBar(content: Text('阅读器切换失败：$e')));
      }
    }
  }
}

ReaderAdapter adaptReaderProvider(
  ReaderFormatRegistration provider,
  ReaderAdapter base,
  PluginManager? plugins,
) {
  try {
    return provider.adapt(base);
  } catch (e) {
    if (plugins != null) {
      for (final item in plugins.records) {
        if (item.status == PluginStatus.enabled &&
            item.formats.any((f) => f.id == provider.id)) {
          scheduleMicrotask(() async {
            try {
              await plugins.disable(item.manifest.id);
              item.error = '阅读处理器已停用：$e';
            } catch (_) {
              item.error = '阅读处理器失败：$e';
            }
          });
          break;
        }
      }
    }
    return base;
  }
}
