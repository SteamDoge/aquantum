// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../reader/reader_contract.dart';
import '../formats/reader_provider_preferences.dart';
import 'article_settings_panel.dart';

class ReaderPreferences {
  String? warning;

  static Map _decode(Object encoded) {
    if (encoded is! String) throw const FormatException('阅读设置格式无效');
    final data = jsonDecode(encoded);
    if (data is! Map || data['version'] != 1) {
      throw const FormatException('阅读设置版本无效');
    }
    return data;
  }

  double lineHeight = 1.9, paragraphGap = 24, margin = 28;
  String font = 'serif', theme = 'system', dock = 'top';

  /// The four format defaults are applied only when a book has no saved
  /// preference. They are deliberately separate from the visual fields above:
  /// changing a direction never reconstructs this object from a preset.
  void applyFormatDefaults(String? format) {
    switch (format) {
      case 'Markdown':
        textPaged = false;
        continuous = false;
        break;
      case 'Comic':
        textPaged = false;
        continuous = true;
        seamless = true;
        fit = 'width';
        break;
      case 'Pdf':
        textPaged = false;
        continuous = true;
        seamless = false;
        fit = 'width';
        break;
      default:
        // TXT/EPUB/MOBI and other reflowable text use discrete pages by
        // default. The caller can still explicitly choose continuous mode.
        textPaged = true;
        continuous = false;
    }
  }

  /// Reflowable text starts paged; applyFormatDefaults makes Markdown scroll.
  /// A saved per-book choice takes precedence over that format default.
  bool textPaged = true;
  bool continuous = false,
      pageAnimation = true,
      seamless = false,
      rightToLeft = false;
  String fit = 'page';
  String dayBackground = 'white', nightBackground = 'dark';
  static const dayColors = <String, Color>{
    'white': Color(0xffffffff), 'grey': Color(0xffeeeeee),
    'paper': Color(0xfff1e8ce), 'green': Color(0xffdbe6d6),
    'blue': Color(0xffdce5ed), // preserve the historical blue book preference
  };
  static const nightColors = <String, Color>{
    'dark': Color(0xff111111),
    'charcoal': Color(0xff262626),
    'navy': Color(0xff1c2833),
    'brown': Color(0xff382f2a),
  };
  bool isDark(Brightness system) =>
      nightColors.containsKey(theme) ||
      (theme == 'system' && system == Brightness.dark);
  String activeBackground(Brightness system) => theme == 'system'
      ? (system == Brightness.dark ? nightBackground : dayBackground)
      : theme;
  Color background(Brightness system) =>
      (dayColors[activeBackground(system)] ??
      nightColors[activeBackground(system)])!;
  void selectBackground(String value, {required bool dark}) {
    if (dark) {
      nightBackground = value;
    } else {
      dayBackground = value;
    }
    theme = value;
  }

  String turnEffect = 'slide';
  double weight = 400;
  int rotation = 0;
  Future<void> load({String? bookId, String? format}) async {
    warning = null;
    applyFormatDefaults(format);
    if (format != null) {
      final paged = await ReaderProviderPreferences.paged(format);
      textPaged = paged;
      continuous = !paged;
    }
    final prefs = await SharedPreferences.getInstance();
    final own = prefs.get(
      bookId == null ? 'reader-ui.v1' : 'reader-ui.v2.$bookId',
    );
    // A book without its own record falls back to the shared pre-RC007 record
    // for the visual axis only. That record was written by whichever format
    // was read last, so its layout fields (a comic's continuous strip, a text
    // scroll choice) must not override another format's preset: an EPUB would
    // otherwise open as a continuous scroll because a comic was read before.
    final legacy = own == null && bookId != null;
    final encoded = own ?? (legacy ? prefs.get('reader-ui.v1') : null);
    if (encoded == null) return;
    late final Map data;
    try {
      data = _decode(encoded);
    } on FormatException {
      warning = '阅读设置无法读取，已使用默认显示；原记录保留。';
      return;
    }
    _readVisual(data);
    if (legacy) {
      // The legacy record's image fields were only ever driven by image books,
      // and its paging switch by plain text; keep those explicit choices for
      // the same kind of book and nothing else.
      // Shared legacy records supply visuals only, never a file direction.
      if (format == 'Comic') {
        if (data['rotation'] is int) rotation = (data['rotation'] as int) % 4;
        if (data['seamless'] is bool) seamless = data['seamless'];
        if ({'width', 'page'}.contains(data['fit'])) fit = data['fit'];
      }
      return;
    }
    if (data['textPaged'] is bool) textPaged = data['textPaged'] == true;
    _readImageLayout(data);
  }

  void _readImageLayout(Map data) {
    if (data['continuous'] is bool) continuous = data['continuous'] == true;
    if (data['rotation'] is int) rotation = (data['rotation'] as int) % 4;
    if (data['seamless'] is bool) seamless = data['seamless'] == true;
    if (data['rightToLeft'] is bool) rightToLeft = data['rightToLeft'] == true;
    if ({'width', 'page'}.contains(data['fit'])) fit = data['fit'];
  }

