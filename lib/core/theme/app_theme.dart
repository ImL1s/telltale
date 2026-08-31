/// Theme assembly: typography scale, component defaults, motion tokens.
library;

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_colors.dart';
import 'gauge_skin.dart';

/// Spacing scale. A 4pt base keeps everything on one rhythm; the named steps
/// stop `EdgeInsets.all(13)` from ever appearing.
abstract final class Spacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double xxl = 32;
  static const double xxxl = 48;
}

abstract final class Radii {
  static const double sm = 8;
  static const double md = 14;
  static const double lg = 20;
  static const double pill = 999;

  static const BorderRadius cardRadius = BorderRadius.all(Radius.circular(md));
  static const BorderRadius sheetRadius =
      BorderRadius.vertical(top: Radius.circular(lg));
}

/// Motion tokens.
///
/// Durations sit in the 120-320ms band: below ~100ms a transition reads as a
/// jump, above ~350ms it reads as sluggish on a screen the user glances at
/// while driving.
abstract final class Motion {
  static const Duration instant = Duration(milliseconds: 120);
  static const Duration fast = Duration(milliseconds: 180);
  static const Duration normal = Duration(milliseconds: 240);
  static const Duration slow = Duration(milliseconds: 320);

  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasised = Curves.easeOutQuart;

  /// Needles overshoot slightly and settle, the way a real instrument does.
  static const Curve needle = Curves.easeOutBack;
}

abstract final class AppTypography {
  static const String display = 'SpaceGrotesk';
  static const String mono = 'JetBrainsMono';

  /// Numerals that do not shuffle sideways as digits change. Without this a
  /// live RPM readout jitters horizontally on every sample, which is far more
  /// distracting than the number itself changing.
  static const List<FontFeature> tabular = [FontFeature.tabularFigures()];

  static TextTheme textTheme(AppPalette palette) {
    TextStyle base(double size, FontWeight weight, {double? height, double? spacing}) {
      return TextStyle(
        fontFamily: display,
        fontSize: size,
        fontWeight: weight,
        height: height,
        letterSpacing: spacing,
        color: palette.textPrimary,
      );
    }

    return TextTheme(
      displayLarge: base(48, FontWeight.w700, height: 1.05, spacing: -1.2),
      displayMedium: base(36, FontWeight.w700, height: 1.1, spacing: -0.8),
      displaySmall: base(28, FontWeight.w600, height: 1.15, spacing: -0.4),
      headlineMedium: base(22, FontWeight.w600, height: 1.25, spacing: -0.2),
      headlineSmall: base(19, FontWeight.w600, height: 1.3),
      titleLarge: base(17, FontWeight.w600, height: 1.35),
      titleMedium: base(15, FontWeight.w600, height: 1.4),
      titleSmall: base(13, FontWeight.w600, height: 1.4, spacing: 0.1),
      bodyLarge: base(15, FontWeight.w400, height: 1.5).copyWith(color: palette.textPrimary),
      bodyMedium: base(14, FontWeight.w400, height: 1.5).copyWith(color: palette.textSecondary),
      bodySmall: base(12.5, FontWeight.w400, height: 1.45).copyWith(color: palette.textSecondary),
      labelLarge: base(14, FontWeight.w600, height: 1.2, spacing: 0.2),
      labelMedium: base(12, FontWeight.w600, height: 1.2, spacing: 0.4),
      // Section eyebrows: small, wide-tracked, quiet.
      labelSmall: base(10.5, FontWeight.w700, height: 1.2, spacing: 1.1)
          .copyWith(color: palette.textTertiary),
    );
  }

  /// Big live numbers on gauge faces.
  static TextStyle readout(AppPalette palette, double size) => TextStyle(
        fontFamily: display,
        fontSize: size,
        fontWeight: FontWeight.w700,
        height: 1.0,
        letterSpacing: -1,
        color: palette.textPrimary,
        fontFeatures: tabular,
      );

  /// Hex payloads, DTC codes, AT commands — anything where character alignment
  /// carries meaning.
  static TextStyle code(AppPalette palette, {double size = 12.5, Color? color}) => TextStyle(
        fontFamily: mono,
        fontSize: size,
        fontWeight: FontWeight.w500,
        height: 1.45,
        color: color ?? palette.textSecondary,
        fontFeatures: tabular,
      );
}

abstract final class AppTheme {
  static ThemeData dark({GaugeSkin skin = GaugeSkin.cluster}) =>
      _build(AppPalette.dark, Brightness.dark, skin);

  static ThemeData light({GaugeSkin skin = GaugeSkin.cluster}) =>
      _build(AppPalette.light, Brightness.light, skin);

