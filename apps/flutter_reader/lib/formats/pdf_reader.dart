// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'reader_provider_preferences.dart';
import 'pdf_paged_layout.dart';
import '../reader/reader_motion.dart';
import 'pdf_region.dart';
import '../reader/reader_panels.dart';
import 'reader_provider.dart';
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';
import '../data/models.dart';
import '../data/reader_api.dart';
import '../dashboard/reading_tracker.dart';
import '../plugins/plugin_api.dart';
import '../plugins/plugin_result.dart';
import '../plugins/plugin_manager.dart';
import '../reader/reader_contract.dart';
import '../reader/reader_extensions.dart';
import '../reader/reader_renderers.dart';
import '../reader/reader_shell.dart';
import '../widgets/note_dialog.dart';
import '../widgets/reader_settings.dart';
import 'pdf_engine.dart';

class PdfReaderScreen extends StatefulWidget {
  final ReaderApi api;
  final Book book;
  final int initialPosition;
  final PluginManager? plugins;
  const PdfReaderScreen({
    super.key,
    required this.api,
    required this.book,
    required this.initialPosition,
    this.plugins,
  });
  @override
  State<PdfReaderScreen> createState() => _PdfReaderScreenState();
}

class _PdfReaderScreenState extends State<PdfReaderScreen>
    with WidgetsBindingObserver {
  final controller = PdfViewerController();
  final preferences = ReaderPreferences();
  late final tracker = ReadingTracker(widget.api, widget.book.id);
  late int position = widget.initialPosition;
  Book? book;
  PdfEngineSession? engine;
  PdfDocumentRefDirect? reference;
  String? error, providerId;
  String direction = 'TopToBottom';
  List<ReaderLocation> outline = [];
  int viewRevision = 0;

  bool get paged => direction != 'TopToBottom';
  bool viewportReady = false;
  final scrollMetrics = ValueNotifier(const ReaderScrollMetrics(0));
  late final scrollSource = ReaderScrollSource(
    metrics: scrollMetrics,
    seek: seekFraction,
  );
  late final pagePhysics = ReaderPageScrollPhysics(
    canSnap: () =>
        paged && controller.isReady && controller.currentZoom <= 1.01,
  );

  void viewportChanged() {
    if (!viewportReady || !controller.isReady || paged) return;
    final height = controller.layout.documentSize.height;
    if (height <= 0) return;
    final visible = controller.visibleRect;
    scrollMetrics.value = ReaderScrollMetrics(
      (visible.top / height).clamp(0.0, 1.0),
      (visible.height / height).clamp(0.0, 1.0),
    );
  }

  void seekFraction(double fraction) {
    if (!viewportReady || !controller.isReady || paged) return;
    final current = controller.value;
    final matrix = current.clone()
      ..setTranslationRaw(
        current.getTranslation().x,
        -fraction.clamp(0.0, 1.0) *
            controller.layout.documentSize.height *
            controller.currentZoom,
        0,
      );
    unawaited(controller.goTo(matrix, duration: Duration.zero));
  }

  void settleStillDrag() {
    // The native viewport skips physics only for a perfectly still release.
    // Real flings are owned by PageScrollPhysics and must not be interrupted.
    if (!paged ||
        !viewportReady ||
        !controller.isReady ||
        controller.currentZoom > 1.01) {
      return;
    }
    final width = controller.viewSize.width;
    if (width <= 0) return;
    final slot = (-controller.value.getTranslation().x / width).round();
    final index = direction == 'RightToLeft'
        ? book!.pages.length - 1 - slot
        : slot;
    go(index.clamp(0, book!.pages.length - 1));
  }

  Future<void> reloadPageSettings() async {
    final value = await widget.api.call('effective_direction', {
      'book': widget.book.id,
    });
    if (!mounted) return;
    setState(() {
      viewportReady = false;
      direction = value['source'] == widget.book.id
          ? value['value']
          : preferences.continuous
          ? 'TopToBottom'
          : preferences.rightToLeft
          ? 'RightToLeft'
          : 'LeftToRight';
      preferences.continuous = !paged;
      preferences.rightToLeft = direction == 'RightToLeft';
      viewRevision++;
    });
  }

  Widget palette(BuildContext context, Widget viewer) {
    final dark =
        preferences.theme == 'dark' ||
        (preferences.theme == 'system' &&
            Theme.of(context).brightness == Brightness.dark);
    return dark
        ? ColorFiltered(
            colorFilter: const ColorFilter.matrix([
              -1,
              0,
              0,
              0,
              255,
              0,
              -1,
              0,
              0,
              255,
              0,
              0,
              -1,
              0,
              255,
              0,
              0,
              0,
              1,
              0,
            ]),
            child: viewer,
          )
        : preferences.theme == 'paper'
        ? ColorFiltered(
            colorFilter: const ColorFilter.mode(
              Color(0xfff4ecd8),
              BlendMode.modulate,
            ),
            child: viewer,
          )
        : viewer;
  }

  Widget fullPage(BuildContext context, int index, {bool preview = false}) =>
      palette(
        context,
        PdfRegion(
          engine: engine!,
          index: index,
          crop: const {},
          interactive: !preview,
        ),
      );

  String status = '阅读位置自动保留';
  bool exiting = false, locked = false, selectionActive = false;
  int overlays = 0;
  Timer? heartbeat;
  bool get foreground =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  bool get desktop => {
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  }.contains(Theme.of(context).platform);
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.plugins?.addListener(pluginChanged);
    controller.addListener(viewportChanged);
    load();
  }

  void pluginChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (foreground && overlays == 0 && !exiting && engine != null) {
      tracker.resume();
    } else {
      unawaited(tracker.pause());
    }
  }

  Future<void> overlay(Future<void> Function() show) async {
    overlays++;
    await tracker.pause();
    try {
      await show();
    } finally {
      overlays--;
      if (mounted && foreground && !exiting && overlays == 0) tracker.resume();
    }
  }

  Future<String?> password() async {
    if (!mounted) return null;
    final text = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('PDF 密码'),
        content: TextField(
          controller: text,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(labelText: '仅用于本次打开，不保存密码'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, text.text),
            child: const Text('打开'),
          ),
        ],
      ),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => text.dispose());
    return result;
  }

  Future<void> load() async {
    providerId = await ReaderProviderPreferences.read(widget.book);
    PdfDocument? opened;
    try {
      await preferences.load(bookId: widget.book.id, format: 'Pdf');
      final gap = await widget.api.call('effective_gap', {
        'book': widget.book.id,
      });
      preferences.seamless = gap['value'] == 'Seamless';
      final source = await widget.api.call('document_path', {
        'book': widget.book.id,
      });
      await pdfrxFlutterInitialize();
      opened = await PdfDocument.openFile(
        source['path'],
        passwordProvider: password,
        useProgressiveLoading: true,
      );
      await opened.reloadPages(
        pageNumbersToReload: [position.clamp(0, opened.pages.length - 1) + 1],
      );
      final actual = Book(
        Map<String, dynamic>.from(
          await widget.api.call('bind_pdf_pages', {
            'book': widget.book.id,
            'resource': source['resource'],
            'revision': source['revision'],
            'count': opened.pages.length,
          }),
        ),
      );
      if (!mounted) {
        await opened.dispose();
        return;
      }
      position = position.clamp(0, actual.pages.length - 1);
      final session = PdfEngineSession(opened, actual);
      setState(() {
        book = actual;
        engine = session;
        reference = PdfDocumentRefDirect(opened!, autoDispose: false);
        error = null;
      });
      await reloadPageSettings();
      final nodes = await opened.loadOutline();
      final entries = <ReaderLocation>[];
      void visit(List<PdfOutlineNode> nodes, int depth) {
        if (depth > 32 || entries.length >= 5000) return;
        for (final node in nodes) {
          final page = (node.dest?.pageNumber ?? 0) - 1;
          if (page >= 0 && page < actual.pages.length) {
            entries.add(
              ReaderLocation(
                'page:${actual.pages[page]['id']}',
                node.title,
                page,
              ),
            );
          }
          visit(node.children, depth + 1);
        }
      }

      visit(nodes, 0);
      if (mounted) setState(() => outline = entries);
      tracker.total = actual.pages.length;
      tracker.position = position;
      await tracker.checkpoint();
      if (mounted && foreground) tracker.resume();
      heartbeat = Timer.periodic(const Duration(seconds: 1), (t) {
        if (tracker.clock.isRunning) {
          tracker.sample();
          if (t.tick % 15 == 0) unawaited(tracker.flush());
        }
      });
    } catch (e) {
      if (engine == null) await opened?.dispose();
      if (mounted) {
        setState(() {
          if (engine == null) {
            error = '$e';
          } else {
            status = '阅读状态保存失败：$e';
          }
        });
      }
    }
  }

  Future<void> save(int index) async {
    if (index == position || book == null) return;
    setState(() => position = index);
    tracker.position = index;
    try {
      await widget.api.call('save_progress', {
        'book': book!.id,
        'index': index,
      });
      if (mounted) setState(() => status = '已保存到第 ${index + 1} 页');
    } catch (e) {
      if (mounted) setState(() => status = '保存失败：$e');
    }
  }

  void go(int index, {bool animate = true}) {
    if (!viewportReady || !controller.isReady || book == null) return;
    final duration =
        animate &&
            preferences.pageAnimation &&
            !MediaQuery.disableAnimationsOf(context)
        ? const Duration(milliseconds: 180)
        : Duration.zero;
    if (!paged) {
      unawaited(controller.goToPage(pageNumber: index + 1, duration: duration));
      return;
    }
    final slot = direction == 'RightToLeft'
        ? book!.pages.length - 1 - index
        : index;
    unawaited(
      controller.goTo(
        Matrix4.identity()
          ..setTranslationRaw(-slot * controller.viewSize.width, 0, 0),
        duration: duration,
      ),
    );
  }

  Future<void> addNote() async {
    String? text;
    await overlay(() async {
      text = await showDialog<String>(
        context: context,
        builder: (_) => const NoteDialog(),
      );
    });
    if (text == null || text!.trim().isEmpty) return;
    try {
      await widget.api.call('add_note', {
        'book': widget.book.id,
        'index': position,
        'text': text,
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  /// Jump-back list instead of a Markdown dump: each note keeps its page anchor,
  /// so the PDF reader can return to the page it was written on.
  Future<void> notes() async {
    try {
      final response = await widget.api.call('notes', {'book': widget.book.id});
      final list = (response as List)
          .map((n) => Map<String, dynamic>.from(n as Map))
          .toList();
      if (!mounted) return;
      if (list.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('这本书还没有关联笔记。')));
        return;
      }
      Map<String, dynamic>? target;
      await overlay(() async {
        target = await showDialog<Map<String, dynamic>>(
          context: context,
          builder: (c) => AlertDialog(
            title: const Text('关联笔记'),
            content: SizedBox(
              width: 600,
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: list.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final note = list[i];
                  final page = (note['location'] as Map?)?['Page']?['page'];
                  final number = widget.book.pages.indexWhere(
                    (p) => p['id'] == page,
                  );
                  final stale = note['stale'] == true;
                  final anchor = number >= 0
                      ? '第 ${number + 1} 页'
                      : '页面已不在本文件中';
                  return ListTile(
                    title: Text(note['markdown']?.toString() ?? ''),
                    subtitle: Text(
                      stale ? '$anchor · 锚点可能漂移' : anchor,
                      style: stale
                          ? TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            )
                          : null,
                    ),
                    trailing: const Icon(Icons.keyboard_return, size: 18),
                    onTap: () => Navigator.pop(context, note),
                  );
                },
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(c),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      });
      final page = target?['location']?['Page']?['page'];
      final number = page == null
          ? -1
          : widget.book.pages.indexWhere((p) => p['id'] == page);
      if (number >= 0) go(number);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  Future<void> link(PdfLink link) async {
    if (link.dest != null) {
      if (paged) {
        go(link.dest!.pageNumber - 1);
      } else {
        await controller.goToDest(link.dest);
      }
      return;
    }
    final uri = link.url;
    if (uri == null || !mounted) return;
    await overlay(() async {
      await showDialog<void>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('文档外部链接'),
          content: SelectableText(uri.toString()),
          actions: [
            TextButton(
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: uri.toString()));
                if (c.mounted) Navigator.pop(c);
              },
              child: const Text('复制链接'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    });
  }

  @override
  void dispose() {
    heartbeat?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    widget.plugins?.removeListener(pluginChanged);
    unawaited(tracker.pause());
    controller.removeListener(viewportChanged);
    scrollMetrics.dispose();
    unawaited(engine?.close() ?? Future.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (engine == null) {
      return Scaffold(
        appBar: AppBar(title: Text(widget.book.title)),
        body: Center(
          child: error == null
              ? const CircularProgressIndicator()
              : Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SelectableText(error!),
                      OutlinedButton(
                        onPressed: () {
                          setState(() => error = null);
                          load();
                        },
                        child: const Text('重新打开'),
                      ),
                    ],
                  ),
                ),
        ),
      );
    }
    final capabilities = ReaderCapabilities(
      search: true,
      navigationLabel: 'PDF 页面',
      settings: {
        ReaderSetting.theme,
        ReaderSetting.imageGap,
        ReaderSetting.continuous,
        if (paged) ReaderSetting.direction,
        if (paged) ReaderSetting.animation,
      },
    );
    Widget content(BuildContext context) {
      final viewer = LayoutBuilder(
        builder: (context, constraints) {
          final viewport = Size(constraints.maxWidth, constraints.maxHeight);
          return PdfViewer(
            reference!,
            key: ValueKey('pdf-view-$viewRevision'),
            controller: controller,
            initialPageNumber: position + 1,
            params: PdfViewerParams(
              margin: preferences.seamless ? 0 : 12,
              pageDropShadow: null,
              scrollPhysics: paged ? pagePhysics : readerContinuousPhysics,
              scrollPhysicsScale: readerContinuousPhysics,
              enableKeyboardNavigation: false,
              sizeDelegateProvider: paged
                  ? const PdfViewerSizeDelegateProviderLegacy(
                      minScale: 1,
                      useAlternativeFitScaleAsMinScale: false,
                      calculateInitialZoom: pdfPagedInitialZoom,
                    )
                  : null,
              layoutPages: !paged
                  ? null
                  : (pages, params) => pagedPdfLayout(
                      [for (final page in pages) Size(page.width, page.height)],
                      margin: params.margin,
                      viewport: viewport,
                      rightToLeft: direction == 'RightToLeft',
                    ),
              calculateCurrentPageNumber: !paged
                  ? null
                  : (visible, pages, current) {
                      // Read the actual layout width, also during a resize:
                      // a newly captured viewport may precede native relayout.
                      final slotWidth =
                          current.layout.documentSize.width / pages.length;
                      final slot = (visible.center.dx / slotWidth)
                          .floor()
                          .clamp(0, pages.length - 1);
                      return (direction == 'RightToLeft'
                              ? pages.length - 1 - slot
                              : slot) +
                          1;
                    },
              // Apply the reading palette once below, including the page margin.
              backgroundColor: Colors.white,
              maxImageBytesCachedOnMemory: 64 * 1024 * 1024,
              onePassRenderingSizeThreshold: 1536,
              horizontalCacheExtent: .25,
              verticalCacheExtent: .5,
              textSelectionParams: PdfTextSelectionParams(
                onTextSelectionChange: (selection) =>
                    selectionActive = selection.hasSelectedText,
              ),
              onPageChanged: (number) {
                if (number != null) save(number - 1);
              },
              onInteractionStart: (_) {
                locked = true;
              },
              onInteractionEnd: (details) {
                locked = false;
                if (details.velocity.pixelsPerSecond.distance == 0) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) settleStillDrag();
                  });
                }
              },
              onViewerReady: (_, _) {
                viewportReady = true;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) {
                    if (paged) go(position, animate: false);
                    viewportChanged();
                  }
                });
              },
              onViewSizeChanged: (_, oldSize, _) {
                if (!paged || oldSize == null) return;
                final page = position;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted && viewportReady) go(page, animate: false);
                });
              },
              linkHandlerParams: PdfLinkHandlerParams(onLinkTap: link),
              pagePaintCallbacks: [engine!.paint],
            ),
          );
        },
      );
      return palette(context, viewer);
    }

    final adapter = PdfReaderAdapter(
      book: book!,
      position: position,
      status: status,
      content: content,
      onGo: go,
      locked: () => locked || selectionActive,
      engine: engine!,
      capabilities: capabilities,
      animation: preferences.pageAnimation,
      rtl: direction == 'RightToLeft',
      vertical: direction == 'TopToBottom',
      outline: outline,
      pageBuilder: fullPage,
    );
    final scope = ExtensionContext(
      bookId: widget.book.id,
      format: 'Pdf',
      capabilities: {
        ReaderCapability.fixedLayout,
        ReaderCapability.selectableText,
      },
    );
    return PopScope(
      canPop: exiting,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || exiting) return;
        await tracker.pause();
        if (!mounted) return;
        setState(() => exiting = true);
        await WidgetsBinding.instance.endOfFrame;
        if (mounted) Navigator.pop(this.context);
      },
      child: Scaffold(
        body: ReaderShell(
          paperColor:
              preferences.theme == 'dark' ||
                  (preferences.theme == 'system' &&
                      Theme.of(context).brightness == Brightness.dark)
              ? const Color(0xff111111)
              : preferences.theme == 'paper'
              ? const Color(0xfff4ecd8)
              : Colors.white,
          adapter: adaptReaderProvider(
            selectedProvider(widget.book, widget.plugins, providerId),
            adapter,
            widget.plugins,
          ),
          directionBuilder: (context) => ComicDirectionPanel(
            api: widget.api,
            book: book!,
            preferences: preferences,
            onChanged: reloadPageSettings,
          ),
          desktop: desktop,
          dock: preferences.dock,
          scroll: paged ? null : scrollSource,
          settingsBuilder: (context, refresh) => ReaderSettingsPanel(
            preferences: preferences,
            capabilities: capabilities,
            fontSize: 20,
            desktop: desktop,
            paged: paged,
            verticalTurning: false,
            onFont: (_) {},
            onChanged: (change) {
              final previousGap = preferences.seamless;
              final wasPaged = paged;
              final previousRtl = preferences.rightToLeft;
              setState(() {
                change();
                direction = preferences.continuous
                    ? 'TopToBottom'
                    : preferences.rightToLeft
                    ? 'RightToLeft'
                    : 'LeftToRight';
                if (wasPaged != paged ||
                    previousRtl != preferences.rightToLeft) {
                  viewportReady = false;
                  viewRevision++;
                }
              });
              if (wasPaged != paged || previousRtl != preferences.rightToLeft) {
                unawaited(
                  widget.api
                      .call('resolve_book_direction', {
                        'book': widget.book.id,
                        'inherit': false,
                        'direction': direction,
                      })
                      .catchError((Object e) {
                        if (mounted) {
                          ScaffoldMessenger.of(
                            this.context,
                          ).showSnackBar(SnackBar(content: Text('阅读方向未保存：$e')));
                        }
                        return null;
                      }),
                );
              }
              refresh();
              preferences.save(bookId: widget.book.id).catchError((Object e) {
                if (mounted) {
                  ScaffoldMessenger.of(
                    this.context,
                  ).showSnackBar(SnackBar(content: Text('$e')));
                }
              });
              controller.invalidate();
              if (previousGap != preferences.seamless) {
                widget.api
                    .call('set_gap', {
                      'book': widget.book.id,
                      'seamless': preferences.seamless,
                    })
                    .catchError((Object e) {
                      if (mounted) {
                        ScaffoldMessenger.of(
                          this.context,
                        ).showSnackBar(SnackBar(content: Text('$e')));
                      }
                      return null;
                    });
              }
            },
          ),
          extensions: ReaderExtensions(widget.plugins, scope),
          invokeExtension: (action) async {
            try {
              final result = await widget.plugins?.invoke(action.id, scope);
              if (mounted) {
                await showPluginResult(this.context, action, result);
              }
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(
                  this.context,
                ).showSnackBar(SnackBar(content: Text('$e')));
              }
            }
          },
          runOverlay: overlay,
          addNote: addNote,
          showNotes: notes,
        ),
      ),
    );
  }
}

