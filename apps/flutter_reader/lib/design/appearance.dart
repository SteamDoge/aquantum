// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import 'theme.dart';
import 'widgets.dart';

/// ReaderApp owns this preference; independent app/test instances share no state.
class AqAppearance extends InheritedWidget {
  final AqPalette palette;
  final Future<void> Function(AqPalette) onChanged;
  const AqAppearance({
    super.key,
    required this.palette,
    required this.onChanged,
    required super.child,
  });
  static AqAppearance? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AqAppearance>();
  @override
  bool updateShouldNotify(AqAppearance oldWidget) =>
      oldWidget.palette != palette;
}

/// Color themes as one grouped selection list, each with its accent swatch.
class PaletteSettings extends StatefulWidget {
  const PaletteSettings({super.key});
  @override
  State<PaletteSettings> createState() => _PaletteSettingsState();
}

class _PaletteSettingsState extends State<PaletteSettings> {
  bool busy = false;
  String? error;
  Future<void> choose(AqAppearance appearance, AqPalette palette) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await appearance.onChanged(palette);
    } catch (e) {
      if (mounted) setState(() => error = '主题保存失败：$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appearance = AqAppearance.maybeOf(context);
    if (appearance == null) return const SizedBox.shrink();
    final brightness = Theme.of(context).brightness;
    final theme = Theme.of(context);
    return AqSection(
      header: '颜色主题',
      footer: error ?? '只改变应用界面配色。正文的纸色与日夜设置在阅读时的 Aa 中逐书保存。',
      dividerIndent: 58,
      children: [
        for (final palette in AqPalette.values)
          Builder(
            builder: (context) {
              final (colors, accent, _) = paletteColors(palette, brightness);
              final selected = appearance.palette == palette;
              return Semantics(
                selected: selected,
                button: true,
                child: InkWell(
                  onTap: busy ? null : () => choose(appearance, palette),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 56),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          _Swatch(accent: accent, paper: colors.background),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  palette.label,
                                  style: theme.textTheme.bodyLarge,
                                ),
                                Text(
                                  palette.description,
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          AnimatedOpacity(
                            opacity: selected ? 1 : 0,
                            duration: const Duration(milliseconds: 140),
                            child: Icon(
                              Icons.check,
                              size: 22,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }
}

class _Swatch extends StatelessWidget {
  final Color accent, paper;
  const _Swatch({required this.accent, required this.paper});
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: paper,
        border: Border.all(color: AqColors.of(context).line),
      ),
      alignment: Alignment.center,
      child: Container(
        width: 18,
        height: 18,
        decoration: BoxDecoration(shape: BoxShape.circle, color: accent),
      ),
    ),
  );
}
