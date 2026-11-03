// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/services.dart';

import '../design/motion.dart';
import '../design/widgets.dart';
import '../formats/document_reader.dart';
import '../formats/document_engine.dart';
import '../plugins/plugin_api.dart';
import 'reader_bookmarks.dart';
import 'reader_contract.dart';
import 'reader_extensions.dart';
import 'reader_panels.dart';
import 'reader_toolbar.dart';
import 'reader_page_overview.dart';
import 'reader_interaction.dart';
import 'reader_scrollbar.dart';
import 'reader_motion.dart';
import 'toolbar_preferences.dart';
import '../screens/toolbar_editor.dart';

/// Sole owner of chrome, modal presentation, hit regions and fixed actions.
class ReaderShell extends StatefulWidget {
  final ReaderAdapter adapter;
  final bool desktop;
  final String dock;
  final Widget Function(BuildContext, VoidCallback) settingsBuilder;
  final ReaderExtensions extensions;
  final Future<void> Function(PluginAction) invokeExtension;
  final Future<void> Function(Future<void> Function()) runOverlay;
  final Future<void> Function() addNote, showNotes;

  /// Asks the host to persist the reading place now (a panel opened, the app
  /// left the foreground). Renderers without a store of their own omit it.
  final Future<void> Function()? onSaveRequested;

  /// Turns the page by [delta] when the adapter drives a live surface; the
  /// shell's own page grid and index arithmetic cannot move a browser page.
  final Future<void> Function(int delta)? onTurn;

  /// Optional panels. `null` hides the entry instead of showing an empty panel,
  /// so a renderer that cannot reinterpret bytes or image direction never
  /// pretends the feature exists.
  final WidgetBuilder? encodingBuilder, directionBuilder;

  /// Whole-book position of top-to-bottom reading for the scrollbar. Without
  /// it the scrollbar falls back to the adapter's own position and count.
  final ReaderScrollSource? scroll;
  final Color? paperColor;
  const ReaderShell({
    super.key,
    required this.adapter,
    required this.desktop,
    required this.dock,
    required this.settingsBuilder,
    required this.extensions,
    required this.invokeExtension,
    required this.runOverlay,
    required this.addNote,
    required this.showNotes,
    this.onSaveRequested,
    this.onTurn,
    this.encodingBuilder,
    this.directionBuilder,
    this.scroll,
    this.paperColor,
  });
  @override
  State<ReaderShell> createState() => _ReaderShellState();
}

/// The one bottom controller every renderer shares. Its height, two text lines
/// included, lets a fixed-page reader keep a page clear of it.
const readerProgressHeight = 104.0;

class _ReaderShellState extends State<ReaderShell> {
  ToolbarLayout toolbarLayout = ToolbarLayout.defaults();
  bool customToolbar = false;
  String? toolbarError;
  Future<void> loadToolbar() async {
    try {
      final result = await ToolbarPreferences().load();
      if (mounted) {
        setState(() {
          toolbarLayout = result;
          customToolbar = result.encode() != ToolbarLayout.defaults().encode();
        });
      }
    } catch (e) {
      if (mounted) setState(() => toolbarError = e.toString());
    }
  }

  void pluginChanged() {
    if (mounted) setState(() {});
  }

  Future<void> editToolbar() async {
    await Navigator.of(context).push(
      MaterialPageRoute<bool>(
        builder: (_) => ToolbarEditor(plugins: widget.extensions.plugins),
      ),
    );
    await loadToolbar();
  }

  late bool visible = widget.desktop && widget.dock != 'hidden';
  late final bookmarkStore = ReaderBookmarkStore(widget.adapter.documentId);
  List<ReaderBookmark> bookmarks = [];
  String? bookmarkError;
  late final Future<void> bookmarksLoaded;
  bool bookmarksReady = false, bookmarkBusy = false, panelOpen = false;
  Offset? down;
  Duration? downAt;
  final pointers = <int>{};
  final controlPointers = <int>{};
  bool cancelled = false;
  VoidCallback? refreshPanel;
  StreamSubscription<DocumentEvent>? _surfaceEvents;
  ReaderAdapter get adapter => widget.adapter;

