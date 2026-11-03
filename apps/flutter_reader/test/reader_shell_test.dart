// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'package:aquantum_reader/data/models.dart';
import 'package:aquantum_reader/reader/reader_bookmarks.dart';
import 'package:aquantum_reader/reader/reader_contract.dart';
import 'package:aquantum_reader/reader/reader_extensions.dart';
import 'package:aquantum_reader/reader/reader_renderers.dart';
import 'package:aquantum_reader/reader/reader_shell.dart';
import 'package:aquantum_reader/reader/reader_interaction.dart';
import 'package:aquantum_reader/reader/reader_page_overview.dart';
import 'package:aquantum_reader/reader/reader_scrollbar.dart';
import 'package:aquantum_reader/reader/reader_toolbar.dart';
import 'package:aquantum_reader/plugins/plugin_api.dart';
import 'package:aquantum_reader/plugins/plugin_manager.dart';
import 'package:aquantum_reader/widgets/reader_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'plugin_fixtures.dart';

Book book(String format, {String? id}) => Book({
  'id': id ?? 'test-$format',
  'project': 'inbox',
  'title': '统一阅读器',
  'format': format,
  'revision': 1,
  'pages': [
    for (var i = 0; i < 3; i++)
      {
        'id': 'stable-$i',
        'resource': {'bytes': 1},
      },
  ],
});

class FixtureAdapter implements ReaderAdapter {
  final String format;
  int current = 0;
  bool locked = false;
  bool vertical = false;
  FixtureAdapter(this.format);
  @override
  String get documentId => 'fixture-$format';
  @override
  String get title => '统一阅读器 $format';
  @override
  String get unit => '页';
  @override
  int get count => 3;
  @override
  int get position => current;
  @override
  bool get paged => true;
  @override
  bool get pageProgress => paged;
  @override
  bool get rightToLeft => false;
  @override
  bool get verticalTurn => vertical;
  @override
  bool get interactionLocked => locked;
  @override
  String get status => '已保存';
  @override
  ReaderCapabilities get capabilities => const ReaderCapabilities();
  @override
  ReaderLocation location(int index) =>
      ReaderLocation('page-$index', '位置 $index', index);
  @override
  int? resolveLocation(String id) => switch (id) {
    'page-0' => 0,
    'page-1' => 1,
    'page-2' => 2,
    _ => null,
  };
  @override
  void goTo(int index) {
    if (index >= 0 && index < count) current = index;
  }

  @override
  Widget buildContent(BuildContext context) =>
      const ColoredBox(color: Color(0xffeeeeee));
  @override
  Widget? buildThumbnail(BuildContext context, int index) => null;
  @override
  Future<List<ReaderSearchHit>> search(String query) async => [];
}

class InteractiveAdapter extends FixtureAdapter {
  bool checked = false;
  InteractiveAdapter() : super('interactive');
  @override
  bool get paged => false;
  @override
  Widget buildContent(BuildContext context) => StatefulBuilder(
    builder: (context, update) => Stack(
      children: [
        const Positioned.fill(child: ColoredBox(color: Colors.white)),
        Positioned(
          left: 80,
          top: 50,
          child: ReaderInteractiveRegion(
            child: Checkbox(
              value: checked,
              onChanged: (v) => update(() => checked = v!),
            ),
          ),
        ),
      ],
    ),
  );
}

class ContinuousPagedAdapter extends FixtureAdapter {
  ContinuousPagedAdapter() : super('PDF');
  @override
  bool get paged => false;
  @override
  bool get pageProgress => true;
}

/// A scrolling renderer that never declared a page counter of its own — the
/// shape a plain text book has. It still gets the same bottom controller.
class ScrollingAdapter extends FixtureAdapter {
  ScrollingAdapter() : super('Txt');
  @override
  String get unit => '段';
  @override
  bool get paged => false;
  @override
  bool get pageProgress => false;
}