  void _readVisual(Map data) {
    double number(String key, double fallback, double min, double max) {
      final value = data[key];
      return value is num && value.isFinite
          ? value.toDouble().clamp(min, max)
          : fallback;
    }

    // Legacy brightness is intentionally ignored; the OS owns brightness.
    if ({'slide', 'cover', 'curl'}.contains(data['turnEffect'])) {
      turnEffect = data['turnEffect'];
    } else if (data['turnEffect'] == 'vertical') {
      turnEffect = 'slide';
    }
    lineHeight = number('lineHeight', lineHeight, 1.2, 2.6);
    paragraphGap = number('paragraphGap', paragraphGap, 8, 48);
    margin = number('margin', margin, 12, 64);
    if ({'serif', 'system'}.contains(data['font'])) font = data['font'];
    if (data['theme'] == 'system' ||
        dayColors.containsKey(data['theme']) ||
        nightColors.containsKey(data['theme'])) {
      theme = data['theme'];
    }
    if (dayColors.containsKey(theme)) dayBackground = theme;
    if (nightColors.containsKey(theme)) nightBackground = theme;
    if (dayColors.containsKey(data['dayBackground'])) {
      dayBackground = data['dayBackground'];
    }
    if (nightColors.containsKey(data['nightBackground'])) {
      nightBackground = data['nightBackground'];
    }
    if ({'top', 'bottom', 'left', 'right', 'hidden'}.contains(data['dock'])) {
      dock = data['dock'];
    }
    if (data['pageAnimation'] is bool) {
      pageAnimation = data['pageAnimation'] == true;
    }
    weight = number('weight', weight, 400, 700);
  }

  Future<void> save({String? bookId}) async {
    final prefs = await SharedPreferences.getInstance();
    final key = bookId == null ? 'reader-ui.v1' : 'reader-ui.v2.$bookId';
    final existing = prefs.get(key);
    if (existing != null) {
      try {
        _decode(existing);
      } on FormatException {
        throw const FormatException('原阅读设置无法解析，暂不能覆盖保存；原记录保留。');
      }
    }
    if (!await prefs.setString(
      key,
      jsonEncode({
        'version': 1,
        'turnEffect': turnEffect,
        'dayBackground': dayBackground,
        'nightBackground': nightBackground,
        'lineHeight': lineHeight,
        'paragraphGap': paragraphGap,
        'margin': margin,
        'font': font,
        'theme': theme,
        'dock': dock,
        'continuous': continuous,
        'textPaged': textPaged,
        'rotation': rotation,
        'pageAnimation': pageAnimation,
        'seamless': seamless,
        'rightToLeft': rightToLeft,
        'fit': fit,
        'weight': weight,
      }),
    )) {
      throw StateError('阅读设置保存失败');
    }
  }
}

class ReaderSettingsPanel extends StatelessWidget {
  final bool compact;
  final ReaderPreferences preferences;
  final ReaderCapabilities capabilities;
  final double fontSize;
  final bool desktop;
  final bool paged;

