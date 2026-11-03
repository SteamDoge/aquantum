// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';

enum ReaderToolbarAction {
  back,
  settings,
  navigation,
  view,
  bookmarks,
  search,
  more,
}

/// One immutable order and glyph set for every renderer and module.
const readerToolbarOrder = ReaderToolbarAction.values;

class ToolbarButton {
  final String id, label;
  final Widget icon;
  final VoidCallback? onPressed;
  const ToolbarButton(this.id, this.label, this.icon, this.onPressed);
}

class ReaderToolbar extends StatelessWidget {
  final bool vertical;
  final ValueChanged<ReaderToolbarAction> onAction;
  final List<ToolbarButton>? customButtons;
  const ReaderToolbar({
    super.key,
    this.vertical = false,
    required this.onAction,
    this.customButtons,
  });
  static String label(ReaderToolbarAction action) => switch (action) {
    ReaderToolbarAction.back => '返回',
    ReaderToolbarAction.settings => '阅读设置',
    ReaderToolbarAction.navigation => '目录与内容导航',
    ReaderToolbarAction.view => '阅读视图与页面导航',
    ReaderToolbarAction.bookmarks => '书签',
    ReaderToolbarAction.search => '搜索',
    ReaderToolbarAction.more => '更多',
  };
  static Widget glyph(ReaderToolbarAction action) => switch (action) {
    ReaderToolbarAction.back => const Icon(Icons.arrow_back),
    ReaderToolbarAction.settings => const ExcludeSemantics(
      child: Text(
        'Aa',
        textScaler: TextScaler.noScaling,
        style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500),
      ),
    ),
    ReaderToolbarAction.navigation => const Icon(Icons.format_list_bulleted),
    ReaderToolbarAction.view => const Icon(Icons.view_carousel_outlined),
    ReaderToolbarAction.bookmarks => const Icon(Icons.bookmark_border),
    ReaderToolbarAction.search => const Icon(Icons.search),
    ReaderToolbarAction.more => const Icon(Icons.more_vert),
  };
  @override
  Widget build(BuildContext context) {
    if (customButtons != null) return custom(context);
    final buttons = [
      for (final action in readerToolbarOrder)
        SizedBox(
          width: 48,
          height: 48,
          child: action == ReaderToolbarAction.back
              ? BackButton(
                  key: const ValueKey('reader-action-back'),
                  style: IconButton.styleFrom(iconSize: 23),
                  onPressed: () => onAction(action),
                )
              : IconButton(
                  key: ValueKey('reader-action-${action.name}'),
                  tooltip: label(action),
                  onPressed: () => onAction(action),
                  iconSize: 23,
                  icon: glyph(action),
                ),
        ),
    ];
    if (vertical) {
      return SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: buttons),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 600) {
          return Row(
            children: [buttons.first, const Spacer(), ...buttons.skip(1)],
          );
        }
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(mainAxisSize: MainAxisSize.min, children: buttons),
        );
      },
    );
  }

  Widget custom(BuildContext context) {
    final entries = customButtons!;
    Widget button(ToolbarButton item) => SizedBox(
      width: 48,
      height: 48,
      child: IconButton(
        key: ValueKey('reader-action-${item.id}'),
        tooltip: item.label,
        onPressed: item.onPressed,
        icon: item.icon,
      ),
    );
    if (vertical) {
      return SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: entries.map(button).toList(),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final slots = (constraints.maxWidth / 48).floor();
        if (entries.length <= slots) {
          return Row(children: entries.map(button).toList());
        }
        if (slots < 3) {
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(children: entries.map(button).toList()),
          );
        }
        final visible = <ToolbarButton>[];
        for (final entry in entries) {
          if (entry.id == 'core.back' || entry.id == 'core.more') {
            visible.add(entry);
          }
        }
        for (final entry in entries) {
          if (visible.length >= slots - 1) break;
          if (!visible.contains(entry)) visible.add(entry);
        }
        visible.sort(
          (a, b) => entries.indexOf(a).compareTo(entries.indexOf(b)),
        );
        final overflow = entries
            .where((entry) => !visible.contains(entry))
            .toList();
        return Row(
          children: [
            ...visible.map(button),
            SizedBox(
              width: 48,
              height: 48,
              child: PopupMenuButton<int>(
                tooltip: '溢出操作',
                icon: const Icon(Icons.unfold_more),
                onSelected: (index) => overflow[index].onPressed?.call(),
                itemBuilder: (_) => [
                  for (var i = 0; i < overflow.length; i++)
                    PopupMenuItem(
                      value: i,
                      enabled: overflow[i].onPressed != null,
                      child: Text(overflow[i].label),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
