// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import '../design/motion.dart';
import '../features/feature_registry.dart';

/// Lazy retained pages, keyed by feature identity rather than shortcut order.
/// Unregistering a source removes its page state from this host immediately.
class FeatureHost extends StatefulWidget {
  final FeatureRegistry registry;
  final String selected;
  const FeatureHost({
    super.key,
    required this.registry,
    required this.selected,
  });
  @override
  State<FeatureHost> createState() => _FeatureHostState();
}

class _FeatureHostState extends State<FeatureHost>
    with SingleTickerProviderStateMixin {
  final Set<String> visited = {};
  late final AnimationController transition = AnimationController(
    vsync: this,
    value: 1,
  );
  @override
  void didUpdateWidget(FeatureHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected) {
      transition.duration = ReaderMotion.duration(
        context,
        ReaderMotion.navigation,
      );
      transition.forward(from: 0);
    }
  }

  @override
  void dispose() {
    transition.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    visited.add(widget.selected);
    visited.removeWhere((id) => widget.registry[id] == null);
    return FadeTransition(
      opacity: transition,
      child: Stack(
        fit: StackFit.expand,
        children: [
          for (final feature in widget.registry.all.where(
            (feature) => visited.contains(feature.id),
          ))
            Offstage(
              key: ValueKey(feature.id),
              offstage: widget.selected != feature.id,
              child: TickerMode(
                enabled: widget.selected == feature.id,
                child: FocusScope(
                  canRequestFocus: widget.selected == feature.id,
                  child: RepaintBoundary(
                    child: Builder(builder: feature.builder),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