  static ThemeData _build(
      AppPalette palette, Brightness brightness, GaugeSkin skin) {
    final scheme = ColorScheme(
      brightness: brightness,
      primary: palette.accent,
      onPrimary: brightness == Brightness.dark
          ? const Color(0xFF00201C)
          : const Color(0xFFFFFFFF),
      secondary: palette.info,
      onSecondary: Colors.white,
      error: palette.danger,
      onError: Colors.white,
      surface: palette.surface,
      onSurface: palette.textPrimary,
      surfaceContainerHighest: palette.surfaceHigh,
      outline: palette.hairline,
      outlineVariant: palette.hairline,
    );

    final text = AppTypography.textTheme(palette);

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: palette.background,
      canvasColor: palette.background,
      textTheme: text,
      fontFamily: AppTypography.display,
      extensions: [palette, skin],
      splashFactory: InkSparkle.splashFactory,

      appBarTheme: AppBarTheme(
        backgroundColor: palette.background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.headlineSmall,
        iconTheme: IconThemeData(color: palette.textSecondary),
        systemOverlayStyle: brightness == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark,
      ),

      // Elevation is expressed with a hairline border rather than a shadow:
      // on a near-black ground a drop shadow is invisible, and a 1px lighter
      // edge is what actually separates a card from the page.
      cardTheme: CardThemeData(
        color: palette.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: Radii.cardRadius,
          side: BorderSide(color: palette.hairline),
        ),
      ),

      dividerTheme: DividerThemeData(
        color: palette.hairline,
        thickness: 1,
        space: 1,
      ),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: palette.accent,
          foregroundColor: scheme.onPrimary,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: Spacing.xl),
          shape: const RoundedRectangleBorder(borderRadius: Radii.cardRadius),
          textStyle: text.labelLarge,
        ),
      ),

      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: palette.textPrimary,
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: Spacing.xl),
          side: BorderSide(color: palette.hairline),
          shape: const RoundedRectangleBorder(borderRadius: Radii.cardRadius),
          textStyle: text.labelLarge,
        ),
      ),

      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: palette.accent,
          minimumSize: const Size(0, 44),
          textStyle: text.labelLarge,
        ),
      ),

      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: palette.textSecondary,
          // 44pt is the minimum comfortable touch target, and this app gets
          // used at arm's length in a moving car.
          minimumSize: const Size(44, 44),
        ),
      ),

      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: palette.surfaceAlt,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Spacing.lg,
          vertical: Spacing.md,
        ),
        border: OutlineInputBorder(
          borderRadius: Radii.cardRadius,
          borderSide: BorderSide(color: palette.hairline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: Radii.cardRadius,
          borderSide: BorderSide(color: palette.hairline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: Radii.cardRadius,
          borderSide: BorderSide(color: palette.accent, width: 1.6),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: Radii.cardRadius,
          borderSide: BorderSide(color: palette.danger),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: Radii.cardRadius,
          borderSide: BorderSide(color: palette.danger, width: 1.6),
        ),
        labelStyle: text.bodyMedium,
        hintStyle: text.bodyMedium?.copyWith(color: palette.textTertiary),
      ),

      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          side: WidgetStatePropertyAll(BorderSide(color: palette.hairline)),
          textStyle: WidgetStatePropertyAll(text.labelMedium),
          backgroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? palette.accent.withValues(alpha: 0.16)
                : Colors.transparent,
          ),
          foregroundColor: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.selected)
                ? palette.accent
                : palette.textSecondary,
          ),
        ),
      ),

      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: palette.surface,
        indicatorColor: palette.accent.withValues(alpha: 0.16),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 68,
        labelTextStyle: WidgetStatePropertyAll(text.labelMedium),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 22,
            color: states.contains(WidgetState.selected)
                ? palette.accent
                : palette.textTertiary,
          ),
        ),
      ),

      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: palette.surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(borderRadius: Radii.sheetRadius),
        showDragHandle: true,
        dragHandleColor: palette.hairline,
      ),

      dialogTheme: DialogThemeData(
        backgroundColor: palette.surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: Radii.cardRadius,
          side: BorderSide(color: palette.hairline),
        ),
        titleTextStyle: text.headlineSmall,
        contentTextStyle: text.bodyMedium,
      ),

      snackBarTheme: SnackBarThemeData(
        backgroundColor: palette.surfaceHigh,
        contentTextStyle: text.bodyMedium?.copyWith(color: palette.textPrimary),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: Radii.cardRadius,
          side: BorderSide(color: palette.hairline),
        ),
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? scheme.onPrimary
              : palette.textTertiary,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? palette.accent
              : palette.surfaceHigh,
        ),
        trackOutlineColor: WidgetStatePropertyAll(palette.hairline),
      ),

      sliderTheme: SliderThemeData(
        activeTrackColor: palette.accent,
        inactiveTrackColor: palette.surfaceHigh,
        thumbColor: palette.accent,
        overlayColor: palette.accent.withValues(alpha: 0.12),
        trackHeight: 4,
      ),

      listTileTheme: ListTileThemeData(
        iconColor: palette.textSecondary,
        titleTextStyle: text.titleMedium,
        subtitleTextStyle: text.bodySmall,
        contentPadding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
      ),

      chipTheme: ChipThemeData(
        backgroundColor: palette.surfaceAlt,
        side: BorderSide(color: palette.hairline),
        labelStyle: text.labelMedium!,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(Radii.sm)),
        ),
      ),

      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          // Desktop (non-Apple) keeps Material transitions; Cupertino glyphs
          // are wrong on Windows/Linux chrome, and the default Material
          // builders already match a keyboard/mouse primary surface.
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
        },
      ),
    );
  }
}

/// Convenience accessor so widgets read `context.palette.accent`.
extension PaletteAccess on BuildContext {
  AppPalette get palette =>
      Theme.of(this).extension<AppPalette>() ?? AppPalette.dark;

  TextTheme get texts => Theme.of(this).textTheme;

  bool get isCompact => MediaQuery.sizeOf(this).width < 600;
}
