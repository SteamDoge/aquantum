// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import 'reader_contract.dart';
import '../design/widgets.dart';

/// Real, scaled page canvases, not a detached thumbnail list or fake neighbours.
class ReaderPageOverview extends StatefulWidget {
  final PagedReaderAdapter adapter;
  final Size pageSize;
  final Color? paperColor;
  final VoidCallback onActivate;

  /// Where to start, so a linear position (a percentage of a reflowed book)
  /// does not have to pretend every page is the same length.
  final int initialPage;
  const ReaderPageOverview({
    super.key,
    required this.adapter,
    required this.pageSize,
    this.paperColor,
    required this.onActivate,
    this.initialPage = 0,
  });
  @override
  State<ReaderPageOverview> createState() => _ReaderPageOverviewState();
}

class _ReaderPageOverviewState extends State<ReaderPageOverview> {
  PageController? pages;
  double fraction = 0;
  PageController get controller => pages!;
  bool dragging = false;
  @override
  void didUpdateWidget(covariant ReaderPageOverview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.adapter.count != widget.adapter.count) dragging = false;
    if (!dragging && oldWidget.adapter.position != widget.adapter.position) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            controller.hasClients &&
            !dragging &&
            (controller.page! - widget.adapter.position).abs() > .01) {
          controller.jumpToPage(widget.adapter.position);
        }
      });
    }
  }

  @override
  void dispose() {
    pages?.dispose();
    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) => NotificationListener<ScrollNotification>(
    onNotification: (event) {
      if (event is ScrollStartNotification && event.dragDetails != null) {
        dragging = true;
      }
      if (event is ScrollEndNotification) dragging = false;
      return false;
    },
    child: LayoutBuilder(
      builder: (context, constraints) {
        // Match slots to the scaled paper width, including short landscape
        // windows. Otherwise height-limited pages leave gaps hiding neighbours.
        final aspect = widget.pageSize.width / widget.pageSize.height;
        final paper = ((constraints.maxHeight - 24) * aspect).clamp(
          0.0,
          constraints.maxWidth * .78 - 20,
        );
        final next = ((paper + 20) / constraints.maxWidth).clamp(.2, .78);
        if (pages == null || (fraction - next).abs() > .001) {
          final previous = pages;
          fraction = next;
          pages = PageController(
            initialPage: widget.initialPage.clamp(0, widget.adapter.count - 1),
            viewportFraction: fraction,
          );
          if (previous != null) {
            WidgetsBinding.instance.addPostFrameCallback(
              (_) => previous.dispose(),
            );
          }
        }
        return PageView.builder(
          key: const ValueKey('reader-page-overview'),
          controller: controller,
          reverse: widget.adapter.rightToLeft,
          itemCount: widget.adapter.count,
          // Clamping a replaced layout or syncing an external position is not
          // a reading action. Only a real gesture may write a new source place.
          onPageChanged: (index) {
            if (dragging) widget.adapter.goTo(index);
          },
          itemBuilder: (context, index) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
            child: Semantics(
              button: true,
              label: '第 ${index + 1} 页，轻点返回沉浸阅读',
              child: GestureDetector(
                onTap: () {
                  if (index != widget.adapter.position) {
                    widget.adapter.goTo(index);
                  }
                  widget.onActivate();
                },
                child: FittedBox(
                  fit: BoxFit.contain,
                  child: SizedBox(
                    key: ValueKey('reader-overview-page-$index'),
                    width: widget.pageSize.width,
                    height: widget.pageSize.height,
                    child: DecoratedBox(
                      position: DecorationPosition.foreground,
                      decoration: BoxDecoration(
                        border: Border(
                          left: BorderSide(
                            color: readerPaperEdge(
                              widget.paperColor ??
                                  Theme.of(context).scaffoldBackgroundColor,
                            ),
                            width: widget.pageSize.width / paper,
                          ),
                          right: BorderSide(
                            color: readerPaperEdge(
                              widget.paperColor ??
                                  Theme.of(context).scaffoldBackgroundColor,
                            ),
                            width: widget.pageSize.width / paper,
                          ),
                          top: BorderSide(
                            color: readerPaperEdge(
                              widget.paperColor ??
                                  Theme.of(context).scaffoldBackgroundColor,
                            ),
                            width: widget.pageSize.width / paper,
                          ),
                          bottom: BorderSide(
                            color: readerPaperEdge(
                              widget.paperColor ??
                                  Theme.of(context).scaffoldBackgroundColor,
                            ),
                            width: widget.pageSize.width / paper,
                          ),
                        ),
                      ),
                      child: ClipRect(
                        child: IgnorePointer(
                          child:
                              widget.adapter.buildPage(
                                context,
                                index,
                                preview: true,
                              ) ??
                              _PageUnavailable(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

/// A page the renderer cannot rebuild; the grid never fakes its contents.
class _PageUnavailable extends StatelessWidget {
  const _PageUnavailable();
  @override
  Widget build(BuildContext context) => Center(
    child: Icon(
      Icons.menu_book_outlined,
      size: 32,
      color: Theme.of(context).colorScheme.outline,
    ),
  );
}
