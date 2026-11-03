// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import '../formats/reader_provider_preferences.dart';
import '../formats/reader_provider.dart';
import 'dart:convert';
import '../formats/document_screen.dart';
import '../formats/document_engine_android.dart';
import '../formats/document_engine_windows.dart';
import '../formats/pdf_reader.dart';
import '../formats/markdown_document.dart';
import '../formats/markdown_content.dart';
import '../formats/markdown_adapter.dart';
import '../reader/text_pagination.dart';
import '../reader/text_chunks.dart';
import '../reader/reader_contract.dart';
import '../reader/reader_renderers.dart';
import '../reader/reader_shell.dart';
import '../reader/reader_extensions.dart';
import '../reader/reader_panels.dart';
import '../widgets/reader_settings.dart';
import '../widgets/comic_strip.dart';
import '../plugins/plugin_api.dart';
import '../plugins/plugin_result.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../dashboard/reading_tracker.dart';
import '../plugins/plugin_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/models.dart';
import '../data/reader_api.dart';
import '../widgets/comic_page.dart';
import '../widgets/note_dialog.dart';
import '../widgets/text_reader.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

class ReaderScreen extends StatefulWidget {
  final ReaderApi api;
  final Book book;
  final int initialPosition;
  final PluginManager? plugins;
  const ReaderScreen({
    super.key,
    required this.api,
    required this.book,
    required this.initialPosition,
    this.plugins,
  });
  @override
  State<ReaderScreen> createState() => _ReaderHostState();
}

/// Resolve software-wide reader selection before mounting a single engine.
/// The library's reading route completes only when the reader actually exits.
class _ReaderHostState extends State<ReaderScreen> {
  bool? foliate;
  late int position = widget.initialPosition;

  @override
  void initState() {
    super.initState();
    if (!widget.book.isComic) {
      foliate = false;
    } else {
      restoreReader();
    }
  }

  Future<void> restoreReader() async {
    String? selected;
    try {
      selected = await ReaderProviderPreferences.read(widget.book);
    } catch (_) {}
    if (!mounted) return;
    setState(
      () => foliate =
          selected == ReaderProviderPreferences.foliateComic &&
          (AndroidDocumentEngine.supported || WindowsDocumentEngine.supported),
    );
  }

  @override
  Widget build(BuildContext context) => foliate == null
      ? const Scaffold(body: Center(child: CircularProgressIndicator()))
      : foliate!
      ? DocumentReaderScreen(
          api: widget.api,
          book: widget.book,
          initialPosition: position,
          plugins: widget.plugins,
        )
      : _CoreReaderScreen(
          api: widget.api,
          book: widget.book,
          initialPosition: position,
          plugins: widget.plugins,
        );
}

