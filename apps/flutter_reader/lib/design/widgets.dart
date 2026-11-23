// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'theme.dart';

/// A page's one strong element: a large title with quiet accent actions.
/// [leading] sits above the title (for example a back link to the parent).
class AqPageHeading extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final Widget? leading;
  const AqPageHeading(
    this.title, {
    super.key,
    this.subtitle,
    this.actions = const [],
    this.leading,
  });
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ?leading,
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(title, style: theme.textTheme.headlineLarge),
              ),
            ),
            IconTheme.merge(
              data: IconThemeData(color: theme.colorScheme.primary),
              child: Row(mainAxisSize: MainAxisSize.min, children: actions),
            ),
          ],
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(subtitle!, style: theme.textTheme.bodySmall),
        ],
      ],
    );
  }
}

/// An inset grouped list: optional header and footer around one rounded
/// group whose rows are separated by hairlines.
class AqSection extends StatelessWidget {
  final String? header, footer;
  final List<Widget> children;

  /// Separator start inset; rows with a leading icon align it to the text.
  final double dividerIndent;
  const AqSection({
    super.key,
    this.header,
    this.footer,
    required this.children,
    this.dividerIndent = 52,
  });
  @override
  Widget build(BuildContext context) {
    final colors = AqColors.of(context);
    final small = Theme.of(context).textTheme.bodySmall;
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (header != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 7),
              child: Semantics(
                header: true,
                child: Text(
                  header!,
                  style: small?.copyWith(fontWeight: FontWeight.w500),
                ),
              ),
            ),
          if (children.isNotEmpty)
            Material(
              color: colors.panel,
              clipBehavior: Clip.antiAlias,
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(14),
                side: MediaQuery.highContrastOf(context)
                    ? BorderSide(color: Theme.of(context).colorScheme.outline)
                    : BorderSide.none,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final (i, child) in children.indexed) ...[
                    if (i > 0) Divider(indent: dividerIndent, height: .5),
                    child,
                  ],
                ],
              ),
            ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 7, 16, 0),
              child: Text(footer!, style: small),
            ),
        ],
      ),
    );
  }
}

/// One row of an [AqSection]: icon, title, optional detail, value and chevron.
class AqRow extends StatelessWidget {
  final IconData? icon;
  final Color? iconColor;
  final String title;
  final String? subtitle, value;
  final Widget? trailing;
  final VoidCallback? onTap, onLongPress;
  final bool? chevron;
  final bool destructive;
  const AqRow({
    super.key,
    required this.title,
    this.icon,
    this.iconColor,
    this.subtitle,
    this.value,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.chevron,
    this.destructive = false,
  });
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AqColors.of(context);
    final accent = destructive
        ? theme.colorScheme.error
        : theme.colorScheme.primary;
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 22, color: iconColor ?? accent),
                const SizedBox(width: 14),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: destructive ? accent : null,
                      ),
                    ),
                    if (subtitle != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          subtitle!,
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                  ],
                ),
              ),
              if (value != null)
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: Text(
                    value!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.muted,
                    ),
                  ),
                ),
              ?trailing,
              if (chevron ?? (onTap != null && trailing == null))
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: colors.muted.withValues(alpha: .7),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The filled search field shared by the library, home and search pages.
/// Without a [controller] it renders as a button that opens search elsewhere.
class AqSearchField extends StatelessWidget {
  final String hint;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged, onSubmitted;
  final VoidCallback? onTap;
  final bool autofocus;
  final int? maxLength;
  const AqSearchField({
    super.key,
    this.hint = '搜索',
    this.controller,
    this.onChanged,
    this.onSubmitted,
    this.onTap,
    this.autofocus = false,
    this.maxLength,
  });
  @override
  Widget build(BuildContext context) {
    final colors = AqColors.of(context);
    if (controller == null) {
      return Semantics(
        button: true,
        label: hint,
        child: Material(
          color: colors.backgroundEnd,
          shape: RoundedSuperellipseBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: ExcludeSemantics(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.search, size: 20, color: colors.muted),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          hint,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colors.muted, fontSize: 15),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return TextField(
      controller: controller,
      autofocus: autofocus,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      textInputAction: TextInputAction.search,
      inputFormatters: [
        if (maxLength != null) LengthLimitingTextInputFormatter(maxLength),
      ],
      style: const TextStyle(fontSize: 15),
      decoration: InputDecoration(
        hintText: hint,
        isDense: true,
        prefixIcon: const Icon(Icons.search, size: 20),
        prefixIconConstraints: const BoxConstraints(minWidth: 40),
        suffixIcon: ListenableBuilder(
          listenable: controller!,
          builder: (context, _) => controller!.text.isEmpty
              ? const SizedBox.shrink()
              : IconButton(
                  tooltip: '清除',
                  iconSize: 18,
                  icon: Icon(Icons.cancel, color: colors.muted),
                  onPressed: () {
                    controller!.clear();
                    onChanged?.call('');
                  },
                ),
        ),
      ),
    );
  }
}

class AqPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const AqPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
  });
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(padding: padding, child: child),
  );
}

