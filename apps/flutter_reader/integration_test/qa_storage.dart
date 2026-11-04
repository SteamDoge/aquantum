// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:io';
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

/// Real filesystem preferences and paths inside a fresh QA directory. No mock
/// preferences and no changes to the user's existing app support folder.
Future<void> configureQaStorage() async {
  final root = Platform.environment['AQ_TEST_SUPPORT'];
  if (!Platform.isWindows || root == null) return;
  await Directory(root).create(recursive: true);
  final paths = _QaPaths(root);
  PathProviderPlatform.instance = paths;
  final preferences = SharedPreferencesWindows()..pathProvider = paths;
  SharedPreferencesStorePlatform.instance = preferences;
}

class _QaPaths extends PathProviderWindows {
  final String root;
  _QaPaths(this.root);
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}
