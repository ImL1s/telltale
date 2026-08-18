/// Colour tokens.
///
/// The app is dark-first: an instrument cluster lives in a car at night, and
/// the deep near-black ground makes the gauge arcs the brightest thing on
/// screen — which is where the driver's eye should go. A light scheme is
/// provided too, because the OS theme is the user's call, not ours.
///
/// Hues carry meaning and are used consistently:
///   aqua   — nominal / the app's own chrome
///   amber  — approaching a limit
///   red    — over a limit, or a fault
///   violet — derived figures the app computed rather than read off the bus
library;

import 'package:flutter/material.dart';

/// Opacity applied to a value that is no longer arriving.
///
/// Not chosen by eye. Dimming is the whole signal, so the temptation is to push
/// it as low as it will go — 0.42 was the previous figure, and on the light
/// theme that put 10.5px status text at **2.68:1**, well under the WCAG 2.2
/// minimum of 4.5:1 for normal text. These are labels read at arm's length
/// through windscreen glare; a stale reading that cannot be read is not a
/// gentler failure than a wrong one.
///
/// 0.62 is the lowest value that clears 4.5:1 on both themes and both
/// surfaces, with margin. `contrast_test.dart` asserts it, so lowering it
/// again fails rather than quietly regressing.
///
/// Opacity is never the only signal either — the stale readouts carry
/// "（資料已過期）" text as well, because colour alone excludes anyone who
/// cannot perceive the difference.
const double kStaleOpacity = 0.62;

/// Opacity for the *painted* parts of a gauge whose value is stale or absent.
///
/// Lower than [kStaleOpacity] on purpose. Nothing has to be read off an arc or
/// a needle, so they can fade far enough to be unmistakable; text cannot, and
/// wrapping both in one value forced a choice between an invisible signal and
/// illegible numbers. At 0.62 the units and label tokens measure 2.4–3.5:1
/// against their panel, well under the 4.5:1 minimum — which is what happened
/// while a single opacity covered the whole tile.
const double kStaleDecorationOpacity = 0.34;

@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.background,
    required this.surface,
    required this.surfaceAlt,
    required this.surfaceHigh,
    required this.hairline,
    required this.textPrimary,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.accentSoft,
    required this.info,
    required this.warning,
    required this.danger,
    required this.success,
    required this.derived,
    required this.gaugeTrack,
    required this.glow,
  });

  final Color background;
  final Color surface;
  final Color surfaceAlt;
  final Color surfaceHigh;
  final Color hairline;

  final Color textPrimary;
  final Color textSecondary;
  final Color textTertiary;

  final Color accent;
  final Color accentSoft;
  final Color info;
  final Color warning;
  final Color danger;
  final Color success;

  /// Marks values the physics engine derived rather than read from a sensor.
  final Color derived;

  /// The unfilled part of a gauge arc.
  final Color gaugeTrack;

  /// Needle and arc bloom. Alpha is baked in.
  final Color glow;

  static const AppPalette dark = AppPalette(
    background: Color(0xFF06080C),
    surface: Color(0xFF0E1218),
    surfaceAlt: Color(0xFF151B23),
    surfaceHigh: Color(0xFF1D242E),
    hairline: Color(0xFF232C38),
    textPrimary: Color(0xFFE9EEF5),
    textSecondary: Color(0xFF93A1B2),
    // 5.1:1 on the surface, 5.5:1 on the background. The previous #5D6A7A
    // measured 3.40:1 — below the WCAG 4.5:1 minimum for normal text, and
    // these are 10.5px status labels read at arm's length through windscreen
    // glare, which is the least forgiving condition this app has.
    textTertiary: Color(0xFF7C8794),
    accent: Color(0xFF35E0C8),
    accentSoft: Color(0xFF1A6F66),
    info: Color(0xFF56A8FF),
    warning: Color(0xFFFFB020),
    danger: Color(0xFFFF4D5E),
    success: Color(0xFF3DDC84),
    derived: Color(0xFFA78BFA),
    gaugeTrack: Color(0xFF1B2431),
    glow: Color(0x5535E0C8),
  );

  /// Light scheme. Accents are darkened rather than reused: the dark-mode aqua
  /// only reaches 1.6:1 on white, which fails contrast for text and reads as
  /// washed-out for an arc.
  static const AppPalette light = AppPalette(
    background: Color(0xFFF4F6FA),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFEDF1F7),
    surfaceHigh: Color(0xFFE2E8F1),
    hairline: Color(0xFFD4DBE6),
    textPrimary: Color(0xFF0F1621),
    textSecondary: Color(0xFF4B5766),
    // 5.1:1 on white, 4.7:1 on the tinted background. Was #778394 at 3.85:1.
    textTertiary: Color(0xFF646F7E),
    // Darkened from #00897B, which put white text at 4.32:1 — just under the
    // threshold, on the app's primary action.
    accent: Color(0xFF00796B),
    accentSoft: Color(0xFF9FE3D9),
    info: Color(0xFF1565C0),
    warning: Color(0xFFB26A00),
    danger: Color(0xFFC62828),
    success: Color(0xFF1B7F45),
    derived: Color(0xFF6D3FD1),
    gaugeTrack: Color(0xFFDDE4EE),
    glow: Color(0x3300897B),
  );

  @override
  AppPalette copyWith({
    Color? background,
    Color? surface,
    Color? surfaceAlt,
    Color? surfaceHigh,
    Color? hairline,
    Color? textPrimary,
    Color? textSecondary,
    Color? textTertiary,
    Color? accent,
    Color? accentSoft,
    Color? info,
    Color? warning,
    Color? danger,
    Color? success,
    Color? derived,
    Color? gaugeTrack,
    Color? glow,
  }) {
    return AppPalette(
      background: background ?? this.background,
      surface: surface ?? this.surface,
      surfaceAlt: surfaceAlt ?? this.surfaceAlt,
      surfaceHigh: surfaceHigh ?? this.surfaceHigh,
      hairline: hairline ?? this.hairline,
      textPrimary: textPrimary ?? this.textPrimary,
      textSecondary: textSecondary ?? this.textSecondary,
      textTertiary: textTertiary ?? this.textTertiary,
      accent: accent ?? this.accent,
      accentSoft: accentSoft ?? this.accentSoft,
      info: info ?? this.info,
      warning: warning ?? this.warning,
      danger: danger ?? this.danger,
      success: success ?? this.success,
      derived: derived ?? this.derived,
      gaugeTrack: gaugeTrack ?? this.gaugeTrack,
      glow: glow ?? this.glow,
    );
  }

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    Color mix(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppPalette(
      background: mix(background, other.background),
      surface: mix(surface, other.surface),
      surfaceAlt: mix(surfaceAlt, other.surfaceAlt),
      surfaceHigh: mix(surfaceHigh, other.surfaceHigh),
      hairline: mix(hairline, other.hairline),
      textPrimary: mix(textPrimary, other.textPrimary),
      textSecondary: mix(textSecondary, other.textSecondary),
      textTertiary: mix(textTertiary, other.textTertiary),
      accent: mix(accent, other.accent),
      accentSoft: mix(accentSoft, other.accentSoft),
      info: mix(info, other.info),
      warning: mix(warning, other.warning),
      danger: mix(danger, other.danger),
      success: mix(success, other.success),
      derived: mix(derived, other.derived),
      gaugeTrack: mix(gaugeTrack, other.gaugeTrack),
      glow: mix(glow, other.glow),
    );
  }
}