class _CoreReaderScreen extends StatefulWidget {
  final ReaderApi api;
  final Book book;
  final int initialPosition;
  final PluginManager? plugins;
  const _CoreReaderScreen({
    required this.api,
    required this.book,
    required this.initialPosition,
    this.plugins,
  });
  @override
  State<_CoreReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<_CoreReaderScreen>
    with WidgetsBindingObserver {
  late final ReadingTracker tracker = ReadingTracker(
    widget.api,
    widget.book.id,
  );
  Timer? heartbeat;
  int overlayDepth = 0;
  bool get overlay => overlayDepth > 0;
  bool exiting = false;
  bool initialized = false;
  double comicWithin = 0;
  int? comicAnchorPage;
  Timer? comicAnchorTimer;

  final preferences = ReaderPreferences();
  final comicController = ItemScrollController();
  bool get desktop => {
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
  }.contains(Theme.of(context).platform);
  bool selectionActive = false, zoomed = false;
  Widget buildSettings(
    BuildContext context,
    VoidCallback refresh,
  ) => ReaderSettingsPanel(
    preferences: preferences,
    capabilities: adapter.capabilities,
    fontSize: fontSize,
    desktop: desktop,
    paged: adapter.paged,
    verticalTurning: false,
    onFont: (value) {
      changeFont(value);
      refresh();
    },
    onChanged: (change) {
      final wasContinuous = comicContinuous;
      final wasTextPaged = preferences.textPaged;
      final previousGap = preferences.seamless;
      final previousRtl = preferences.rightToLeft;
      setState(() {
        change();
        if (widget.book.isComic && wasContinuous != preferences.continuous) {
          verticalTurn = preferences.continuous;
        }
      });
      if (widget.book.isComic && wasContinuous != comicContinuous) {
        zoomed = false;
        final oldPages = pages;
        pages = PageController(initialPage: index);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) oldPages.dispose();
        });
      }
      refresh();
      preferences.save(bookId: widget.book.id).catchError((Object e) {
        if (mounted) {
          ScaffoldMessenger.of(
            this.context,
          ).showSnackBar(SnackBar(content: Text(e.toString())));
        }
      });
      if (widget.book.isComic) {
        if (wasContinuous != comicContinuous) {
          unawaited(
            writeComicSetting('resolve_book_direction', {
              'inherit': false,
              'direction': comicContinuous
                  ? 'TopToBottom'
                  : preferences.rightToLeft
                  ? 'RightToLeft'
                  : 'LeftToRight',
            }),
          );
        }
        if (previousGap != preferences.seamless) {
          unawaited(
            writeComicSetting('set_gap', {'seamless': preferences.seamless}),
          );
        }
        if (previousRtl != preferences.rightToLeft && !verticalTurn) {
          unawaited(
            writeComicSetting('resolve_book_direction', {
              'inherit': false,
              'direction': preferences.rightToLeft
                  ? 'RightToLeft'
                  : 'LeftToRight',
            }),
          );
        }
      }
      // The newly mounted reader owns its initial source restoration. A second
      // seek here races its refinement and can save the preceding chunk's start.
      // Only an already scrolling reader needs a visual-settings reflow seek.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            widget.book.isComic ||
            !textController.isAttached ||
            preferences.textPaged ||
            wasTextPaged != preferences.textPaged) {
          return;
        }
        if (markdownDocument != null && useMarkdown) {
          textController.jumpTo(
            index: markdownDocument!.blockForParagraph(index),
          );
        } else if (paragraphs != null && paragraphs!.isNotEmpty) {
          final chunks = TextChunks.of(paragraphs!);
          final source = chunks.locate(index, withinOf(index, textOffset));
          seekController.seek(
            TextReader.progressOf(paragraphs!).fractionAt(source.$1, source.$2),
          );
        }
      });
    },
  );
  late ReaderAdapter adapter;

  /// Top-to-bottom reading's whole-book position, shared with the scrollbar.
  final scrollMetrics = ValueNotifier(const ReaderScrollMetrics(0));
  final seekController = ReaderSeekController();
  late final scrollSource = ReaderScrollSource(
    metrics: scrollMetrics,
    seek: seekController.seek,
  );

  /// A comic read top to bottom is one continuous strip, whether the reader
  /// chose continuous reading or the 从上到下 direction: top-to-bottom reading
  /// never pages.
  bool get comicContinuous => preferences.continuous || verticalTurn;

  /// How far [offset] characters are into [paragraph] (0–1).
  double withinOf(int paragraph, int offset) {
    final text = paragraphs;
    if (text == null || paragraph < 0 || paragraph >= text.length) return 0;
    final length = text[paragraph].length;
    return length == 0 ? 0 : (offset / length).clamp(0.0, 1.0);
  }

  ExtensionContext scope([String? selectedText]) => ExtensionContext(
    bookId: widget.book.id,
    format: widget.book.format,
    selectedText: selectedText,
    capabilities: widget.book.isComic
        ? {ReaderCapability.image, ReaderCapability.fixedLayout}
        : {ReaderCapability.selectableText, ReaderCapability.reflow},
  );
  void pluginChanged() {
    if (!mounted) return;
    setState(() {});
    if (paragraphs != null && !widget.book.isComic) {
      unawaited(
        reloadText().catchError((Object e) {
          if (mounted) setState(() => error = '$e');
        }),
      );
    }
  }

  Future<void> invoke(PluginAction action, ExtensionContext scope) async {
    await withOverlay(() async {
      try {
        final result = await widget.plugins!.invoke(action.id, scope);
        if (result != null && mounted) {
          await showPluginResult(context, action, result);
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(e.toString())));
        }
      }
      return null;
    });
  }

  bool get foreground =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && !overlay && !exiting) {
      tracker.resume();
    } else {
      unawaited(saveComicAnchor());
      unawaited(tracker.pause());
    }
  }

  Future<T?> withOverlay<T>(Future<T?> Function() show) async {
    overlayDepth++;
    await saveComicAnchor();
    await tracker.pause();
    try {
      return await show();
    } finally {
      overlayDepth--;
      if (mounted && foreground && !overlay && !exiting) tracker.resume();
    }
  }

  bool paginationPending = false;
  List<String>? paragraphs;

  /// Heading outline derived by the core, so the client never re-guesses it.
  List<ReaderOutlineEntry> outline = const [];
  MarkdownDocument? markdownDocument;
  String? textEncoding;
  String? error;
  late int index = widget.initialPosition;
  late PageController pages = PageController(initialPage: index);
  final textController = ItemScrollController();
  double fontSize = 20;
  int textOffset = 0;
  final pagedTextController = PagedTextController();
  TextPagination? textLayout;
  Object? paginationKey;

  /// The layout and mode the paged view was last positioned for. The view is
  /// re-positioned only when one of them changes: a rebuild for anything else
  /// (the save status after every turn) must never snap a page that is being
  /// dragged or is animating back to its start.
  (TextPagination?, bool)? positionedFor;

  /// System fonts can arrive after the first layout; measured pages are then
  /// stale, so the cache is dropped and the book re-measured once.
  void fontsChanged() {
    if (!mounted) return;
    setState(() => paginationKey = null);
  }

  String get textSource => widget.book.pages.isEmpty
      ? '${widget.book.revision}'
      : widget.book.pages.first['resource']['id'] as String? ??
            '${widget.book.revision}';
  String get anchorSource => '$textSource:${textEncoding ?? 'auto'}';
  String? providerId;
  ReaderFormatRegistration get provider =>
      selectedProvider(widget.book, widget.plugins, providerId);
  bool get useMarkdown => provider.surface == 'markdown';

  bool saving = false;
  String saveLabel = '阅读位置自动保留';
  int get count =>
      widget.book.isComic ? widget.book.pages.length : paragraphs?.length ?? 0;
  @override
  void initState() {
    super.initState();
    // A fixed-page PDF and a reflowed document own their own screen: neither
    // has a paragraph list for this reader to page through.
    if (widget.book.isPdf || widget.book.isDocument) return;
    WidgetsBinding.instance.addObserver(this);
    widget.plugins?.addListener(pluginChanged);
    PaintingBinding.instance.systemFonts.addListener(fontsChanged);
    heartbeat = Timer.periodic(const Duration(seconds: 1), (_) {
      if (tracker.clock.isRunning) {
        tracker.sample();
        if (heartbeat!.tick % 15 == 0) unawaited(tracker.flush());
      }
    });
    load();
  }

  @override
  void dispose() {
    if (widget.book.isPdf || widget.book.isDocument) {
      super.dispose();
      return;
    }
    comicAnchorTimer?.cancel();
    unawaited(saveComicAnchor());
    pages.dispose();
    scrollMetrics.dispose();
    heartbeat?.cancel();
    PaintingBinding.instance.systemFonts.removeListener(fontsChanged);
    WidgetsBinding.instance.removeObserver(this);
    widget.plugins?.removeListener(pluginChanged);
    unawaited(tracker.pause());
    super.dispose();
  }

  /// Re-reads the text after an encoding change. Bytes are untouched; only the
  /// interpretation and the stored per-book choice change, so the paragraph
  /// list is replaced in place and the reading position is clamped.
  Future<void> reloadText() async {
    final doc = await widget.api.call('read_text', {'book': widget.book.id});
    final text = (doc['paragraphs'] as List).cast<String>();
    final markdown = useMarkdown
        ? MarkdownDocument.parse(doc['source'] as String? ?? text.join('\n\n'))
        : null;
    if (!mounted) return;
    setState(() {
      paragraphs = text;
      textEncoding = doc['encoding'] as String?;
      outline = ReaderOutlineEntry.parse(doc['outline']);
      markdownDocument = markdown;
      if (index >= text.length && text.isNotEmpty) index = text.length - 1;
      textOffset = 0;
      error = null;
    });
    tracker.total = count;
  }

  Future<void> applyEncoding(String? encoding) async {
    await widget.api.call('set_text_encoding', {
      'book': widget.book.id,
      'encoding': ?encoding,
    });
    await reloadText();
  }

  /// Direction lives in the core so it survives restarts and can inherit from
  /// the project; the reader only mirrors the effective value.
  ///
  /// The core direction is one of LeftToRight / RightToLeft / TopToBottom.
  /// `rightToLeft` covers only the horizontal pair, so a TopToBottom book needs
  /// the separate [verticalTurn] flag; without it the paged view keeps sliding
  /// left/right after the user switched to top/bottom turns.
  bool verticalTurn = false;
  Future<void> reloadDirection() async {
    // Only image books carry a turn direction; text has no axis to mirror.
    if (!widget.book.isComic) return;
    // Direction is decorative next to the pages themselves: a host that cannot
    // answer (older bridge, failed call) keeps horizontal turns.
    final Object? effective;
    try {
      effective = await widget.api.call('effective_direction', {
        'book': widget.book.id,
      });
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final own = effective is Map && effective['source'] == widget.book.id;
    final value = own
        ? effective['value']?.toString() ?? 'LeftToRight'
        : preferences.continuous
        ? 'TopToBottom'
        : preferences.rightToLeft
        ? 'RightToLeft'
        : 'LeftToRight';
    final wasVertical = verticalTurn;
    setState(() {
      verticalTurn = own && value == 'TopToBottom';
      if (verticalTurn) {
        preferences.continuous = true;
      } else if (own) {
        preferences.continuous = false;
      }
      // RTL belongs to the horizontal pair. Once turns are vertical the stale
      // flag is cleared so a later return to 从右到左 does not silently stay on.
      preferences.rightToLeft = value == 'RightToLeft';
    });
    // A PageController caches the viewport it first saw, so flipping the scroll
    // axis in place would keep the old scroll extent. Rebuild it in the new
    // axis from the current page, the same way toggling continuous reading does.
    if (wasVertical != verticalTurn) {
      zoomed = false;
      final oldPages = pages;
      if (mounted) setState(() => pages = PageController(initialPage: index));
      WidgetsBinding.instance.addPostFrameCallback((_) => oldPages.dispose());
    }
  }

  Future<void> writeComicSetting(
    String method,
    Map<String, dynamic> values,
  ) async {
    try {
      await widget.api.call(method, {'book': widget.book.id, ...values});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('阅读设置未保存：$e')));
      }
    }
  }

  Future<void> loadComicGap() async {
    if (!widget.book.isComic) return;
    try {
      final effective = await widget.api.call('effective_gap', {
        'book': widget.book.id,
      });
      // Explicit book/project choices win. With no override, keep the latest
      // format default (continuous seamless comics) and legacy user choice.
      if (effective is Map && effective['source'] != null) {
        preferences.seamless = effective['value'] == 'Seamless';
      }
    } catch (_) {
      // Older hosts without gap resolution can still display the full pages.
    }
  }

  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      providerId = await ReaderProviderPreferences.read(widget.book);
      final savedFont =
          (prefs.getDouble('reader-font-size.v1.${widget.book.id}') ??
                  prefs.getDouble('reader-font-size') ??
                  20)
              .clamp(14.0, 32.0);
      await preferences.load(
        bookId: widget.book.id,
        format: widget.book.format,
      );
      await loadComicGap();
      if (widget.book.isComic && widget.book.pages.isNotEmpty) {
        try {
          final raw = prefs.getString(
            'reader-image-anchor.v1.${widget.book.id}',
          );
          if (raw != null) {
            final anchor = jsonDecode(raw);
            final page =
                widget.book.pages[index.clamp(0, widget.book.pages.length - 1)];
            if (anchor is Map &&
                anchor['version'] == 1 &&
                anchor['page'] == page['id'] &&
                anchor['resource'] == page['resource']['id'] &&
                anchor['within'] is num &&
                (anchor['within'] as num).isFinite) {
              comicWithin = (anchor['within'] as num).toDouble().clamp(
                0.0,
                1.0,
              );
              comicAnchorPage = index;
              // Decode the cheap header before refining a position inside a long
              // image, so an unloaded placeholder cannot determine the offset.
              if (comicWithin > 0) {
                await ComicPage.load(
                  widget.api,
                  widget.book,
                  page['id'] as String,
                );
              }
            }
          }
        } catch (_) {
          /* A missing/corrupt local anchor must not prevent reading. */
        }
      }
      List<String>? text;
      List<ReaderOutlineEntry>? entries;
      MarkdownDocument? markdown;
      if (!widget.book.isComic) {
        final doc = await widget.api.call('read_text', {
          'book': widget.book.id,
        });
        text = (doc['paragraphs'] as List).cast<String>();
        textEncoding = doc['encoding'] as String?;
        entries = ReaderOutlineEntry.parse(doc['outline']);
        if (useMarkdown) {
          markdown = MarkdownDocument.parse(
            doc['source'] as String? ?? text.join('\n\n'),
          );
        }
      }
      if (text != null && index < text.length) {
        try {
          final encoded = prefs.getString(
            'reader-text-anchor.v1.${widget.book.id}',
          );
          if (encoded != null) {
            final anchor = jsonDecode(encoded);
            if (anchor['version'] == 1 &&
                anchor['source'] == anchorSource &&
                anchor['paragraph'] == index &&
                anchor['offset'] is int &&
                anchor['offset'] >= 0 &&
                anchor['offset'] < text[index].length) {
              textOffset = anchor['offset'];
            }
          }
        } catch (_) {
          /* Retain unrecognised local anchors; the core paragraph remains readable. */
        }
      }
      if (!mounted) return;
      setState(() {
        paragraphs = text;
        outline = entries ?? const [];
        markdownDocument = markdown;
        fontSize = savedFont;
        error = null;
        initialized = true;
      });
      if (count > 0 && index >= count) {
        index = count - 1;
        if (widget.book.isComic && pages.hasClients) {
          pages.jumpToPage(index);
        }
      }
      tracker.total = count;
      tracker.position = index;
      await tracker.checkpoint();
      if (mounted && foreground && !overlay && !exiting) tracker.resume();
      // Same for the turn axis: a TopToBottom book must slide vertically on the
      // very first frame, not only after the user reopens the direction panel.
      unawaited(reloadDirection());
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
        });
      }
    }
  }

  /// Where continuous text settled: the paragraph at the top of the screen and
  /// how far into it. Moving inside one paragraph only refreshes the local
  /// anchor; reaching another paragraph saves progress as well.
  void textPosition(int paragraph, double within) {
    final text = paragraphs;
    if (text == null || paragraph < 0 || paragraph >= text.length) return;
    final length = text[paragraph].length;
    textOffset = length == 0
        ? 0
        : (within * length).floor().clamp(0, length - 1);
    if (paragraph == index) {
      unawaited(saveAnchor(paragraph, textOffset));
    } else {
      save(paragraph);
    }
  }

  /// The local in-paragraph anchor beside the core's paragraph progress.
  Future<void> saveAnchor(int paragraph, int offset) async {
    if (widget.book.isComic) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      'reader-text-anchor.v1.${widget.book.id}',
      jsonEncode({
        'version': 1,
        'source': anchorSource,
        'paragraph': paragraph,
        'offset': offset,
      }),
    );
  }

  Future<void> save(int value) async {
    if (!mounted) return;
    if (value != index) {
      zoomed = false;
      if (widget.book.isComic && !comicContinuous) {
        comicWithin = 0;
        comicAnchorPage = value;
      }
    }
    tracker.position = value;
    unawaited(
      widget.plugins?.hostServices?.broker
              .emit('reader.position', {
                'bookId': widget.book.id,
                'position': value,
              })
              .catchError((Object _) => null) ??
          Future.value(),
    );
    setState(() {
      index = value;
      saving = true;
    });
    try {
      final saved = widget.api.call('save_progress', {
        'book': widget.book.id,
        'index': value,
        if (paragraphs != null && !widget.book.isComic && !widget.book.isPdf)
          'content_progress':
              (TextReader.fractionOf(
                        paragraphs!,
                        value,
                        withinOf(value, textOffset),
                      ) *
                      10000)
                  .round(),
      });
      // Queued after the save, so the neighbours are usually ready by the
      // time the reader turns to them.
      if (widget.book.isComic) {
        for (final next in [value + 1, value - 1]) {
          if (next >= 0 && next < count) {
            ComicPage.prefetch(
              widget.api,
              widget.book,
              widget.book.pages[next]['id'] as String,
            );
          }
        }
      }
      await saved;
      // Written with the latest place in this paragraph; once the reader has
      // moved on, the newer save owns the anchor and this one must not
      // overwrite it.
      if (index == value) await saveAnchor(value, textOffset);
      if (mounted) {
        setState(() {
          saveLabel =
              '已保存到${widget.book.isComic ? '第 ${value + 1} 页' : '第 ${value + 1} 段'}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          saveLabel = '保存失败：$e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          saving = false;
        });
      }
    }
  }

  /// Moves to [value] in the active unit (page, or paragraph while text
  /// scrolls). Only a neighbouring turn animates: a slider or panel jump lands
  /// directly, so it neither plays a long slide nor reports — and saves —
  /// every page it would have passed on the way.
  void go(int value) {
    if (!mounted) return;
    if (widget.book.isComic) {
      comicWithin = 0;
      comicAnchorPage = value;
    }
    if (!widget.book.isComic && preferences.textPaged && textLayout != null) {
      if (value < 0 || value >= textLayout!.pages.length) return;
      if (value == textLayout!.pageFor(index, textOffset)) return;
      final current =
          pagedTextController.page ?? textLayout!.pageFor(index, textOffset);
      // A new whole-book layout may replace the nearby layout while the turn
      // animation is running. Preserve the requested source anchor first so
      // replacing the PageView cannot silently return the reader to its old page.
      final target = textLayout!.pages[value].anchor;
      if (index != target.paragraph || textOffset != target.start) {
        textOffset = target.start;
        unawaited(save(target.paragraph));
      }
      pagedTextController.goTo(
        value,
        animate: preferences.pageAnimation && (value - current).abs() <= 1,
      );
      return;
    }
    if (value < 0 || value >= count) return;
    zoomed = false;
    if (!widget.book.isComic) {
      if (textController.isAttached) {
        textController.jumpTo(
          index:
              markdownDocument?.blockForParagraph(value) ??
              TextChunks.of(paragraphs!).locate(value, 0).$1,
        );
      }
      // A jump from a panel lands on the paragraph's start.
      textOffset = 0;
      save(value);
    } else if (comicContinuous && comicController.isAttached) {
      comicController.jumpTo(index: value);
      save(value);
    } else if (!preferences.pageAnimation ||
        (value - index).abs() > 1 ||
        MediaQuery.disableAnimationsOf(context)) {
      pages.jumpToPage(value);
    } else {
      pages.animateToPage(
        value,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
  }

  void goToText(int paragraph, int offset) {
    final text = paragraphs;
    if (text == null || paragraph < 0 || paragraph >= text.length) return;
    textOffset = offset.clamp(0, text[paragraph].length);
    seekController.seek(
      TextReader.fractionOf(text, paragraph, withinOf(paragraph, textOffset)),
    );
    unawaited(save(paragraph));
  }

  void comicAnchor(int page, double within) {
    comicAnchorPage = page;
    comicWithin = within;
    comicAnchorTimer?.cancel();
    comicAnchorTimer = Timer(const Duration(milliseconds: 250), () {
      if (mounted) unawaited(saveComicAnchor());
    });
  }

  Future<void> saveComicAnchor() async {
    if (!initialized || !widget.book.isComic) return;
    final book = widget.book;
    final page = comicAnchorPage ?? index;
    if (page < 0 || page >= book.pages.length) return;
    final entry = book.pages[page];
    final within = comicWithin;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(
        'reader-image-anchor.v1.${book.id}',
        jsonEncode({
          'version': 1,
          'page': entry['id'],
          'resource': entry['resource']['id'],
          'within': within,
        }),
      )) {
        throw StateError('本机偏好写入失败');
      }
    } catch (e) {
      if (mounted) setState(() => saveLabel = '图内阅读位置未保存：$e');
    }
  }

  /// Navigates to a source paragraph whatever unit the reader shows: paged
  /// text addresses pages, so the paragraph is translated first.
  void goParagraph(int paragraph) {
    final layout = textLayout;
    if (!widget.book.isComic &&
        preferences.textPaged &&
        layout != null &&
        layout.pages.isNotEmpty) {
      go(layout.pageFor(paragraph));
    } else {
      go(paragraph);
    }
  }

  Future<void> changeFont(double value) async {
    setState(() {
      fontSize = value.clamp(14, 32);
    });
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('reader-font-size.v1.${widget.book.id}', fontSize);
  }

  Widget selectionMenu(BuildContext context, EditableTextState state) {
    final value = state.textEditingValue;
    final selection = value.selection.textInside(value.text);
    final current = scope(selection);
    unawaited(
      widget.plugins?.hostServices?.broker
              .emit('reader.selection', {
                'bookId': widget.book.id,
                'selectedText': selection,
              })
              .catchError((Object _) => null) ??
          Future.value(),
    );
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: state.contextMenuAnchors,
      buttonItems: [
        ...state.contextMenuButtonItems,
        for (final action
            in widget.plugins?.actions(ExtensionPoint.textSelection, current) ??
                <PluginAction>[])
          ContextMenuButtonItem(
            label: action.name,
            onPressed: () {
              ContextMenuController.removeAny();
              invoke(action, current);
            },
          ),
      ],
    );
  }

  Future<void> addNote() async {
    final result = await withOverlay(
      () => showDialog<String>(
        context: context,
        builder: (_) => const NoteDialog(),
      ),
    );
    if (result == null || result.trim().isEmpty) return;
    try {
      await widget.api.call('add_note', {
        'book': widget.book.id,
        'index': index,
        'text': result,
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('笔记已保存，并关联当前阅读位置')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  Future<void> showNotes() async {
    try {
      final response = await widget.api.call('notes', {'book': widget.book.id});
      final notes = (response as List)
          .map((n) => Map<String, dynamic>.from(n as Map))
          .toList();
      if (!mounted) return;
      if (notes.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('这本书还没有关联笔记。')));
        return;
      }
      final target = await withOverlay(
        () => showDialog<Map<String, dynamic>>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('关联笔记'),
            content: SizedBox(
              width: 600,
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: notes.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, i) {
                  final note = notes[i];
                  final location = note['location'] as Map? ?? const {};
                  final paragraph = location['Paragraph']?['index'];
                  final page = location['Page']?['page'];
                  final anchor = page != null
                      ? '图片页 ${widget.book.pages.indexWhere((p) => p['id'] == page) + 1}'
                      : '第 ${(paragraph as num?)?.toInt() ?? 0} 段';
                  final stale = note['stale'] == true;
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
                onPressed: () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          ),
        ),
      );
      if (target == null || !mounted) return;
      final location = target['location'] as Map? ?? const {};
      final page = location['Page']?['page'];
      if (page != null) {
        final position = widget.book.pages.indexWhere((p) => p['id'] == page);
        if (position >= 0) go(position);
      } else {
        goParagraph((location['Paragraph']?['index'] as num?)?.toInt() ?? 0);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.toString())));
      }
    }
  }

  @override
  Widget build(BuildContext context) => widget.book.isPdf
      ? PdfReaderScreen(
          api: widget.api,
          book: widget.book,
          initialPosition: widget.initialPosition,
          plugins: widget.plugins,
        )
      : widget.book.isDocument
      ? DocumentReaderScreen(
          api: widget.api,
          book: widget.book,
          initialPosition: widget.initialPosition,
          plugins: widget.plugins,
        )
      : LayoutBuilder(
          builder: (context, constraints) =>
              buildReader(context, constraints.biggest),
        );

  Widget buildReader(BuildContext context, Size viewport) {
    final base = Theme.of(context);
    // Reading day/night is content state. Keep the surrounding ReaderShell
    // under the app's own UI theme so chrome never changes with the page.
    final articleDark = preferences.isDark(base.brightness);
    final articleScheme = ColorScheme.fromSeed(
      seedColor: base.colorScheme.primary,
      brightness: articleDark ? Brightness.dark : Brightness.light,
    );
    final articleBackground = preferences.background(base.brightness);
    final articleTheme = base.copyWith(
      scaffoldBackgroundColor: articleBackground,
      textTheme: base.textTheme.apply(
        bodyColor: articleScheme.onSurface,
        displayColor: articleScheme.onSurface,
      ),
    );
    final safe = MediaQuery.paddingOf(
      context,
    ).copyWith(bottom: MediaQuery.viewPaddingOf(context).bottom);
    final canvas = Size(
      (viewport.width - safe.horizontal).clamp(1, double.infinity),
      (viewport.height - safe.vertical).clamp(1, double.infinity),
    );
    // Markdown pages from the same paragraph text its scrolling view shows, so
    // switching to left-right keeps a real page count instead of falling back
    // to a scroll the reader did not ask for.
    // Continuous reading never needs whole-book glyph pagination.
    if (!widget.book.isComic && preferences.textPaged && paragraphs != null) {
      final style = TextStyle(
        fontSize: fontSize,
        height: preferences.lineHeight,
        fontWeight: FontWeight
            .values[((preferences.weight / 100).round() - 1).clamp(0, 8)],
        fontFamily: preferences.font == 'serif' ? 'Noto Serif CJK SC' : null,
        fontFamilyFallback: const ['SimSun', 'serif'],
        letterSpacing: .3,
        color: articleScheme.onSurface,
      );
      // Keyed on every measured input; late-arriving system fonts clear the
      // key through [fontsChanged], so a cached layout is never stale.
      final key = (
        canvas,
        style,
        MediaQuery.textScalerOf(context),
        preferences.paragraphGap,
        preferences.margin,
        paragraphs,
      );
      // Rebuilt at most once per input change; caching only the inputs keeps an
      // input-free rebuild from handing back a layout measured for another size.
      if (key != paginationKey) {
        paginationKey = key;
        paginationPending = true;
        unawaited(
          TextPagination.layoutAsync(
            paragraphs: paragraphs!,
            viewport: canvas,
            style: style,
            scaler: MediaQuery.textScalerOf(context),
            direction: Directionality.of(context),
            margin: preferences.margin,
            paragraphGap: preferences.paragraphGap,
            reserved: 0,
            backgroundColor: articleBackground,
            chapterStarts: [
              for (final entry in outline) (entry.index, entry.offset),
            ],
            anchorParagraph: index,
            anchorOffset: textOffset,
            onPreview: (layout) {
              if (mounted && key == paginationKey && preferences.textPaged) {
                setState(() => textLayout = layout);
              }
            },
            cancelled: () =>
                !mounted || key != paginationKey || !preferences.textPaged,
          ).then(
            (layout) {
              if (mounted && key == paginationKey && preferences.textPaged) {
                setState(() {
                  textLayout = layout;
                  paginationPending = false;
                });
              }
            },
            onError: (Object e) {
              if (mounted && key == paginationKey && preferences.textPaged) {
                setState(() {
                  error = e.toString();
                  paginationPending = false;
                });
              }
            },
          ),
        );
      }
    }
    if (!preferences.textPaged) {
      paginationKey = null;
      textLayout = null;
    }
    final textPage = textLayout?.pageFor(index, textOffset) ?? 0;
    // A page layout that appears later (the first frame, a mode switch, a
    // font change) must land on the paragraph the reader was reading.
    final positioning = (textLayout, preferences.textPaged);
    if (preferences.textPaged && positioning != positionedFor) {
      positionedFor = positioning;
      final layout = textLayout;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            !identical(layout, textLayout) ||
            !pagedTextController.attached ||
            layout == null ||
            layout.pages.isEmpty) {
          return;
        }
        final target = layout.pageFor(index, textOffset);
        if (pagedTextController.page != target) {
          pagedTextController.goTo(target, animate: false);
        }
      });
    } else if (!preferences.textPaged) {
      positionedFor = null;
    }
    final layoutAtBuild = textLayout;
    Widget textPageWidget() => PagedTextReader(
      key: ValueKey(textLayout),
      layout: textLayout!,
      controller: pagedTextController,
      initialPage: textPage,
      rightToLeft: preferences.rightToLeft,
      effect: preferences.turnEffect,
      onSelectionActive: (value) => selectionActive = value,
      contextMenuBuilder: selectionMenu,
      onPage: (page) {
        if (!identical(layoutAtBuild, textLayout)) return;
        final anchor = layoutAtBuild!.pages[page].anchor;
        if (index == anchor.paragraph && textOffset == anchor.start) return;
        textOffset = anchor.start;
        save(anchor.paragraph);
      },
    );
    final content = Theme(
      data: articleTheme,
      child: ColoredBox(
        color: articleBackground,
        child: SafeArea(
          top: false,
          bottom: false,
          child: Column(
            children: [
              if (widget.book.format == 'Markdown' &&
                  (!preferences.textPaged ||
                      textLayout == null ||
                      textLayout!.pages.isEmpty))
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 8,
                  ),
                  child: Text(
                    'Markdown · 正文只读，交互单独保存',
                    style: TextStyle(
                      color: articleScheme.onSurfaceVariant,
                      fontSize: 12,
                    ),
                  ),
                ),
              Expanded(
                child: error != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(error!),
                              const SizedBox(height: 16),
                              OutlinedButton(
                                onPressed: load,
                                child: const Text('重新读取'),
                              ),
                            ],
                          ),
                        ),
                      )
                    : !initialized || count == 0
                    ? Center(
                        child:
                            !initialized ||
                                paragraphs == null && !widget.book.isComic
                            ? const CircularProgressIndicator()
                            : const Text('这份内容还没有可阅读的段落。'),
                      )
                    : widget.book.isComic
                    ? comicContinuous
                          ? ComicStrip(
                              api: widget.api,
                              book: widget.book,
                              position: index,
                              rotation: preferences.rotation,
                              seamless: preferences.seamless,
                              onZoomChanged: (value) => zoomed = value,
                              controller: comicController,
                              onPosition: save,
                              initialWithin: comicAnchorPage == index
                                  ? comicWithin
                                  : 0,
                              onAnchor: comicAnchor,
                              onMetrics: (value) => scrollMetrics.value = value,
                              seek: seekController,
                            )
                          // Paging is always left/right and whole pages only;
                          // top-to-bottom reading is the strip above.
                          : PageView.builder(
                              controller: pages,
                              reverse: preferences.rightToLeft,
                              itemCount: count,
                              onPageChanged: save,
                              itemBuilder: (context, current) {
                                final page =
                                    widget.book.pages[current]['id'] as String;
                                return RotatedBox(
                                  quarterTurns: preferences.rotation,
                                  child: ComicPage(
                                    api: widget.api,
                                    book: widget.book,
                                    page: page,
                                    fitWidth: preferences.fit == 'width',
                                    onZoomChanged: (value) => zoomed = value,
                                  ),
                                );
                              },
                            )
                    : useMarkdown &&
                          markdownDocument != null &&
                          !(preferences.textPaged &&
                              textLayout != null &&
                              textLayout!.pages.isNotEmpty)
                    ? MarkdownContent(
                        api: widget.api,
                        book: widget.book,
                        document: markdownDocument!,
                        controller: textController,
                        position: index,
                        onPosition: save,
                        onMetrics: (value) => scrollMetrics.value = value,
                        seek: seekController,
                        onSelectionActive: (value) => selectionActive = value,
                        fontSize: fontSize,
                        lineHeight: preferences.lineHeight,
                        margin: preferences.margin,
                        paragraphGap: preferences.paragraphGap,
                        fontFamily: preferences.font == 'serif'
                            ? 'Noto Serif CJK SC'
                            : null,
                      )
                    : preferences.textPaged
                    ? ((textLayout == null)
                          ? const Center(child: CircularProgressIndicator())
                          : textPageWidget())
                    : TextReader(
                        title: widget.book.title,
                        paragraphs: paragraphs!,
                        fontSize: fontSize,
                        lineHeight: preferences.lineHeight,
                        fontWeight:
                            FontWeight.values[((preferences.weight / 100)
                                        .round() -
                                    1)
                                .clamp(0, 8)],
                        onSelectionActive: (value) => selectionActive = value,
                        paragraphGap: preferences.paragraphGap,
                        margin: preferences.margin,
                        fontFamily: preferences.font == 'serif'
                            ? 'Noto Serif CJK SC'
                            : null,
                        position: index,
                        initialWithin: withinOf(index, textOffset),
                        controller: textController,
                        contextMenuBuilder: selectionMenu,
                        onPosition: textPosition,
                        onMetrics: (value) => scrollMetrics.value = value,
                        seek: seekController,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
    final status = saving ? '正在保存阅读位置' : saveLabel;
    adapter = widget.book.isComic
        ? ComicReaderAdapter(
            book: widget.book,
            position: index,
            status: status,
            content: (_) => content,
            onGo: go,
            locked: () => zoomed,
            continuous: comicContinuous,
            rightToLeft: preferences.rightToLeft,
            animatePageTurns: preferences.pageAnimation,
            pageBuilder: (context, current, preview) {
              final page = widget.book.pages[current]['id'] as String;
              return RotatedBox(
                quarterTurns: preferences.rotation,
                child: ComicPage(
                  api: widget.api,
                  book: widget.book,
                  page: page,
                  interactive: !preview,
                  fitWidth: preview ? false : preferences.fit == 'width',
                ),
              );
            },
            thumbnail: (_, current) {
              final page = widget.book.pages[current]['id'] as String;
              return ComicPage(
                api: widget.api,
                book: widget.book,
                page: page,
                interactive: false,
              );
            },
          )
        : useMarkdown &&
              markdownDocument != null &&
              !(preferences.textPaged &&
                  textLayout != null &&
                  textLayout!.pages.isNotEmpty)
        ? MarkdownReaderAdapter(
            book: widget.book,
            position: index,
            status: status,
            content: (_) => content,
            onGo: go,
            locked: () => selectionActive,
            paragraphs: paragraphs ?? [],
            document: markdownDocument!,
          )
        : preferences.textPaged &&
              textLayout != null &&
              textLayout!.pages.isNotEmpty
        ? PagedTextReaderAdapter(
            book: widget.book,
            position: textPage,
            status: status,
            content: (_) => content,
            onGo: (page) {
              final current = textLayout;
              if (current == null ||
                  layoutAtBuild == null ||
                  page < 0 ||
                  page >= layoutAtBuild.pages.length) {
                return;
              }
              final anchor = layoutAtBuild.pages[page].anchor;
              go(
                identical(layoutAtBuild, current)
                    ? page
                    : current.pageFor(anchor.paragraph, anchor.start),
              );
            },
            locked: () => selectionActive,
            layout: textLayout!,
            paragraphs: paragraphs!,
            entries: outline,
            rightToLeft: preferences.rightToLeft,
            animatePageTurns: preferences.pageAnimation,
          )
        : TextReaderAdapter(
            book: widget.book,
            position: index,
            status: status,
            content: (_) => content,
            onGo: go,
            locked: () => selectionActive,
            paragraphs: paragraphs ?? [],
            currentOffset: textOffset,
            onGoToText: goToText,
            entries: outline,
          );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: base.brightness == Brightness.dark
          ? SystemUiOverlayStyle.light
          : SystemUiOverlayStyle.dark,
      child: PopScope(
        canPop: exiting,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop || exiting) return;
          await saveComicAnchor();
          await tracker.pause();
          if (!mounted) return;
          if (tracker.error != null) {
            ScaffoldMessenger.of(
              this.context,
            ).showSnackBar(SnackBar(content: Text('阅读统计未保存：${tracker.error}')));
          }
          setState(() => exiting = true);
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            Navigator.of(this.context).pop();
          });
        },
        child: Scaffold(
          // Dialogs/sheets handle the keyboard themselves. Keep this canvas at
          // the size used to paginate; shrinking it would overflow existing pages.
          resizeToAvoidBottomInset: false,
          body: ReaderShell(
            paperColor: articleBackground,
            adapter: adaptReaderProvider(provider, adapter, widget.plugins),
            desktop: desktop,
            dock: preferences.dock,
            scroll: adapter.paged ? null : scrollSource,
            settingsBuilder: buildSettings,
            extensions: ReaderExtensions(widget.plugins, scope()),
            invokeExtension: (action) => invoke(action, scope()),
            runOverlay: (show) async {
              await withOverlay(show);
            },
            addNote: addNote,
            showNotes: showNotes,
            encodingBuilder: widget.book.isComic || widget.book.isPdf
                ? null
                : (context) => ReaderEncodingPanel(
                    load: () => widget.api.call('text_encoding', {
                      'book': widget.book.id,
                    }),
                    apply: (encoding) => applyEncoding(encoding),
                  ),
            directionBuilder: widget.book.isComic
                ? (context) => ComicDirectionPanel(
                    api: widget.api,
                    book: widget.book,
                    preferences: preferences,
                    onChanged: () async {
                      await reloadDirection();
                    },
                  )
                : null,
          ),
        ),
      ),
    );
  }
}
