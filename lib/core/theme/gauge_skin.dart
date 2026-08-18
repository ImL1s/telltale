/// What an instrument *is*, not what colour it is painted.
///
/// The five skins this file describes differ in the shape of the dial, what
/// carries the value, whether there is a needle at all, how the face is
/// treated, and how the reading moves when it changes. Two of them do not draw
/// a needle; one does not draw a continuous arc; one deliberately refuses to
/// animate. A palette swap could not produce any of that.
///
/// Everything here is geometry and behaviour. Colour still comes from
/// `AppPalette` and `GaugeHue`, because a skin has to work in both light and
/// dark and those two palettes are not each other's brightness variants — the
/// note on `GaugeHue` explains why.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// What draws the current value.
enum GaugePointer {
  /// A needle sweeping from the centre. The reading is where it points.
  needle,

  /// A short bar riding the arc at the current value, with no spoke. Reads as
  /// a marker on a scale rather than an instrument with a moving part.
  marker,

  /// Nothing. The filled portion of the arc *is* the value, and the numeral
  /// carries the precision. The quietest of the five, and the only one with
  /// no moving geometry at all.
  none,
}

/// How the scale is marked.
enum GaugeTicks {
  /// No marks. The endpoints are labelled and nothing else is.
  none,

  /// Evenly spaced minor marks, longer at the quarters.
  graduated,

  /// The arc is drawn as discrete blocks rather than a continuous sweep, in
  /// the manner of a shift light. Coarser to read at a glance and far harder
  /// to misread by a few percent, which is the trade a driver wants.
  segmented,

  /// Graduated marks plus a numeral at every quarter, the way a mechanical
  /// dial is printed.
  numerals,
}

/// How the face behind the arc is treated.
enum GaugeFace {
  /// Nothing behind the arc. The tile's own surface shows through.
  flat,

  /// A slightly darker disc, so the instrument reads as recessed into the
  /// panel.
  recessed,

  /// A dial plate lighter than the panel, as a printed instrument face is.
  plate,
}

/// One instrument's shape and behaviour.
@immutable
class GaugeSkin extends ThemeExtension<GaugeSkin> {
  const GaugeSkin({
    required this.id,
    required this.name,
    required this.description,
    required this.startAngle,
    required this.sweepAngle,
    required this.trackFraction,
    required this.pointer,
    required this.ticks,
    required this.face,
    required this.valueDuration,
    required this.valueCurve,
    required this.readoutScale,
    required this.cornerRadius,
    required this.usesMonospaceReadout,
  });

  /// Stable across releases: this is what gets persisted.
  final String id;

  /// Shown in the picker.
  final String name;

  /// One line saying what it is *for*, not what it looks like.
  final String description;

  /// Where the scale begins, in radians, measured the way `Canvas.drawArc`
  /// does — zero at three o'clock, increasing clockwise.
  final double startAngle;

  /// How far it runs. A shallower sweep is easier to read at a glance and
  /// carries less precision; a longer one is the opposite.
  final double sweepAngle;

  /// Track thickness as a fraction of the dial radius.
  final double trackFraction;

  final GaugePointer pointer;
  final GaugeTicks ticks;
  final GaugeFace face;

  /// How long the reading takes to travel, and along what curve.
  ///
  /// Not decoration. A needle that eases into place is easier to read and
  /// lies for the length of the easing; telemetry that must not lie moves
  /// instantly and looks worse doing it. Each skin takes a side.
  final Duration valueDuration;
  final Curve valueCurve;

  /// Multiplier on the numeral in the middle. A skin that drops the needle
  /// can afford a bigger number, and needs one.
  final double readoutScale;

  /// Tile corner radius, in logical pixels.
  final double cornerRadius;

  /// Whether the readout uses the tabular face. Digits that do not shift
  /// sideways as the value changes are easier to read while moving; a skin
  /// imitating a printed dial wants the opposite.
  final bool usesMonospaceReadout;

  /// Whether this skin's value changes are worth animating at all.
  bool get animatesValue => valueDuration > Duration.zero;

  @override
  GaugeSkin copyWith({
    String? id,
    String? name,
    String? description,
    double? startAngle,
    double? sweepAngle,
    double? trackFraction,
    GaugePointer? pointer,
    GaugeTicks? ticks,
    GaugeFace? face,
    Duration? valueDuration,
    Curve? valueCurve,
    double? readoutScale,
    double? cornerRadius,
    bool? usesMonospaceReadout,
  }) =>
      GaugeSkin(
        id: id ?? this.id,
        name: name ?? this.name,
        description: description ?? this.description,
        startAngle: startAngle ?? this.startAngle,
        sweepAngle: sweepAngle ?? this.sweepAngle,
        trackFraction: trackFraction ?? this.trackFraction,
        pointer: pointer ?? this.pointer,
        ticks: ticks ?? this.ticks,
        face: face ?? this.face,
        valueDuration: valueDuration ?? this.valueDuration,
        valueCurve: valueCurve ?? this.valueCurve,
        readoutScale: readoutScale ?? this.readoutScale,
        cornerRadius: cornerRadius ?? this.cornerRadius,
        usesMonospaceReadout:
            usesMonospaceReadout ?? this.usesMonospaceReadout,
      );