  /// A live browser surface hides nothing: the page grid cannot redraw it.
  bool get liveSurface =>
      adapter is LiveReaderAdapter &&
      (adapter as LiveReaderAdapter).liveSurface;

  /// The shell shows the scaled page grid instead of the page itself.
  bool get grid =>
      adapter.paged && adapter is PagedReaderAdapter && !liveSurface;

  /// Navigates to a location a panel handed back. A renderer that can target
  /// the place itself (a chapter href, a text anchor) does so; otherwise the
  /// location's linear index is the position.
  void goToLocation(ReaderLocation location) {
    final target = adapter;
    if (target is LocationReaderAdapter) {
      unawaited(target.goToLocation(location));
      return;
    }
    adapter.goTo(location.index);
  }

  /// Item-count position for a renderer that reports nothing finer.
  late final indexScroll = IndexScrollSource(moveTo);
  ReaderScrollSource get scrollSource => widget.scroll ?? indexScroll.source;

  @override
  void initState() {
    super.initState();
    bookmarksLoaded = loadBookmarks();
    unawaited(loadToolbar());
    widget.extensions.plugins?.addListener(pluginChanged);
    connectSurface();
    indexScroll.update(adapter.position, adapter.count);
  }

  void connectSurface() {
    unawaited(_surfaceEvents?.cancel());
    final target = adapter;
    if (target is DocumentReaderAdapter) {
      _surfaceEvents = target.engine.events.listen((event) {
        if (!mounted || panelOpen) return;
        if (event.name == 'surface-turn') {
          final delta = event.detail['delta'];
          if (delta is num && !adapter.interactionLocked) {
            turnPage(delta < 0 ? -1 : 1);
          }
          return;
        }
        if (event.name != 'surface-tap') return;
        final x = event.detail['x'], y = event.detail['y'];
        if (x is num && y is num) {
          tap(Offset(x.toDouble(), y.toDouble()), const Size(1, 1));
        }
      });
    }
  }

