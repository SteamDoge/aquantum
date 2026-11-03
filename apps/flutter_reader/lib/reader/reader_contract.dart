// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

/// The shell consumes capabilities, never file suffixes or renderer classes.
enum ReaderSetting {
  turnEffect,
  fontSize,
  fontFamily,
  fontWeight,
  lineHeight,
  paragraphGap,
  margin,
  theme,
  animation,
  continuous,
  fit,
  direction,
  imageGap,
  rotation,
  textPaging,
}

enum ReaderPanel {
  format,
  settings,
  navigation,
  view,
  bookmarks,
  search,
  more,
  encoding,
  direction,
}

class ReaderCapabilities {
  final Set<ReaderSetting> settings;
  final bool search, bookmarks;
  final String searchExplanation, navigationLabel;

  /// Text books can reinterpret their bytes; image books cannot.
  final bool encoding;
  const ReaderCapabilities({
    this.settings = const {},
    this.search = false,
    this.bookmarks = true,
    this.searchExplanation = '当前渲染器没有提供可检索的文字。',
    this.navigationLabel = '内容导航',
    this.encoding = false,
  });
  bool supports(ReaderSetting setting) => settings.contains(setting);
}

class ReaderLocation {
  final String id, label;
  final int index;
  const ReaderLocation(this.id, this.label, this.index);
}

class ReaderSearchHit {
  final ReaderLocation location;
  final String excerpt;
  const ReaderSearchHit(this.location, this.excerpt);
}

/// Where a top-to-bottom (continuous) reader is in the whole book.
///
/// Both values are shares of the book's content length — characters for text,
/// displayed image height for comics, the engine's own text measure for
/// reflowed documents — never of item or chapter counts.
class ReaderScrollMetrics {
  /// Share of the book above the top of the viewport, 0 at the start.
  final double fraction;

  /// Share of the book on screen, or `null` when the renderer cannot tell.
  final double? viewport;
  const ReaderScrollMetrics(this.fraction, [this.viewport]);

  @override
  bool operator ==(Object other) =>
      other is ReaderScrollMetrics &&
      other.fraction == fraction &&
      other.viewport == viewport;

  @override
  int get hashCode => Object.hash(fraction, viewport);
}

/// A continuous reader's whole-book position and the way to move it, handed to
/// the shell's scrollbar. Kept beside the adapter rather than on it, so a
/// format module wrapping the adapter cannot drop it.
class ReaderScrollSource {
  final ValueListenable<ReaderScrollMetrics> metrics;

  /// Moves the top of the viewport to [fraction] of the book.
  final void Function(double fraction) seek;
  const ReaderScrollSource({required this.metrics, required this.seek});
}

/// Lets a screen ask whichever continuous list it is showing to move to a share
/// of the book; the list attaches itself while mounted.
class ReaderSeekController {
  void Function(double fraction)? _seek;
  void attach(void Function(double fraction) seek) => _seek = seek;
  void detach(void Function(double fraction) seek) {
    if (identical(_seek, seek)) _seek = null;
  }

  void seek(double fraction) => _seek?.call(fraction.clamp(0.0, 1.0));
}

abstract interface class ReaderAdapter {
  String get documentId;
  String get title;
  String get unit;
  int get position;
  int get count;
  bool get paged;

  /// Kept so a renderer can still declare where its own page counter lives.
  ///
  /// The shell no longer reads it: every renderer gets the same bottom
  /// controller (arrow, slider, `position / count unit`, status), because a
  /// reader that silently lost its slider when it switched between scrolling
  /// and paging was two different readers. [count] must be at least 1 whenever
  /// the book has a readable position, so the slider always spans something.
  bool get pageProgress;
  bool get rightToLeft;

  /// True when pages turn top-to-bottom instead of left/right. The shell uses
  /// it so tap and drag regions follow the real turn axis.
  bool get verticalTurn;
  bool get interactionLocked;
  String get status;
  ReaderCapabilities get capabilities;
  ReaderLocation location(int index);
  int? resolveLocation(String id);
  void goTo(int index);
  Widget buildContent(BuildContext context);
  Widget? buildThumbnail(BuildContext context, int index);
  Future<List<ReaderSearchHit>> search(String query);
}

/// Optional real-page surface shared by paged engines and the shell overview.
///
/// A renderer that cannot rebuild an arbitrary page on demand (a live browser
/// surface, for one) keeps the interface but reports itself through
/// [LiveReaderAdapter] so the shell never swaps its content for the grid.
abstract interface class PagedReaderAdapter implements ReaderAdapter {
  /// The page at [index], or `null` when this renderer cannot rebuild a page
  /// it is not displaying. The shell never invents a page in its place.
  Widget? buildPage(BuildContext context, int index, {required bool preview});
  bool get animatePageTurns;
}