Widget shell(
  ReaderAdapter adapter, {
  bool desktop = false,
  String dock = 'top',
  PluginManager? plugins,
  Future<void> Function(PluginAction)? invoke,
  TextScaler scaler = TextScaler.noScaling,
  bool reduced = false,
  bool optionalPanels = false,
  EdgeInsets keyboard = EdgeInsets.zero,
  Future<void> Function()? save,
}) => MaterialApp(
  theme: ThemeData(
    platform: desktop ? TargetPlatform.windows : TargetPlatform.android,
  ),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: scaler,
      disableAnimations: reduced,
      viewInsets: keyboard,
    ),
    child: child!,
  ),
  home: Scaffold(
    body: ReaderShell(
      adapter: adapter,
      desktop: desktop,
      dock: dock,
      settingsBuilder: (_, _) => const Text('能力设置'),
      extensions: ReaderExtensions(
        plugins,
        const ExtensionContext(capabilities: {ReaderCapability.image}),
      ),
      invokeExtension: invoke ?? (_) async {},
      runOverlay: (show) => show(),
      addNote: () async {},
      showNotes: () async {},
      encodingBuilder: optionalPanels ? (_) => const Text('真实编码面板') : null,
      directionBuilder: optionalPanels ? (_) => const Text('真实方向面板') : null,
    ),
  ),
);

class PanelPlugin implements ReaderPlugin {
  @override
  PluginManifest get manifest => const PluginManifest(
    id: 'community.panels',
    name: '面板扩展',
    version: '1.0.0',
    description: '测试能力',
  );
  @override
  Future<void> activate(PluginRegistrar registrar) async {
    for (final point in [
      ExtensionPoint.readerToolbar,
      ExtensionPoint.readerSettings,
      ExtensionPoint.readerSearch,
      ExtensionPoint.readerNavigation,
      ExtensionPoint.readerBookmarks,
    ]) {
      registrar.action(
        PluginAction(
          id: 'community.panels.action.${point.name}',
          name: '插件 ${point.name}',
          icon: Icons.extension_outlined,
          point: point,
          requires: {ReaderCapability.image},
          invoke: (_) async => '实际插件结果',
        ),
      );
    }
  }

