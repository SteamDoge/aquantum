// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.

import 'package:flutter/widgets.dart';

import 'strings_en.dart';
import 'strings_zh_hant.dart';

/// Interface language preference; [system] follows the device locale list.
enum AppLanguage {
  system('system'),
  zhHans('zh-Hans'),
  en('en'),
  zhHant('zh-Hant');

  const AppLanguage(this.code);

  /// Stable value written to settings.
  final String code;

  static AppLanguage parse(String? code) => values.firstWhere(
    (language) => language.code == code,
    orElse: () => system,
  );
}

/// A language the interface is rendered in. Simplified Chinese is the source
/// text; the other languages are looked up from their catalogs.
enum UiLanguage {
  zhHans(
    Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hans',
      countryCode: 'CN',
    ),
    '简体中文',
  ),
  en(Locale('en'), 'English'),
  zhHant(
    Locale.fromSubtags(
      languageCode: 'zh',
      scriptCode: 'Hant',
      countryCode: 'TW',
    ),
    '繁體中文',
  );

  const UiLanguage(this.locale, this.nativeName);
  final Locale locale;

  /// Endonym shown in the language picker; never translated.
  final String nativeName;
}

final List<Locale> supportedUiLocales = [
  for (final language in UiLanguage.values) language.locale,
];

/// Picks the first supported language in the device preference order.
/// Chinese without a script uses the region: TW, HK and MO are Traditional.
/// Devices with no Chinese or English preference use English.
UiLanguage resolveLanguage(AppLanguage preference, List<Locale> system) {
  switch (preference) {
    case AppLanguage.zhHans:
      return UiLanguage.zhHans;
    case AppLanguage.en:
      return UiLanguage.en;
    case AppLanguage.zhHant:
      return UiLanguage.zhHant;
    case AppLanguage.system:
      break;
  }
  for (final locale in system) {
    if (locale.languageCode == 'zh') {
      return switch (locale.scriptCode) {
        'Hant' => UiLanguage.zhHant,
        'Hans' => UiLanguage.zhHans,
        _ =>
          const {'TW', 'HK', 'MO'}.contains(locale.countryCode)
              ? UiLanguage.zhHant
              : UiLanguage.zhHans,
      };
    }
    if (locale.languageCode == 'en') return UiLanguage.en;
  }
  return UiLanguage.en;
}

/// Replaces the device locale list; tests pin it so results do not depend on
/// the machine running them.
@visibleForTesting
List<Locale>? debugSystemLocales;

List<Locale> get systemLocales =>
    debugSystemLocales ?? WidgetsBinding.instance.platformDispatcher.locales;

/// Replaces the locale handed to Material. Widget tests keep Material in
/// English because `WidgetTester.pageBack` finds the back button by its
/// English "Back" tooltip.
@visibleForTesting
Locale? debugMaterialLocale;

/// The locale for MaterialApp: the interface language unless a test pins it.
Locale get materialLocale => debugMaterialLocale ?? uiLanguage.locale;

UiLanguage _current = UiLanguage.zhHans;

/// The language [tr] currently renders.
UiLanguage get uiLanguage => _current;

/// Sets the language without rebuilding; use before the first frame or from
/// `initState`.
void initLanguage(AppLanguage preference) {
  _current = resolveLanguage(preference, systemLocales);
}

/// Sets the language and rebuilds every mounted widget so text produced by
/// [tr] follows. Call from event handlers or listeners, never during build.
void applyLanguage(AppLanguage preference) {
  final next = resolveLanguage(preference, systemLocales);
  if (next == _current) return;
  _current = next;
  void rebuild(Element element) {
    element.markNeedsBuild();
    element.visitChildren(rebuild);
  }

  WidgetsBinding.instance.rootElement?.visitChildren(rebuild);
}

final RegExp _placeholder = RegExp(r'\{(\w+)(?::([^|{}]*)\|([^{}]*))?\}');

/// Translates Simplified Chinese [source] into the current language.
///
/// [source] must be a single string literal so the catalog test can find it;
/// pass dynamic parts through [args] as `{name}` placeholders. A translation
/// may write `{name:one|other}` to pick a word by whether the number is 1.
/// Text without a catalog entry is shown unchanged, which also lets messages
/// from the Rust core pass through `tr` safely.
String tr(String source, [Map<String, Object?> args = const {}]) {
  final text = switch (_current) {
    UiLanguage.zhHans => source,
    UiLanguage.en => enStrings[source] ?? source,
    UiLanguage.zhHant => zhHantStrings[source] ?? source,
  };
  if (args.isEmpty) return text;
  return text.replaceAllMapped(_placeholder, (match) {
    final name = match[1]!;
    if (!args.containsKey(name)) return match[0]!;
    final value = args[name];
    if (match[2] == null) return '$value';
    return value == 1 ? match[2]! : match[3]!;
  });
}