class PdfReaderAdapter extends SessionReaderAdapter
    implements PagedReaderAdapter, OutlineReaderAdapter {
  final bool rtl, animation;
  @override
  final List<ReaderLocation> outline;
  final Widget Function(BuildContext, int, {bool preview}) pageBuilder;
  @override
  Widget? buildPage(BuildContext context, int index, {required bool preview}) =>
      pageBuilder(context, index, preview: preview);
  @override
  bool get animatePageTurns => animation;
  final PdfEngineSession engine;
  @override
  final ReaderCapabilities capabilities;
  PdfReaderAdapter({
    required super.book,
    required super.position,
    required super.status,
    required super.content,
    required super.onGo,
    required super.locked,
    required this.engine,
    required this.capabilities,
    required this.rtl,
    this.animation = true,
    required this.outline,
    required this.pageBuilder,
    this.vertical = false,
  });

  /// TopToBottom documents scroll vertically;
  /// the shell needs the same axis for its tap and drag bands.
  final bool vertical;
  @override
  bool get verticalTurn => vertical;
  @override
  int get count => book.pages.length;
  @override
  String get unit => '页';
  @override
  bool get paged => !vertical;

  /// The shell shows the same bottom controls for discrete pages and a
  /// viewport-based whole-book scrollbar for continuous reading.
  @override
  bool get pageProgress => true;
  @override
  bool get rightToLeft => rtl;
  @override
  ReaderLocation location(int index) => ReaderLocation(
    'page:${book.pages[index]['id']}',
    '第 ${index + 1} 页',
    index,
  );
  @override
  int? resolveLocation(String id) {
    final index = book.pages.indexWhere((p) => 'page:${p['id']}' == id);
    return index < 0 ? null : index;
  }

  @override
  Widget? buildThumbnail(BuildContext context, int index) =>
      PdfThumbnail(engine: engine, index: index);
  @override
  Future<List<ReaderSearchHit>> search(String query) => engine.search(query);
}

class PdfThumbnail extends StatefulWidget {
  final PdfEngineSession engine;
  final int index;
  const PdfThumbnail({super.key, required this.engine, required this.index});
  @override
  State<PdfThumbnail> createState() => _PdfThumbnailState();
}

class _PdfThumbnailState extends State<PdfThumbnail> {
  ui.Image? image;
  String? error;
  @override
  void initState() {
    super.initState();
    widget.engine
        .thumbnail(widget.index)
        .then((result) {
          if (!mounted) {
            result?.dispose();
            return;
          }
          setState(() => image = result);
        })
        .catchError((Object e) {
          if (mounted) setState(() => error = '$e');
        });
  }

  @override
  void dispose() {
    image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => image == null
      ? (error == null
            ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.broken_image_outlined))
      : RawImage(image: image, fit: BoxFit.contain);
}