  /// True when the book turns pages top-to-bottom; the horizontal direction
  /// switch then has nothing to control.
  final bool verticalTurning;
  final void Function(void Function() change) onChanged;
  final ValueChanged<double> onFont;
  const ReaderSettingsPanel({
    super.key,
    this.compact = true,
    required this.preferences,
    required this.capabilities,
    required this.fontSize,
    required this.desktop,
    this.paged = true,
    this.verticalTurning = false,
    required this.onChanged,
    required this.onFont,
  });
  @override
  Widget build(BuildContext context) {
    final p = preferences;
    if (compact &&
        capabilities.supports(ReaderSetting.fontSize) &&
        capabilities.supports(ReaderSetting.fontFamily) &&
        (capabilities.supports(ReaderSetting.textPaging) ||
            capabilities.supports(ReaderSetting.continuous))) {
      return ArticleSettingsPanel(
        preferences: p,
        showEffects: capabilities.supports(ReaderSetting.turnEffect),
        usesContinuous: !capabilities.supports(ReaderSetting.textPaging),
        fontSize: fontSize,
        onFont: onFont,
        onChanged: onChanged,
        advanced: (context, refresh) => ReaderSettingsPanel(
          compact: false,
          preferences: p,
          capabilities: capabilities,
          fontSize: fontSize,
          desktop: desktop,
          paged: paged,
          verticalTurning: verticalTurning,
          onFont: onFont,
          onChanged: (change) {
            onChanged(change);
            refresh();
          },
        ),
      );
    }
    bool supports(ReaderSetting setting) => capabilities.supports(setting);
    Widget slider(
      String label,
      double value,
      double min,
      double max,
      ValueChanged<double> change,
    ) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label ${value.toStringAsFixed(1)}'),
        Slider(value: value, min: min, max: max, onChanged: change),
      ],
    );
    Widget choices(
      String title,
      String value,
      List<(String, String)> options,
      ValueChanged<String> change,
    ) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final option in options)
              ChoiceChip(
                label: Text(option.$2),
                selected: value == option.$1,
                onSelected: (_) => change(option.$1),
              ),
          ],
        ),
        const SizedBox(height: 16),
      ],
    );
    return DefaultTabController(
      length: 2,
      child: Column(
        children: [
          if (p.warning != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                p.warning!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const TabBar(
            tabs: [
              Tab(text: '布局'),
              Tab(text: '更多'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                ListView(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  children: [
                    if (supports(ReaderSetting.fontSize))
                      slider('字号', fontSize, 14, 32, onFont),
                    if (supports(ReaderSetting.fontFamily))
                      choices('字体', p.font, [
                        ('serif', '衬线字体'),
                        ('system', '系统字体'),
                      ], (v) => onChanged(() => p.font = v)),
                    if (supports(ReaderSetting.fontWeight))
                      slider(
                        '字重',
                        p.weight,
                        400,
                        700,
                        (v) => onChanged(() => p.weight = v),
                      ),
                    if (supports(ReaderSetting.lineHeight))
                      slider(
                        '行距',
                        p.lineHeight,
                        1.2,
                        2.6,
                        (v) => onChanged(() => p.lineHeight = v),
                      ),
                    if (supports(ReaderSetting.paragraphGap))
                      slider(
                        '段距',
                        p.paragraphGap,
                        8,
                        48,
                        (v) => onChanged(() => p.paragraphGap = v),
                      ),
                    if (supports(ReaderSetting.margin))
                      slider(
                        '页边距',
                        p.margin,
                        12,
                        64,
                        (v) => onChanged(() => p.margin = v),
                      ),
                    if (supports(ReaderSetting.textPaging))
                      choices('阅读方式', p.textPaged ? 'paged' : 'scroll', [
                        ('scroll', '上下滚动'),
                        ('paged', '左右翻页'),
                      ], (v) => onChanged(() => p.textPaged = v == 'paged')),
                    if (supports(ReaderSetting.fit))
                      choices('适应屏幕', p.fit, [
                        ('page', '适应页面'),
                        ('width', '适应宽度'),
                      ], (v) => onChanged(() => p.fit = v)),
                    if (supports(ReaderSetting.continuous))
                      // 从上到下 is top-to-bottom reading itself, so it always
                      // scrolls; paging is only ever left/right.
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('纵向连续阅读'),
                        subtitle: Text(
                          verticalTurning
                              ? '阅读方向为从上到下，始终上下连续滚动；改为从左到右或从右到左后可按页翻阅'
                              : '关闭后左右按页翻阅',
                        ),
                        value: p.continuous || verticalTurning,
                        onChanged: verticalTurning
                            ? null
                            : (v) => onChanged(() => p.continuous = v),
                      ),
                    if (supports(ReaderSetting.imageGap))
                      choices('页面间距', p.seamless ? 'seamless' : 'gapped', [
                        ('gapped', '有缝'),
                        ('seamless', '无缝'),
                      ], (v) => onChanged(() => p.seamless = v == 'seamless')),
                    // The core direction panel owns LeftToRight / RightToLeft /
                    // TopToBottom. This quick switch only mirrors the horizontal
                    // pair, so it is meaningless while turns are top-to-bottom.
                    if (supports(ReaderSetting.direction) && !verticalTurning)
                      choices('横向翻页方向', p.rightToLeft ? 'rtl' : 'ltr', [
                        ('ltr', '从左到右'),
                        ('rtl', '从右到左'),
                      ], (v) => onChanged(() => p.rightToLeft = v == 'rtl')),
                    if (supports(ReaderSetting.rotation))
                      OutlinedButton.icon(
                        onPressed: () =>
                            onChanged(() => p.rotation = (p.rotation + 1) % 4),
                        icon: const Icon(Icons.rotate_right),
                        label: Text('旋转 · ${p.rotation * 90}°'),
                      ),
                    if (capabilities.settings.isEmpty)
                      const Text('当前渲染器没有可调整的布局设置。'),
                  ],
                ),
                ListView(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  children: [
                    if (supports(ReaderSetting.theme))
                      choices(
                        '阅读主题',
                        p.theme == 'system'
                            ? 'system'
                            : (p.isDark(Brightness.light) ? 'dark' : p.theme),
                        [('system', '跟随应用'), ('paper', '纸张'), ('dark', '夜间')],
                        (v) => onChanged(() {
                          if (v == 'system') {
                            p.theme = v;
                          } else {
                            p.selectBackground(
                              v == 'dark' ? p.nightBackground : v,
                              dark: v == 'dark',
                            );
                          }
                        }),
                      ),
                    if (supports(ReaderSetting.animation))
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('页面切换动画'),
                        subtitle: const Text('系统减少动态效果优先'),
                        value: p.pageAnimation,
                        onChanged: (v) => onChanged(() => p.pageAnimation = v),
                      ),
                    if (desktop && !paged)
                      const Text('上下滚动使用顶部工具栏，轻点正文切换沉浸。分页时可设置工具栏停靠位置。'),
                    if (desktop && paged)
                      choices('阅读工具栏位置', p.dock, [
                        ('top', '上'),
                        ('bottom', '下'),
                        ('left', '左'),
                        ('right', '右'),
                        ('hidden', '隐藏'),
                      ], (v) => onChanged(() => p.dock = v)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
