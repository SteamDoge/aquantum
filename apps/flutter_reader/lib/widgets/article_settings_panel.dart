// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import 'reader_settings.dart';

/// Compact native text controls; spacing is a separate page inside the sheet.
class ArticleSettingsPanel extends StatefulWidget {
  final ReaderPreferences preferences;
  final double fontSize;
  final bool showEffects;
  final bool usesContinuous;
  final ValueChanged<double> onFont;
  final void Function(VoidCallback) onChanged;
  final Widget Function(BuildContext, VoidCallback) advanced;
  const ArticleSettingsPanel({
    super.key,
    required this.preferences,
    this.showEffects = true,
    this.usesContinuous = false,
    required this.fontSize,
    required this.onFont,
    required this.onChanged,
    required this.advanced,
  });
  @override
  State<ArticleSettingsPanel> createState() => _ArticleSettingsPanelState();
}

class _ArticleSettingsPanelState extends State<ArticleSettingsPanel> {
  int page = 0;
  ReaderPreferences get p => widget.preferences;
  bool get paged => widget.usesContinuous ? !p.continuous : p.textPaged;
  void change(VoidCallback edit) {
    widget.onChanged(edit);
    if (mounted) setState(() {});
  }

  Widget spacing(
    String label,
    double value,
    List<double> values,
    ValueChanged<double> apply,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 14),
      LayoutBuilder(
        builder: (context, constraints) {
          final selected = values.reduce(
            (a, b) => (a - value).abs() < (b - value).abs() ? a : b,
          );
          void drag(double x) => change(
            () => apply(
              values[(x / constraints.maxWidth * values.length).floor().clamp(
                0,
                values.length - 1,
              )],
            ),
          );
          return GestureDetector(
            onHorizontalDragStart: (d) => drag(d.localPosition.dx),
            onHorizontalDragUpdate: (d) => drag(d.localPosition.dx),
            child: Container(
              height: 64,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(36),
              ),
              child: Row(
                children: [
                  for (var i = 0; i < values.length; i++)
                    Expanded(child: spacingChoice(i, values, selected, apply)),
                ],
              ),
            ),
          );
        },
      ),
      const SizedBox(height: 36),
    ],
  );
  Widget spacingChoice(
    int index,
    List<double> values,
    double selected,
    ValueChanged<double> apply,
  ) {
    final active = values[index] == selected;
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      selected: active,
      button: true,
      child: InkWell(
        onTap: () => change(() => apply(values[index])),
        borderRadius: BorderRadius.circular(36),
        child: Center(
          child: AnimatedContainer(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 120),
            width: 64,
            height: 64,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: active ? colors.surface : Colors.transparent,
              shape: BoxShape.circle,
              boxShadow: active
                  ? [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .10),
                        blurRadius: 8,
                      ),
                    ]
                  : null,
            ),
            child: Text(
              ['较小', '适中', '较大', '最大'][index],
              style: TextStyle(
                color: active ? colors.onSurface : colors.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget mode(bool paged, String label) => Semantics(
    checked: this.paged == paged,
    inMutuallyExclusiveGroup: true,
    child: InkWell(
      onTap: () => change(() {
        p.textPaged = paged;
        p.continuous = !paged;
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            Icon(
              this.paged == paged
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 20,
            ),
            const SizedBox(width: 8),
            Text(label),
          ],
        ),
      ),
    ),
  );

  Widget palette(
    String label,
    bool dark,
    List<String> keys,
    List<String> names,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label),
      const SizedBox(height: 8),
      Row(
        children: [
          for (var i = 0; i < keys.length; i++)
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(right: i == keys.length - 1 ? 0 : 8),
                child: Semantics(
                  button: true,
                  selected:
                      (dark ? p.nightBackground : p.dayBackground) == keys[i],
                  label: names[i],
                  child: InkWell(
                    onTap: () =>
                        change(() => p.selectBackground(keys[i], dark: dark)),
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      height: 48,
                      decoration: BoxDecoration(
                        color: (dark
                            ? ReaderPreferences.nightColors
                            : ReaderPreferences.dayColors)[keys[i]],
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color:
                              (dark ? p.nightBackground : p.dayBackground) ==
                                  keys[i]
                              ? Theme.of(context).colorScheme.primary
                              : Theme.of(context).colorScheme.outlineVariant,
                        ),
                      ),
                      child:
                          (dark ? p.nightBackground : p.dayBackground) ==
                              keys[i]
                          ? Icon(
                              Icons.check,
                              color: dark ? Colors.white : Colors.black,
                            )
                          : null,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    if (page == 2) {
      return Column(
        children: [
          TextButton.icon(
            onPressed: () => setState(() => page = 0),
            icon: const Icon(Icons.arrow_back),
            label: const Text('返回阅读设置'),
          ),
          Expanded(
            child: widget.advanced(context, () {
              if (mounted) setState(() {});
            }),
          ),
        ],
      );
    }
    if (page == 1) {
      return ListView(
        key: const ValueKey('article-spacing'),
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              IconButton(
                tooltip: '返回阅读设置',
                onPressed: () => setState(() => page = 0),
                icon: const Icon(Icons.keyboard_arrow_down),
              ),
              Expanded(
                child: Text(
                  '间距设置',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          spacing('行间距', p.lineHeight, [
            1.2,
            1.6,
            2.0,
            2.6,
          ], (v) => p.lineHeight = v),
          spacing('段间距', p.paragraphGap, [
            8,
            16,
            28,
            48,
          ], (v) => p.paragraphGap = v),
          spacing('页面边距', p.margin, [12, 24, 40, 64], (v) => p.margin = v),
        ],
      );
    }
    return SingleChildScrollView(
      key: const ValueKey('article-aa'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  '字号',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              Text('字号 ${widget.fontSize.round()}'),
            ],
          ),
          Row(
            children: [
              IconButton(
                tooltip: '缩小字号',
                onPressed: () =>
                    widget.onFont((widget.fontSize - 1).clamp(14, 32)),
                icon: const Icon(Icons.text_decrease),
              ),
              Expanded(
                child: Slider(
                  value: widget.fontSize,
                  min: 14,
                  max: 32,
                  divisions: 18,
                  label: '${widget.fontSize.round()}',
                  onChanged: widget.onFont,
                ),
              ),
              IconButton(
                tooltip: '增大字号',
                onPressed: () =>
                    widget.onFont((widget.fontSize + 1).clamp(14, 32)),
                icon: const Icon(Icons.text_increase),
              ),
            ],
          ),
          const Divider(height: 32),
          const Text('字体', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: p.font,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: const [
              DropdownMenuItem(value: 'system', child: Text('系统字体')),
              DropdownMenuItem(value: 'serif', child: Text('衬线字体')),
            ],
            onChanged: (v) {
              if (v != null) change(() => p.font = v);
            },
          ),
          const Divider(height: 32),
          const Text('阅读背景', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          palette(
            '日间背景',
            false,
            const ['white', 'grey', 'paper', 'green'],
            const ['白色', '浅灰', '纸张', '浅绿'],
          ),
          const SizedBox(height: 12),
          palette(
            '夜间背景',
            true,
            const ['dark', 'charcoal', 'navy', 'brown'],
            const ['夜间', '深灰', '蓝黑', '棕黑'],
          ),
          const SizedBox(height: 8),
          const Text('日间与夜间背景独立保存，切换主题时自动恢复。', style: TextStyle(fontSize: 12)),
          const Divider(height: 32),
          const Text('阅读方式', style: TextStyle(fontWeight: FontWeight.bold)),
          mode(true, '左右翻页'),
          if (paged && widget.showEffects)
            LayoutBuilder(
              builder: (context, c) => Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final effect in const [
                    ('slide', '平移翻页', Icons.view_carousel_outlined),
                    ('cover', '覆盖翻页', Icons.layers_outlined),
                    ('curl', '仿真翻页', Icons.auto_stories_outlined),
                  ])
                    SizedBox(
                      width: c.maxWidth >= 320
                          ? (c.maxWidth - 16) / 3
                          : (c.maxWidth - 8) / 2,
                      child: OutlinedButton(
                        onPressed: () => change(() => p.turnEffect = effect.$1),
                        style: OutlinedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          side: BorderSide(
                            color: p.turnEffect == effect.$1
                                ? Theme.of(context).colorScheme.primary
                                : Theme.of(context).colorScheme.outlineVariant,
                          ),
                        ),
                        child: Column(
                          children: [
                            Icon(effect.$3),
                            const SizedBox(height: 8),
                            Text(effect.$2),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          mode(false, '上下滚动'),
          const Divider(height: 32),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => setState(() => page = 1),
                  icon: const Icon(Icons.format_line_spacing),
                  label: const Text('间距设置'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextButton(
                  onPressed: () => setState(() => page = 2),
                  child: const Text('更多'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