/// The two ends of one gauge's arc gradient, already resolved for a theme.
typedef GaugeColors = ({Color bright, Color dim});

/// Per-gauge hue.
///
/// Every gauge sweeps from a dimmed version of its own hue to the full hue, and
/// only crosses into red inside its redline zone. That keeps a wall of gauges
/// varied enough to tell apart at a glance while staying one family — a
/// free-for-all of hues reads as noise, a single hue reads as undifferentiated.
///
/// Each hue carries a separate pair per theme, and they are not simple
/// lightenings of one another. On black the arc runs dark → vivid, and `dim`
/// has to be a deep shade. On white that same deep shade blended into the dial
/// face turns it muddy, and the vivid end loses contrast, so the light pair
/// inverts the relationship: a pale tint at the low end, a saturated mid-tone
/// at the high end.
enum GaugeHue {
  aqua(
    darkBright: Color(0xFF35E0C8),
    darkDim: Color(0xFF0E4F49),
    lightBright: Color(0xFF00897B),
    lightDim: Color(0xFF9FE0D6),
  ),
  blue(
    darkBright: Color(0xFF56A8FF),
    darkDim: Color(0xFF123A63),
    lightBright: Color(0xFF1565C0),
    lightDim: Color(0xFFAECDF0),
  ),
  violet(
    darkBright: Color(0xFFA78BFA),
    darkDim: Color(0xFF3A2A66),
    lightBright: Color(0xFF6D3FD1),
    lightDim: Color(0xFFCDBBF3),
  ),
  amber(
    darkBright: Color(0xFFFFB020),
    darkDim: Color(0xFF5C3F06),
    lightBright: Color(0xFFB26A00),
    lightDim: Color(0xFFF3D3A0),
  ),
  rose(
    darkBright: Color(0xFFFF6B8A),
    darkDim: Color(0xFF5C1F2E),
    lightBright: Color(0xFFC2185B),
    lightDim: Color(0xFFF3B7C8),
  ),
  lime(
    darkBright: Color(0xFF8BE04E),
    darkDim: Color(0xFF32521B),
    lightBright: Color(0xFF4E8F20),
    lightDim: Color(0xFFC4E5A5),
  );

  const GaugeHue({
    required this.darkBright,
    required this.darkDim,
    required this.lightBright,
    required this.lightDim,
  });

  final Color darkBright;
  final Color darkDim;
  final Color lightBright;
  final Color lightDim;

  GaugeColors resolve(Brightness brightness) => brightness == Brightness.dark
      ? (bright: darkBright, dim: darkDim)
      : (bright: lightBright, dim: lightDim);

  /// Assigns a stable hue from a PID id, so the same gauge keeps its colour
  /// across launches without anyone having to store a choice.
  static GaugeHue forKey(String key) {
    var hash = 0;
    for (final unit in key.codeUnits) {
      hash = (hash * 31 + unit) & 0x7FFFFFFF;
    }
    return GaugeHue.values[hash % GaugeHue.values.length];
  }
}

extension GaugeHueContext on BuildContext {
  GaugeColors gaugeColors(GaugeHue hue) =>
      hue.resolve(Theme.of(this).brightness);
}
