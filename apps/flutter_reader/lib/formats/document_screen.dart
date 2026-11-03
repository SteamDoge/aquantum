// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'reader_provider_preferences.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../dashboard/reading_tracker.dart';
import '../data/document_resource.dart';
import '../data/models.dart';
import '../data/reader_api.dart';
import '../plugins/plugin_api.dart';
import '../plugins/plugin_result.dart';
import '../plugins/plugin_manager.dart';
import '../reader/reader_extensions.dart';
import '../reader/reader_shell.dart';
import '../widgets/note_dialog.dart';
import '../widgets/reader_settings.dart';
import 'document_engine.dart';
import 'document_engine_windows.dart';
import 'document_engine_android.dart';
import 'document_reader.dart';
import 'reader_provider.dart';

/// Reads an EPUB/MOBI/AZW3/FB2 book the way its publisher laid it out.
///
/// The page itself belongs to the bundled foliate engine inside a WebView; this
/// screen owns everything around it — the shell, the panels, progress, notes
/// and the display preferences — all of which stay native Flutter so the seven
/// fixed toolbar entries never depend on the book format.
class DocumentReaderScreen extends StatefulWidget {
  final ReaderApi api;
  final Book book;
  final int initialPosition;
  final PluginManager? plugins;
  const DocumentReaderScreen({
    super.key,
    required this.api,
    required this.book,
    this.initialPosition = 0,
    this.plugins,
  });
  @override
  State<DocumentReaderScreen> createState() => _DocumentReaderScreenState();
}

