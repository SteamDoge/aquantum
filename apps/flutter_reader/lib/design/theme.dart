// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';
import '../l10n/l10n.dart';

/// Palettes change color only; shape, typography and motion remain shared.
enum AqPalette {
  lucent,
  folio,
  edition,
  nocturne;

  String get label => switch (this) {
    lucent => tr('澄光'),
    folio => tr('纸境'),
    edition => tr('墨序'),
    nocturne => tr('曜夜'),
  };
  static AqPalette parse(String? value) =>
      values.firstWhere((p) => p.name == value, orElse: () => lucent);
}

/// Grouped-list tokens: [background] is the page behind inset groups,
/// [panel] the group itself, [backgroundEnd] a raised fill (search fields,
/// tracks), [line] hairline separators and [soft] the accent selection tint.
@immutable
class AqColors extends ThemeExtension<AqColors> {
  final Color background, backgroundEnd, panel, muted, line, soft;
  const AqColors({
    required this.background,
    required this.backgroundEnd,
    required this.panel,
    required this.muted,
    required this.line,
    required this.soft,
  });
  static AqColors of(BuildContext context) =>
      Theme.of(context).extension<AqColors>() ??
      paletteColors(AqPalette.lucent, Theme.of(context).brightness).$1;
  @override
  AqColors copyWith({
    Color? background,
    Color? backgroundEnd,
    Color? panel,
    Color? muted,
    Color? line,
    Color? soft,
  }) => AqColors(
    background: background ?? this.background,
    backgroundEnd: backgroundEnd ?? this.backgroundEnd,
    panel: panel ?? this.panel,
    muted: muted ?? this.muted,
    line: line ?? this.line,
    soft: soft ?? this.soft,
  );
  @override
  AqColors lerp(covariant AqColors? other, double t) => other == null
      ? this
      : AqColors(
          background: Color.lerp(background, other.background, t)!,
          backgroundEnd: Color.lerp(backgroundEnd, other.backgroundEnd, t)!,
          panel: Color.lerp(panel, other.panel, t)!,
          muted: Color.lerp(muted, other.muted, t)!,
          line: Color.lerp(line, other.line, t)!,
          soft: Color.lerp(soft, other.soft, t)!,
        );
}

(AqColors, Color, Color) paletteColors(
  AqPalette palette,
  Brightness brightness,
) {
  // background, raised fill, panel, muted, line, soft, accent, text.
  final values = switch ((palette, brightness == Brightness.dark)) {
    (AqPalette.lucent, false) => const [
      0xfff2f2f7,
      0xffe5e5ea,
      0xffffffff,
      0xff6c6c70,
      0xffdcdce1,
      0xffe3edff,
      0xff0066d6,
      0xff1c1c1e,
    ],
    (AqPalette.folio, false) => const [
      0xfff5f3ee,
      0xffe8e5dc,
      0xfffffefb,
      0xff6d6a62,
      0xffdedad0,
      0xfffbefd2,
      0xff9a6400,
      0xff26241f,
    ],
    (AqPalette.edition, false) => const [
      0xfff4f3ef,
      0xffe6e4de,
      0xffffffff,
      0xff6b6a65,
      0xffdcdad4,
      0xfffbe4e1,
      0xffbf3226,
      0xff1f1f1d,
    ],
    (AqPalette.nocturne, false) => const [
      0xfff3f3f8,
      0xffe4e4ed,
      0xffffffff,
      0xff6a6a76,
      0xffdcdce6,
      0xffe9e8fd,
      0xff5552d6,
      0xff1c1c24,
    ],
    (AqPalette.lucent, true) => const [
      0xff000000,
      0xff2c2c2e,
      0xff1c1c1e,
      0xff98989f,
      0xff38383a,
      0xff10284a,
      0xff4da3ff,
      0xfff5f5f7,
    ],
    (AqPalette.folio, true) => const [
      0xff0d0c0a,
      0xff2e2b26,
      0xff1e1c19,
      0xffa29d92,
      0xff3a3732,
      0xff3a2e12,
      0xffffcc33,
      0xfff4f1ea,
    ],
    (AqPalette.edition, true) => const [
      0xff0b0b0b,
      0xff2c2b2a,
      0xff1d1c1b,
      0xff9f9c97,
      0xff393836,
      0xff3d1d1a,
      0xffff7a6e,
      0xfff3f2ee,
    ],
    (AqPalette.nocturne, true) => const [
      0xff07070b,
      0xff2a2a33,
      0xff1a1a21,
      0xff9c9cab,
      0xff36363f,
      0xff26244a,
      0xffa8a6ff,
      0xfff2f2f8,
    ],
  };
  return (
    AqColors(
      background: Color(values[0]),
      backgroundEnd: Color(values[1]),
      panel: Color(values[2]),
      muted: Color(values[3]),
      line: Color(values[4]),
      soft: Color(values[5]),
    ),
    Color(values[6]),
    Color(values[7]),
  );
}

