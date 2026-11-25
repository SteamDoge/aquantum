// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/models.dart';
import '../widgets/book_cover.dart';
import '../data/reader_api.dart';
import '../screens/library_actions.dart' show NameDialog;
import 'dashboard_data.dart';
import 'widget_registry.dart';
import '../l10n/l10n.dart';

class ReadingGoal extends ChangeNotifier {
  Map<String, int> history = {};
  String? error;
  int at(String day) {
    final keys = history.keys.where((d) => d.compareTo(day) <= 0).toList()
      ..sort();
    return keys.isEmpty ? 5 : history[keys.last]!;
  }

  Future<void> load() async {
    try {
      final raw = (await SharedPreferences.getInstance()).getString(
        'reading-goal.v1',
      );
      if (raw != null) {
        final data = jsonDecode(raw);
        if (data is! Map || data['version'] != 1 || data['history'] is! Map) {
          throw FormatException(tr('阅读目标版本不支持'));
        }
        final parsed = Map<String, int>.from(data['history']);
        if (parsed.values.any((m) => m < 1 || m > 1440)) {
          throw FormatException(tr('阅读目标配置无效'));
        }
        history = parsed;
      }
    } catch (e) {
      error = e.toString();
    }
    notifyListeners();
  }

  Future<void> set(int minutes) async {
    if (error != null) throw StateError(error!);
    if (minutes < 1 || minutes > 1440) throw StateError(tr('请输入 1–1440 分钟'));
    final next = {...history, calendarDay(DateTime.now()): minutes};
    if (!await (await SharedPreferences.getInstance()).setString(
      'reading-goal.v1',
      jsonEncode({'version': 1, 'history': next}),
    )) {
      throw StateError(tr('阅读目标保存失败'));
    }
    history = next;
    notifyListeners();
  }
}

