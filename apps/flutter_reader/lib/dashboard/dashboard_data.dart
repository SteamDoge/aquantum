// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/foundation.dart';
import '../data/models.dart';

String calendarDay(DateTime time) =>
    '${time.year.toString().padLeft(4, '0')}-${time.month.toString().padLeft(2, '0')}-${time.day.toString().padLeft(2, '0')}';
String readingDuration(int milliseconds) {
  final seconds = milliseconds ~/ 1000;
  return '${seconds ~/ 3600}:${(seconds ~/ 60 % 60).toString().padLeft(2, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';
}

class ReadingVisit {
  final String id, bookId, day;
  final int startedAt, milliseconds, position, total;
  ReadingVisit(Map<String, dynamic> json)
    : id = json['id'],
      bookId = json['book'],
      day = json['day'],
      startedAt = json['started_at'],
      milliseconds = json['elapsed_ms'],
      position = json['position'],
      total = json['total'];
}

/// One immutable calculation per snapshot, shared by both dashboards.
class DashboardData {
  final LibrarySnapshot library;
  final DateTime now;
  late final List<ReadingVisit> sessions = List.unmodifiable(
    (library.catalog['reading_sessions'] as List? ?? [])
        .where((s) => s['actor'] == library.catalog['actor'])
        .map((s) => ReadingVisit(Map<String, dynamic>.from(s))),
  );
  late final Map<String, int> daily = _daily();
  late final Map<String, ReadingVisit> latest = _latest();
  late final List<Book> recent = List.unmodifiable(
    library.books.where((b) => latest.containsKey(b.id)).toList()..sort(
      (a, b) => latest[b.id]!.startedAt.compareTo(latest[a.id]!.startedAt),
    ),
  );
  DashboardData(this.library, {DateTime? now}) : now = now ?? DateTime.now();
  Map<String, int> _daily() {
    final result = <String, int>{};
    for (final s in sessions) {
      result.update(
        s.day,
        (n) => n + s.milliseconds,
        ifAbsent: () => s.milliseconds,
      );
    }
    return Map.unmodifiable(result);
  }

  Map<String, ReadingVisit> _latest() {
    final result = <String, ReadingVisit>{};
    for (final s in sessions) {
      final old = result[s.bookId];
      if (old == null || s.startedAt >= old.startedAt) result[s.bookId] = s;
    }
    return Map.unmodifiable(result);
  }

  int get today => daily[calendarDay(now)] ?? 0;
  List<DateTime> get week =>
      List.generate(7, (i) => DateTime(now.year, now.month, now.day - 6 + i));
  int get streak {
    var day = DateTime(now.year, now.month, now.day);
    if ((daily[calendarDay(day)] ?? 0) == 0) {
      day = DateTime(day.year, day.month, day.day - 1);
    }
    var count = 0;
    while ((daily[calendarDay(day)] ?? 0) > 0) {
      count++;
      day = DateTime(day.year, day.month, day.day - 1);
    }
    return count;
  }

  List<ReadingVisit> get annual =>
      sessions.where((s) => s.day.startsWith('${now.year}-')).toList();
  int get yearTime => annual.fold(0, (n, s) => n + s.milliseconds);
  int get yearBooks => annual.map((s) => s.bookId).toSet().length;
  int get completedBooks => annual
      .where((s) => s.total > 0 && s.position + 1 == s.total)
      .map((s) => s.bookId)
      .toSet()
      .length;
  String progress(Book book) {
    final visit = latest[book.id];
    if (visit == null || visit.total == 0) return '尚无阅读记录';
    // A document has no page count before it is laid out, so it reports how
    // far through the text the saved anchor sits instead of a page ratio.
    final percent = library.documentPercent(book);
    if (percent != null) return '读到 $percent%';
    final measured = library.contentFraction(book);
    if (measured != null) return '读到 ${(measured * 100).round()}%';
    final pos = library.position(book) + 1;
    if (!book.isComic && !book.isPdf) return '读到第 $pos 段';
    return '$pos/${visit.total} 页 · ${(pos / visit.total * 100).clamp(0, 100).round()}%';
  }

  double? fraction(Book book) =>
      library.contentFraction(book) ??
      (book.isDocument
          ? (library.documentPercent(book) ?? 0) / 100
          : book.isComic || book.isPdf
          ? ((library.position(book) + 1) / (latest[book.id]?.total ?? 1))
                .clamp(0.0, 1.0)
          : null);

  String lastRead(Book book) {
    final visit = latest[book.id];
    if (visit == null) return '未读';
    if (visit.day == calendarDay(now)) return '今天';
    return visit.day;
  }
}

class DashboardDataSource extends ChangeNotifier {
  DashboardData? value;
  void update(LibrarySnapshot library) {
    value = DashboardData(library);
    notifyListeners();
  }
}
