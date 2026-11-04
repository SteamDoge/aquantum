// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'dart:io';
import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    final path = Platform.environment['AQ_LONG_RESULTS']!;
    await File(
      path,
    ).writeAsString(const JsonEncoder.withIndent('  ').convert(data));
  },
);
