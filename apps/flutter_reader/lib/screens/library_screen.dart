// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:io';
import '../dashboard/reading_tracker.dart';
import 'search_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../dashboard/dashboard_data.dart';
import '../dashboard/widget_registry.dart';
import '../dashboard/dashboard_layout.dart';
import '../dashboard/dashboard_screen.dart';
import '../dashboard/core_widgets.dart';
import 'library_actions.dart';
import 'dart:convert';
import 'dart:async';

import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/reader_api.dart';
import '../design/motion.dart';
import '../features/feature_registry.dart';
import '../plugins/plugin_manager.dart';
import '../plugins/plugin_package.dart';
import '../plugins/plugin_host.dart';
import '../plugins/plugin_reader.dart';
import 'package:path_provider/path_provider.dart';
import '../navigation/navigation_controller.dart';
import '../navigation/navigation_preferences.dart';
import '../navigation/navigation_shell.dart';
import '../navigation/feature_host.dart';
import 'navigation_editor.dart';
import 'plugin_screen.dart';
import 'plugin_import.dart';
import 'profile_details.dart';
import 'library_content.dart';
import 'import_dialog.dart';
import 'reader_screen.dart';
import 'profile_screen.dart';
import 'storage_maintenance.dart';

class LibraryScreen extends StatefulWidget {
  final ReaderApi api;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  final PluginPackageStore? pluginPackages;
  final PluginHostServices? pluginServices;
  final Future<void> Function(Map<String, dynamic>)? onLibraryRestored;
  final Future<void> Function()? onRestoreRollback;
  const LibraryScreen({
    super.key,
    required this.api,
    required this.themeMode,
    required this.onThemeChanged,
    this.pluginPackages,
    this.pluginServices,
    this.onLibraryRestored,
    this.onRestoreRollback,
  });
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with WidgetsBindingObserver {
  Timer? calendarRefresh;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(refresh());
      if (plugins.ready) {
        unawaited(
          plugins.resume().catchError((Object e) => notify(e.toString())),
        );
      }
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (plugins.ready) {
        unawaited(
          plugins.suspend().catchError((Object e) => notify(e.toString())),
        );
      }
    }
  }

  LibrarySnapshot? library;
  String? projectId, error;
  bool busy = false;
  String query = '';
  final searchController = TextEditingController();
  late final FeatureRegistry features;
  late final AppNavigation navigation;
  late final PluginManager plugins;
  final dashboardRegistry = DashboardRegistry();
  final dashboardData = DashboardDataSource();
  final homeLayout = DashboardLayout(DashboardPage.home);
  final statisticsLayout = DashboardLayout(DashboardPage.statistics);
  final goal = ReadingGoal();
  bool grid = true;
  String sort = 'name';
  LibraryActions get actions =>
      LibraryActions(context, library!, widget.api, plugins, act, onRead: open);
  Future<void> loadView() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      grid = prefs.getBool('project-grid.v1') ?? true;
      sort = prefs.getString('project-sort.v1') ?? 'name';
    });
  }

  Future<void> setView(bool value, String order) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString('project-sort.v1', order) ||
          !await prefs.setBool('project-grid.v1', value)) {
        throw StateError('项目视图保存失败');
      }
      if (mounted) {
        setState(() {
          grid = value;
          sort = order;
        });
      }
    } catch (e) {
      notify(e.toString());
    }
  }

  Future<void> batchMove(List<Book> books) async {
    final target = await actions.target();
    if (target != null) {
      await act(() async {
        await widget.api.call('move_books', {
          'books': books.map((b) => b.id).toList(),
          'target': target,
        });
      });
    }
  }

  NavigationProfile profile = NavigationProfile.mobile;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    calendarRefresh = Timer.periodic(const Duration(minutes: 1), (_) {
      final current = library;
      if (current != null &&
          calendarDay(DateTime.now()) !=
              calendarDay(dashboardData.value!.now)) {
        dashboardData.update(current);
      }
    });
    dashboardRegistry.registerCore(
      coreDashboardWidgets(
        api: widget.api,
        goal: goal,
        onBook: open,
        onMenu: (b) => actions.book(b),
        onStatistics: () => openFeature(FeatureRegistry.statistics),
      ),
    );
    unawaited(homeLayout.load());
    unawaited(statisticsLayout.load());
    unawaited(goal.load());
    unawaited(loadView());
    features = FeatureRegistry([
      AppFeature(
        id: 'core.statistics-api',
        name: '统计接口说明',
        icon: Icons.code_outlined,
        allowNavigation: false,
        builder: (context) => ListView(
          padding: EdgeInsets.fromLTRB(
            24,
            24,
            24,
            24 + MediaQuery.paddingOf(context).bottom,
          ),
          children: const [
            Text('统计读取接口 · API 1', style: TextStyle(fontSize: 26)),
            SizedBox(height: 16),
            SelectableText(
              '组件使用同一个只读 DashboardData 快照。\n\ntoday / daily：本地日期的前台阅读毫秒。\nweek：含今天的最近七天。\nstreak：截至今天或昨天的连续有阅读记录天数。\nyearTime / yearBooks：当年毫秒 / 唯一阅读文件数。\ncompletedBooks：到达末尾的唯一文件数，非人工确认读完。\nrecent / latest：有效书架文件的最近会话。\n\n组件定义：source.widget.id、名称、图标、适用页、样式、尺寸、依赖、renderer。实例配置：id/style/wide/limit，主页和统计分别保存。\n\n可信编译插件通过 PluginRegistrar.widget/provider 注册；每份快照复用 provider 结果。声明式 ZIP 只能使用预定只读指标，不执行代码。\n\n当前只统计本机，不回填旧版缺失的时长。跨设备同步、任意时间范围、OCR/翻译、代码沙箱和系统桌面组件待实现。完整示例见交付的插件规范与 PRODUCT_SPEC。',
              style: TextStyle(fontSize: 16, height: 1.7),
            ),
          ],
        ),
      ),
      AppFeature(
        id: 'core.search',
        name: '全文搜索',
        icon: Icons.search,
        builder: (_) => library == null
            ? _loading()
            : SearchScreen(
                api: widget.api,
                library: library!,
                onOpen: (book, paragraph) => open(book, position: paragraph),
                onIndexChanged: () => refresh(),
              ),
      ),
      AppFeature(
        id: FeatureRegistry.home,
        name: '主页',
        icon: Icons.home_outlined,
        builder: (_) => library == null
            ? _loading()
            : DashboardScreen(
                page: DashboardPage.home,
                onSearch: () => openFeature('core.search'),
                onImport: import,
                registry: dashboardRegistry,
                layout: homeLayout,
                data: dashboardData,
              ),
      ),
      AppFeature(
        id: FeatureRegistry.statistics,
        name: '阅读统计',
        icon: Icons.insights_outlined,
        builder: (_) => library == null
            ? _loading()
            : DashboardScreen(
                page: DashboardPage.statistics,
                registry: dashboardRegistry,
                layout: statisticsLayout,
                data: dashboardData,
              ),
      ),
      AppFeature(
        id: 'core.archive',
        name: '已移除文件',
        icon: Icons.restore,
        builder: (context) => library == null
            ? _loading()
            : ListView(
                padding: EdgeInsets.fromLTRB(
                  24,
                  24,
                  24,
                  24 + MediaQuery.paddingOf(context).bottom,
                ),
                children: [
                  const Text('已移除文件', style: TextStyle(fontSize: 26)),
                  const Text('副本与记录均保留，点击恢复到原项目。'),
                  for (final b in library!.allBooks.where((b) => b.archived))
                    ListTile(
                      title: Text(b.title),
                      trailing: IconButton(
                        tooltip: '恢复到书架',
                        icon: const Icon(Icons.restore),
                        onPressed: () => act(() async {
                          await widget.api.call('manage_book', {
                            'book': b.id,
                            'action': 'restore',
                          });
                        }),
                      ),
                    ),
                ],
              ),
      ),
      AppFeature(
        id: FeatureRegistry.projects,
        name: '资料库',
        icon: Icons.library_books_outlined,
        builder: (context) => library == null
            ? _loading()
            : _books(MediaQuery.sizeOf(context).width >= 840),
      ),
      AppFeature(
        id: FeatureRegistry.plugins,
        name: '插件',
        icon: Icons.extension_outlined,
        builder: (_) => PluginScreen(
          manager: plugins,
          onImport: importPlugin,
          onLink: () => importPluginRemote(),
          onUpdate: (record) => importPluginRemote(record),
        ),
      ),
      for (final section in ProfileDetail.values)
        AppFeature(
          id: 'core.${section.name}',
          name: switch (section) {
            ProfileDetail.settings => '设置',
            ProfileDetail.storage => '存储管理',
            ProfileDetail.history => '操作记录',
          },
          icon: switch (section) {
            ProfileDetail.settings => Icons.settings_outlined,
            ProfileDetail.storage => Icons.storage_outlined,
            ProfileDetail.history => Icons.history,
          },
          builder: (_) => library == null
              ? _loading()
              : ProfileDetails(
                  plugins: plugins,
                  library: library!,
                  section: section,
                  onStatisticsHelp: () => openFeature('core.statistics-api'),
                  onStorageMaintenance: () async {
                    await Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => StorageMaintenanceScreen(
                          api: widget.api,
                          onRestored: widget.onLibraryRestored,
                          onRollback: widget.onRestoreRollback,
                        ),
                      ),
                    );
                    await refresh();
                  },
                  mode: widget.themeMode,
                  onThemeChanged: (mode) {
                    widget.onThemeChanged(mode);
                    unawaited(
                      plugins.hostServices?.broker.emit('theme.changed', {
                            'brightness': mode.name,
                          }) ??
                          Future.value(),
                    );
                  },
                ),
        ),
      AppFeature(
        id: FeatureRegistry.me,
        name: '我的',
        icon: Icons.person_outline,
        builder: (_) => library == null
            ? _loading()
            : ProfileScreen(
                library: library!,
                themeMode: widget.themeMode,
                onThemeChanged: (mode) {
                  widget.onThemeChanged(mode);
                  unawaited(
                    plugins.hostServices?.broker.emit('theme.changed', {
                          'brightness': mode.name,
                        }) ??
                        Future.value(),
                  );
                },
                registry: features,
                onOpen: openFeature,
                onCustomize: customizeNavigation,
                onImportPlugin: importPlugin,
              ),
      ),
    ]);
    navigation = AppNavigation(features, DeviceNavigationStore());
    plugins = PluginManager(
      features,
      DevicePluginStore(),
      hostServices:
          widget.pluginServices ??
          PluginHostServices(
            api: widget.api,
            storageRoot: () async => widget.api is RustReaderApi
                ? '${(widget.api as RustReaderApi).root}/plugins'
                : '${(await getApplicationSupportDirectory()).path}/plugin-host-v1/plugins',
            onImported: () => unawaited(refresh()),
            onOpenFile: (pluginId, name, bytes) async {
              final base =
                  Platform.environment['AQ_READER_DATA'] ??
                  (await getApplicationSupportDirectory()).path;
              final session = await PluginReaderSession.open(
                '$base/plugin-host-v1/temp',
                name,
                bytes,
                scope: pluginId,
              );
              if (!mounted) throw StateError('宿主页面已关闭');
              // Opening acknowledges presentation; reading may last much longer
              // than a JS RPC timeout and must not hold the plugin request open.
              unawaited(
                Navigator.of(context)
                    .push(
                      ReaderMotion.route<void>(
                        context,
                        (_) => ReaderScreen(
                          api: session.api,
                          book: session.book,
                          initialPosition: session.position,
                          plugins: plugins,
                        ),
                        '/plugin-read/${session.book.id}',
                      ),
                    )
                    .then<void>(
                      (_) {},
                      onError: (Object error, StackTrace stack) {
                        if (mounted) notify(error.toString());
                      },
                    ),
              );
            },
            onOpenPage: openFeature,
            onMessage: (message) async {
              if (mounted) notify(message);
            },
            onOpenBook: (id) async {
              await refresh();
              if (mounted) {
                final book = library!.books.where((b) => b.id == id);
                if (book.isNotEmpty) await open(book.first);
              }
            },
            theme: () => {
              'brightness': Theme.of(context).brightness.name,
              'colors': {
                for (final entry in {
                  'bg': Theme.of(context).colorScheme.surface,
                  'card': Theme.of(context).colorScheme.surfaceContainer,
                  'text': Theme.of(context).colorScheme.onSurface,
                  'muted': Theme.of(context).colorScheme.onSurfaceVariant,
                  'line': Theme.of(context).colorScheme.outlineVariant,
                  'accent': Theme.of(context).colorScheme.primary,
                  'soft': Theme.of(context).colorScheme.primaryContainer,
                }.entries)
                  entry.key:
                      '#${(entry.value.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}',
              },
              'schemaVersion': 1,
            },
          ),
      dashboards: dashboardRegistry,
    );
    unawaited(loadPlugins().then((_) => navigation.load()));
    unawaited(
      recoverReadingCheckpoints(widget.api).then((errors) async {
        await refresh();
        if (mounted && errors.isNotEmpty) notify(errors.join('\n'));
      }),
    );
  }

  Future<void> loadPlugins() async {
    try {
      final packages = await widget.pluginPackages?.load();
      if (!mounted) return;
      for (final module in packages?.plugins ?? <JavaScriptPlugin>[]) {
        plugins.restorePackage(module);
      }
      if (packages != null) plugins.setInventory(packages);
    } catch (error) {
      plugins.packageErrors.add('插件包读取失败：$error');
    }
    if (mounted) await plugins.load();
  }

  @override
  void dispose() {
    calendarRefresh?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    searchController.dispose();
    navigation.dispose();
    plugins.dispose();
    features.dispose();
    dashboardRegistry.dispose();
    dashboardData.dispose();
    homeLayout.dispose();
    statisticsLayout.dispose();
    goal.dispose();
    super.dispose();
  }

  Future<void> openFeature(String id) async {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    try {
      await navigation.open(profile, id);
    } catch (error) {
      notify(error.toString());
    }
  }

  Future<void> customizeNavigation() => Navigator.of(context).push<void>(
    ReaderMotion.route<void>(
      context,
      (_) => NavigationEditor(navigation: navigation, initialProfile: profile),
      '/navigation',
    ),
  );

  Future<void> importPlugin() async {
    final packages = widget.pluginPackages;
    if (packages == null) {
      notify('当前运行入口未配置插件包目录');
      return;
    }
    if (busy || !plugins.ready || plugins.busy) return;
    setState(() => busy = true);
    try {
      await importPluginZip(context, plugins, packages);
    } catch (error) {
      notify(error.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> importPluginRemote([PluginRecord? updating]) async {
    final packages = widget.pluginPackages;
    if (packages == null || busy || !plugins.ready || plugins.busy) return;
    setState(() => busy = true);
    try {
      await importPluginLink(context, plugins, packages, updating: updating);
    } catch (e) {
      notify(e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void selectProject(String id) {
    setState(() {
      projectId = id;
      query = '';
      searchController.clear();
    });
  }

  Future<void> refresh() async {
    try {
      final result = await widget.api.call('snapshot');
      if (!mounted) return;
      setState(() {
        library = LibrarySnapshot(result);
        if (!library!.projects.any((p) => p.id == projectId)) {
          projectId = library!.inbox;
        }
        error = null;
      });
      dashboardData.update(library!);
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
        });
      }
    }
  }

  void notify(String message) {
    if (mounted) {
      final rail =
          profile == NavigationProfile.desktop ||
          MediaQuery.sizeOf(context).width >= 840;
      final expanded =
          navigation.preferences(profile).layout.expanded &&
          MediaQuery.sizeOf(context).width >= 700;
      final keyboard = MediaQuery.viewInsetsOf(context).bottom;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.fromLTRB(
            rail ? (expanded ? 236 : 84) : 16,
            0,
            16,
            keyboard > 0 ? keyboard + 16 : (rail ? 16 : 104),
          ),
        ),
      );
    }
  }

  Future<void> act(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
    });
    try {
      await action();
      await refresh();
    } catch (e) {
      notify(e.toString());
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
        });
      }
    }
  }

  Future<void> import() => act(() async {
    final changed = await pickAndImport(
      context,
      widget.api,
      projectId!,
      library!.project(projectId!).name,
    );
    if (changed) notify('已导入，原文件保留');
  });
  Future<void> createProject() async {
    var candidate = '';
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建项目'),
        content: TextField(
          onChanged: (value) => candidate = value,
          autofocus: true,
          maxLength: 80,
          decoration: const InputDecoration(labelText: '项目名称'),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, candidate),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (name != null && name.trim().isNotEmpty) {
      await act(() async {
        final id = await widget.api.call('create_project', {
          'parent': projectId,
          'name': name,
        });
        projectId = id;
      });
    }
  }

  Future<void> loadSample() => act(() async {
    const files = {
      '山间笔记.txt':
          '山间笔记\n\n清晨的山谷安静，只有风从树梢经过。走进林间时，脚步也自然放慢了。\n\n阅读也是一次缓慢的行走。不必急着到达终点，每一段停留都有它的意义。\n\n你可以调整字号、保存阅读位置，或记下此刻想到的事。下次打开时，仍从这一段开始。',
      '阅读器使用说明.md':
          '# 让书回到手边\n\n先在项目页导入文件。软件保留原文件，阅读时使用内部副本。\n\n## 当前版本\n\n支持 TXT、Markdown、PDF、EPUB、MOBI、AZW3、FB2 与图片漫画。不同格式的阅读设置按实际能力显示。\n\n## 阅读笔记\n\n打开一本书，选择“记笔记”。笔记和原书通过固定编号关联。',
    };
    await widget.api.call('import_files', {
      'target': projectId,
      'files': files.entries
          .map(
            (e) => {'name': e.key, 'data': base64Encode(utf8.encode(e.value))},
          )
          .toList(),
    });
    notify('示例已加入当前项目');
  });
  Future<void> open(Book book, {int? position}) async {
    plugins.hostServices?.currentReader = {
      'bookId': book.id,
      'title': book.title,
      'format': book.format,
    };
    unawaited(
      plugins.hostServices?.broker.emit('file.opened', {
            'bookId': book.id,
            'format': book.format,
          }) ??
          Future.value(),
    );
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    await Navigator.of(context).push(
      ReaderMotion.route<void>(
        context,
        (_) => ReaderScreen(
          api: widget.api,
          book: book,
          initialPosition: position ?? library!.position(book),
          plugins: plugins,
        ),
        '/read/${book.id}',
      ),
    );
    if (mounted) ScaffoldMessenger.of(context).hideCurrentSnackBar();
    plugins.hostServices?.currentReader = null;
    await refresh();
  }

  @override
  Widget build(BuildContext context) {
    profile = switch (Theme.of(context).platform) {
      TargetPlatform.windows ||
      TargetPlatform.linux ||
      TargetPlatform.macOS => NavigationProfile.desktop,
      _ => NavigationProfile.mobile,
    };
    return AnimatedBuilder(
      animation: Listenable.merge([navigation, plugins]),
      builder: (context, _) {
        final selected = navigation.selected(profile);
        final atRoot =
            projectId == null ||
            library == null ||
            library!.project(projectId!).parent == null;
        final canPop =
            (selected == FeatureRegistry.home ||
            (selected == FeatureRegistry.projects && atRoot && query.isEmpty));
        return PopScope(
          canPop: canPop,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            if (selected != FeatureRegistry.projects) {
              openFeature(
                selected == FeatureRegistry.me
                    ? FeatureRegistry.home
                    : FeatureRegistry.me,
              );
            } else if (query.isNotEmpty) {
              selectProject(projectId!);
            } else if (!atRoot) {
              selectProject(library!.project(projectId!).parent!);
            }
          },
          child: Scaffold(
            // Navigation stays in window coordinates; the shell gives only
            // page content the keyboard inset (including HTML plugin pages).
            resizeToAvoidBottomInset: false,
            body: NavigationShell(
              navigation: navigation,
              profile: profile,
              onOpen: openFeature,
              onToggleExpanded: () async {
                try {
                  await navigation.setExpanded(
                    profile,
                    !navigation.preferences(profile).layout.expanded,
                  );
                } catch (error) {
                  notify(error.toString());
                }
              },
              projectTree: library == null
                  ? null
                  : Column(
                      children: [
                        const Divider(),
                        for (final project in library!.projects)
                          Padding(
                            padding: EdgeInsets.only(
                              left:
                                  ((library!.ancestors(project.id).length - 1)
                                              .clamp(0, 4) *
                                          8)
                                      .toDouble(),
                            ),
                            child: ListTile(
                              dense: true,
                              selected:
                                  selected == FeatureRegistry.projects &&
                                  projectId == project.id,
                              leading: const Icon(
                                Icons.folder_outlined,
                                size: 18,
                              ),
                              title: Text(
                                project.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              onTap: () {
                                selectProject(project.id);
                                openFeature(FeatureRegistry.projects);
                              },
                            ),
                          ),
                      ],
                    ),
              child: Column(
                children: [
                  if (busy) const LinearProgressIndicator(minHeight: 2),
                  Expanded(
                    child: navigation.ready
                        ? FeatureHost(registry: features, selected: selected)
                        : const Center(child: CircularProgressIndicator()),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _loading() => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: error == null
          ? const CircularProgressIndicator()
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('资料库暂时无法打开', style: TextStyle(fontSize: 22)),
                const SizedBox(height: 16),
                SelectableText(error!),
                const SizedBox(height: 24),
                FilledButton(onPressed: refresh, child: const Text('重试')),
              ],
            ),
    ),
  );
  Widget _books(bool wide) => LibraryContent(
    library: library!,
    api: widget.api,
    grid: grid,
    sort: sort,
    onView: setView,
    onBookMenu: (b) => actions.book(b),
    onProjectMenu: (p) => actions.project(p),
    onBatch: batchMove,
    searchController: searchController,
    projectId: projectId!,
    query: query,
    wide: wide,
    busy: busy,
    onImport: import,
    onCreateProject: createProject,
    onSample: loadSample,
    onBook: open,
    onProject: selectProject,
    onSearch: (value) => setState(() {
      query = value;
    }),
  );
}