List<DashboardDefinition> coreDashboardWidgets({
  required ReaderApi api,
  required ReadingGoal goal,
  required ValueChanged<Book> onBook,
  required ValueChanged<Book> onMenu,
  required VoidCallback onStatistics,
}) {
  Widget title(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Semantics(
      header: true,
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w600,
          letterSpacing: -.2,
        ),
      ),
    ),
  );
  Widget recent(
    BuildContext context,
    DashboardData data,
    DashboardInstance config,
    bool hero,
  ) {
    final books = hero
        ? data.recent.take(1).toList()
        : data.recent
              .skip(config.skipLatest ? 1 : 0)
              .take(config.limit)
              .toList();
    if (!hero &&
        config.style != 'detailed' &&
        MediaQuery.textScalerOf(context).scale(14) < 23) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          title(tr('最近阅读')),
          if (books.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Text(tr('从资料库打开一份文件，阅读记录会显示在这里。')),
            ),
          LayoutBuilder(
            builder: (context, constraints) {
              final columns = (constraints.maxWidth / 96).floor().clamp(2, 8);
              final width =
                  (constraints.maxWidth - 14 * (columns - 1)) / columns;
              return Wrap(
                spacing: 14,
                runSpacing: 20,
                children: [
                  for (final book in books)
                    SizedBox(
                      width: width,
                      child: InkWell(
                        onTap: () => onBook(book),
                        onLongPress: () => onMenu(book),
                        onSecondaryTap: () => onMenu(book),
                        borderRadius: BorderRadius.circular(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            AspectRatio(
                              aspectRatio: 1 / 1.4,
                              child: BookCover(api: api, book: book),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              book.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 5),
                            Text(
                              '${book.label} · ${data.progress(book)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: title(hero ? tr('继续阅读') : tr('最近阅读'))),
            if (hero)
              Flexible(
                child: TextButton(
                  onPressed: onStatistics,
                  child: Text(
                    tr('查看记录'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
          ],
        ),
        if (books.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text(tr('从资料库打开一份文件，阅读记录会显示在这里。')),
          ),
        for (final book in books)
          InkWell(
            onTap: () => onBook(book),
            onLongPress: () => onMenu(book),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: hero ? 72 : 48,
                    height: hero ? 101 : 66,
                    child: BookCover(api: api, book: book),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          book.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: hero ? 18 : 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(data.progress(book)),
                        if (hero && data.fraction(book) != null) ...[
                          const SizedBox(height: 12),
                          LinearProgressIndicator(
                            value: data.fraction(book),
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ],
                        const SizedBox(height: 8),
                        Text(
                          data.lastRead(book),
                          style: TextStyle(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: tr('文件操作'),
                    onPressed: () => onMenu(book),
                    icon: const Icon(Icons.more_vert),
                  ),
                ],
              ),
            ),
          ),
        if (!hero && config.style == 'detailed') ...[
          const Divider(),
          Text(tr('最近会话')),
          for (final visit in data.sessions.reversed.take(config.limit))
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                data.library.allBooks
                        .where((b) => b.id == visit.bookId)
                        .firstOrNull
                        ?.title ??
                    tr('已移除文件'),
              ),
              subtitle: Text(
                '${visit.day} · ${readingDuration(visit.milliseconds)}',
              ),
            ),
        ],
      ],
    );
  }

  return [
    DashboardDefinition(
      id: 'core.widget.continue',
      localizedName: () => tr('继续阅读'),
      icon: Icons.auto_stories_outlined,
      render: (c, d, i, _) => recent(c, d, i, true),
    ),
    DashboardDefinition(
      id: 'core.widget.recent',
      supportsLimit: true,
      localizedName: () => tr('最近阅读'),
      icon: Icons.history,
      render: (c, d, i, _) => recent(c, d, i, false),
    ),
    DashboardDefinition(
      id: 'core.widget.goal',
      localizedName: () => tr('今日阅读目标'),
      icon: Icons.timelapse,
      render: (context, data, config, _) => AnimatedBuilder(
        animation: goal,
        builder: (context, _) {
          final minutes = goal.at(calendarDay(data.now));
          final fraction = (data.today / (minutes * 60000)).clamp(0.0, 1.0);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              title(tr('今日阅读目标')),
              if (config.style == 'compact' &&
                  MediaQuery.textScalerOf(context).scale(16) < 24)
                SizedBox(
                  height: 160,
                  child: CustomPaint(
                    painter: _GoalArc(fraction, Theme.of(context).colorScheme),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            readingDuration(data.today),
                            style: const TextStyle(
                              fontSize: 32,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          Text(
                            tr('今日前台阅读 · 目标 {minutes} 分钟', {
                              'minutes': minutes,
                            }),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              else ...[
                Text(
                  readingDuration(data.today),
                  style: const TextStyle(fontSize: 32),
                ),
                const SizedBox(height: 12),
                LinearProgressIndicator(value: fraction),
                const SizedBox(height: 12),
                Text(
                  tr('完成 {value}% · 目标 {minutes} 分钟', {
                    'value': (fraction * 100).round(),
                    'minutes': minutes,
                  }),
                ),
              ],
              TextButton(
                onPressed: () async {
                  final resultText = await showDialog<String>(
                    context: context,
                    builder: (_) => NameDialog(
                      title: tr('每日阅读目标（分钟，1–1440）'),
                      initial: '$minutes',
                    ),
                  );
                  final result = resultText == null
                      ? null
                      : int.tryParse(resultText) ?? 0;
                  if (result != null) {
                    try {
                      await goal.set(result);
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text(e.toString())));
                      }
                    }
                  }
                },
                child: Text(tr('设置阅读目标')),
              ),
              if (goal.error != null) Text(goal.error!),
            ],
          );
        },
      ),
    ),
    DashboardDefinition(
      id: 'core.widget.week',
      localizedName: () => tr('每周阅读与连续记录'),
      icon: Icons.date_range_outlined,
      render: (context, data, config, _) => AnimatedBuilder(
        animation: goal,
        builder: (context, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            title(tr('最近七天')),
            LayoutBuilder(
              builder: (context, constraints) => Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final day in data.week)
                    SizedBox(
                      width: math.max(40, (constraints.maxWidth - 48) / 7),
                      child: Column(
                        children: [
                          Text(tr('一二三四五六日')[day.weekday - 1]),
                          const SizedBox(height: 8),
                          Icon(
                            (data.daily[calendarDay(day)] ?? 0) >=
                                    goal.at(calendarDay(day)) * 60000
                                ? Icons.check_circle
                                : (data.daily[calendarDay(day)] ?? 0) > 0
                                ? Icons.timelapse
                                : Icons.circle_outlined,
                            color: (data.daily[calendarDay(day)] ?? 0) > 0
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(
                                    context,
                                  ).colorScheme.onSurfaceVariant,
                          ),
                          if (config.style == 'detailed')
                            Text(
                              tr('{value}分', {
                                'value':
                                    (data.daily[calendarDay(day)] ?? 0) ~/
                                    60000,
                              }),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(tr('连续阅读 {streak} 天', {'streak': data.streak})),
          ],
        ),
      ),
    ),
    DashboardDefinition(
      id: 'core.widget.year',
      localizedName: () => tr('年度阅读概览'),
      icon: Icons.insights_outlined,
      render: (context, data, config, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          title(tr('{year} 年阅读概览', {'year': data.now.year})),
          Text(
            readingDuration(data.yearTime),
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 12),
          Text(
            tr('阅读 {yearBooks} 份 · 到达末尾 {completedBooks} 份', {
              'yearBooks': data.yearBooks,
              'completedBooks': data.completedBooks,
            }),
          ),
          if (config.style == 'detailed') ...[
            const SizedBox(height: 16),
            for (var m = 1; m <= 12; m++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    SizedBox(
                      width: 40,
                      child: Text(
                        tr(
                          '1 月|2 月|3 月|4 月|5 月|6 月|7 月|8 月|9 月|10 月|11 月|12 月',
                        ).split('|')[m - 1],
                      ),
                    ),
                    Expanded(
                      child: LinearProgressIndicator(
                        value: data.yearTime == 0
                            ? 0
                            : data.annual
                                      .where(
                                        (s) =>
                                            s.day.substring(5, 7) ==
                                            m.toString().padLeft(2, '0'),
                                      )
                                      .fold(0, (n, s) => n + s.milliseconds) /
                                  data.yearTime,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      tr('{value} 分', {
                        'value':
                            data.annual
                                .where(
                                  (s) =>
                                      s.day.substring(5, 7) ==
                                      m.toString().padLeft(2, '0'),
                                )
                                .fold(0, (n, s) => n + s.milliseconds) ~/
                            60000,
                      }),
                    ),
                  ],
                ),
              ),
          ],
          if (config.style == 'compact')
            TextButton(onPressed: onStatistics, child: Text(tr('查看详细统计'))),
        ],
      ),
    ),
    DashboardDefinition(
      id: 'core.widget.files',
      localizedName: () => tr('项目与文件数量'),
      icon: Icons.folder_outlined,
      render: (c, d, i, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          title(tr('资料库')),
          Text(
            tr('{value} 个项目 · {count} 份文件', {
              'value': d.library.projects.length - 1,
              'count': d.library.books.length,
            }),
          ),
          if (i.style == 'detailed') ...[
            for (final f in const [
              'Txt',
              'Markdown',
              'Comic',
              'Pdf',
              'Epub',
              'Mobi',
              'Azw3',
              'Fb2',
            ])
              if (d.library.books.any((b) => b.format == f))
                Text(
                  '$f · ${d.library.books.where((b) => b.format == f).length}',
                ),
            for (final p in d.library.projects)
              Text(
                tr('{name} · {value} 份', {
                  'name': p.name,
                  'value': d.library.booksIn(p.id).length,
                }),
              ),
          ],
        ],
      ),
    ),
  ];
}

class _GoalArc extends CustomPainter {
  final double fraction;
  final ColorScheme colors;
  _GoalArc(this.fraction, this.colors);
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCenter(
      center: Offset(size.width / 2, size.height - 10),
      width: math.min(size.width - 16, 280),
      height: math.min(size.width - 16, 280),
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round
      ..color = colors.surfaceContainerHighest;
    canvas.drawArc(rect, math.pi, math.pi, false, paint);
    if (fraction > 0) {
      canvas.drawArc(
        rect,
        math.pi,
        math.pi * fraction,
        false,
        paint..color = colors.primary,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GoalArc old) =>
      old.fraction != fraction || old.colors != colors;
}
