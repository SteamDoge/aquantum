// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';

/// A document control owns this pointer; the shell must not also toggle chrome
/// or change page when the control receives its tap.
class ReaderControlPointer extends Notification {
  final int pointer;
  ReaderControlPointer(this.pointer);
}

class ReaderInteractiveRegion extends StatelessWidget {
  final Widget child;
  const ReaderInteractiveRegion({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) =>
        ReaderControlPointer(event.pointer).dispatch(context),
    child: child,
  );
}