  @override
  Future<void> deactivate() async {}
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'document controls keep their tap without toggling mobile chrome',
    (tester) async {
      final adapter = InteractiveAdapter();
      await tester.pumpWidget(shell(adapter));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      expect(adapter.checked, isTrue);
      expect(find.byTooltip('阅读设置').hitTestable(), findsNothing);
      final region = tester.getRect(
        find.byKey(const ValueKey('reader-content-hit-region')),
      );
      await tester.tapAt(region.topLeft + const Offset(250, 40));
      await tester.pumpAndSettle();
      expect(find.byTooltip('阅读设置').hitTestable(), findsOneWidget);
    },
  );
  testWidgets('more opens encoding and direction without a reader picker', (
    tester,
  ) async {
    await tester.pumpWidget(
      shell(FixtureAdapter('test'), desktop: true, optionalPanels: true),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('阅读处理器'), findsNothing);
    expect(find.text('阅读器选择'), findsNothing);
    await tester.tap(find.byTooltip('关闭面板'));
    await tester.pumpAndSettle();
    for (final pair in [('文字编码', '真实编码面板'), ('阅读方向', '真实方向面板')]) {
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(pair.$1));
      await tester.pumpAndSettle();
      expect(find.text(pair.$2), findsOneWidget);
      await tester.tap(find.byTooltip('关闭面板'));
      await tester.pumpAndSettle();
    }
  });
  test(
    'Kindle page regions obey the diagram and reverse RTL without changing chrome',
    () {
      ReaderTapAction at(
        double x,
        double y, {
        bool visible = false,
        bool rtl = false,
      }) => readerTapAction(
        point: Offset(x, y),
        size: const Size(400, 800),
        chromeVisible: visible,
        paged: true,
        rightToLeft: rtl,
      );
      expect(at(300, 80), ReaderTapAction.toggleChrome);
      expect(at(40, 400), ReaderTapAction.previous);
      expect(at(200, 400), ReaderTapAction.next);
      expect(at(40, 400, rtl: true), ReaderTapAction.next);
      expect(at(200, 400, rtl: true), ReaderTapAction.previous);
      expect(at(200, 400, visible: true), ReaderTapAction.toggleChrome);
    },
  );
  test('a top-to-bottom page summons the chrome anywhere it is tapped', () {
    ReaderTapAction at(double x, double y, {bool visible = false}) =>
        readerTapAction(
          point: Offset(x, y),
          size: const Size(400, 800),
          chromeVisible: visible,
          paged: true,
          rightToLeft: false,
          verticalTurn: true,
        );
    // Top-to-bottom books have no side edge to turn on: the page itself turns
    // on the scroll, so a tap only brings the chrome back wherever it lands.
    expect(at(40, 40), ReaderTapAction.toggleChrome);
    expect(at(360, 40), ReaderTapAction.toggleChrome);
    expect(at(40, 200), ReaderTapAction.toggleChrome);
    expect(at(360, 400), ReaderTapAction.toggleChrome);
    expect(at(40, 700), ReaderTapAction.toggleChrome);
    // A visible toolbar is still dismissed by the same tap.
    expect(at(200, 40, visible: true), ReaderTapAction.toggleChrome);
    expect(at(200, 700, visible: true), ReaderTapAction.toggleChrome);
  });
  test(
    'old preferences gain safe defaults and retain existing typography',
    () async {
      SharedPreferences.setMockInitialValues({
        'reader-ui.v1': jsonEncode({
          'version': 1,
          'lineHeight': 2.2,
          'paragraphGap': 30,
          'margin': 32,
          'font': 'system',
          'theme': 'paper',
          'dock': 'left',
          'continuous': true,
          'rotation': 1,
        }),
      });
      final prefs = ReaderPreferences();
      await prefs.load();
      expect(prefs.lineHeight, 2.2);
      expect(prefs.font, 'system');
      expect(prefs.pageAnimation, isTrue);
      expect(prefs.fit, 'page');
      await prefs.save();
      final restored = ReaderPreferences();
      await restored.load();
      expect(restored.dock, 'left');
      expect(restored.continuous, isTrue);
    },
  );
  test(
    'direction and format defaults never reset visual preferences',
    () async {
      SharedPreferences.setMockInitialValues({});
      final epub = ReaderPreferences()..theme = 'paper';
      epub.lineHeight = 2.2;
      epub.paragraphGap = 31;
      epub.textPaged = false;
      await epub.save(bookId: 'book-a');

      final restored = ReaderPreferences();
      await restored.load(bookId: 'book-a', format: 'Epub');
      expect(restored.textPaged, isFalse);
      expect(restored.theme, 'paper');
      expect(restored.lineHeight, 2.2);
      expect(restored.paragraphGap, 31);

      final markdown = ReaderPreferences();
      await markdown.load(bookId: 'book-b', format: 'Markdown');
      expect(markdown.textPaged, isFalse);
      expect(markdown.theme, 'system');
      markdown.textPaged = true;
      markdown.theme = 'dark';
      await markdown.save(bookId: 'book-b');
      final markdownAgain = ReaderPreferences();
      await markdownAgain.load(bookId: 'book-b', format: 'Markdown');
      expect(markdownAgain.textPaged, isTrue);
      expect(markdownAgain.theme, 'dark');
    },
  );
  testWidgets(
    'module actions live inside panels and revocation never mutates seven buttons',
    (tester) async {
      final registry = testRegistry();
      final manager = PluginManager(
        registry,
        MemoryPluginStore(),
        bundled: [PanelPlugin()],
      );
      await manager.load();
      await manager.install('community.panels');
      await manager.enable('community.panels', {});
      String? invoked;
      await tester.pumpWidget(
        shell(
          FixtureAdapter('image'),
          desktop: true,
          plugins: manager,
          invoke: (action) async {
            invoked = await manager.invoke(
              action.id,
              const ExtensionContext(capabilities: {ReaderCapability.image}),
            );
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.extension_outlined), findsNothing);
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('插件 readerToolbar'));
      await tester.pumpAndSettle();
      expect(invoked, '实际插件结果');
      await tester.tap(find.byTooltip('阅读设置'));
      await tester.pumpAndSettle();
      expect(find.text('插件 readerSettings'), findsOneWidget);
      await manager.disable('community.panels');
      await tester.pumpAndSettle();
      expect(find.text('插件 readerSettings'), findsNothing);
      await tester.tap(find.byTooltip('关闭面板'));
      await tester.pumpAndSettle();
      expect(find.byType(ReaderToolbar), findsOneWidget);
      expect(find.text('Aa'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      manager.dispose();
      registry.dispose();
    },
  );
  testWidgets(
    'all formats including future adapters preserve seven positions and glyphs',
    (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      List<Offset>? baseline;
      for (final format in [
        'TXT',
        'EPUB',
        'Markdown',
        'PDF',
        'Comic',
        'Image',
        'Future',
      ]) {
        await tester.pumpWidget(shell(FixtureAdapter(format), desktop: true));
        await tester.pumpAndSettle();
        final centers = [
          for (final action in readerToolbarOrder)
            tester.getCenter(
              find.byKey(ValueKey('reader-action-${action.name}')),
            ),
        ];
        baseline ??= centers;
        expect(centers, baseline);
        expect(find.text('Aa'), findsOneWidget);
        expect(find.byType(ReaderToolbar), findsOneWidget);
        for (final action in readerToolbarOrder) {
          expect(
            tester.getSize(
              find.byKey(ValueKey('reader-action-${action.name}')),
            ),
            const Size(48, 48),
          );
        }
        expect(tester.takeException(), isNull);
      }
    },
  );
  testWidgets(
    'mobile starts immersive and toggles both regions without reflow or false drag taps',
    (tester) async {
      final adapter = FixtureAdapter('image');
      await tester.pumpWidget(shell(adapter));
      await tester.pumpAndSettle();
      expect(find.byTooltip('阅读设置').hitTestable(), findsNothing);
      final region = find.byKey(const ValueKey('reader-content-hit-region'));
      final initial = tester.getRect(region);
      await tester.tapAt(initial.topLeft + const Offset(100, 60));
      await tester.pumpAndSettle();
      expect(find.byTooltip('阅读设置').hitTestable(), findsOneWidget);
      expect(find.byTooltip('下一页').hitTestable(), findsOneWidget);
      expect(tester.getRect(region), initial);
      await tester.tapAt(initial.center);
      await tester.pumpAndSettle();
      expect(find.byTooltip('阅读设置').hitTestable(), findsNothing);
      expect(find.byTooltip('下一页').hitTestable(), findsNothing);
      await tester.dragFrom(initial.center, const Offset(100, 0));
      await tester.pumpAndSettle();
      expect(adapter.position, 0);
      final secondary = await tester.startGesture(initial.center, buttons: 2);
      await secondary.up();
      await tester.pumpAndSettle();
      expect(adapter.position, 0);
      adapter.locked = true;
      await tester.tapAt(initial.center);
      await tester.pumpAndSettle();
      expect(adapter.position, 0);
      adapter.locked = false;
      await tester.tapAt(initial.center);
      await tester.pumpAndSettle();
      expect(adapter.position, 1);
    },
  );
  testWidgets(
    'continuous PDF keeps the bottom page controller it alone can drive',
    (tester) async {
      final adapter = ContinuousPagedAdapter();
      Widget build() => shell(adapter, desktop: true);
      await tester.pumpWidget(build());
      await tester.pumpAndSettle();
      // Continuous reading uses the whole-book scrollbar and does not reserve
      // a bottom page toolbar.
      expect(find.text('1 / 3 页'), findsNothing);
      expect(find.byType(ReaderScrollbar), findsOneWidget);
      expect(find.byType(Slider), findsNothing);
      expect(find.byType(ReaderPageOverview), findsNothing);
    },
  );
  testWidgets(
    'scrolling gets the whole-book scrollbar, paging keeps the bottom controller',
    (tester) async {
      for (final adapter in <FixtureAdapter>[
        ScrollingAdapter(),
        FixtureAdapter('Epub'),
      ]) {
        await tester.pumpWidget(shell(adapter, desktop: true));
        await tester.pumpAndSettle();
        // Each mode has exactly one locator: the scrollbar while scrolling,
        // the bottom page controller while paging — never both.
        expect(
          find.byType(ReaderScrollbar),
          adapter.paged ? findsNothing : findsOneWidget,
        );
        expect(
          find.byType(Slider),
          adapter.paged ? findsOneWidget : findsNothing,
        );
        expect(
          find.text('1 / 3 ${adapter.unit}'),
          adapter.paged ? findsOneWidget : findsNothing,
        );
        expect(find.byType(ReaderPageOverview), findsNothing);
        if (adapter.paged) {
          expect(find.byType(Slider).hitTestable(), findsOneWidget);
        }
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'unsupported search explains capability; bookmarks really persist and navigate',
    (tester) async {
      final adapter = FixtureAdapter('image');
      await tester.pumpWidget(shell(adapter, desktop: true));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('搜索'));
      await tester.pumpAndSettle();
      expect(find.text('当前渲染器没有提供可检索的文字。'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭面板'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('书签'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加当前位置书签'));
      await tester.pumpAndSettle();
      expect(
        (await ReaderBookmarkStore(
          adapter.documentId,
        ).load()).single.locationId,
        'page-0',
      );
      await tester.tap(find.byTooltip('关闭面板'));
      await tester.pumpAndSettle();
      adapter.current = 2;
      await tester.tap(find.byTooltip('书签'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('位置 0'));
      await tester.pumpAndSettle();
      expect(adapter.position, 0);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'renderer search yields actual text anchors and image bookmarks survive reordering',
    () async {
      final text = TextReaderAdapter(
        book: book('Txt'),
        position: 0,
        status: '',
        content: (_) => const SizedBox(),
        onGo: (_) {},
        locked: () => false,
        paragraphs: ['第一段', '真实 Needle 搜索段落', '第三段'],
      );
      final hits = await text.search('needle');
      expect(hits.single.location.index, 1);
      expect(hits.single.excerpt, contains('Needle'));
      expect(text.resolveLocation('paragraph:9:1'), isNull);
      final original = book('Comic');
      final reordered = Book({
        'id': original.id,
        'project': 'inbox',
        'title': '漫画',
        'format': 'Comic',
        'revision': 2,
        'pages': original.pages.reversed.toList(),
      });
      final comic = ComicReaderAdapter(
        book: reordered,
        position: 0,
        status: '',
        content: (_) => const SizedBox(),
        onGo: (_) {},
        locked: () => false,
        continuous: false,
        rightToLeft: false,
        thumbnail: (_, _) => const SizedBox(),
      );
      expect(comic.resolveLocation('page:stable-0'), 2);
      expect(comic.capabilities.supports(ReaderSetting.fontSize), isFalse);
      expect(text.capabilities.supports(ReaderSetting.fit), isFalse);
    },
  );
  test(
    'unknown bookmark version is retained instead of being replaced',
    () async {
      SharedPreferences.setMockInitialValues({
        'reader-bookmarks.v1.bad': '{"version":9,"items":[]}',
      });
      await expectLater(
        ReaderBookmarkStore('bad').load(),
        throwsFormatException,
      );
      expect(
        (await SharedPreferences.getInstance()).getString(
          'reader-bookmarks.v1.bad',
        ),
        contains('"version":9'),
      );
    },
  );
  testWidgets(
    'large text landscape dock changes and hidden dock recover without changing actions',
    (tester) async {
      tester.view.physicalSize = const Size(812, 375);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final adapter = FixtureAdapter('pdf');
      for (final dock in ['left', 'right', 'top', 'bottom', 'hidden']) {
        await tester.pumpWidget(
          shell(
            adapter,
            desktop: true,
            dock: dock,
            scaler: TextScaler.linear(2),
            reduced: true,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byType(ReaderToolbar), findsOneWidget);
        if (dock == 'hidden') {
          expect(find.byTooltip('阅读设置').hitTestable(), findsNothing);
        }
        expect(tester.takeException(), isNull);
      }
      final region = tester.getRect(
        find.byKey(const ValueKey('reader-content-hit-region')),
      );
      await tester.tapAt(region.topLeft + const Offset(100, 50));
      await tester.pump();
      expect(find.byTooltip('阅读设置').hitTestable(), findsOneWidget);
    },
  );
  testWidgets('saved desktop dock does not reveal mobile chrome', (
    tester,
  ) async {
    final adapter = FixtureAdapter('image');
    await tester.pumpWidget(shell(adapter, dock: 'bottom'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(shell(adapter, dock: 'left'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('阅读设置').hitTestable(), findsNothing);
  });
  testWidgets('actual text search works in keyboard-constrained landscape', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(812, 375);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var selected = -1;
    final adapter = TextReaderAdapter(
      book: book('Txt'),
      position: 0,
      status: '',
      content: (_) => const ColoredBox(color: Colors.white),
      onGo: (i) => selected = i,
      locked: () => false,
      paragraphs: ['第一段', '真实命中 needle 段落'],
    );
    await tester.pumpWidget(
      shell(
        adapter,
        desktop: true,
        keyboard: const EdgeInsets.only(bottom: 220),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('搜索'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byType(TextField), 'needle');
    await tester.tap(find.byTooltip('开始搜索'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(shell(adapter, desktop: true));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(ListTile).first);
    await tester.pumpAndSettle();
    expect(selected, 1);
    expect(tester.takeException(), isNull);
  });
  test('comic defaults keep visual fields when direction changes', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = ReaderPreferences();
    await preferences.load(bookId: 'comic', format: 'Comic');
    expect(preferences.continuous, isTrue);
    expect(preferences.seamless, isTrue);
    expect(preferences.fit, 'width');
    preferences.theme = 'dark';
    preferences.lineHeight = 2.1;
    preferences.textPaged = false;
    await preferences.save(bookId: 'comic');
    final restored = ReaderPreferences();
    await restored.load(bookId: 'comic', format: 'Comic');
    expect(restored.theme, 'dark');
    expect(restored.lineHeight, 2.1);
    expect(restored.textPaged, isFalse);
    expect(restored.continuous, isTrue);
  });
}
