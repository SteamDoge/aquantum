// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import 'theme.dart';
import 'widgets.dart';
import '../l10n/l10n.dart';

/// ReaderApp owns these preferences; independent app/test instances share no
/// state. Without [onLanguageChanged] the language choice is not offered.
class AqAppearance extends InheritedWidget {
  final AqPalette palette;
  final Future<void> Function(AqPalette) onChanged;
  final AppLanguage language;
  final Future<void> Function(AppLanguage)? onLanguageChanged;
  const AqAppearance({
    super.key,
    required this.palette,
    required this.onChanged,
    this.language = AppLanguage.system,
    this.onLanguageChanged,
    required super.child,
  });
  static AqAppearance? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AqAppearance>();
  @override
  bool updateShouldNotify(AqAppearance oldWidget) =>
      oldWidget.palette != palette || oldWidget.language != language;
}

/// The name of a language choice: "follow system" is translated, languages
/// are always shown in their own name.
String languageLabel(AppLanguage language) => switch (language) {
  AppLanguage.system => tr('跟随系统'),
  AppLanguage.zhHans => UiLanguage.zhHans.nativeName,
  AppLanguage.en => UiLanguage.en.nativeName,
  AppLanguage.zhHant => UiLanguage.zhHant.nativeName,
};

/// Interface languages as one grouped selection list, like the color themes.
class LanguageSettings extends StatefulWidget {
  const LanguageSettings({super.key});
  @override
  State<LanguageSettings> createState() => _LanguageSettingsState();
}

class _LanguageSettingsState extends State<LanguageSettings> {
  bool busy = false;
  String? error;
  Future<void> choose(
    Future<void> Function(AppLanguage) change,
    AppLanguage language,
  ) async {
    if (busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await change(language);
    } catch (e) {
      if (mounted) setState(() => error = tr('语言保存失败：{e}', {'e': e}));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appearance = AqAppearance.maybeOf(context);
    final change = appearance?.onLanguageChanged;
    if (appearance == null || change == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return AqSection(
      header: tr('语言'),
      footer: error,
      children: [
        for (final language in AppLanguage.values)
          Builder(
            builder: (context) {
              final selected = appearance.language == language;
              return Semantics(
                selected: selected,
                button: true,
                child: InkWell(
                  key: ValueKey('language-${language.code}'),
                  onTap: busy ? null : () => choose(change, language),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 52),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  languageLabel(language),
                                  style: theme.textTheme.bodyLarge,
                                ),
                                if (language == AppLanguage.system)
                                  Text(
                                    resolveLanguage(
                                      AppLanguage.system,
                                      systemLocales,
                                    ).nativeName,
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
      if (mounted) setState(() => error = tr('主题保存失败：{e}', {'e': e}));
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
      header: tr('颜色主题'),
      footer: error,
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
                            child: Text(
                              palette.label,
                              style: theme.textTheme.bodyLarge,
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