/// Transient controls blur; content cards remain opaque and inexpensive.
class AqCapsule extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const AqCapsule({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
  });
  @override
  Widget build(BuildContext context) {
    final colors = AqColors.of(context);
    final contrast = MediaQuery.highContrastOf(context);
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(28),
      side: BorderSide(
        color: contrast
            ? Theme.of(context).colorScheme.outline
            : colors.line.withValues(alpha: .6),
        width: .5,
      ),
    );
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        shadows: [
          BoxShadow(
            color: Colors.black.withValues(
              alpha: Theme.of(context).brightness == Brightness.dark
                  ? .35
                  : .08,
            ),
            blurRadius: 18,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: shape),
        child: BackdropFilter(
          enabled: !contrast,
          filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Material(
            color: colors.panel.withValues(alpha: contrast ? 1 : .86),
            shape: shape,
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

/// The round add button at the bottom right of list pages. ASpan uses the
/// same button with the same icon for creating rules.
class AqAddButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final String tooltip;
  const AqAddButton({
    super.key,
    required this.onPressed,
    required this.tooltip,
  });
  @override
  Widget build(BuildContext context) => FloatingActionButton(
    // Several pages can show one at a time (tabs share a route).
    heroTag: null,
    tooltip: tooltip,
    onPressed: onPressed,
    child: const Icon(Icons.add, size: 28),
  );
}

/// One row of an [showAqContextMenu] panel.
class AqMenuAction<T> {
  final T value;
  final String label;
  final IconData icon;
  final Color? iconColor;
  final bool destructive, enabled;
  const AqMenuAction(
    this.value,
    this.label,
    this.icon, {
    this.iconColor,
    this.destructive = false,
    this.enabled = true,
  });
}

/// Long-press / right-click menu: a frosted panel beside the press point with
/// the subject's name as a gray header, then groups of actions with the icon
/// in front. Put a destructive action in its own last group. ASpan draws its
/// context menus with the same layout.
Future<T?> showAqContextMenu<T>(
  BuildContext context,
  Offset position, {
  String? title,
  required List<List<AqMenuAction<T>>> sections,
}) {
  HapticFeedback.selectionClick();
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭菜单',
    barrierColor: Colors.black.withValues(alpha: .12),
    // Reduced motion: the menu fades in without growing.
    transitionDuration: const Duration(milliseconds: 160),
    pageBuilder: (context, animation, _) {
      final media = MediaQuery.of(context);
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeIn,
      );
      return CustomSingleChildLayout(
        delegate: _ContextMenuLayout(position, media.padding),
        child: FadeTransition(
          opacity: curved,
          child: ScaleTransition(
            scale: Tween(
              begin: media.disableAnimations ? 1.0 : .92,
              end: 1.0,
            ).animate(curved),
            child: _ContextMenuPanel<T>(title: title, sections: sections),
          ),
        ),
      );
    },
  );
}

Offset? _lastPress;
bool _trackingPress = false;

/// Remembers where the last press went down, so a context menu opened by a
/// long press, right click or ⋯ button appears beside it. Call once from the
/// screen that owns the menus.
void trackMenuPresses() {
  if (_trackingPress) return;
  _trackingPress = true;
  GestureBinding.instance.pointerRouter.addGlobalRoute((event) {
    if (event is PointerDownEvent) _lastPress = event.position;
  });
}

