// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Android's picker copies files into the app cache. Resolve only that trusted
/// directory alias; leave each selected child untouched for native link checks.
Future<String> pickedCachePath(String path) async {
  if (!Platform.isAndroid) return path;
  final cache = await getTemporaryDirectory();
  final prefix = '${cache.path}/';
  if (!path.startsWith(prefix)) return path;
  final canonical = await cache.resolveSymbolicLinks();
  return '$canonical/${path.substring(prefix.length)}';
}
