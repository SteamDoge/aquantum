// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:aquantum_reader/reader/reader_contract.dart';
import 'package:aquantum_reader/widgets/reader_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('PDF gap choices stay visible without a continuous preference', (
    tester,
  ) async {
    final preferences = ReaderPreferences()..continuous = false;
    preferences.theme = 'dark';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, refresh) => ReaderSettingsPanel(
              preferences: preferences,
              capabilities: const ReaderCapabilities(
                settings: {ReaderSetting.imageGap},
              ),
              fontSize: 20,
              desktop: true,
              onFont: (_) {},
              onChanged: (change) => refresh(change),
            ),
          ),
        ),
      ),
    );
    expect(find.text('页面间距'), findsOneWidget);
    await tester.tap(find.text('无缝'));
    await tester.pump();
    expect(preferences.seamless, isTrue);
    expect(preferences.continuous, isFalse);
    expect(preferences.theme, 'dark');
    await tester.tap(find.text('有缝'));
    await tester.pump();
    expect(preferences.seamless, isFalse);
  });
}
