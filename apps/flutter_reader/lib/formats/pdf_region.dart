// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'pdf_engine.dart';

/// Samples only the visible PDFium region. Original PDF bytes remain unchanged.
class PdfRegion extends StatefulWidget {
  final PdfEngineSession engine;
  final int index;
  final Map<String, dynamic> crop;
  final bool interactive;
  const PdfRegion({
    super.key,
    required this.engine,
    required this.index,
    required this.crop,
    this.interactive = true,
  });
  @override
  State<PdfRegion> createState() => _PdfRegionState();
}

class _PdfRegionState extends State<PdfRegion> {
  ui.Image? image;
  Object? error;
  String? request;
  int generation = 0;
  void render(double width) {
    final key = '${widget.index}:$width:${widget.crop}';
    if (request == key) return;
    request = key;
    final current = ++generation;
    widget.engine
        .region(widget.index, widget.crop, width)
        .then(
          (next) {
            if (!mounted || current != generation) {
              next?.dispose();
              return;
            }
            final previous = image;
            setState(() {
              image = next;
              error = null;
            });
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => previous?.dispose(),
            );
          },
          onError: (Object e) {
            if (mounted && current == generation) setState(() => error = e);
          },
        );
  }

  @override
  void dispose() {
    generation++;
    image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, size) {
      render(size.maxWidth * MediaQuery.devicePixelRatioOf(context));
      final page = image == null
          ? Center(
              child: error == null
                  ? const CircularProgressIndicator()
                  : Text('$error'),
            )
          : Center(
              child: RawImage(image: image, fit: BoxFit.contain),
            );
      return widget.interactive
          ? InteractiveViewer(
              minScale: 1,
              maxScale: 4,
              child: SizedBox.expand(child: page),
            )
          : page;
    },
  );
}
