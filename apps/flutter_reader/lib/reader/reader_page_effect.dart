// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';

/// Visual page transitions only. None of these changes continuous reading mode.
class ReaderPageEffect extends StatelessWidget {
  final String effect;
  final double delta, width;
  final bool rightToLeft;
  final Widget child;
  const ReaderPageEffect({
    super.key,
    required this.effect,
    required this.delta,
    required this.width,
    required this.rightToLeft,
    required this.child,
  });
  @override
  Widget build(BuildContext context) {
    if (effect == 'slide' || MediaQuery.disableAnimationsOf(context)) {
      return child;
    }
    if (effect == 'cover') {
      final shift = delta.clamp(0.0, 1.0) * width * (rightToLeft ? -1 : 1);
      return Transform.translate(
        offset: Offset(-shift, 0),
        child: ClipRect(
          clipper: _CoverReveal(delta.clamp(0.0, 1.0), rightToLeft),
          child: child,
        ),
      );
    }
    final progress = delta.abs().clamp(0.0, 1.0);
    if (delta > 0) {
      return Transform.translate(
        offset: Offset(-delta * width * (rightToLeft ? -1 : 1), 0),
        child: ClipRect(
          clipper: _CoverReveal(delta.clamp(0.0, 1.0), rightToLeft),
          child: child,
        ),
      );
    }
    return Transform.translate(
      offset: Offset(-delta * width * (rightToLeft ? -1 : 1), 0),
      child: CustomPaint(
        foregroundPainter: _FoldShadow(progress, rightToLeft),
        child: ClipPath(
          clipper: _FoldClip(progress, rightToLeft),
          child: child,
        ),
      ),
    );
  }
}

class _CoverReveal extends CustomClipper<Rect> {
  final double remaining;
  final bool rtl;
  _CoverReveal(this.remaining, this.rtl);
  @override
  Rect getClip(Size size) => rtl
      ? Rect.fromLTWH(0, 0, size.width * (1 - remaining), size.height)
      : Rect.fromLTRB(size.width * remaining, 0, size.width, size.height);
  @override
  bool shouldReclip(_CoverReveal old) =>
      old.remaining != remaining || old.rtl != rtl;
}

class _FoldClip extends CustomClipper<Path> {
  final double progress;
  final bool rtl;
  _FoldClip(this.progress, this.rtl);
  @override
  Path getClip(Size size) {
    final edge = size.width * (1 - progress);
    final bend = size.width * .10 * progress;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(edge, 0)
      ..quadraticBezierTo(edge - bend, size.height * .5, edge, size.height)
      ..lineTo(0, size.height)
      ..close();
    if (!rtl) return path;
    return path.transform(
      (Matrix4.identity()
            ..setEntry(0, 0, -1)
            ..setEntry(0, 3, size.width))
          .storage,
    );
  }

  @override
  bool shouldReclip(_FoldClip old) =>
      old.progress != progress || old.rtl != rtl;
}

class _FoldShadow extends CustomPainter {
  final double progress;
  final bool rtl;
  _FoldShadow(this.progress, this.rtl);
  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0 || progress >= 1) return;
    if (rtl) {
      canvas.translate(size.width, 0);
      canvas.scale(-1, 1);
    }
    final edge = size.width * (1 - progress),
        bend = size.width * .10 * progress;
    final fold = Path()
      ..moveTo(edge, 0)
      ..quadraticBezierTo(edge - bend, size.height * .5, edge, size.height)
      ..quadraticBezierTo(edge + bend, size.height * .5, edge, 0)
      ..close();
    canvas.drawShadow(fold, Colors.black.withValues(alpha: .35), 5, false);
    canvas.drawPath(
      fold,
      Paint()
        ..shader = LinearGradient(
          colors: [
            const Color(0xffb7b5ae),
            const Color(0xfffaf7ed),
            const Color(0xffd3d0c6),
          ],
        ).createShader(Rect.fromLTWH(edge - bend, 0, bend * 2, size.height)),
    );
  }

  @override
  bool shouldRepaint(_FoldShadow old) =>
      old.progress != progress || old.rtl != rtl;
}
