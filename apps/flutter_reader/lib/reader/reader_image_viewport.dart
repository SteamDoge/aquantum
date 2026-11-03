// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// At natural size one finger belongs to the surrounding reading scroll.
/// Two fingers zoom; once enlarged, one finger pans the enlarged page.
class ReaderImageViewport extends StatefulWidget {
  final Widget child;
  final TransformationController controller;
  final ValueChanged<bool>? onZoomChanged;
  const ReaderImageViewport({
    super.key,
    required this.child,
    required this.controller,
    this.onZoomChanged,
  });
  @override
  State<ReaderImageViewport> createState() => _ReaderImageViewportState();
}

class _ReadingScaleRecognizer extends ScaleGestureRecognizer {
  final bool Function() zoomed;
  _ReadingScaleRecognizer(this.zoomed);
  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent && pointerCount < 2 && !zoomed()) return;
    super.handleEvent(event);
  }
}

class _ReaderImageViewportState extends State<ReaderImageViewport> {
  double initialScale = 1;
  Offset anchor = Offset.zero;
  @override
  Widget build(BuildContext context) => RawGestureDetector(
    gestures: {
      _ReadingScaleRecognizer:
          GestureRecognizerFactoryWithHandlers<_ReadingScaleRecognizer>(
            () => _ReadingScaleRecognizer(
              () => widget.controller.value.getMaxScaleOnAxis() > 1.01,
            ),
            (recognizer) {
              recognizer.onStart = (details) {
                final matrix = widget.controller.value;
                initialScale = matrix.getMaxScaleOnAxis();
                final translation = matrix.getTranslation();
                anchor =
                    (details.localFocalPoint -
                        Offset(translation.x, translation.y)) /
                    initialScale;
              };
              recognizer.onUpdate = (details) {
                final scale = (initialScale * details.scale).clamp(1.0, 5.0);
                final size = context.size;
                var translation = details.localFocalPoint - anchor * scale;
                if (size != null) {
                  translation = Offset(
                    translation.dx.clamp(size.width * (1 - scale), 0.0),
                    translation.dy.clamp(size.height * (1 - scale), 0.0),
                  );
                }
                widget.controller.value = Matrix4.identity()
                  ..setEntry(0, 0, scale)
                  ..setEntry(1, 1, scale)
                  ..setEntry(0, 3, translation.dx)
                  ..setEntry(1, 3, translation.dy);
                widget.onZoomChanged?.call(scale > 1.01);
              };
            },
          ),
    },
    child: ClipRect(
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, child) =>
            Transform(transform: widget.controller.value, child: child),
        child: widget.child,
      ),
    ),
  );
}