  /// Interpolating between two *instruments* is not meaningful — halfway
  /// between a needle and no needle is not a thing to draw — so this snaps at
  /// the midpoint rather than producing a shape neither skin describes.
  ///
  /// The angles and widths could be tweened, and deliberately are not: a dial
  /// that morphs its geometry while the numbers keep updating is unreadable
  /// for the duration, on a screen somebody may be glancing at from a driving
  /// seat.
  @override
  GaugeSkin lerp(ThemeExtension<GaugeSkin>? other, double t) {
    if (other is! GaugeSkin) return this;
    return t < 0.5 ? this : other;
  }

  /// The default, and the one every existing screenshot was taken of: a
  /// 270° dial with a needle, recessed face and graduated ticks.
  static const cluster = GaugeSkin(
    id: 'cluster',
    name: '儀表艙',
    description: '車廠儀表板的樣子。指針、270 度刻度盤、凹陷的面盤。',
    startAngle: math.pi * 0.75,
    sweepAngle: math.pi * 1.5,
    trackFraction: 0.13,
    pointer: GaugePointer.needle,
    ticks: GaugeTicks.graduated,
    face: GaugeFace.recessed,
    valueDuration: Duration(milliseconds: 320),
    valueCurve: Curves.easeOutCubic,
    readoutScale: 1,
    cornerRadius: 18,
    usesMonospaceReadout: true,
  );

  /// Half an arc, no needle, no ticks, and a large numeral. For reading a
  /// number rather than watching a movement.
  static const minimal = GaugeSkin(
    id: 'minimal',
    name: '極簡',
    description: '半圓弧、沒有指針、沒有刻度。要看的是數字，不是動作。',
    startAngle: math.pi,
    sweepAngle: math.pi,
    trackFraction: 0.09,
    pointer: GaugePointer.none,
    ticks: GaugeTicks.none,
    face: GaugeFace.flat,
    valueDuration: Duration(milliseconds: 450),
    valueCurve: Curves.easeOutQuart,
    readoutScale: 1.28,
    cornerRadius: 24,
    usesMonospaceReadout: true,
  );

  /// Blocks rather than a sweep, a marker rather than a needle, and no
  /// easing at all.
  static const track = GaugeSkin(
    id: 'track',
    name: '賽道',
    description: '分段燈條、無平滑動畫。數值到哪就是哪，不做過渡。',
    startAngle: math.pi * 0.85,
    sweepAngle: math.pi * 1.3,
    trackFraction: 0.17,
    pointer: GaugePointer.marker,
    ticks: GaugeTicks.segmented,
    face: GaugeFace.flat,
    // Deliberately none. A racing instrument that eases is telling you where
    // the engine *was*; the whole point of it is that it is not doing that.
    valueDuration: Duration.zero,
    valueCurve: Curves.linear,
    readoutScale: 1.1,
    cornerRadius: 8,
    usesMonospaceReadout: true,
  );

  /// A printed dial: long sweep, numerals round the face, a slow needle that
  /// settles the way a mechanical one does.
  static const classic = GaugeSkin(
    id: 'classic',
    name: '經典',
    description: '印刷式面盤、整圈數字、指針像機械錶一樣慢慢定位。',
    startAngle: math.pi * 0.7,
    sweepAngle: math.pi * 1.6,
    trackFraction: 0.06,
    pointer: GaugePointer.needle,
    ticks: GaugeTicks.numerals,
    face: GaugeFace.plate,
    valueDuration: Duration(milliseconds: 700),
    // Overshoots slightly and settles, as a needle on a spring does.
    valueCurve: Curves.elasticOut,
    readoutScale: 0.85,
    cornerRadius: 999,
    usesMonospaceReadout: false,
  );

  /// A shallow arc low on the tile, for night driving: little lit area, no
  /// large bright surfaces, and no animation to catch the eye.
  static const night = GaugeSkin(
    id: 'night',
    name: '夜視',
    description: '夜間駕駛用。低亮度、淺弧、不做動畫，盡量不搶走注意力。',
    startAngle: math.pi * 1.1,
    sweepAngle: math.pi * 0.8,
    trackFraction: 0.07,
    pointer: GaugePointer.marker,
    ticks: GaugeTicks.none,
    face: GaugeFace.flat,
    valueDuration: Duration.zero,
    valueCurve: Curves.linear,
    readoutScale: 1.15,
    cornerRadius: 14,
    usesMonospaceReadout: true,
  );

  static const all = <GaugeSkin>[cluster, minimal, track, classic, night];

  static GaugeSkin byId(String? id) =>
      all.firstWhere((s) => s.id == id, orElse: () => cluster);
}

extension GaugeSkinContext on BuildContext {
  /// The instrument this app is currently drawing.
  ///
  /// Falls back to [GaugeSkin.cluster] rather than throwing: a widget rendered
  /// outside the app's theme — a test pumping a bare `MaterialApp`, a preview
  /// — should draw something reasonable rather than nothing.
  GaugeSkin get gaugeSkin =>
      Theme.of(this).extension<GaugeSkin>() ?? GaugeSkin.cluster;
}
