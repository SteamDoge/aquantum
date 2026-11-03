// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';

import '../features/feature_registry.dart';
import 'navigation_glass.dart';

/// A mobile-only glass dock. Gesture previews do not navigate or write prefs;
/// a valid release commits one destination through the existing controller.
class LiquidNavigationDock extends StatefulWidget {
  final List<AppFeature> items;
  final String selected;
  final ValueChanged<String> onOpen;
  const LiquidNavigationDock({
    super.key,
    required this.items,
    required this.selected,
    required this.onOpen,
  });

  static double heightOf(BuildContext context) =>
      64 + (MediaQuery.textScalerOf(context).scale(12) - 12).clamp(0, 48);
  static double contentInsetOf(BuildContext context) => heightOf(context) + 24;

  @override
  State<LiquidNavigationDock> createState() => _LiquidNavigationDockState();
}

class _LiquidNavigationDockState extends State<LiquidNavigationDock>
    with TickerProviderStateMixin {
  late final AnimationController _position;
  late final AnimationController _lift;
  late final Listenable _motion;
  late List<String> _itemIds;
  int? _pointer, _preview, _hover;
  Offset _down = Offset.zero;
  bool _dragging = false, _reduced = false;
  double _touchX = 0;

  int get _selected => math.max(
    0,
    widget.items.indexWhere((item) => item.id == widget.selected),
  );

  @override
  void initState() {
    super.initState();
    _position = AnimationController.unbounded(
      vsync: this,
      value: _selected.toDouble(),
    );
    _lift = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 130),
      reverseDuration: const Duration(milliseconds: 250),
    );
    _motion = Listenable.merge([_position, _lift]);
    _itemIds = widget.items.map((item) => item.id).toList();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.disableAnimationsOf(context);
    if (_reduced) {
      _position.stop();
      _position.value = (_preview ?? _selected).toDouble();
      _lift.stop();
      _lift.value = 0;
    }
  }

  @override
  void didUpdateWidget(LiquidNavigationDock oldWidget) {
    super.didUpdateWidget(oldWidget);
    final nextIds = widget.items.map((item) => item.id).toList();
    final sameItems = _itemIds.join('|') == nextIds.join('|');
    _itemIds = nextIds;
    if (!sameItems || oldWidget.selected != widget.selected) {
      _pointer = null;
      _preview = null;
      _dragging = false;
      _hover = null;
      _releaseLift();
      _settle(_selected.toDouble());
    }
  }

  void _settle(double target) {
    if (_reduced) {
      _position.value = target;
      return;
    }
    if ((_position.value - target).abs() < .001 && !_position.isAnimating) {
      return;
    }
    _position.animateWith(
      SpringSimulation(
        const SpringDescription(mass: 1.1, stiffness: 420, damping: 30),
        _position.value,
        target,
        _position.velocity.clamp(-12.0, 12.0),
        tolerance: const Tolerance(distance: .001, velocity: .005),
      ),
    );
  }

  void _releaseLift() {
    if (_reduced) {
      _lift.value = 0;
    } else {
      _lift.reverse();
    }
  }

  double _at(Offset point, double width) {
    final x = Directionality.of(context) == TextDirection.rtl
        ? width - point.dx
        : point.dx;
    final pitch = (width - 8) / widget.items.length;
    return ((x - 4) / pitch - .5).clamp(
      0.0,
      (widget.items.length - 1).toDouble(),
    );
  }

  void _begin(PointerDownEvent event, double width) {
    if (_pointer != null || (event.buttons & kPrimaryButton) == 0) return;
    final index = _at(event.localPosition, width).round();
    _down = event.localPosition;
    _touchX = _down.dx;
    _position.stop();
    setState(() {
      _pointer = event.pointer;
      _preview = index;
      _dragging = false;
    });
    _settle(index.toDouble());
    if (!_reduced) _lift.forward();
  }

  void _move(PointerMoveEvent event, double width) {
    if (event.pointer != _pointer) return;
    if (!_dragging && (event.localPosition - _down).distance < 8) return;
    final at = _at(event.localPosition, width);
    final index = at.round();
    if (_preview != index) unawaited(HapticFeedback.selectionClick());
    _position.stop();
    setState(() {
      _dragging = true;
      _preview = index;
      _touchX = event.localPosition.dx.clamp(0, width);
    });
    _position.value = at;
  }

  void _end(PointerEvent event, double width, double height, bool commit) {
    if (event.pointer != _pointer) return;
    final inside = Rect.fromLTRB(
      -12,
      -24,
      width + 12,
      height + 24,
    ).contains(event.localPosition);
    final index = commit && inside ? _preview : null;
    setState(() {
      _pointer = null;
      _preview = null;
      _dragging = false;
    });
    _releaseLift();
    _settle((index ?? _selected).toDouble());
    // A highlighted fallback (e.g. Me while an unpinned plugin page is open)
    // still needs activation; only the controller knows the actual open page.
    if (index != null) {
      widget.onOpen(widget.items[index].id);
    }
  }

  @override
  void dispose() {
    _position.dispose();
    _lift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    final opaque = MediaQuery.highContrastOf(context);
    final dark = colors.brightness == Brightness.dark;
    final height = LiquidNavigationDock.heightOf(context);
    return RepaintBoundary(
      key: const ValueKey('mobile-navigation'),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: widget.items.length >= 5
              ? 560
              : widget.items.length * 88.0 + 12,
        ),
        child: SizedBox(
          height: height,
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              final pitch = (width - 8) / widget.items.length;
              return MouseRegion(
                cursor: SystemMouseCursors.click,
                onHover: (event) {
                  if (event.kind == PointerDeviceKind.touch) return;
                  final index = _at(event.localPosition, width).round();
                  if (_hover != index) setState(() => _hover = index);
                },
                onExit: (_) => setState(() => _hover = null),
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (e) => _begin(e, width),
                  onPointerMove: (e) => _move(e, width),
                  onPointerUp: (e) => _end(e, width, height, true),
                  onPointerCancel: (e) => _end(e, width, height, false),
                  child: AnimatedBuilder(
                    animation: _motion,
                    builder: (context, _) {
                      final lift = _lift.value.clamp(0.0, 1.0);
                      final stretch = math.min(
                        1.0,
                        _position.velocity.abs() / 8,
                      );
                      final lensWidth = math.min(
                        width - 8,
                        pitch - 3 + lift * 5 + stretch * 4,
                      );
                      final logical =
                          4 + (_position.value + .5) * pitch - lensWidth / 2;
                      final left =
                          Directionality.of(context) == TextDirection.rtl
                          ? width - logical - lensWidth
                          : logical;
                      return DecoratedBox(
                        decoration: ShapeDecoration(
                          shape: navigationGlassShape,
                          shadows: [
                            BoxShadow(
                              color: colors.shadow.withValues(
                                alpha: dark ? .3 : .12,
                              ),
                              blurRadius: 22,
                              offset: const Offset(0, 7),
                            ),
                          ],
                        ),
                        child: NavigationGlass(
                          opaque: opaque,
                          child: Stack(
                            clipBehavior: Clip.none,
                            children: [
                              if (!opaque && lift > .001)
                                Positioned.fill(
                                  child: IgnorePointer(
                                    child: DecoratedBox(
                                      decoration: ShapeDecoration(
                                        shape: navigationGlassShape,
                                        gradient: RadialGradient(
                                          center: Alignment(
                                            _touchX / width * 2 - 1,
                                            -.4,
                                          ),
                                          radius: .75,
                                          colors: [
                                            Colors.white.withValues(
                                              alpha: .25 * lift,
                                            ),
                                            Colors.transparent,
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              Positioned(
                                left: left.clamp(2, width - lensWidth - 2),
                                top: 4 - lift,
                                width: lensWidth,
                                height: height - 8 + 2 * lift,
                                child: IgnorePointer(
                                  child: DecoratedBox(
                                    key: const ValueKey(
                                      'navigation-glass-lens',
                                    ),
                                    decoration: ShapeDecoration(
                                      shape: navigationGlassShape,
                                      color: opaque
                                          ? colors.primaryContainer
                                          : colors.primaryContainer.withValues(
                                              alpha: .38 * (1 - lift),
                                            ),
                                      shadows: [
                                        if (lift > .01)
                                          BoxShadow(
                                            color: colors.shadow.withValues(
                                              alpha: .1 * lift,
                                            ),
                                            blurRadius: 8,
                                            offset: Offset(0, 3 * lift),
                                          ),
                                      ],
                                    ),
                                    child: NavigationGlass(
                                      lens: true,
                                      lift: lift,
                                      opaque: opaque,
                                      child: const SizedBox.expand(),
                                    ),
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.all(4),
                                child: Row(
                                  children: [
                                    for (
                                      var index = 0;
                                      index < widget.items.length;
                                      index++
                                    )
                                      Expanded(
                                        child: _DockButton(
                                          key: ValueKey(widget.items[index].id),
                                          feature: widget.items[index],
                                          selected:
                                              widget.items[index].id ==
                                              widget.selected,
                                          preview:
                                              (_preview ?? _selected) == index,
                                          hover: _hover == index,
                                          lift: _reduced
                                              ? 0
                                              : lift *
                                                    (1 -
                                                            (_position.value -
                                                                    index)
                                                                .abs())
                                                        .clamp(0, 1),
                                          onOpen: () => widget.onOpen(
                                            widget.items[index].id,
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
                    },
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _DockButton extends StatefulWidget {
  final AppFeature feature;
  final bool selected, preview, hover;
  final double lift;
  final VoidCallback onOpen;
  const _DockButton({
    super.key,
    required this.feature,
    required this.selected,
    required this.preview,
    required this.hover,
    required this.lift,
    required this.onOpen,
  });
  @override
  State<_DockButton> createState() => _DockButtonState();
}

class _DockButtonState extends State<_DockButton> {
  bool _focused = false;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = widget.preview
        ? colors.primary
        : colors.onSurfaceVariant;
    return Semantics(
      container: true,
      button: true,
      selected: widget.selected,
      label: widget.feature.name,
      onTap: widget.onOpen,
      child: Tooltip(
        message: widget.feature.name,
        excludeFromSemantics: true,
        child: FocusableActionDetector(
          onShowFocusHighlight: (value) => setState(() => _focused = value),
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          },
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onOpen();
                return null;
              },
            ),
          },
          child: Container(
            key: ValueKey('nav-${widget.feature.id}'),
            decoration: ShapeDecoration(
              color: widget.hover
                  ? colors.onSurface.withValues(alpha: .045)
                  : null,
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(28),
                side: BorderSide(
                  color: _focused ? colors.primary : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: ExcludeSemantics(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Transform.translate(
                    offset: Offset(0, -1.5 * widget.lift),
                    child: Transform.scale(
                      scale: 1 + .1 * widget.lift,
                      child: Icon(
                        widget.feature.icon,
                        color: foreground,
                        size: 25,
                      ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    widget.feature.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: foreground,
                      fontSize: 11.5,
                      height: 1.2,
                      fontWeight: widget.preview
                          ? FontWeight.w600
                          : FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