/// A measured page keeps its original canvas while a replacement layout is
/// being prepared. The shell scales that canvas instead of relaying out glyphs.
abstract interface class MeasuredPagedReaderAdapter
    implements PagedReaderAdapter {
  Size get pageCanvasSize;
}

abstract interface class OutlineReaderAdapter implements ReaderAdapter {
  List<ReaderLocation> get outline;
}

/// Engines with chapter hrefs/CFIs cannot compare outline ordinals to progress.
abstract interface class ActiveOutlineReaderAdapter
    implements OutlineReaderAdapter {
  int? get activeOutlineIndex;
}

/// Optional stable-anchor navigation, including a character within a paragraph.
abstract interface class LocationReaderAdapter implements ReaderAdapter {
  Future<void> goToLocation(ReaderLocation location);
}

/// A renderer whose content is a live surface, not something Flutter can
/// repaint from memory.
///
/// The shell normally swaps a paged page for its scaled page overview so the
/// whole book can be swept. A browser surface cannot be re-rendered per page
/// and holds the only copy of the laid-out book, so hiding it would show a
/// preview the renderer cannot produce. A renderer declaring this opt-in keeps
/// its content mounted while chrome is visible, and drives page turning from
/// its own content instead of relying on the shell's page grid.
abstract interface class LiveReaderAdapter implements ReaderAdapter {
  /// Whether the live surface handles page turns and shows its own pages, so
  /// the shell must neither hide it behind the page overview nor turn pages on
  /// a tap it already forwarded.
  bool get liveSurface;
}

/// A heading the core derived from the book bytes.
///
/// [index] is the paragraph (or page) the reader jumps to, so an outline entry
/// can never point somewhere the reader does not display. [level] is 1 for
/// chapter-like headings, deeper values for sub-headings.
class ReaderOutlineEntry {
  final int index;
  final String title;
  final int level;
  final int offset;
  const ReaderOutlineEntry(
    this.index,
    this.title,
    this.level, {
    this.offset = 0,
  });

  /// Tolerant parse: the core owns the shape, the client degrades to no
  /// outline rather than failing to open a readable book.
  static List<ReaderOutlineEntry> parse(Object? raw) {
    if (raw is! List) return const [];
    final entries = <ReaderOutlineEntry>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final index = item['index'];
      final title = item['title'];
      if (index is! int || index < 0 || title is! String || title.isEmpty) {
        continue;
      }
      final level = item['level'];
      final offset = item['offset'];
      entries.add(
        ReaderOutlineEntry(
          index,
          title,
          level is int ? level : 1,
          offset: offset is int && offset >= 0 ? offset : 0,
        ),
      );
    }
    return entries;
  }
}

/// The chrome's fixed top strip, and the rest of a scrolled page that summons
/// it. Called only for short stationary taps.
enum ReaderTapAction { toggleChrome, previous, next }

/// Turns a stationary tap into one action for every renderer.
///
/// A horizontal book keeps the behaviour readers already know: the top strip
/// summons the chrome, the leading edge goes back and the rest goes forward.
/// A top-to-bottom book has no side edge to turn on, so the whole page summons
/// the chrome and the turns happen on the scroll itself. Either way the chrome,
/// when visible, is only dismissed by a tap; reflowing and fixed-layout
/// documents follow the same two rules, so no format invents its own bands.
ReaderTapAction readerTapAction({
  required Offset point,
  required Size size,
  required bool chromeVisible,
  required bool paged,
  required bool rightToLeft,
  bool verticalTurn = false,
}) {
  if (chromeVisible) {
    return ReaderTapAction.toggleChrome;
  }
  // Top-to-bottom reading is one continuous scroll: there is no page edge to
  // turn on and a tap must never jump the text, so any tap only brings the
  // chrome back. Only discrete left/right pages have turn bands.
  if (verticalTurn || !paged) {
    return ReaderTapAction.toggleChrome;
  }
  if (point.dy < size.height * .24) {
    return ReaderTapAction.toggleChrome;
  }
  final previous = point.dx < size.width * .15;
  return previous != rightToLeft
      ? ReaderTapAction.previous
      : ReaderTapAction.next;
}

/// Physical page boundaries can differ from a rounded whole-book progress index.
abstract interface class PageTurnBoundaryReaderAdapter {
  bool get canTurnBackward;
  bool get canTurnForward;
}
