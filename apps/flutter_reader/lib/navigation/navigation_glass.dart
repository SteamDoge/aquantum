// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

const navigationGlassShape = RoundedSuperellipseBorder(
  borderRadius: BorderRadius.all(Radius.circular(100)),
);

/// The dock's two bounded surfaces share one compiled program, not a scene
/// capture or a continuously running render loop. Each owns its shader instance.
class NavigationGlass extends StatefulWidget {
  final Widget child;
  final double lift;
  final bool lens, opaque;
  const NavigationGlass({
    super.key,
    required this.child,
    this.lift = 0,
    this.lens = false,
    this.opaque = false,
  });

  @override
  State<NavigationGlass> createState() => _NavigationGlassState();
}

class _NavigationGlassState extends State<NavigationGlass> {
  static Future<ui.FragmentProgram?>? _program;
  ui.FragmentShader? _shader;
  bool _requested = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(NavigationGlass oldWidget) {
    super.didUpdateWidget(oldWidget);
    _load();
  }

  void _load() {
    if (_requested ||
        widget.opaque ||
        !ui.ImageFilter.isShaderFilterSupported) {
      return;
    }
    _requested = true;
    _program ??= ui.FragmentProgram.fromAsset('shaders/navigation_glass.frag')
        .then<ui.FragmentProgram?>((program) => program)
        .catchError((Object error, StackTrace stack) {
          debugPrint('Navigation glass uses blur fallback: $error');
          return null;
        });
    unawaited(
      _program!.then((program) {
        if (mounted && program != null) {
          setState(() => _shader = program.fragmentShader());
        }
      }),
    );
  }

  @override
  void dispose() {
    _shader?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = colors.brightness == Brightness.dark;
    final lift = widget.lift.clamp(0.0, 1.0);
    final radius = BorderRadius.circular(100);
    return LayoutBuilder(
      builder: (context, size) {
        final shader = _shader;
        ui.ImageFilter filter = ui.ImageFilter.blur(
          sigmaX: widget.lens ? 1.5 : 13,
          sigmaY: widget.lens ? 1.5 : 13,
        );
        if (!widget.opaque && shader != null) {
          // 0/1 and sampler 0 belong to the engine's ImageFilter input.
          shader
            ..setFloat(2, size.maxWidth)
            ..setFloat(3, size.maxHeight)
            ..setFloat(4, widget.lens ? 5 + 5 * lift : 6)
            ..setFloat(5, widget.lens ? 0.4 : 1.0);
          final refraction = ui.ImageFilter.shader(shader);
          // The shader only bends light at the rim; it does not blur. The dock
          // floats above scrolling pages, so the main surface must frost what
          // passes beneath it before refracting. The small lens sits on that
          // frosted surface and needs refraction alone.
          filter = widget.lens
              ? refraction
              : ui.ImageFilter.compose(outer: refraction, inner: filter);
        }
        final tint = widget.opaque
            ? widget.lens
                  ? colors.primaryContainer
                  : colors.surfaceContainerHigh
            : widget.lens
            ? colors.primaryContainer.withValues(alpha: .24 * (1 - lift))
            : colors.surfaceContainer.withValues(alpha: dark ? .58 : .48);
        return ClipRSuperellipse(
          borderRadius: radius,
          child: BackdropFilter(
            key: ValueKey(
              widget.opaque
                  ? 'navigation-glass-opaque'
                  : shader == null
                  ? 'navigation-glass-blur'
                  : 'navigation-glass-refraction',
            ),
            enabled: !widget.opaque,
            filter: filter,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                color: widget.opaque ? tint : null,
                shape: RoundedSuperellipseBorder(
                  borderRadius: radius,
                  side: BorderSide(
                    width: .8,
                    color: widget.opaque
                        ? colors.outline
                        : Colors.white.withValues(alpha: dark ? .24 : .68),
                  ),
                ),
                gradient: widget.opaque
                    ? null
                    : LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Color.alphaBlend(
                            Colors.white.withValues(alpha: .14 + lift * .13),
                            tint,
                          ),
                          Color.alphaBlend(
                            Colors.white.withValues(alpha: .015),
                            tint,
                          ),
                          Color.alphaBlend(
                            colors.onSurface.withValues(alpha: .035),
                            tint,
                          ),
                        ],
                        stops: const [0, .48, 1],
                      ),
              ),
              child: widget.child,
            ),
          ),
        );
      },
    );
  }
}