/// Where a context menu opens: the last press, or the middle of the screen
/// when it was opened without one (keyboard, accessibility action).
Offset menuPosition(BuildContext context) {
  final size = MediaQuery.sizeOf(context);
  final press = _lastPress;
  return press != null && (Offset.zero & size).contains(press)
      ? press
      : size.center(Offset.zero);
}

class _ContextMenuLayout extends SingleChildLayoutDelegate {
  final Offset position;
  final EdgeInsets padding;
  const _ContextMenuLayout(this.position, this.padding);
  static const margin = 8.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.loose(
        Size(
          math.min(280, constraints.maxWidth - margin * 2),
          constraints.maxHeight - padding.vertical - margin * 2,
        ),
      );

  @override
  Offset getPositionForChild(Size size, Size child) {
    double place(double at, double extent, double min, double max) {
      // Open toward the free side of the press point, then keep it on screen.
      final start = at + extent > max ? at - extent : at;
      return start.clamp(min, math.max(min, max - extent));
    }

    return Offset(
      place(
        position.dx,
        child.width,
        padding.left + margin,
        size.width - padding.right - margin,
      ),
      place(
        position.dy,
        child.height,
        padding.top + margin,
        size.height - padding.bottom - margin,
      ),
    );
  }

  @override
  bool shouldRelayout(_ContextMenuLayout old) =>
      old.position != position || old.padding != padding;
}

class _ContextMenuPanel<T> extends StatelessWidget {
  final String? title;
  final List<List<AqMenuAction<T>>> sections;
  const _ContextMenuPanel({required this.title, required this.sections});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AqColors.of(context);
    final contrast = MediaQuery.highContrastOf(context);
    final dark = theme.brightness == Brightness.dark;
    final shape = RoundedSuperellipseBorder(
      borderRadius: BorderRadius.circular(14),
      side: BorderSide(
        color: contrast ? colors.line : colors.line.withValues(alpha: .6),
        width: contrast ? 1 : .5,
      ),
    );
    final groups = [
      for (final s in sections)
        if (s.isNotEmpty) s,
    ];
    final rows = <Widget>[
      if (title != null) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 11, 16, 10),
          child: Text(
            title!,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Divider(height: .5, thickness: .5, color: colors.line),
      ],
      for (final (g, group) in groups.indexed) ...[
        if (g > 0)
          ColoredBox(
            color: colors.line.withValues(alpha: .45),
            child: const SizedBox(height: 6),
          ),
        for (final (i, action) in group.indexed) ...[
          if (i > 0)
            Divider(
              height: .5,
              thickness: .5,
              indent: 48,
              color: colors.line.withValues(alpha: .7),
            ),
          _ContextMenuRow<T>(action),
        ],
      ],
    ];
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        shadows: [
          BoxShadow(
            color: Colors.black.withValues(alpha: dark ? .35 : .1),
            blurRadius: 24,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ClipPath(
        clipper: ShapeBorderClipper(shape: shape),
        child: BackdropFilter(
          enabled: !contrast,
          filter: ui.ImageFilter.blur(sigmaX: 20, sigmaY: 20),
          child: Material(
            color: colors.panel.withValues(alpha: contrast ? 1 : .86),
            shape: shape,
            child: IntrinsicWidth(
              stepWidth: 56,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: rows,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ContextMenuRow<T> extends StatelessWidget {
  final AqMenuAction<T> action;
  const _ContextMenuRow(this.action);
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = AqColors.of(context).muted;
    final color = !action.enabled
        ? muted.withValues(alpha: .6)
        : action.destructive
        ? theme.colorScheme.error
        : theme.colorScheme.onSurface;
    return InkWell(
      onTap: action.enabled
          ? () => Navigator.pop<T>(context, action.value)
          : null,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 46, minWidth: 200),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(
                action.icon,
                size: 20,
                color: action.enabled && !action.destructive
                    ? action.iconColor ?? color
                    : color,
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  action.label,
                  style: theme.textTheme.bodyLarge?.copyWith(color: color),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Article-owned colors are independent of application chrome and palette.
Color readerOverviewBackground(Color paper) => Color.lerp(
  paper,
  paper.computeLuminance() > .45 ? Colors.black : Colors.white,
  .055,
)!;
Color readerPaperEdge(Color paper) => Color.lerp(
  paper,
  paper.computeLuminance() > .45
      ? const Color(0xff92979d)
      : const Color(0xffa6adb5),
  .32,
)!;
