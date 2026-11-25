// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.

import 'dart:async';
import 'dart:ui';

import 'package:aquantum_reader/l10n/l10n.dart';

/// Integration flows assert Simplified Chinese text, so "follow system"
/// resolves to Simplified Chinese on any device. Material stays in English
/// because `WidgetTester.pageBack` looks for the "Back" tooltip.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  debugSystemLocales = const [Locale('zh', 'CN')];
  debugMaterialLocale = const Locale('en');
  initLanguage(AppLanguage.system);
  await testMain();
}
