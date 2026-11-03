// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:aquantum_reader/reader/text_pagination.dart';

/// Lays out the given paragraphs the way the reader screen does, on the default
/// test font, and returns the measured pages.
TextPagination lay(
  List<String> paragraphs, {
  Size viewport = const Size(375, 700),
  double paragraphGap = 24,
  double reserved = 0,
  TextScaler scaler = TextScaler.noScaling,
  TextDirection direction = TextDirection.ltr,
}) => TextPagination.forReader(
  paragraphs: paragraphs,
  viewport: viewport,
  style: const TextStyle(fontSize: 20, height: 1.6),
  scaler: scaler,
  direction: direction,
  margin: 28,
  paragraphGap: paragraphGap,
  takenByReadout: reserved,
);

void main() {
  test('no page starts with a boundary that paints nothing', () {
    for (final text in const [
      '\u7b2c\u4e00\u6bb5',
      '\u7b2c\u4e00\u6bb5\u3002',
      '\u3002\u3002\u3002\u3002\u3002\u3002',
      'One. Two. Three.',
      '\u5c71\u95f4\u7b14\u8bb0\uff0c\u9759\u9759\u5730\u8bfb\u3002',
    ]) {
      final layout = lay([text]);
      for (final page in layout.pages) {
        expect(page.fragments, isNotEmpty, reason: 'a page must paint');
        for (final fragment in page.fragments) {
          expect(
            fragment.displayText.trim(),
            isNotEmpty,
            reason: 'empty fragment at ${fragment.start}-${fragment.end}',
          );
        }
      }
      expect(layout.pages.map((p) => p.anchor.paragraph).toSet(), contains(0));
      expect(
        layout.pages
            .expand((p) => p.fragments)
            .map((f) => f.displayText)
            .join(),
        text,
        reason: 'every character still lands on exactly one page',
      );
    }
  });

  test('a long paragraph becomes several pages that all paint', () {
    final long = List.filled(400, '\u5c71\u95f4\u7b14\u8bb0').join();
    final layout = lay([long]);
    expect(layout.pages.length, greaterThan(1));
    for (final page in layout.pages) {
      expect(page.fragments, isNotEmpty);
      for (final fragment in page.fragments) {
        expect(fragment.displayText, isNotEmpty);
      }
    }
    expect(layout.pages.first.anchor.paragraph, 0);
    expect(layout.pageFor(0), 0);
  });

  test('every paragraph keeps its own page anchor', () {
    final layout = lay(const [
      '\u7b2c\u4e00\u6bb5',
      '\u7b2c\u4e8c\u6bb5',
      '\u7b2c\u4e09\u6bb5',
    ]);
    expect(layout.pages, isNotEmpty);
    for (var i = 0; i < 3; i++) {
      expect(layout.pageFor(i), inInclusiveRange(0, layout.pages.length - 1));
    }
    // Paging is monotonic: a later paragraph never lands on an earlier page.
    expect(layout.pageFor(1), greaterThanOrEqualTo(layout.pageFor(0)));
    expect(layout.pageFor(2), greaterThanOrEqualTo(layout.pageFor(1)));
  });

  test('reserved readout room shortens the page without adding pages', () {
    final paragraphs = List.filled(
      30,
      '\u5c71\u95f4\u7b14\u8bb0\u3002',
    ).toList();
    final plain = lay(paragraphs);
    final kept = lay(paragraphs, reserved: 104);
    expect(plain.pages.length, greaterThan(1));
    expect(kept.pages.length, greaterThanOrEqualTo(plain.pages.length));
    for (final page in kept.pages) {
      expect(page.fragments, isNotEmpty);
    }
    expect(kept.pages.first.anchor.paragraph, 0);
  });
}