  @override
  void dispose() {
    widget.extensions.plugins?.removeListener(pluginChanged);
    unawaited(_surfaceEvents?.cancel());
    indexScroll.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ReaderShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.extensions.plugins != widget.extensions.plugins) {
      oldWidget.extensions.plugins?.removeListener(pluginChanged);
      widget.extensions.plugins?.addListener(pluginChanged);
    }
    indexScroll.update(adapter.position, adapter.count);
    if (panelOpen) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && panelOpen) refreshPanel?.call();
      });
    }
    if (!identical(oldWidget.adapter, widget.adapter)) connectSurface();
    if (widget.desktop && oldWidget.dock != widget.dock) {
      visible = widget.dock != 'hidden';
    }
  }

  Future<void> loadBookmarks() async {
    try {
      final result = await bookmarkStore.load();
      if (mounted) {
        setState(() {
          bookmarks = result;
          bookmarksReady = true;
        });
      }
    } catch (e) {
      if (mounted) setState(() => bookmarkError = e.toString());
    }
  }

  void tap(Offset point, Size size) {
    // A grid owns its own page taps. Live surfaces report filtered document
    // taps through the engine channel so both platforms use these same rules.
    if (adapter.interactionLocked || panelOpen || (visible && grid)) {
      return;
    }
    // The document channel filters links, selections and drags before routing
    // a tap through the same regions as every other renderer.
    {
      final action = readerTapAction(
        point: point,
        size: size,
        chromeVisible: visible,
        paged: adapter.paged,
        rightToLeft: adapter.rightToLeft,
        verticalTurn: adapter.verticalTurn,
      );
      switch (action) {
        case ReaderTapAction.toggleChrome:
          setState(() => visible = !visible);
        // Turn bands exist only on discrete pages; a continuous scroll never
        // gets here (see [readerTapAction]).
        case ReaderTapAction.previous:
          if (canTurn(-1)) turnPage(-1);
        case ReaderTapAction.next:
          if (canTurn(1)) turnPage(1);
      }
      return;
    }
  }

  /// A live page turns through the host; an indexed page moves by index,
  /// because a reflowed document's percentage counter is not a page number.
  void turnPage(int delta) {
    final turn = widget.onTurn;
    if (liveSurface && turn != null) {
      unawaited(turn(delta));
    } else {
      adapter.goTo(adapter.position + delta);
    }
  }

  /// Whether the shell can reach [index]. A count of zero means the book has no
  /// readable position yet, so nothing is reachable — the same rule for every
  /// renderer, including one that keeps its own linear progress.
  bool reachable(int index) =>
      adapter.count > 0 && index >= 0 && index < adapter.count;

  bool canTurn(int delta) => adapter is PageTurnBoundaryReaderAdapter
      ? (delta < 0
            ? (adapter as PageTurnBoundaryReaderAdapter).canTurnBackward
            : (adapter as PageTurnBoundaryReaderAdapter).canTurnForward)
      : reachable(adapter.position + delta);

  /// A slider seeks progress; it never guesses a physical turn from a 0.1% step.
  void moveTo(int index) {
    if (reachable(index)) adapter.goTo(index);
  }

  int get sliderMax => adapter.count > 1 ? adapter.count - 1 : 0;

  double get sliderValue =>
      adapter.count <= 1 ? 0 : adapter.position.clamp(0, sliderMax).toDouble();

  double get sliderRange => sliderMax.toDouble();

  String get sliderLabel =>
      adapter is DocumentReaderAdapter && adapter.unit == '%'
      ? '${((adapter as DocumentReaderAdapter).fraction * 100).toStringAsFixed(1)}%'
      : adapter.count == 0
      ? '0'
      : '${adapter.position + 1}';

  String get positionText =>
      adapter is DocumentReaderAdapter && adapter.unit == '%'
      ? sliderLabel
      : adapter.count == 0
      ? '0 / 0 ${adapter.unit}'
      : '${adapter.position + 1} / ${adapter.count} ${adapter.unit}';

  Future<void> toggleBookmark(StateSetter update) async {
    if (!bookmarksReady || bookmarkBusy || adapter.count == 0) return;
    final location = adapter.location(adapter.position);
    final next = [...bookmarks];
    if (next.any((b) => b.locationId == location.id)) {
      next.removeWhere((b) => b.locationId == location.id);
    } else {
      next.add(ReaderBookmark(location.id, location.label));
    }
    await persistBookmarks(next, update);
  }

  Future<void> persistBookmarks(
    List<ReaderBookmark> next,
    StateSetter update,
  ) async {
    update(() => bookmarkBusy = true);
    try {
      await bookmarkStore.save(next);
      if (mounted) {
        setState(() => bookmarks = next);
        update(() {});
      }
    } catch (e) {
      if (mounted) update(() => bookmarkError = e.toString());
    } finally {
      bookmarkBusy = false;
      if (mounted) {
        setState(() {});
        update(() {});
      }
    }
  }

  Future<void> openPanel(ReaderPanel panel) async {
    if (panelOpen) return;
    panelOpen = true;
    // A panel is a pause: the host stores the place before the sheet covers
    // the page, so a crash while it is open never loses the read.
    try {
      await widget.onSaveRequested?.call();
    } catch (_) {
      // Saving is the host's business; a lookup panel must still open.
    }
    ReaderPanel? nextPanel;
    try {
      if (panel == ReaderPanel.bookmarks) await bookmarksLoaded;
      if (!mounted) return;
      await widget.runOverlay(() async {
        final result = await showModalBottomSheet<Object>(
          context: context,
          useSafeArea: true,
          showDragHandle: false,
          isScrollControlled: true,
          sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
              ? AnimationStyle.noAnimation
              : AnimationStyle(
                  duration: ReaderMotion.navigation,
                  reverseDuration: ReaderMotion.navigation,
                ),
          builder: (sheetContext) => StatefulBuilder(
            builder: (context, update) {
              refreshPanel = () {
                if (context.mounted) update(() {});
              };
              void safeUpdate(VoidCallback change) {
                if (context.mounted) update(change);
              }

              Widget buildSheet() => Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.viewInsetsOf(context).bottom,
                ),
                child: SizedBox(
                  height:
                      (MediaQuery.sizeOf(context).height -
                          MediaQuery.viewInsetsOf(context).bottom) *
                      .84,
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                panelTitle(panel),
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                            ),
                            IconButton(
                              tooltip: '关闭面板',
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                        Expanded(
                          child: panelContent(panel, context, safeUpdate),
                        ),
                        if (widget.extensions.actions(panel).isNotEmpty) ...[
                          const Divider(),
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 150),
                            child: ListView(
                              shrinkWrap: true,
                              children: [
                                for (final action
                                    in widget.extensions
                                        .actions(panel)
                                        .where(
                                          (a) =>
                                              panel != ReaderPanel.more ||
                                              !toolbarLayout.hidden.contains(
                                                a.id,
                                              ),
                                        ))
                                  ListTile(
                                    leading: Icon(action.icon),
                                    title: Text(action.name),
                                    onTap: () => Navigator.pop(context, action),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              );
              final manager = widget.extensions.plugins;
              return manager == null
                  ? buildSheet()
                  : ListenableBuilder(
                      listenable: manager,
                      builder: (_, _) => buildSheet(),
                    );
            },
          ),
        );
        if (!mounted) return;
        if (result is ReaderPanel) nextPanel = result;
        if (result is ReaderLocation) goToLocation(result);
        if (result is int) adapter.goTo(result);
        if (result is PluginAction) await widget.invokeExtension(result);
        if (result == 'note') await widget.addNote();
        if (result == 'notes') await widget.showNotes();
        if (result == 'hide') setState(() => visible = false);
        if (result == 'toolbar') await editToolbar();
      });
    } finally {
      refreshPanel = null;
      panelOpen = false;
    }
    if (mounted && nextPanel != null) await openPanel(nextPanel!);
  }

  String panelTitle(ReaderPanel panel) => switch (panel) {
    ReaderPanel.format => '阅读处理器',
    ReaderPanel.settings => '阅读设置',
    ReaderPanel.navigation => adapter.capabilities.navigationLabel,
    ReaderPanel.view => '阅读视图与页面导航',
    ReaderPanel.search => '搜索',
    ReaderPanel.bookmarks => '书签',
    ReaderPanel.more => '更多',
    ReaderPanel.encoding => '文字编码',
    ReaderPanel.direction => '阅读方向',
  };
  Widget panelContent(
    ReaderPanel panel,
    BuildContext context,
    StateSetter update,
  ) => switch (panel) {
    ReaderPanel.format => const Center(child: Text('请在软件设置中选择阅读器。')),
    ReaderPanel.encoding =>
      widget.encodingBuilder?.call(context) ??
          const Center(child: Text('当前内容不是可识别的文字块。')),
    ReaderPanel.direction =>
      widget.directionBuilder?.call(context) ??
          const Center(child: Text('当前内容没有可调整的页面方向。')),
    ReaderPanel.settings => widget.settingsBuilder(
      context,
      () => update(() {}),
    ),
    ReaderPanel.navigation || ReaderPanel.view => ReaderNavigationPanel(
      adapter: adapter,
      thumbnails: panel == ReaderPanel.view,
      onSelect: (location) => Navigator.pop(context, location),
    ),
    ReaderPanel.search => ReaderSearchPanel(
      adapter: adapter,
      onSelect: (location) => Navigator.pop(context, location),
    ),
    ReaderPanel.bookmarks => bookmarkPanel(context, update),
    ReaderPanel.more => ListView(
      children: [
        if (toolbarError != null) Text(toolbarError!),
        ListTile(
          leading: const Icon(Icons.tune),
          title: const Text('编辑工具栏'),
          onTap: () => Navigator.pop(context, 'toolbar'),
        ),
        for (final native in readerToolbarOrder)
          if (!toolbarLayout.pinned.contains(toolbarCoreId(native)) &&
              !toolbarLayout.hidden.contains(toolbarCoreId(native)))
            ListTile(
              leading: ReaderToolbar.glyph(native),
              title: Text(ReaderToolbar.label(native)),
              onTap: () {
                final panel = switch (native) {
                  ReaderToolbarAction.settings => ReaderPanel.settings,
                  ReaderToolbarAction.navigation => ReaderPanel.navigation,
                  ReaderToolbarAction.view => ReaderPanel.view,
                  ReaderToolbarAction.bookmarks => ReaderPanel.bookmarks,
                  ReaderToolbarAction.search => ReaderPanel.search,
                  _ => ReaderPanel.more,
                };
                Navigator.pop(context, panel);
              },
            ),
        ListTile(
          leading: const Icon(Icons.edit_note_outlined),
          title: const Text('记笔记'),
          onTap: adapter.count > 0
              ? () => Navigator.pop(context, 'note')
              : null,
        ),
        ListTile(
          leading: const Icon(Icons.notes_outlined),
          title: const Text('关联笔记'),
          onTap: () => Navigator.pop(context, 'notes'),
        ),
        if (widget.encodingBuilder != null)
          ListTile(
            leading: const Icon(Icons.translate_outlined),
            title: const Text('文字编码'),
            subtitle: const Text('识别不确定时手动指定，原文件不改动'),
            onTap: () => Navigator.pop(context, ReaderPanel.encoding),
          ),
        if (widget.directionBuilder != null)
          ListTile(
            leading: const Icon(Icons.swap_horiz_outlined),
            title: const Text('阅读方向'),
            subtitle: const Text('按项目默认或单本覆盖'),
            onTap: () => Navigator.pop(context, ReaderPanel.direction),
          ),
        ListTile(
          leading: const Icon(Icons.fullscreen),
          title: const Text('隐藏阅读工具'),
          onTap: () => Navigator.pop(context, 'hide'),
        ),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text('轻点阅读区域顶部可再次显示工具栏。'),
        ),
      ],
    ),
  };
  Widget bookmarkPanel(BuildContext context, StateSetter update) {
    if (!adapter.capabilities.bookmarks) {
      return const Center(child: Text('当前渲染器未提供稳定阅读位置，暂不支持书签。'));
    }
    final currentLocation = adapter.count > 0
        ? adapter.location(adapter.position).id
        : null;
    final currentBookmark = bookmarks.indexWhere(
      (bookmark) => bookmark.locationId == currentLocation,
    );
    return Column(
      children: [
        if (bookmarkError != null) Text(bookmarkError!),
        if (!bookmarksReady && bookmarkError == null)
          const LinearProgressIndicator(),
        OutlinedButton.icon(
          onPressed: bookmarksReady && !bookmarkBusy && adapter.count > 0
              ? () => toggleBookmark(update)
              : null,
          icon: const Icon(Icons.bookmark_add_outlined),
          label: Text(
            adapter.count > 0 &&
                    bookmarks.any(
                      (b) =>
                          b.locationId == adapter.location(adapter.position).id,
                    )
                ? '移除当前位置书签'
                : '添加当前位置书签',
          ),
        ),
        Expanded(
          child: bookmarks.isEmpty
              ? const Center(child: Text('还没有书签。'))
              : ScrollablePositionedList.builder(
                  key: ValueKey((
                    'bookmarks',
                    adapter.documentId,
                    currentLocation,
                    bookmarks.length,
                  )),
                  itemCount: bookmarks.length,
                  initialScrollIndex: currentBookmark < 0 ? 0 : currentBookmark,
                  initialAlignment: .35,
                  itemBuilder: (context, i) {
                    final bookmark = bookmarks[i];
                    return ListTile(
                      selected: bookmark.locationId == currentLocation,
                      title: Text(
                        bookmark.label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle:
                          adapter.resolveLocation(bookmark.locationId) == null
                          ? const Text('来源位置已不可用，书签保留')
                          : null,
                      onTap:
                          adapter.resolveLocation(bookmark.locationId) == null
                          ? null
                          : () => Navigator.pop(
                              context,
                              ReaderLocation(
                                bookmark.locationId,
                                bookmark.label,
                                adapter.resolveLocation(bookmark.locationId) ??
                                    adapter.position,
                              ),
                            ),
                      trailing: IconButton(
                        tooltip: '删除书签',
                        onPressed: bookmarkBusy
                            ? null
                            : () => persistBookmarks(
                                bookmarks.where((b) => b != bookmark).toList(),
                                update,
                              ),
                        icon: const Icon(Icons.delete_outline),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  void action(ReaderToolbarAction action) {
    if (action == ReaderToolbarAction.back) {
      Navigator.maybePop(context);
      return;
    }
    openPanel(switch (action) {
      ReaderToolbarAction.settings => ReaderPanel.settings,
      ReaderToolbarAction.navigation => ReaderPanel.navigation,
      ReaderToolbarAction.view => ReaderPanel.view,
      ReaderToolbarAction.bookmarks => ReaderPanel.bookmarks,
      ReaderToolbarAction.search => ReaderPanel.search,
      _ => ReaderPanel.more,
    });
  }

  Widget animateChrome(Widget child, Offset offset) => ExcludeSemantics(
    excluding: !visible,
    child: IgnorePointer(
      ignoring: !visible,
      child: AnimatedSlide(
        offset: visible ? Offset.zero : offset,
        duration: ReaderMotion.duration(context, ReaderMotion.navigation),
        curve: ReaderMotion.curve,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: ReaderMotion.duration(context, ReaderMotion.navigation),
          child: child,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    // The bottom page controller belongs to discrete horizontal pagination.
    // Continuous readers use the right rail instead, so changing a page gap or
    // a scroll direction cannot accidentally reserve bottom space.
    final showProgress = adapter.paged;
    final side =
        adapter.paged &&
        widget.desktop &&
        {'left', 'right'}.contains(widget.dock);
    // A saved bottom dock belongs to discrete pages only. Continuous reading
    // always mounts its toolbar at the top, while preserving the preference.
    final bottom = adapter.paged && widget.desktop && widget.dock == 'bottom';
    final paper =
        widget.paperColor ?? Theme.of(context).scaffoldBackgroundColor;
    final topChrome = 80.0 + MediaQuery.textScalerOf(context).scale(12) * 1.5;
    final available = toolbarItems(widget.extensions.plugins);
    final buttons = ReaderToolbar(
      vertical: side,
      onAction: action,
      customButtons: !customToolbar
          ? null
          : [
              for (final id in toolbarLayout.pinned)
                for (final item in available.where((item) => item.id == id))
                  ToolbarButton(
                    id,
                    item.name,
                    item.icon,
                    id.startsWith('core.')
                        ? () => action(
                            ReaderToolbarAction.values.byName(id.substring(5)),
                          )
                        : widget.extensions
                              .actions(ReaderPanel.more)
                              .any((a) => a.id == id)
                        ? () async {
                            final match = widget.extensions
                                .actions(ReaderPanel.more)
                                .where((a) => a.id == id);
                            if (match.isNotEmpty) {
                              await widget.invokeExtension(match.first);
                            }
                          }
                        : null,
                  ),
            ],
    );
    final toolbar = SafeArea(
      top: !bottom,
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: AqCapsule(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: side
              ? SizedBox(width: 48, child: buttons)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    buttons,
                    Text(
                      adapter.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
        ),
      ),
    );
    final progress = SafeArea(
      top: false,
      maintainBottomViewPadding: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: AqCapsule(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: adapter.paged ? '上一页' : '上一${adapter.unit}',
                    onPressed: canTurn(-1) ? () => turnPage(-1) : null,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  Expanded(
                    child: Slider(
                      value: sliderValue,
                      max: sliderRange,
                      label: sliderLabel,
                      onChanged: sliderMax > 0
                          ? (v) => moveTo(v.round())
                          : null,
                    ),
                  ),
                  IconButton(
                    tooltip: adapter.paged ? '下一页' : '下一${adapter.unit}',
                    onPressed: canTurn(1) ? () => turnPage(1) : null,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
              Text(positionText, style: Theme.of(context).textTheme.bodySmall),
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  adapter.status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return ScrollConfiguration(
      behavior: ScrollConfiguration.of(
        context,
      ).copyWith(physics: readerContinuousPhysics),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              setState(() => visible = !visible),
        },
        child: Focus(
          autofocus: true,
          child: NotificationListener<ReaderControlPointer>(
            onNotification: (event) {
              controlPointers.add(event.pointer);
              return true;
            },
            child: Stack(
              children: [
                Positioned.fill(
                  child: SafeArea(
                    maintainBottomViewPadding: true,
                    child: LayoutBuilder(
                      builder: (context, constraints) => Listener(
                        key: const ValueKey('reader-content-hit-region'),
                        behavior: HitTestBehavior.translucent,
                        onPointerDown: (event) {
                          pointers.add(event.pointer);
                          if (event.buttons != kPrimaryButton) {
                            cancelled = true;
                            return;
                          }
                          if (pointers.length == 1) {
                            down = event.localPosition;
                            downAt = event.timeStamp;
                            cancelled = false;
                          } else {
                            cancelled = true;
                          }
                        },
                        onPointerMove: (event) {
                          if (down != null &&
                              (event.localPosition - down!).distance > 8) {
                            cancelled = true;
                          }
                        },
                        onPointerCancel: (event) {
                          pointers.remove(event.pointer);
                          controlPointers.remove(event.pointer);
                          cancelled = true;
                        },
                        onPointerUp: (event) {
                          pointers.remove(event.pointer);
                          if (controlPointers.remove(event.pointer) ||
                              liveSurface) {
                            return;
                          }
                          if (!cancelled &&
                              pointers.isEmpty &&
                              downAt != null &&
                              event.timeStamp - downAt! <
                                  const Duration(milliseconds: 300)) {
                            tap(event.localPosition, constraints.biggest);
                          }
                        },
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Padding(
                              padding: EdgeInsets.only(
                                // Continuous chrome overlays the unmodified
                                // article canvas; showing it never reflows text.
                                top: 0,
                                // A scaled overview owns the chrome in paged mode.
                                // Keep its hidden native page at full canvas size;
                                // reducing it would invalidate measured pagination.
                                bottom:
                                    visible && !bottom && showProgress && !grid
                                    ? 104
                                    : 0,
                              ),
                              child: Offstage(
                                offstage: visible && grid,
                                child: adapter.buildContent(context),
                              ),
                            ),
                            // A pending grid is the page: it owns the whole
                            // area, so no tap may reach the surface underneath.
                            if (visible && grid)
                              Positioned.fill(
                                child: AbsorbPointer(
                                  child: ColoredBox(
                                    color: readerOverviewBackground(paper),
                                    child: const SizedBox.expand(),
                                  ),
                                ),
                              ),
                            if (visible && grid)
                              Padding(
                                padding: EdgeInsets.only(
                                  top: !side && !bottom ? topChrome : 12,
                                  bottom: bottom
                                      ? topChrome + readerProgressHeight
                                      : (showProgress ? 104 : 16),
                                  left: side && widget.dock == 'left' ? 88 : 0,
                                  right: side && widget.dock == 'right'
                                      ? 88
                                      : 0,
                                ),
                                child: ReaderPageOverview(
                                  adapter: adapter as PagedReaderAdapter,
                                  pageSize:
                                      adapter is MeasuredPagedReaderAdapter
                                      ? (adapter as MeasuredPagedReaderAdapter)
                                            .pageCanvasSize
                                      : constraints.biggest,
                                  paperColor: paper,
                                  initialPage: adapter.position,
                                  onActivate: () =>
                                      setState(() => visible = false),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (side)
                  Positioned(
                    top: 0,
                    bottom: 140,
                    left: widget.dock == 'left' ? 0 : null,
                    right: widget.dock == 'right' ? 0 : null,
                    child: animateChrome(
                      toolbar,
                      Offset(widget.dock == 'left' ? -1 : 1, 0),
                    ),
                  )
                else if (!bottom)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    child: animateChrome(toolbar, const Offset(0, -1)),
                  ),
                // Last in the stack, so the one controller is reachable and drawn
                // above the page grid as well as above a scrolled page. Top-to-
                // bottom reading gets the browser-style whole-book scrollbar
                // instead of the bottom controller.
                // Kept inside the safe area, so the thumb never runs under the
                // status bar, a notch or the gesture bar.
                if (!showProgress && adapter.count > 0)
                  Positioned(
                    top:
                        MediaQuery.paddingOf(context).top +
                        (visible && !side ? 64 : 8),
                    right: MediaQuery.paddingOf(context).right,
                    bottom: MediaQuery.viewPaddingOf(context).bottom + 8,
                    width: 28,
                    child: ReaderScrollbar(source: scrollSource),
                  ),
                if (showProgress)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: animateChrome(
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [if (bottom) toolbar, progress],
                      ),
                      const Offset(0, 1),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
