// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:async';
import 'dart:math';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/reader_api.dart';
import 'dashboard_data.dart';

String sessionId() {
  final random = Random.secure();
  final b = List.generate(16, (_) => random.nextInt(256));
  b[6] = b[6] & 15 | 64;
  b[8] = b[8] & 63 | 128;
  final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// Monotonic foreground time. Checkpoints replace a session instead of adding it.
/// A one-second sample splits local days; background/overlays stop the stopwatch.
class ReadingTracker {
  final ReaderApi api;
  final String book;
  final DateTime Function() now;
  final Stopwatch clock;
  late String day, id;
  late int startedAt;
  int elapsed = 0, position = 0, total = 0;
  String? error;
  Future<void> _pending = Future.value();
  ReadingTracker(
    this.api,
    this.book, {
    DateTime Function()? now,
    Stopwatch? clock,
  }) : now = now ?? DateTime.now,
       clock = clock ?? Stopwatch() {
    day = calendarDay(this.now());
    id = sessionId();
    startedAt = this.now().millisecondsSinceEpoch;
  }
  void resume() {
    if (total > 0) clock.start();
  }

  void sample() {
    final delta = clock.elapsedMilliseconds;
    clock.reset();
    final nextDay = calendarDay(now());
    if (nextDay != day) {
      // Allocate the elapsed sample across midnight rather than assigning it all
      // to the day on which the checkpoint happens.
      final current = now();
      final sinceMidnight = current
          .difference(DateTime(current.year, current.month, current.day))
          .inMilliseconds;
      final todayPart = delta.clamp(0, sinceMidnight);
      elapsed += delta - todayPart;
      unawaited(flush());
      day = nextDay;
      id = sessionId();
      startedAt = current.millisecondsSinceEpoch - todayPart;
      elapsed = todayPart;
    } else {
      elapsed += delta;
    }
  }

  Future<void> checkpoint() {
    sample();
    return flush();
  }

  Future<void> pause() {
    sample();
    clock.stop();
    return flush();
  }

  Future<void> flush() {
    if (total <= 0) return Future.value();
    final payload = <String, dynamic>{
      'id': id,
      'actor': '00000000-0000-0000-0000-000000000000',
      'book': book,
      'day': day,
      'started_at': startedAt,
      'elapsed_ms': elapsed,
      'position': position,
      'total': total,
    };
    final future = _pending.then((_) async {
      try {
        final prefs = await SharedPreferences.getInstance();
        final key = 'reading-pending.v1.${payload['id']}';
        if (!await prefs.setString(key, jsonEncode(payload))) {
          throw StateError('阅读统计暂存失败');
        }
        await api.call('reading_checkpoint', payload);
        await prefs.remove(key);
        error = null;
      } catch (e) {
        error = e.toString();
      }
    });
    _pending = future;
    return future;
  }
}

Future<List<String>> recoverReadingCheckpoints(ReaderApi api) async {
  final prefs = await SharedPreferences.getInstance();
  final errors = <String>[];
  for (final key in prefs.getKeys().where(
    (k) => k.startsWith('reading-pending.v1.'),
  )) {
    try {
      await api.call(
        'reading_checkpoint',
        Map<String, dynamic>.from(jsonDecode(prefs.getString(key)!)),
      );
      await prefs.remove(key);
    } catch (e) {
      errors.add('有阅读会话尚未转存，暂存已保留：$e');
    }
  }
  return errors;
}
