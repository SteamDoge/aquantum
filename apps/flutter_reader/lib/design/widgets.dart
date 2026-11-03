// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'theme.dart';

class AqBrand extends StatelessWidget {
  final bool compact;
  const AqBrand({super.key, this.compact = false});
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        Icons.travel_explore_outlined,
        size: compact ? 23 : 25,
        color: Theme.of(context).colorScheme.primary,
      ),
      const SizedBox(width: 8),
      Text(
        'AQuantum',
        style: Theme.of(
          context,
        ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
      ),
      if (!compact) ...[
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            'READER',
            maxLines: 1,
            overflow: TextOverflow.fade,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontSize: 9,
              letterSpacing: 1.4,
              color: AqColors.of(context).muted,
            ),
          ),
        ),
      ],
    ],
  );
}

class AqPageHeading extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> actions;
  final bool brand;
  const AqPageHeading(
    this.title, {
    super.key,
    this.subtitle,
    this.actions = const [],
    this.brand = true,
  });
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (brand) ...[const AqBrand(), const SizedBox(height: 24)],
      if (subtitle != null) ...[
        Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 6),
      ],
      Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                ),
                ExcludeSemantics(
                  child: Text(
                    '.',
                    style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    ],
  );
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
        color: contrast ? Theme.of(context).colorScheme.outline : colors.line,
      ),
    );
    return ClipPath(
      clipper: ShapeBorderClipper(shape: shape),
      child: BackdropFilter(
        enabled: !contrast,
        filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Material(
          color: colors.panel.withValues(alpha: contrast ? 1 : .92),
          shape: shape,
          child: Padding(padding: padding, child: child),
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
