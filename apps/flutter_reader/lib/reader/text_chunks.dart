// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
/// Bounded display runs; source paragraph identities and UTF-16 offsets stay intact.
class TextChunk {
  final int paragraph, start, end;
  const TextChunk(this.paragraph, this.start, this.end);
}

class TextChunks {
  static const maxLength = 2048;
  static final _cache = Expando<TextChunks>();
  final List<String> paragraphs;
  final chunks = <TextChunk>[];
  final first = <int>[];
  factory TextChunks.of(List<String> paragraphs) =>
      _cache[paragraphs] ??= TextChunks._(paragraphs);
  TextChunks._(this.paragraphs) {
    for (var p = 0; p < paragraphs.length; p++) {
      first.add(chunks.length);
      final text = paragraphs[p];
      var start = 0;
      do {
        var end = (start + maxLength).clamp(0, text.length);
        if (end < text.length) {
          final newline = text.lastIndexOf('\n', end - 1);
          if (newline > start + maxLength ~/ 2) end = newline + 1;
          final last = text.codeUnitAt(end - 1);
          if (last >= 0xd800 && last <= 0xdbff) end--;
        }
        chunks.add(TextChunk(p, start, end));
        start = end;
      } while (start < text.length);
    }
  }
  String text(int i) {
    final c = chunks[i];
    return paragraphs[c.paragraph].substring(c.start, c.end);
  }

  (int, double) locate(int paragraph, double within) {
    final p = paragraph.clamp(0, paragraphs.length - 1);
    final offset = within.clamp(0.0, 1.0) * paragraphs[p].length;
    var i = first[p];
    while (i + 1 < chunks.length &&
        chunks[i + 1].paragraph == p &&
        offset >= chunks[i].end) {
      i++;
    }
    final c = chunks[i];
    return (
      i,
      c.end == c.start
          ? 0
          : ((offset - c.start) / (c.end - c.start)).clamp(0.0, 1.0),
    );
  }

  (int, double) source(int i, double within) {
    final c = chunks[i];
    final length = paragraphs[c.paragraph].length;
    return (
      c.paragraph,
      length == 0 ? 0 : (c.start + (c.end - c.start) * within) / length,
    );
  }

  double weight(int i) {
    final c = chunks[i];
    return (c.end - c.start) +
        (c.end == paragraphs[c.paragraph].length ? 8.0 : 0.0);
  }
}
