// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../design/motion.dart';
import '../features/feature_registry.dart';
import 'navigation_controller.dart';
import 'navigation_preferences.dart';
import 'liquid_navigation_dock.dart';

/// Adapters own placement only. No layout widget registers or orders features.
class NavigationShell extends StatelessWidget {
  final AppNavigation navigation;
  final NavigationProfile profile;
  final Widget child;
  final Widget? projectTree;
  final ValueChanged<String> onOpen;
  final VoidCallback onToggleExpanded;
  const NavigationShell({
    super.key,
    required this.navigation,
    required this.profile,
    required this.child,
    required this.onOpen,
    required this.onToggleExpanded,
    this.projectTree,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final rail = profile == NavigationProfile.desktop || size.width >= 840;
    final expanded =
        navigation.preferences(profile).layout.expanded && size.width >= 700;
    final items = navigation.items(profile);
    final selected = navigation.selected(profile);
    final highlighted = items.any((f) => f.id == selected)
        ? selected
        : FeatureRegistry.me;
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    // The mobile dock floats above full-height pages. Shortening the page to
    // reserve dock space clips content into a separate bottom tray, so the
    // dock footprint is reported as bottom padding instead, as with
    // Scaffold.extendBody: pages scroll beneath it and their ends rest above.
    final floating = !rail && keyboard == 0;
    final systemBottom = MediaQuery.paddingOf(context).bottom;
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final icons = dark ? Brightness.light : Brightness.dark;
    // Pages run under the system navigation area. Gesture navigation reports
    // back-swipe zones at the side edges and needs no backing, so pages show
    // through to the screen edge. Button navigation has none; its buttons
    // need a scrim over scrolling content. Android 15's own contrast scrim
    // keeps the colour chosen at launch and ignores later in-app or system
    // theme changes, so the shell paints a theme-coloured scrim itself.
    final gestures = MediaQuery.systemGestureInsetsOf(context);
    final buttonScrim =
        !rail &&
        theme.platform == TargetPlatform.android &&
        systemBottom > 0 &&
        gestures.left == 0 &&
        gestures.right == 0;
    // Button colours are not reliably the app's to choose: on Android 15 the
    // launcher-drawn button bar follows the system theme and ignores the
    // requested appearance. Under buttons, the scrim and the request therefore
    // follow the system theme, so either behaviour keeps the buttons legible.
    // When the in-app theme matches it, the scrim simply continues the page.
    final system = MediaQuery.platformBrightnessOf(context);
    final scrimColor = theme.brightness == system
        ? theme.scaffoldBackgroundColor.withValues(alpha: 0.9)
        : system == Brightness.dark
        ? const Color(0xCC000000)
        : const Color(0xE6FFFFFF);
    final buttons = !buttonScrim
        ? icons
        : system == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    // The owning Scaffold and feature pages share the theme background.
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        // Only a page drawn under the status bar (edge-to-edge) sits behind its
        // icons, so only then do they follow the in-app theme, which can differ
        // from the system's. A separate system-coloured bar keeps its default.
        statusBarIconBrightness: MediaQuery.paddingOf(context).top > 0
            ? icons
            : null,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
        // The shell paints the button-navigation scrim (see above).
        systemNavigationBarContrastEnforced: false,
        systemNavigationBarIconBrightness: buttons,
      ),
      child: SafeArea(
        // Mobile pages extend behind the gesture area; the dock stays above it.
        bottom: rail,
        child: Row(
          children: [
            // Keep the content at the same element-tree address during resizing.
            if (rail)
              _DesktopRail(
                items: items,
                selected: highlighted,
                expanded: expanded,
                onOpen: onOpen,
                onToggleExpanded: onToggleExpanded,
                projectTree: projectTree,
              )
            else
              const SizedBox.shrink(),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: Padding(
                      // Only the keyboard shortens pages.
                      padding: EdgeInsets.only(bottom: keyboard),
                      child: _PageInsets(
                        dock: floating
                            ? LiquidNavigationDock.contentInsetOf(context)
                            : 0,
                        child: child,
                      ),
                    ),
                  ),
                  if (buttonScrim)
                    Positioned(
                      key: const ValueKey('navigation-bar-scrim'),
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: systemBottom,
                      child: IgnorePointer(
                        child: ColoredBox(color: scrimColor),
                      ),
                    ),
                  if (floating)
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 12 + systemBottom,
                      child: Center(
                        child: LiquidNavigationDock(
                          items: items,
                          selected: highlighted,
                          onOpen: onOpen,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Page-facing insets below the SafeArea. Child Scaffolds must not consume
/// the keyboard inset twice; under the floating dock, its footprint joins the
/// remaining system inset so each page's scrollable can end above the dock.
class _PageInsets extends StatelessWidget {
  final double dock;
  final Widget child;
  const _PageInsets({required this.dock, required this.child});
  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context).removeViewInsets(removeBottom: true);
    return MediaQuery(
      data: media.copyWith(
        padding: media.padding.copyWith(bottom: media.padding.bottom + dock),
      ),
      child: child,
    );
  }
}

class _DesktopRail extends StatelessWidget {
  final List<AppFeature> items;
  final String selected;
  final bool expanded;
  final ValueChanged<String> onOpen;
  final VoidCallback onToggleExpanded;
  final Widget? projectTree;
  const _DesktopRail({
    required this.items,
    required this.selected,
    required this.expanded,
    required this.onOpen,
    required this.onToggleExpanded,
    this.projectTree,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedContainer(
      key: const ValueKey('desktop-navigation'),
      // Leave 48px hit targets after the panel and destination borders.
      width: expanded ? 220 : 68,
      duration: ReaderMotion.duration(context, ReaderMotion.navigation),
      curve: ReaderMotion.curve,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(right: BorderSide(color: scheme.outlineVariant)),
      ),
      // Expanded contents use their final width while the outer pane animates.
      // Project-tree ListTiles must never be laid out at a compact rail width.
      child: ClipRect(
        child: OverflowBox(
          alignment: Alignment.topLeft,
          minWidth: expanded ? 219 : 67,
          maxWidth: expanded ? 219 : 67,
          child: Column(
            children: [
              const SizedBox(height: 16),
              IconButton(
                tooltip: expanded ? '收起导航' : '展开导航',
                onPressed: onToggleExpanded,
                icon: const Icon(Icons.menu_open),
              ),
              if (expanded)
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Text(
                    'AQuantum\nReader',
                    style: TextStyle(
                      fontSize: 18,
                      height: 1.1,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Icon(
                    Icons.auto_stories_outlined,
                    color: scheme.primary,
                  ),
                ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  children: [
                    for (final feature in items.where(
                      (f) => f.id != FeatureRegistry.me,
                    ))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _Destination(
                          feature: feature,
                          selected: selected == feature.id,
                          vertical: false,
                          compact: !expanded,
                          onTap: () => onOpen(feature.id),
                        ),
                      ),
                    if (expanded && projectTree != null)
                      Material(
                        type: MaterialType.transparency,
                        child: projectTree!,
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(7, 8, 7, 8),
                child: SizedBox(
                  width: double.infinity,
                  child: _Destination(
                    feature: items.last,
                    selected: selected == FeatureRegistry.me,
                    vertical: false,
                    compact: !expanded,
                    onTap: () => onOpen(FeatureRegistry.me),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Destination extends StatelessWidget {
  final AppFeature feature;
  final bool selected, vertical, compact;
  final VoidCallback onTap;
  const _Destination({
    required this.feature,
    required this.selected,
    required this.vertical,
    this.compact = false,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = selected ? scheme.primary : scheme.onSurfaceVariant;
    final icon = ExcludeSemantics(child: Icon(feature.icon, color: color));
    final label = Text(
      feature.name,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: color,
        fontSize: vertical ? 12 : 14,
        fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
      ),
    );
    return Semantics(
      selected: selected,
      button: true,
      label: feature.name,
      onTap: onTap,
      child: Tooltip(
        message: feature.name,
        excludeFromSemantics: true,
        child: AnimatedContainer(
          duration: ReaderMotion.duration(context, ReaderMotion.navigation),
          curve: ReaderMotion.curve,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            color: selected
                ? scheme.primaryContainer.withValues(alpha: .65)
                : Colors.transparent,
            border: Border.all(
              color: selected
                  ? scheme.primary.withValues(alpha: .24)
                  : Colors.transparent,
            ),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              key: ValueKey('nav-${feature.id}'),
              borderRadius: BorderRadius.circular(22),
              onTap: onTap,
              excludeFromSemantics: true,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: vertical ? 8 : 12,
                ),
                child: compact
                    ? icon
                    : vertical
                    ? Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          icon,
                          const SizedBox(height: 4),
                          ExcludeSemantics(child: label),
                        ],
                      )
                    : Row(
                        children: [
                          icon,
                          const SizedBox(width: 12),
                          Expanded(child: ExcludeSemantics(child: label)),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
