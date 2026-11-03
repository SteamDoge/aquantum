// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';

abstract final class ReaderMotion {
  static const feedback = Duration(milliseconds: 140);
  static const navigation = Duration(milliseconds: 220);
  static const page = Duration(milliseconds: 280);
  static const Curve curve = Curves.easeOutCubic;

  static Duration duration(BuildContext context, Duration normal) =>
      MediaQuery.disableAnimationsOf(context) ? Duration.zero : normal;

  static Route<T> route<T>(
    BuildContext context,
    WidgetBuilder builder,
    String name,
  ) => PageRouteBuilder<T>(
    settings: RouteSettings(name: name),
    transitionDuration: duration(context, page),
    reverseTransitionDuration: duration(context, navigation),
    pageBuilder: (context, _, _) => builder(context),
    transitionsBuilder: (context, animation, _, child) {
      if (MediaQuery.disableAnimationsOf(context)) return child;
      return SlideTransition(
        position: Tween(
          begin: const Offset(.035, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: animation, curve: curve)),
        child: FadeTransition(opacity: animation, child: child),
      );
    },
  );
}
