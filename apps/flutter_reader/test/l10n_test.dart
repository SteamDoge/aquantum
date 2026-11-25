// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.

import 'dart:io';
import 'dart:ui';

import 'package:aquantum_reader/l10n/l10n.dart';
import 'package:aquantum_reader/l10n/strings_en.dart';
import 'package:aquantum_reader/l10n/strings_zh_hant.dart';
import 'package:flutter_test/flutter_test.dart';

final _han = RegExp(r'[\u3400-\u9fff]');
final _trCall = RegExp(
  r'''\btr\(\s*(?:'((?:\\.|[^'\\\n])*)'|"((?:\\.|[^"\\\n])*)")''',
);
final _literal = RegExp(r'''(?:'(?:\\.|[^'\\\n])*'|"(?:\\.|[^"\\\n])*")''');
final _placeholderName = RegExp(r'\{(\w+)');

/// Drops comments and lines marked `l10n-keep` (text that is matched rather
/// than shown, such as patterns for parsing Chinese input).
String _code(String source) => source
    .split('\n')
    .where((line) => !line.contains('l10n-keep'))
    .map((line) {
      final trimmed = line.trimLeft();
      if (trimmed.startsWith('//')) return '';
      var start = 0;
      while (true) {
        final at = line.indexOf('//', start);
        if (at < 0) return line;
        final before = line.substring(0, at);
        if ("'".allMatches(before).length.isEven &&
            '"'.allMatches(before).length.isEven) {
          return before;
        }
        start = at + 2;
      }
    })
    .join('\n');

String _unescape(String raw) => raw.replaceAllMapped(
  RegExp(r'\\(.)'),
  (m) => switch (m[1]) {
    'n' => '\n',
    't' => '\t',
    _ => m[1]!,
  },
);

Set<String> _placeholders(String text) => {
  for (final match in _placeholderName.allMatches(text)) match[1]!,
};

void main() {
  final sources = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .where((file) => !file.uri.pathSegments.contains('l10n'))
      .toList();

  test('every interface string goes through tr and is translated', () {
    final keys = <String>{};
    final problems = <String>[];
    for (final file in sources) {
      final code = _code(file.readAsStringSync());
      for (final match in _trCall.allMatches(code)) {
        final raw = match[1] ?? match[2]!;
        if (RegExp(r'(^|[^\\])\$').hasMatch(raw)) {
          problems.add('${file.path}: interpolation inside tr key: $raw');
        }
        keys.add(_unescape(raw));
      }
      for (final match in _literal.allMatches(code.replaceAll(_trCall, ''))) {
        if (_han.hasMatch(match[0]!)) {
          problems.add('${file.path}: untranslated literal ${match[0]}');
        }
      }
    }
    for (final key in keys) {
      if (!enStrings.containsKey(key)) problems.add('missing en: $key');
      if (!zhHantStrings.containsKey(key)) {
        problems.add('missing zh-Hant: $key');
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('catalogs share keys and placeholders', () {
    expect(
      enStrings.keys.toSet().difference(zhHantStrings.keys.toSet()),
      isEmpty,
    );
    expect(
      zhHantStrings.keys.toSet().difference(enStrings.keys.toSet()),
      isEmpty,
    );
    for (final MapEntry(:key, :value) in [
      ...enStrings.entries,
      ...zhHantStrings.entries,
    ]) {
      expect(value.trim(), isNotEmpty, reason: key);
      expect(_placeholders(value), _placeholders(key), reason: key);
    }
    for (final MapEntry(:key, :value) in enStrings.entries) {
      expect(_han.hasMatch(value), isFalse, reason: '$key → $value');
    }
  });

  test('system preference resolves from the device locale order', () {
    UiLanguage system(List<Locale> locales) =>
        resolveLanguage(AppLanguage.system, locales);
    expect(system(const [Locale('zh', 'CN')]), UiLanguage.zhHans);
    expect(system(const [Locale('zh', 'TW')]), UiLanguage.zhHant);
    expect(system(const [Locale('zh', 'HK')]), UiLanguage.zhHant);
    expect(
      system(const [
        Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
      ]),
      UiLanguage.zhHant,
    );
    expect(
      system(const [
        Locale.fromSubtags(
          languageCode: 'zh',
          scriptCode: 'Hans',
          countryCode: 'HK',
        ),
      ]),
      UiLanguage.zhHans,
    );
    expect(system(const [Locale('en', 'US')]), UiLanguage.en);
    expect(system(const [Locale('ja'), Locale('zh', 'TW')]), UiLanguage.zhHant);
    expect(system(const [Locale('fr')]), UiLanguage.en);
    expect(system(const []), UiLanguage.en);
    expect(
      resolveLanguage(AppLanguage.zhHant, const [Locale('en')]),
      UiLanguage.zhHant,
    );
    expect(AppLanguage.parse('zh-Hant'), AppLanguage.zhHant);
    expect(AppLanguage.parse('unknown'), AppLanguage.system);
  });

  test('tr substitutes arguments and chooses plural words', () {
    addTearDown(() => initLanguage(AppLanguage.zhHans));
    initLanguage(AppLanguage.zhHans);
    expect(tr('跟随系统'), '跟随系统');
    expect(tr('未收录的文字'), '未收录的文字');
    initLanguage(AppLanguage.en);
    expect(tr('跟随系统'), 'System default');
    expect(tr('未收录的文字'), '未收录的文字');
    initLanguage(AppLanguage.zhHant);
    expect(tr('跟随系统'), '跟隨系統');
  });
}
