// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:aquantum_reader/plugins/plugin_api.dart';
import 'package:aquantum_reader/plugins/plugin_manager.dart';
import 'package:aquantum_reader/reader/reader_contract.dart';
import 'package:aquantum_reader/reader/reader_extensions.dart';
import 'package:aquantum_reader/reader/reader_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// A renderer that draws its own pages in place, like the bundled document
/// engine: the shell must keep it on screen and forward turns to the host.
class LiveAdapter implements PagedReaderAdapter {
  final turned = <int>[];
  int current = 0;
  @override
  String get documentId => 'live-doc';
  @override
  String get title => '青柳随笔';
  @override
  String get unit => '%';
  @override
  int get count => 1000;
  @override
  int get position => current;
  @override
  bool get paged => true;
  @override
  bool get pageProgress => true;
  @override
  bool get animatePageTurns => true;
  @override
  bool get rightToLeft => false;
  @override
  bool get verticalTurn => false;
  @override
  bool get interactionLocked => false;
  @override
  String get status => '约 0%';
  @override
  ReaderCapabilities get capabilities => const ReaderCapabilities();
  @override
  ReaderLocation location(int index) =>
      ReaderLocation('at:$index', '位置 $index', index);
  @override
  int? resolveLocation(String id) => int.tryParse(id.split(':').last);
  @override
  void goTo(int index) => current = index;
  @override
  Widget buildContent(BuildContext context) =>
      const ColoredBox(color: Color(0xfffafafa));
  @override
  Widget? buildPage(BuildContext context, int index, {required bool preview}) =>
      null;
  @override
  Widget? buildThumbnail(BuildContext context, int index) => null;
  @override
  Future<List<ReaderSearchHit>> search(String query) async => [];
}

class LiveDocumentAdapter extends LiveAdapter implements LiveReaderAdapter {
  @override
  bool get liveSurface => true;
}

Widget shell(
  ReaderAdapter adapter, {
  Future<void> Function(int delta)? turn,
  PluginManager? plugins,
}) => MaterialApp(
  home: Scaffold(
    body: ReaderShell(
      adapter: adapter,
      desktop: false,
      dock: 'top',
      settingsBuilder: (_, _) => const Text('能力设置'),
      extensions: ReaderExtensions(
        plugins,
        const ExtensionContext(capabilities: {ReaderCapability.image}),
      ),
      invokeExtension: (_) async {},
      runOverlay: (show) => show(),
      addNote: () async {},
      showNotes: () async {},
      onTurn: turn,
    ),
  ),
);

/// The live-surface expectations in a real application binding: the pointer
/// pipeline the shell relies on only runs end to end there, and the browser
/// engine's real pointer events arrive through that same pipeline.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('a live surface keeps its page and forwards turns', (
    tester,
  ) async {
    final adapter = LiveDocumentAdapter();
    final turned = <int>[];
    await tester.pumpWidget(
      shell(adapter, turn: (delta) async => turned.add(delta)),
    );
    await tester.pumpAndSettle();
    final region = tester.getRect(
      find.byKey(const ValueKey('reader-content-hit-region')),
    );
    await tester.tapAt(
      Offset(region.left + region.width * .85, region.center.dy),
    );
    await tester.pumpAndSettle();
    expect(turned, [1], reason: 'a tap in the turning band asks the host');
    expect(
      adapter.current,
      0,
      reason: 'the percentage counter is not a page index',
    );
  });
}
