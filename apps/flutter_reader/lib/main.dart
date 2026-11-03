// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/reader_api.dart';
import 'data/library_locations.dart';
import 'data/backup_preferences.dart';
import 'design/theme.dart';
import 'design/appearance.dart';
import 'plugins/plugin_package.dart';
import 'plugins/plugin_host.dart';
import 'screens/library_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final support =
      Platform.environment['AQ_READER_DATA'] ??
      '${(await getApplicationSupportDirectory()).path}/plugin-host-v1';
  await Directory(support).create(recursive: true);
  final locations = LibraryLocations(support);
  String active;
  try {
    await locations.recoverInterruptedSwitches();
    active = await locations.current();
  } catch (error) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SelectableText('资料库选择记录无法读取，原记录和资料保留。\n$error'),
            ),
          ),
        ),
      ),
    );
    return;
  }
  runApp(
    ReaderApp(
      api: RustReaderApi(active),
      pluginPackages: FilePluginPackageStore('$active/plugins/packages'),
      libraryLocations: locations,
    ),
  );
}

class ReaderApp extends StatefulWidget {
  final ReaderApi api;
  final PluginPackageStore? pluginPackages;
  final PluginHostServices? pluginServices;
  final LibraryLocations? libraryLocations;
  const ReaderApp({
    super.key,
    required this.api,
    this.pluginPackages,
    this.pluginServices,
    this.libraryLocations,
  });
  @override
  State<ReaderApp> createState() => _ReaderAppState();
}

class _ReaderAppState extends State<ReaderApp> {
  late ReaderApi api = widget.api;
  late PluginPackageStore? packages = widget.pluginPackages;
  late final LibraryLocations? locations =
      widget.libraryLocations ??
      (widget.api is RustReaderApi
          ? LibraryLocations((widget.api as RustReaderApi).root)
          : null);
  ThemeMode mode = ThemeMode.system;
  AqPalette palette = AqPalette.lucent;
  bool canRollback = false;
  @override
  void initState() {
    super.initState();
    _loadTheme();
    locations
        ?.latest()
        .then((value) {
          if (mounted) setState(() => canRollback = value?['previous'] != null);
        })
        .catchError((Object _) {
          /* Startup already validates the selected record. */
        });
  }

  Future<void> _loadTheme() async {
    final pref = await SharedPreferences.getInstance();
    final saved = pref.getString('theme');
    if (mounted) {
      setState(() {
        mode = ThemeMode.values.firstWhere(
          (m) => m.name == saved,
          orElse: () => ThemeMode.system,
        );
        final savedPalette = pref.get('appearance.palette.v1');
        palette = AqPalette.parse(savedPalette is String ? savedPalette : null);
      });
    }
  }

  Future<void> setTheme(ThemeMode value) async {
    setState(() {
      mode = value;
    });
    final pref = await SharedPreferences.getInstance();
    await pref.setString('theme', value.name);
  }

  Future<void> setPalette(AqPalette value) async {
    final pref = await SharedPreferences.getInstance();
    if (!await pref.setString('appearance.palette.v1', value.name)) {
      throw StateError('无法保存颜色主题，当前选择未改变');
    }
    if (mounted) setState(() => palette = value);
  }

  Future<void> restoreLibrary(Map<String, dynamic> restored) async {
    final previous = api;
    if (previous is! RustReaderApi || locations == null) {
      throw StateError('当前运行入口未配置资料库切换。');
    }
    await previous.idle;
    // The native Windows host can return an MSIX-virtualized canonical path.
    // Address this task's recovered copy through the same root namespace as
    // the current Dart session, then validate its marker and library identity.
    final candidate = restored['task'] is String
        ? '${previous.root}/recovered-libraries/${restored['task']}'
        : restored['root'] as String;
    final root = await locations!.resolve(await locations!.relative(candidate));
    final next = RustReaderApi(root, libraryPath: previous.libraryPath);
    final state = await next.call('snapshot');
    if (restored['library'] != null &&
        state['catalog']['id'] != restored['library']) {
      throw const FormatException('恢复副本身份复核失败。');
    }
    final oldPreferences = await preferenceSnapshot();
    final checkpoint = await retainPreferenceSnapshot(
      previous.root,
      oldPreferences,
    );
    final intent = await locations!.beginSwitch(previous.root, checkpoint);
    try {
      await applyPreferenceSnapshot(
        restoredPreferenceSnapshot(
          Map<String, dynamic>.from(restored['device_preferences']),
        ),
      );
      await locations!.select(
        root,
        previousRoot: previous.root,
        previousPreferences: checkpoint,
      );
    } catch (error) {
      try {
        await applyPreferenceSnapshot(oldPreferences);
        await locations!.finishSwitch(intent);
      } catch (rollback) {
        throw StateError('切换未完成，原资料库保留。设置回退失败：$rollback；恢复前快照：$checkpoint');
      }
      rethrow;
    }
    try {
      await locations!.finishSwitch(intent);
    } catch (_) {
      // The selected record already committed; startup can reconcile the
      // retained intent without rolling back a successful root selection.
    }
    if (mounted) {
      setState(() {
        api = next;
        packages = FilePluginPackageStore('$root/plugins/packages');
        canRollback = true;
      });
      await _loadTheme();
    }
  }

  Future<void> rollbackRestore() async {
    final data = await locations?.rollbackData();
    if (data == null) throw StateError('没有恢复前的资料库记录。');
    await restoreLibrary(data);
  }

  @override
  Widget build(BuildContext context) => AqAppearance(
    palette: palette,
    onChanged: setPalette,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AQuantum Reader',
      theme: readerTheme(Brightness.light, palette: palette),
      darkTheme: readerTheme(Brightness.dark, palette: palette),
      themeMode: mode,
      home: LibraryScreen(
        key: ValueKey(api),
        api: api,
        pluginPackages: packages,
        pluginServices: widget.pluginServices,
        onLibraryRestored: locations == null ? null : restoreLibrary,
        onRestoreRollback: locations == null || !canRollback
            ? null
            : rollbackRestore,
        themeMode: mode,
        onThemeChanged: setTheme,
      ),
    ),
  );
}
