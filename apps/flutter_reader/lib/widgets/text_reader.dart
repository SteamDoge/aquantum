// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../reader/continuous_progress.dart';
import '../reader/text_chunks.dart';
import '../reader/reader_contract.dart';

/// Top-to-bottom text: one free, continuous scroll that stops wherever the
/// finger leaves it. Nothing snaps to a paragraph or a screen.
class TextReader extends StatefulWidget {
  final String title;
  final List<String> paragraphs;
  final double fontSize;
  final double lineHeight, paragraphGap, margin;
  final String? fontFamily;
  final FontWeight fontWeight;
  final ValueChanged<bool>? onSelectionActive;
  final int position;

  /// How far into [position] (0–1) the reader was, restored after layout.
  final double initialWithin;
  final ItemScrollController controller;

  /// The paragraph at the top of the screen and how far into it the screen
  /// starts, reported once scrolling settles.
  final void Function(int paragraph, double within) onPosition;

  /// Whole-book position on every scroll frame, for the scrollbar.
  final ValueChanged<ReaderScrollMetrics>? onMetrics;
  final ReaderSeekController? seek;
  final EditableTextContextMenuBuilder? contextMenuBuilder;
  const TextReader({
    super.key,
    required this.title,
    required this.paragraphs,
    required this.fontSize,
    this.lineHeight = 1.9,
    this.paragraphGap = 24,
    this.margin = 28,
    this.fontFamily = 'Noto Serif CJK SC',
    this.fontWeight = FontWeight.w400,
    this.onSelectionActive,
    required this.position,
    this.initialWithin = 0,
    required this.controller,
    required this.onPosition,
    this.onMetrics,
    this.seek,
    this.contextMenuBuilder,
  });

  /// A paragraph's share of the book: its characters plus a little for the
  /// line it always occupies, so empty lines are not free.
  static double weightOf(String paragraph) => paragraph.length + 8.0;
  static final _progress = Expando<WeightedProgress>();
  static WeightedProgress progressOf(List<String> paragraphs) =>
      _progress[paragraphs] ??= _buildProgress(paragraphs);
  static WeightedProgress _buildProgress(List<String> paragraphs) {
    final chunks = TextChunks.of(paragraphs);
    return WeightedProgress(List.generate(chunks.chunks.length, chunks.weight));
  }

  static double fractionOf(
    List<String> paragraphs,
    int paragraph,
    double within,
  ) {
    final source = TextChunks.of(paragraphs).locate(paragraph, within);
    return progressOf(paragraphs).fractionAt(source.$1, source.$2);
  }

  @override
  State<TextReader> createState() => _TextReaderState();
}

class _TextReaderState extends State<TextReader> {
  final positions = ItemPositionsListener.create();
  final offsets = ScrollOffsetController();
  late final seeker = PositionedListSeeker(
    items: widget.controller,
    offsets: offsets,
    positions: positions,
  );
  late TextChunks chunks = TextChunks.of(widget.paragraphs);
  late WeightedProgress progress = _progressFor(widget.paragraphs);
  Timer? debounce;
  bool userScroll = false;

  /// Set while the scrollbar moves the text, so where it lands is saved even
  /// though no finger scrolled.
  bool seeking = false;
  (int, double)? reported;

  static WeightedProgress _progressFor(List<String> paragraphs) =>
      TextReader.progressOf(paragraphs);

  @override
  void initState() {
    super.initState();
    positions.itemPositions.addListener(changed);
    widget.seek?.attach(seekTo);
    reported = (widget.position, widget.initialWithin);
    if (widget.initialWithin > .001) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          seeker.jump(
            chunks.locate(widget.position, widget.initialWithin).$1,
            chunks.locate(widget.position, widget.initialWithin).$2,
          );
        }
      });
    }
  }

  @override
  void didUpdateWidget(covariant TextReader oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.paragraphs, widget.paragraphs)) {
      chunks = TextChunks.of(widget.paragraphs);
      progress = _progressFor(widget.paragraphs);
    }
    if (!identical(oldWidget.seek, widget.seek)) {
      oldWidget.seek?.detach(seekTo);
      widget.seek?.attach(seekTo);
    }
  }

  @override
  void dispose() {
    debounce?.cancel();
    widget.seek?.detach(seekTo);
    positions.itemPositions.removeListener(changed);
    super.dispose();
  }

  void seekTo(double fraction) {
    if (!widget.controller.isAttached) return;
    final (index, within) = progress.locate(fraction);
    // Stays on until the place the seek reached has been reported: the list
    // publishes its final position after the seek itself completes.
    seeking = true;
    seeker.jump(index, within);
  }

  void changed() {
    final value = positions.itemPositions.value;
    final metrics = progress.measure(value);
    if (metrics != null) widget.onMetrics?.call(metrics);
    if (!userScroll && !seeking) return;
    final first = WeightedProgress.firstVisible(value);
    if (first == null) return;
    final source = chunks.source(first.index, WeightedProgress.withinOf(first));
    final within = source.$2;
    final last = reported;
    // Only a real move is saved: another paragraph, or a clear step inside a
    // long one.
    if (last != null &&
        last.$1 == source.$1 &&
        (last.$2 - within).abs() < .02) {
      return;
    }
    debounce?.cancel();
    final index = source.$1;
    debounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      reported = (index, within);
      seeking = false;
      widget.onPosition(index, within);
    });
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 720;
    return NotificationListener<UserScrollNotification>(
      onNotification: (notification) {
        userScroll = notification.direction != ScrollDirection.idle;
        return false;
      },
      child: LayoutBuilder(
        builder: (context, constraints) {
          seeker.viewportExtent = constraints.maxHeight;
          return ScrollablePositionedList.builder(
            itemCount: chunks.chunks.length,
            initialScrollIndex: chunks
                .locate(widget.position, widget.initialWithin)
                .$1,
            itemScrollController: widget.controller,
            scrollOffsetController: offsets,
            itemPositionsListener: positions,
            padding: EdgeInsets.symmetric(
              horizontal: wide ? widget.margin * 2 : widget.margin,
              vertical: wide ? 40 : 24,
            ),
            itemBuilder: (context, index) => Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: double.infinity),
                child: Padding(
                  padding: EdgeInsets.only(
                    bottom:
                        chunks.chunks[index].end ==
                            widget
                                .paragraphs[chunks.chunks[index].paragraph]
                                .length
                        ? widget.paragraphGap
                        : 0,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (index == 0 &&
                          chunks.text(index).trim() != widget.title.trim())
                        Padding(
                          padding: const EdgeInsets.only(bottom: 28),
                          child: Text(
                            widget.title,
                            style: TextStyle(
                              fontSize: widget.fontSize * 1.5,
                              height: 1.3,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      SelectableText(
                        chunks.text(index),
                        onSelectionChanged: (selection, _) => widget
                            .onSelectionActive
                            ?.call(!selection.isCollapsed),
                        contextMenuBuilder: widget.contextMenuBuilder,
                        style: TextStyle(
                          fontSize:
                              index == 0 &&
                                  chunks.text(index).trim() ==
                                      widget.title.trim()
                              ? widget.fontSize * 1.5
                              : widget.fontSize,
                          height: widget.lineHeight,
                          fontFamily: widget.fontFamily,
                          fontWeight: widget.fontWeight,
                          fontFamilyFallback: const ['SimSun', 'serif'],
                          letterSpacing: .3,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
