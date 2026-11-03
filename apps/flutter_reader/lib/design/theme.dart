// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 AQuantum Reader contributors.
import 'package:flutter/material.dart';

/// Palettes change color only; shape, typography and motion remain shared.
enum AqPalette {
  lucent('澄光', '冰蓝与清透'),
  folio('纸境', '暖纸与墨青'),
  edition('墨序', '骨白与朱红'),
  nocturne('曜夜', '石墨与冷紫');

  final String label, description;
  const AqPalette(this.label, this.description);
  static AqPalette parse(String? value) =>
      values.firstWhere((p) => p.name == value, orElse: () => lucent);
}

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
  final values = switch ((palette, brightness == Brightness.dark)) {
    (AqPalette.lucent, false) => const [
      0xfff5f8ff,
      0xffe7f1f4,
      0xffffffff,
      0xff5e6c82,
      0xffdce4ef,
      0xffe7edfc,
      0xff315ccc,
      0xff17253d,
    ],
    (AqPalette.folio, false) => const [
      0xfffaf7ee,
      0xffe9eadd,
      0xfffcfaf3,
      0xff62665c,
      0xffdcd9cb,
      0xffe2e8de,
      0xff24554c,
      0xff292d29,
    ],
    (AqPalette.edition, false) => const [
      0xfffaf9f4,
      0xffeae9e1,
      0xfffffdf7,
      0xff60635b,
      0xffd6d5cc,
      0xfff1e3dc,
      0xffb43d31,
      0xff202321,
    ],
    (AqPalette.nocturne, false) => const [
      0xfff7f6fc,
      0xffe5e7f2,
      0xffffffff,
      0xff62667b,
      0xffdedeea,
      0xffeae8f6,
      0xff6760ad,
      0xff25263a,
    ],
    (AqPalette.lucent, true) => const [
      0xff111d31,
      0xff152439,
      0xff1c2a40,
      0xffa8b7d1,
      0xff31425c,
      0xff2c4268,
      0xffa4bfff,
      0xffedf2fc,
    ],
    (AqPalette.folio, true) => const [
      0xff222720,
      0xff292f26,
      0xff2d332a,
      0xffb8bcaa,
      0xff41483a,
      0xff3f4b37,
      0xffc8d9b6,
      0xffeeeade,
    ],
    (AqPalette.edition, true) => const [
      0xff20221f,
      0xff2a2c25,
      0xff292c26,
      0xffb3b6aa,
      0xff45483e,
      0xff49322b,
      0xfff29983,
      0xfff0efe5,
    ],
    (AqPalette.nocturne, true) => const [
      0xff12151e,
      0xff1d2130,
      0xff1c202d,
      0xffb0b2c7,
      0xff34394c,
      0xff37364d,
      0xffb3adf0,
      0xffeeedf7,
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
        onPrimary: dark ? tokens.background : Colors.white,
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
        surfaceContainerHigh: tokens.soft,
        surfaceContainerHighest: tokens.soft,
        outlineVariant: tokens.line,
        surfaceTint: Colors.transparent,
      );
  final base = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: tokens.background,
    fontFamilyFallback: const [
      'Microsoft YaHei',
      'Noto Sans CJK SC',
      'sans-serif',
    ],
    visualDensity: VisualDensity.standard,
  );
  final line = BorderSide(color: tokens.line);
  return base.copyWith(
    extensions: [tokens],
    textTheme: base.textTheme.copyWith(
      headlineLarge: base.textTheme.headlineLarge?.copyWith(
        fontSize: 32,
        fontWeight: FontWeight.w600,
        letterSpacing: -.8,
      ),
      headlineMedium: base.textTheme.headlineMedium?.copyWith(
        fontSize: 28,
        fontWeight: FontWeight.w600,
        letterSpacing: -.6,
      ),
      titleLarge: base.textTheme.titleLarge?.copyWith(
        fontSize: 20,
        fontWeight: FontWeight.w600,
      ),
      titleMedium: base.textTheme.titleMedium?.copyWith(
        fontSize: 15,
        fontWeight: FontWeight.w600,
      ),
      bodyMedium: base.textTheme.bodyMedium?.copyWith(height: 1.5),
      bodySmall: base.textTheme.bodySmall?.copyWith(
        color: tokens.muted,
        height: 1.5,
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: tokens.background,
      foregroundColor: text,
      scrolledUnderElevation: 0,
      elevation: 0,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(
        color: text,
        fontWeight: FontWeight.w600,
      ),
    ),
    cardTheme: CardThemeData(
      color: tokens.panel,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(23),
        side: line,
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: tokens.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(28),
        side: line,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: tokens.panel,
      surfaceTintColor: Colors.transparent,
      modalBackgroundColor: tokens.panel,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: tokens.panel,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: line,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        side: line,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: accent,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: tokens.panel,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: line,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: line,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: accent, width: 1.5),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: tokens.line,
      thickness: .7,
      space: 24,
    ),
    chipTheme: base.chipTheme.copyWith(
      backgroundColor: tokens.panel,
      selectedColor: tokens.soft,
      side: BorderSide.none,
      shape: const StadiumBorder(),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: accent,
      linearTrackColor: tokens.soft,
      linearMinHeight: 3,
      borderRadius: BorderRadius.circular(4),
    ),
    navigationBarTheme: const NavigationBarThemeData(height: 72),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      showCloseIcon: true,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 112),
    ),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 450),
    ),
  );
}
