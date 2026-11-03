// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import 'theme.dart';

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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('颜色主题', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, size) {
            final columns =
                size.maxWidth >= 620 &&
                    MediaQuery.textScalerOf(context).scale(14) < 25
                ? 4
                : 2;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final palette in AqPalette.values)
                  SizedBox(
                    width: (size.maxWidth - 12 * (columns - 1)) / columns,
                    child: Builder(
                      builder: (context) {
                        final (colors, accent, _) = paletteColors(
                          palette,
                          Theme.of(context).brightness,
                        );
                        final selected = appearance.palette == palette;
                        return Semantics(
                          selected: selected,
                          button: true,
                          child: Material(
                            color: colors.panel,
                            clipBehavior: Clip.antiAlias,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(20),
                              side: BorderSide(
                                color: selected ? accent : colors.line,
                                width: selected ? 1.5 : 1,
                              ),
                            ),
                            child: InkWell(
                              onTap: busy
                                  ? null
                                  : () => choose(appearance, palette),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Container(
                                      height: 44,
                                      decoration: BoxDecoration(
                                        color: colors.backgroundEnd,
                                        borderRadius: BorderRadius.circular(11),
                                      ),
                                      child: Align(
                                        alignment: Alignment.centerLeft,
                                        child: Padding(
                                          padding: const EdgeInsets.all(10),
                                          child: Container(
                                            width: 38,
                                            height: 15,
                                            decoration: BoxDecoration(
                                              color: accent,
                                              borderRadius:
                                                  BorderRadius.circular(10),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 10),
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            palette.label,
                                            style: Theme.of(
                                              context,
                                            ).textTheme.titleSmall,
                                          ),
                                        ),
                                        if (selected)
                                          Icon(
                                            Icons.check_circle_outline,
                                            size: 18,
                                            color: accent,
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 5),
                                    Text(
                                      palette.description,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
              ],
            );
          },
        ),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        const SizedBox(height: 20),
      ],
    );
  }
}
