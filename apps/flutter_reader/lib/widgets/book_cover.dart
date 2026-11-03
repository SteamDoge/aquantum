// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:typed_data';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../data/models.dart';
import '../data/reader_api.dart';
import 'comic_page.dart';

/// Visible covers request one managed image; text documents use a typographic cover.
class BookCover extends StatefulWidget {
  final Book book;
  final ReaderApi api;
  const BookCover({super.key, required this.book, required this.api});
  @override
  State<BookCover> createState() => _BookCoverState();
}

class _BookCoverState extends State<BookCover> {
  Future<Uint8List>? cover() => widget.book.metadata['cover'] != null
      ? widget.api.call('book_cover', {'book': widget.book.id}).then((value) {
          if (value is! String) throw const FormatException('封面不可用');
          return base64Decode(value);
        })
      : widget.book.isComic && widget.book.pages.isNotEmpty
      ? ComicPage.load(widget.api, widget.book, widget.book.pages.first['id'])
      : null;
  late Future<Uint8List>? image = cover();

  @override
  void didUpdateWidget(covariant BookCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.book != widget.book || oldWidget.api != widget.api) {
      image = cover();
    }
  }

  @override
  Widget build(BuildContext context) {
    final seed = widget.book.id.codeUnits.fold<int>(
      0,
      (a, b) => (a * 31 + b) & 0x7fffffff,
    );
    const inks = [
      Color(0xff31537d),
      Color(0xff806049),
      Color(0xff3a6059),
      Color(0xff655d80),
    ];
    final fallback = Semantics(
      label: '封面：${widget.book.title}',
      image: true,
      child: ExcludeSemantics(
        child: MediaQuery.withNoTextScaling(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: inks[seed % inks.length],
              borderRadius: BorderRadius.circular(6),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x20112842),
                  blurRadius: 8,
                  offset: Offset(2, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: CustomPaint(
                painter: const _BookDecoration(),
                child: LayoutBuilder(
                  builder: (context, constraints) => constraints.maxWidth < 50
                      ? Icon(
                          Icons.menu_book_outlined,
                          color: const Color(0xfffff9ef),
                        )
                      : Padding(
                          padding: EdgeInsets.all(
                            (constraints.maxWidth * .12).clamp(8.0, 18.0),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                widget.book.label,
                                maxLines: 1,
                                style: TextStyle(
                                  color: Colors.white70,
                                  fontSize: (constraints.maxWidth * .06).clamp(
                                    8.0,
                                    11.0,
                                  ),
                                  letterSpacing: 1.2,
                                ),
                              ),
                              const Spacer(flex: 2),
                              Text(
                                widget.book.title,
                                maxLines: 5,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: const Color(0xfffff9ef),
                                  fontWeight: FontWeight.w500,
                                  height: 1.35,
                                  fontSize: (constraints.maxWidth * .15).clamp(
                                    11.0,
                                    24.0,
                                  ),
                                ),
                              ),
                              const Spacer(flex: 3),
                              Text(
                                'AQuantum',
                                maxLines: 1,
                                style: TextStyle(
                                  color: Colors.white60,
                                  fontSize: (constraints.maxWidth * .045).clamp(
                                    7.0,
                                    9.0,
                                  ),
                                  letterSpacing: 1,
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    if (image == null) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: FutureBuilder<Uint8List>(
        future: image,
        builder: (c, r) => r.hasData
            ? Image.memory(
                r.data!,
                fit: BoxFit.cover,
                cacheWidth: 320,
                errorBuilder: (_, _, _) => fallback,
              )
            : fallback,
      ),
    );
  }
}

class _BookDecoration extends CustomPainter {
  const _BookDecoration();
  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()
      ..color = const Color(0x30ffffff)
      ..style = PaintingStyle.stroke
      ..strokeWidth = .7;
    final center = Offset(size.width * .91, size.height * .7);
    for (final factor in [.15, .29, .43, .57]) {
      canvas.drawCircle(center, size.width * factor, line);
    }
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width * .045, size.height),
      Paint()..color = const Color(0x30102238),
    );
    canvas.drawLine(
      Offset(size.width * .045, 0),
      Offset(size.width * .045, size.height),
      Paint()
        ..color = const Color(0x33ffffff)
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_BookDecoration oldDelegate) => false;
}
