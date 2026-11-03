// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import '../data/models.dart';

class BookTile extends StatelessWidget {
  final Book book;
  final VoidCallback onOpen;
  const BookTile({super.key, required this.book, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const coverColors = [
      Color(0xFF526A58),
      Color(0xFF766953),
      Color(0xFF596A75),
      Color(0xFF755D67),
    ];
    final hash = book.title.runes.fold<int>(0, (sum, c) => sum + c);
    final cover = coverColors[hash % coverColors.length];
    return Semantics(
      button: true,
      label: '打开 ${book.title}，${book.label}',
      child: InkWell(
        onTap: onOpen,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: .74,
                child: Container(
                  decoration: BoxDecoration(
                    color: cover,
                    borderRadius: BorderRadius.circular(4),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .10),
                        blurRadius: 12,
                        offset: const Offset(2, 5),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        color: Colors.black.withValues(alpha: .12),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(18),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                book.isComic
                                    ? Icons.auto_stories_outlined
                                    : Icons.menu_book_outlined,
                                color: Colors.white70,
                                size: 23,
                              ),
                              const Spacer(),
                              Text(
                                book.title,
                                maxLines: 4,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  height: 1.35,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 14),
                              Container(
                                width: 28,
                                height: 2,
                                color: Colors.white54,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                book.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
              const SizedBox(height: 5),
              Text(
                '${book.label}  ${sizeLabel(book.bytes)}',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