class _DocumentReaderScreenState extends State<DocumentReaderScreen>
    with WidgetsBindingObserver {
  final preferences = ReaderPreferences();
  late final tracker = ReadingTracker(widget.api, widget.book.id);
  DocumentEngine? engine;
  DocumentReaderAdapter? adapter;
  DocumentResource? resource;
  int fontSize = 20;
  String? providerId;
  String? error;
  bool exiting = false, turning = false;
  int overlays = 0;
  Timer? heartbeat, debounce;

  bool get foreground =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  bool get desktop => {
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
  }.contains(Theme.of(context).platform);

  /// Document formats need the bundled browser engine; no other platform has
  /// one wired yet, and the screen says so instead of showing an empty page.
  bool get supported =>
      (WindowsDocumentEngine.supported || AndroidDocumentEngine.supported) &&
      (widget.book.isDocument || widget.book.isComic);

  Brightness? _brightness;
  TextScaler? _textScaler;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final brightness = Theme.of(context).brightness;
    final scaler = MediaQuery.textScalerOf(context);
    if ((_brightness != brightness || _textScaler != scaler) &&
        adapter?.ready == true) {
      unawaited(_applyStyle());
    }
    _brightness = brightness;
    _textScaler = scaler;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.plugins?.addListener(pluginChanged);
    _restore();
  }

  void _documentChanged() {
    final current = adapter;
    if (!mounted || current == null) return;
    if (current.ready) {
      tracker.total = current.count;
      tracker.position = current.position;
      unawaited(
        widget.plugins?.hostServices?.broker
                .emit('reader.position', {
                  'bookId': widget.book.id,
                  'position': current.position,
                })
                .catchError((Object _) => null) ??
            Future.value(),
      );
      if (foreground && overlays == 0 && !exiting) tracker.resume();
    }
    setState(() {});
  }

  void pluginChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (foreground && overlays == 0 && !exiting && adapter?.ready == true) {
      tracker.resume();
    } else {
      unawaited(tracker.pause());
      unawaited(_savePlace());
    }
  }

  /// Anything modal pauses reading, so a panel never counts as reading time.
  Future<void> overlay(Future<void> Function() show) async {
    overlays++;
    await tracker.pause();
    try {
      await show();
    } finally {
      overlays--;
      if (foreground && !exiting && adapter?.ready == true) tracker.resume();
    }
  }

  @override
  void dispose() {
    heartbeat?.cancel();
    debounce?.cancel();
    widget.plugins?.removeListener(pluginChanged);
    WidgetsBinding.instance.removeObserver(this);
    adapter?.removeListener(_documentChanged);
    adapter?.dispose();
    unawaited(tracker.pause());
    unawaited(engine?.close());
    super.dispose();
  }

  /// Restores the shell's preferences and the saved processor choice.
  Future<void> _restore() async {
    try {
      final stored = await SharedPreferences.getInstance();
      await preferences.load(
        bookId: widget.book.id,
        format: widget.book.format,
      );
      final savedFont =
          stored.getDouble('reader-font-size.v1.${widget.book.id}') ??
          stored.getDouble('reader-font-size');
      providerId = await ReaderProviderPreferences.read(widget.book);
      fontSize = (savedFont ?? fontSize).round().clamp(14, 32);
    } catch (_) {
      // Preferences are display state; a failure must not stop the book.
    }
    if (mounted) await _connect();
  }

  Future<void> _connect() async {
    if (!supported) {
      setState(() => error = '当前平台还不能显示这种文档。');
      return;
    }
    if (!mounted) return;
    setState(() => error = null);
    DocumentEngine? opened;
    try {
      final resource = widget.book.isComic
          ? null
          : await loadDocument(widget.api, widget.book.id);
      opened = AndroidDocumentEngine.supported
          ? AndroidDocumentEngine.create()
          : await WindowsDocumentEngine.create();
      final adapter = DocumentReaderAdapter(book: widget.book, engine: opened);
      if (!mounted) {
        adapter.dispose();
        await opened.close();
        return;
      }
      this.resource = resource;
      engine = opened;
      this.adapter = adapter;
      adapter.addListener(_documentChanged);
      setState(() {});
      await opened.ready;
      if (!mounted) return;
      // Stage saved typography and flow before the engine resolves the saved
      // CFI. Restoring under default layout and styling afterwards can drift.
      await _applyStyle();
      if (!mounted) return;
      if (widget.book.isComic) {
        await adapter.openImages(
          anchor: await _savedAnchor(),
          readImage: (id) async =>
              (await widget.api.call('read_image', {
                    'book': widget.book.id,
                    'page': id,
                  }))
                  as String,
        );
      } else {
        await adapter.open(
          await resource!.read(),
          name: resource.name.isEmpty ? widget.book.title : resource.name,
          format: resource.format.isEmpty
              ? widget.book.format
              : resource.format,
          anchor: await _savedAnchor(),
        );
      }
      if (!mounted) return;
      await _applyStyle();
      if (foreground && overlays == 0 && !exiting) tracker.resume();
      _scheduleHeartbeat();
      setState(() {});
    } catch (e) {
      if (identical(engine, opened)) {
        adapter?.removeListener(_documentChanged);
        adapter?.dispose();
        adapter = null;
        engine = null;
      }
      await opened?.close();
      if (mounted) setState(() => error = '$e');
    }
  }

  /// The anchor the core stored for this book, or none on a first read.
  ///
  /// Progress is a CFI: a fraction would move the reader whenever the window or
  /// the font changed, so it is never reopened as a position.
  Future<String?> _savedAnchor() async {
    try {
      final response = await widget.api.call('snapshot', {});
      final catalog = response is Map ? response['catalog'] : null;
      final raw = catalog is Map ? catalog['progress'] : null;
      if (raw is! List) return null;
      for (final row in raw) {
        final entry = row as Map;
        if (entry['book'] != widget.book.id ||
            (catalog is Map && entry['actor'] != catalog['actor'])) {
          continue;
        }
        final location = entry['location'];
        if (widget.book.isComic && location is Map && location['Page'] is Map) {
          return (location['Page'] as Map)['page']?.toString();
        }
        final document = location is Map ? location['Document'] : null;
        final anchor = document is Map ? document['anchor'] : null;
        if (anchor is String && anchor.isNotEmpty) return anchor;
      }
    } catch (_) {
      // An unreadable snapshot means a first read, never a failed open.
    }
    if (widget.book.isComic && widget.book.pages.isNotEmpty) {
      return widget.book.pages[widget.initialPosition.clamp(
            0,
            widget.book.pages.length - 1,
          )]['id']
          as String;
    }
    return null;
  }

  Future<void> _applyStyle() async {
    final engine = this.engine;
    if (engine == null) return;
    try {
      await engine.style({
        'theme': preferences.activeBackground(
          mounted ? Theme.of(context).brightness : Brightness.light,
        ),
        'continuous': preferences.continuous,
        'turnEffect': preferences.turnEffect,
        'animation':
            preferences.pageAnimation &&
            mounted &&
            !MediaQuery.disableAnimationsOf(context),
        'margin': preferences.margin,
        'fit': preferences.fit,
        'fontSize': (mounted
            ? MediaQuery.textScalerOf(context).scale(fontSize.toDouble())
            : fontSize.toDouble()),
        'fontFamily': preferences.font,
        'lineHeight': preferences.lineHeight,
        'paragraphGap': preferences.paragraphGap,
      });
      if (mounted) adapter?.setContinuous(preferences.continuous);
    } catch (_) {
      adapter?.setStatus('阅读设置应用失败，请重试。');
    }
  }

  /// Saves the reading place while reading, after every pause and on exit.
  Future<void> _savePlace() async {
    final adapter = this.adapter;
    if (adapter == null || !adapter.ready) return;
    try {
      await adapter.settle();
      if (widget.book.isComic) {
        await widget.api.call('save_progress', {
          'book': widget.book.id,
          'index': adapter.position,
        });
        return;
      }
      final anchor = adapter.anchor;
      if (anchor.isEmpty) return;
      await widget.api.call('save_progress_at', {
        'book': widget.book.id,
        'anchor': anchor,
        'progress': (adapter.fraction * 100).round().clamp(0, 100),
      });
    } catch (e) {
      if (mounted) adapter.setStatus('保存进度失败：$e');
    }
  }

  void _scheduleHeartbeat() {
    heartbeat?.cancel();
    heartbeat = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!foreground || exiting || overlays > 0) return;
      if (tracker.clock.isRunning) tracker.sample();
      if (timer.tick % 15 == 0) {
        unawaited(tracker.flush());
        unawaited(_savePlace());
      }
    });
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
    final adapter = this.adapter;
    if (adapter == null || !adapter.ready) return;
    try {
      await adapter.settle();
      await widget.api.call('add_note', {
        'book': widget.book.id,
        if (widget.book.isComic)
          'index': adapter.position
        else
          'anchor': adapter.anchor,
        'progress': (adapter.fraction * 100).round().clamp(0, 100),
        'text': text,
      });
      if (mounted) adapter.setStatus('笔记已保存在当前位置');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }

  /// Jump-back list: every note keeps the CFI it was written at.
  Future<void> showNotes() async {
    List<Map<String, dynamic>> notes;
    try {
      final response = await widget.api.call('notes', {'book': widget.book.id});
      notes = [
        for (final note in response as List)
          Map<String, dynamic>.from(note as Map),
      ];
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$e')));
      }
      return;
    }
    if (!mounted) return;
    if (notes.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('这本书还没有关联笔记。')));
      return;
    }
    String? anchor;
    await overlay(() async {
      anchor = await showDialog<String>(
        context: context,
        builder: (sheet) => AlertDialog(
          title: const Text('关联笔记'),
          content: SizedBox(
            width: 600,
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: notes.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final note = notes[i];
                final location = note['location'];
                final document = location is Map ? location['Document'] : null;
                final percent = document is Map ? document['progress'] : null;
                final stale = note['stale'] == true;
                final label = percent is int ? '约 $percent%' : '文内位置';
                return ListTile(
                  title: Text(note['markdown']?.toString() ?? ''),
                  subtitle: Text(
                    stale ? '$label · 锚点可能漂移' : label,
                    style: stale
                        ? TextStyle(color: Theme.of(context).colorScheme.error)
                        : null,
                  ),
                  trailing: const Icon(Icons.keyboard_return, size: 18),
                  onTap: () => Navigator.pop(
                    sheet,
                    document is Map
                        ? document['anchor']?.toString()
                        : location is Map && location['Page'] is Map
                        ? (location['Page'] as Map)['page']?.toString()
                        : null,
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(sheet),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    });
    final target = anchor;
    if (target != null && target.isNotEmpty) {
      await adapter?.goToHref(target);
    }
  }

  /// Turns the page by the shell's shared tap and drag rules.
  Future<void> turn(int delta) async {
    final adapter = this.adapter;
    final engine = this.engine;
    if (adapter == null || engine == null || turning) return;
    turning = true;
    try {
      await engine.turn(delta);
      await adapter.settle();
    } catch (e) {
      adapter.setStatus('翻页失败：$e');
    } finally {
      turning = false;
      // Every turn is a reading event; the debounce keeps a fast flip cheap
      // without waiting for the whole heartbeat.
      debounce?.cancel();
      debounce = Timer(const Duration(milliseconds: 900), () {
        if (foreground) unawaited(_savePlace());
      });
    }
  }

  Future<void> save() async {
    await tracker.pause();
    await _savePlace();
  }

  Widget _loading() => Scaffold(
    appBar: AppBar(title: Text(widget.book.title)),
    body: Center(
      child: error == null
          ? const CircularProgressIndicator(strokeWidth: 2)
          : Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(error!, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: supported
                        ? () {
                            setState(() => error = null);
                            unawaited(_connect());
                          }
                        : null,
                    child: const Text('重试'),
                  ),
                ],
              ),
            ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final book = widget.book;
    final adapter = this.adapter;
    if (adapter == null) return _loading();
    final scope = ExtensionContext(
      bookId: book.id,
      format: book.format,
      capabilities: {
        if (!widget.book.isComic) ReaderCapability.selectableText,
        if (adapter.info?.paginated == true) ReaderCapability.reflow,
        if (adapter.info?.paginated == false) ReaderCapability.fixedLayout,
      },
    );
    return PopScope(
      canPop: exiting,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || exiting) return;
        await save();
        if (!mounted) return;
        setState(() => exiting = true);
        Navigator.pop(this.context);
      },
      child: Scaffold(
        body: Stack(
          children: [
            ReaderShell(
              paperColor: preferences.background(Theme.of(context).brightness),
              adapter: adaptReaderProvider(
                selectedProvider(book, widget.plugins, providerId),
                adapter,
                widget.plugins,
              ),
              desktop: desktop,
              dock: preferences.dock,
              // Reflowed text reports a text-length position; a managed comic
              // shown here keeps the page-count fallback.
              scroll: adapter.paged || book.isComic
                  ? null
                  : adapter.scrollSource,
              settingsBuilder: (context, refresh) => ReaderSettingsPanel(
                preferences: preferences,
                capabilities: adapter.capabilities,
                fontSize: fontSize.toDouble(),
                desktop: desktop,
                paged: adapter.paged,
                // Continuous here is a switchable mode, not a core
                // TopToBottom direction that locks a comic into scrolling.
                verticalTurning: false,
                onFont: (value) {
                  setState(() => fontSize = value.round().clamp(14, 32));
                  refresh();
                  unawaited(_applyStyle());
                  unawaited(
                    SharedPreferences.getInstance().then((prefs) async {
                      if (!await prefs.setDouble(
                        'reader-font-size.v1.${widget.book.id}',
                        fontSize.toDouble(),
                      )) {
                        adapter.setStatus('字号保存失败');
                      }
                    }),
                  );
                },
                onChanged: (change) {
                  setState(change);
                  refresh();
                  unawaited(_applyStyle());
                  unawaited(
                    preferences.save(bookId: widget.book.id).catchError((
                      Object e,
                    ) {
                      if (mounted) {
                        ScaffoldMessenger.of(
                          this.context,
                        ).showSnackBar(SnackBar(content: Text('$e')));
                      }
                    }),
                  );
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
              showNotes: showNotes,
              onSaveRequested: save,
              onTurn: turn,
            ),
            if (!adapter.ready)
              const IgnorePointer(
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ),
          ],
        ),
      ),
    );
  }
}
