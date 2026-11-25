// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
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
import 'l10n/l10n.dart';

/// Device preference holding [AppLanguage.code]; absent means follow system.
const languagePreferenceKey = 'appearance.language.v1';

AppLanguage _savedLanguage(SharedPreferences preferences) {
  final saved = preferences.get(languagePreferenceKey);
  return AppLanguage.parse(saved is String ? saved : null);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Resolve the interface language before the first frame so it never
  // flashes in another language.
  try {
    initLanguage(_savedLanguage(await SharedPreferences.getInstance()));
  } catch (_) {
    initLanguage(AppLanguage.system);
  }
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
        locale: materialLocale,
        supportedLocales: supportedUiLocales,
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: SelectableText(
                tr('资料库选择记录无法读取，原记录和资料保留。\n{error}', {'error': error}),
              ),
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

class _ReaderAppState extends State<ReaderApp> with WidgetsBindingObserver {
  late ReaderApi api = widget.api;
  late PluginPackageStore? packages = widget.pluginPackages;
  late final LibraryLocations? locations =
      widget.libraryLocations ??
      (widget.api is RustReaderApi
          ? LibraryLocations((widget.api as RustReaderApi).root)
          : null);
  ThemeMode mode = ThemeMode.system;
  AqPalette palette = AqPalette.lucent;
  AppLanguage language = AppLanguage.system;
  bool canRollback = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    if (language == AppLanguage.system) applyLanguage(language);
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
        language = _savedLanguage(pref);
      });
      applyLanguage(language);
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
      throw StateError(tr('无法保存颜色主题，当前选择未改变'));
    }
    if (mounted) setState(() => palette = value);
  }

  Future<void> setLanguage(AppLanguage value) async {
    final pref = await SharedPreferences.getInstance();
    if (!await pref.setString(languagePreferenceKey, value.code)) {
      throw StateError(tr('无法保存语言设置，当前选择未改变'));
    }
    if (!mounted) return;
    setState(() => language = value);
    applyLanguage(value);
  }

  Future<void> restoreLibrary(Map<String, dynamic> restored) async {
    final previous = api;
    if (previous is! RustReaderApi || locations == null) {
      throw StateError(tr('当前运行入口未配置资料库切换。'));
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
      throw FormatException(tr('恢复副本身份复核失败。'));
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
        throw StateError(
          tr('切换未完成，原资料库保留。设置回退失败：{rollback}；恢复前快照：{checkpoint}', {
            'rollback': rollback,
            'checkpoint': checkpoint,
          }),
        );
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
    if (data == null) throw StateError(tr('没有恢复前的资料库记录。'));
    await restoreLibrary(data);
  }

  @override
  Widget build(BuildContext context) => AqAppearance(
    palette: palette,
    onChanged: setPalette,
    language: language,
    onLanguageChanged: setLanguage,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'AQuantum Reader',
      locale: materialLocale,
      supportedLocales: supportedUiLocales,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
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