ThemeData readerTheme(
  Brightness brightness, {
  AqPalette palette = AqPalette.lucent,
}) {
  final (tokens, accent, text) = paletteColors(palette, brightness);
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness)
      .copyWith(
        primary: accent,
        onPrimary: dark ? Colors.black : Colors.white,
        primaryContainer: tokens.soft,
        onPrimaryContainer: accent,
        secondaryContainer: tokens.soft,
        onSecondaryContainer: text,
        surface: tokens.panel,
        onSurface: text,
        onSurfaceVariant: tokens.muted,
        surfaceContainerLowest: tokens.panel,
        surfaceContainerLow: tokens.background,
        surfaceContainer: tokens.backgroundEnd,
        surfaceContainerHigh: tokens.backgroundEnd,
        surfaceContainerHighest: tokens.backgroundEnd,
        outlineVariant: tokens.line,
        surfaceTint: Colors.transparent,
      );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: tokens.background,
    fontFamilyFallback: const [
      'PingFang SC',
      'Microsoft YaHei UI',
      'Microsoft YaHei',
      'Noto Sans CJK SC',
      'sans-serif',
    ],
    visualDensity: VisualDensity.standard,
  );
  final t = base.textTheme;
  final radius12 = BorderRadius.circular(12);
  final field = OutlineInputBorder(
    borderRadius: BorderRadius.circular(10),
    borderSide: BorderSide.none,
  );
  return base.copyWith(
    extensions: [tokens],
    textTheme: t.copyWith(
      // Large title: the one strong element at the top of every page.
      headlineLarge: t.headlineLarge?.copyWith(
        fontSize: 32,
        height: 1.15,
        fontWeight: FontWeight.w700,
        letterSpacing: -.4,
      ),
      headlineMedium: t.headlineMedium?.copyWith(
        fontSize: 26,
        fontWeight: FontWeight.w700,
        letterSpacing: -.3,
      ),
      titleLarge: t.titleLarge?.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w600,
        letterSpacing: -.2,
      ),
      titleMedium: t.titleMedium?.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w600,
      ),
      titleSmall: t.titleSmall?.copyWith(
        fontSize: 14,
        fontWeight: FontWeight.w600,
      ),
      bodyLarge: t.bodyLarge?.copyWith(fontSize: 16, height: 1.4),
      bodyMedium: t.bodyMedium?.copyWith(fontSize: 15, height: 1.45),
      bodySmall: t.bodySmall?.copyWith(
        fontSize: 13,
        color: tokens.muted,
        height: 1.4,
      ),
      labelSmall: t.labelSmall?.copyWith(color: tokens.muted),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: tokens.background,
      foregroundColor: text,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
      elevation: 0,
      centerTitle: true,
      iconTheme: IconThemeData(color: accent),
      actionsIconTheme: IconThemeData(color: accent),
      titleTextStyle: t.titleMedium?.copyWith(
        color: text,
        fontSize: 17,
        fontWeight: FontWeight.w600,
      ),
    ),
    cardTheme: CardThemeData(
      color: tokens.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(16)),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: tokens.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedSuperellipseBorder(borderRadius: BorderRadius.circular(22)),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: tokens.panel,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: tokens.panel,
      showDragHandle: true,
      dragHandleColor: tokens.line,
      shape: const RoundedSuperellipseBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: tokens.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: dark ? .5 : .18),
      shape: RoundedSuperellipseBorder(borderRadius: radius12),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(tokens.panel),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(
          RoundedSuperellipseBorder(borderRadius: radius12),
        ),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        // Button styles replace the ambient style: derive from the theme so
        // the CJK font fallback survives.
        textStyle: t.labelLarge?.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedSuperellipseBorder(borderRadius: radius12),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        side: BorderSide(color: tokens.line),
        shape: RoundedSuperellipseBorder(borderRadius: radius12),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 40),
        textStyle: t.labelLarge?.copyWith(
          fontSize: 15,
          fontWeight: FontWeight.w500,
        ),
        shape: RoundedSuperellipseBorder(borderRadius: radius12),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    // The round add button shared with ASpan.
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: accent,
      foregroundColor: dark ? Colors.black : Colors.white,
      elevation: 3,
      focusElevation: 3,
      hoverElevation: 4,
      highlightElevation: 2,
      shape: const CircleBorder(),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: accent,
      minLeadingWidth: 28,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      shape: RoundedSuperellipseBorder(borderRadius: radius12),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: tokens.backgroundEnd,
      hintStyle: TextStyle(color: tokens.muted),
      prefixIconColor: tokens.muted,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: field,
      enabledBorder: field,
      focusedBorder: field.copyWith(
        borderSide: BorderSide(color: accent, width: 1.5),
      ),
    ),
    dividerTheme: DividerThemeData(color: tokens.line, thickness: .5, space: 1),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: tokens.backgroundEnd,
      selectedColor: tokens.soft,
      side: BorderSide.none,
      shape: const StadiumBorder(),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        backgroundColor: tokens.backgroundEnd,
        // The selected segment is lifted above the track: white in light,
        // a lighter grey in dark (the dark panel is darker than the track).
        selectedBackgroundColor: dark
            ? Color.alphaBlend(
                text.withValues(alpha: .16),
                tokens.backgroundEnd,
              )
            : tokens.panel,
        selectedForegroundColor: text,
        foregroundColor: text,
        side: BorderSide(color: tokens.backgroundEnd, width: 2),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    ),
    switchTheme: SwitchThemeData(
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected)
            ? accent
            : tokens.backgroundEnd,
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: accent,
      linearTrackColor: tokens.backgroundEnd,
      linearMinHeight: 3,
      borderRadius: BorderRadius.circular(4),
    ),
    navigationBarTheme: const NavigationBarThemeData(height: 72),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      showCloseIcon: true,
      shape: RoundedSuperellipseBorder(borderRadius: radius12),
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 112),
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 450),
    ),
  );
}
