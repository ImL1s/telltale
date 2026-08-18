/// Circular instrument gauge.
///
/// Painted in two layers, which is the Flutter equivalent of the offscreen
/// bitmap cache the original app used: the bezel, ticks and endpoint labels
/// only change when size or theme changes, so they sit in their own
/// [RepaintBoundary] and are not re-rasterised on every telemetry sample. Only
/// the arc, needle and readout repaint at data rate.
///
/// Numbers are printed at the two arc endpoints only, never around the rim.
/// At the ~170px a dashboard tile actually gets, a full ring of tick numbers is
/// illegible *and* collides with the central readout; the scale's endpoints
/// plus evenly-spaced tick marks carry the same information and leave the
/// middle clear for the one number the driver is reading.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/gauge_skin.dart';
import '../../../core/theme/app_theme.dart';

/// A 270° sweep opening at the bottom — the layout every car instrument uses,
/// because it keeps the resting needle clear of the readout.
// The dial's geometry now comes from `GaugeSkin` on the theme. It was two
// constants here, which meant a "skin" could only ever have repainted the same
// instrument in another colour — and the request was for five instruments.

class DialGauge extends StatefulWidget {
  const DialGauge({
    required this.value,
    required this.minValue,
    required this.maxValue,
    required this.label,
    required this.units,
    this.hue = GaugeHue.aqua,
    this.redlineFrom,
    this.majorTicks = 7,
    this.minorPerMajor = 4,
    this.isStale = false,
    this.footnote,
    super.key,
  });

  /// The reading, or null when there is none.
  ///
  /// Null is not the same as zero. A gauge with no data must say so — showing
  /// `pid.minValue` puts a real-looking number on screen for a sensor that
  /// never answered.
  final double? value;

  final double minValue;
  final double maxValue;
  final String label;
  final String units;
  final GaugeHue hue;

  /// Value at which the redline arc begins. Null hides it.
  final double? redlineFrom;

  final int majorTicks;
  final int minorPerMajor;

  /// Dims the whole gauge when the reading is not fresh, so a frozen number is
  /// visibly frozen rather than quietly wrong.
  final bool isStale;

  /// Optional line under the readout, e.g. "推算值" for derived figures.
  final String? footnote;

  double get _span => (maxValue - minValue).abs() < 1e-9 ? 1 : maxValue - minValue;

  double get _fraction {
    final v = value;
    if (v == null || v.isNaN || v.isInfinite) return 0;
    return ((v - minValue) / _span).clamp(0.0, 1.0);
  }

  double? get _redlineFraction {
    final start = redlineFrom;
    if (start == null || start >= maxValue) return null;
    return ((start - minValue) / _span).clamp(0.0, 1.0);
  }

  @override
  State<DialGauge> createState() => _DialGaugeState();
}

class _DialGaugeState extends State<DialGauge>
    with SingleTickerProviderStateMixin {
  /// Drives the needle directly.
  ///
  /// This replaces a `TweenAnimationBuilder`, whose builder rebuilt the
  /// `CustomPaint` on every animation tick — allocating a painter, diffing an
  /// element and updating a render object 120 times a second, per gauge. The
  /// painter now listens to the animation itself through
  /// `CustomPainter(repaint:)`, which repaints without rebuilding anything.
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Motion.fast,
  );

  /// The instrument's own idea of how a reading should move.
  ///
  /// Read in `didUpdateWidget` rather than captured once, because the skin can
  /// change under a live dashboard and the next update must obey the new one.
  /// Two of the five skins ask for no animation at all — a racing instrument
  /// that eases is showing where the engine *was*, which is the one thing it
  /// exists not to do — so this can legitimately be zero.

  late Animation<double> _fraction =
      AlwaysStoppedAnimation<double>(widget._fraction);

  @override
  void didUpdateWidget(DialGauge oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = widget._fraction;
    if (target == _fraction.value) return;
    // Start from wherever the needle currently is, not from the previous
    // target, so a value changing mid-sweep continues rather than jumping.
    final skin = context.gaugeSkin;
    if (!skin.animatesValue) {
      // Snapped, and the controller left alone. Driving a zero-duration
      // controller still schedules a frame per change and still leaves the
      // painter subscribed to a `Listenable` that will never move.
      setState(() => _fraction = AlwaysStoppedAnimation<double>(target));
      return;
    }
    _controller.duration = skin.valueDuration;
    _fraction = Tween<double>(begin: _fraction.value, end: target)
        .chain(CurveTween(curve: skin.valueCurve))
        .animate(_controller);
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final skin = context.gaugeSkin;
    final colors = context.gaugeColors(widget.hue);
    final v = widget.value;
    final inRedline = widget.redlineFrom != null &&
        v != null &&
        !v.isNaN &&
        v >= widget.redlineFrom!;

    return LayoutBuilder(
      builder: (context, constraints) {
        final size = math.min(constraints.maxWidth, constraints.maxHeight);
        if (size <= 0) return const SizedBox.shrink();

        // A custom-painted gauge is invisible to a screen reader: there is no
        // text in it, only a canvas. Without this, TalkBack reads a blank tile
        // — no name, no value — which makes the whole dashboard unusable.
        return Semantics(
          container: true,
          // The painted dial is invisible to a screen reader, so this node
          // supplies the whole reading — which means the readout's own Text
          // widgets would otherwise be announced a second time, as a bare
          // number after a sentence that already contained it.
          excludeSemantics: true,
          label: widget.label,
          // The *reason* has to be spoken, not only drawn. The footnote says
          // 公式錯誤 or 匯流排錯誤 or 無回應，稍後重試 on screen, and with
          // `excludeSemantics` a screen reader heard "無資料" for all three —
          // a formula the user can fix, a bus fault they cannot, and a sensor
          // that will be retried, all announced identically.
          //
          // A stale reading keeps both: the number is real and its age is the
          // qualification. A gauge with no value at all leads with the reason,
          // because that is the whole of what there is to say.
          value: widget.value == null
              ? (widget.footnote?.isNotEmpty ?? false
                  ? '無資料 — ${widget.footnote}'
                  : '無資料')
              : '${_semanticValue(widget.value!)}${widget.units.isEmpty ? '' : ' ${widget.units}'}'
                  '${widget.isStale ? '（資料已過期）' : ''}'
                  '${(widget.footnote?.isNotEmpty ?? false) ? ' — ${widget.footnote}' : ''}',
          child: SizedBox.square(
            dimension: size,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Opacity wraps the *painted* layers only.
                //
                // It used to wrap the whole stack, readout included, and at any
                // opacity low enough to read as "dimmed" the small text went
                // under the legibility floor: at 0.62 the units and label
                // tokens measure 2.4–3.5:1 against their panel, where 4.5:1 is
                // the minimum. Pushing the opacity up until they passed would
                // have removed the signal entirely.
                //
                // So the dial fades and the numbers do not. The signal is
                // carried by the arc, the needle and the footnote text — never
                // by contrast alone, which excludes anyone who cannot perceive
                // the difference.
                Opacity(
                  opacity: _decorationOpacity,
                  child: RepaintBoundary(
                  child: CustomPaint(
                    size: Size.square(size),
                    painter: _GaugeChromePainter(
                      palette: palette,
                      skin: skin,
                      colors: colors,
                      majorTicks: widget.majorTicks,
                      minorPerMajor: widget.minorPerMajor,
                      redlineFraction: widget._redlineFraction,
                      minValue: widget.minValue,
                      maxValue: widget.maxValue,
                    ),
                  ),
                  ),
                ),
                // Its own boundary. Without one, repainting the needle marks
                // the nearest enclosing layer dirty — and since the dashboard
                // lays tiles out with Column/Row/Wrap rather than a
                // GridView.builder, which would add per-child boundaries
                // automatically, that layer holds every other gauge's dynamic
                // layer, six readouts and the panel chrome. One widget.value changing
                // re-rasterised all of it.
                Opacity(
                  opacity: _decorationOpacity,
                  child: RepaintBoundary(
                    child: CustomPaint(
                      size: Size.square(size),
                      painter: _GaugeValuePainter(
                        animation: _fraction,
                        palette: palette,
                        skin: skin,
                        colors: colors,
                        inRedline: inRedline,
                      ),
                    ),
                  ),
                ),
                // Endpoint scale labels sit in the arc's opening at the bottom,
                // where nothing else competes for the space.
                _EndpointLabels(
                  minValue: widget.minValue,
                  maxValue: widget.maxValue,
                  diameter: size,
                ),
                _GaugeReadout(
                  value: widget.value,
                  units: widget.units,
                  label: widget.label,
                  // With the numbers no longer dimmed, the words carry the
                  // signal — and they carry it for people the fading dial
                  // does not reach either.
                  footnote: widget.isStale && widget.footnote == null
                      ? '資料已過期'
                      : widget.footnote,
                  diameter: size,
                  inRedline: inRedline,
                  colors: colors,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// How far the painted layers fade when the value is stale or absent.
  ///
  /// Lower than the text could survive, which is the point of separating them:
  /// the dial can fade far enough to be unmistakable because nothing has to be
  /// read off it.
  double get _decorationOpacity =>
      (widget.isStale || widget.value == null) ? kStaleDecorationOpacity : 1;

  /// The reading as a screen reader should say it, at the same precision the
  /// readout shows.
  ///
  /// Through the same function the readout uses, because the sentence above
  /// used to be a claim rather than a fact: this had its own copy of a
  /// different rule, so a lambda of 0.85 was printed as 0.9 and read aloud as
  /// 0.85. Two of this app's users hearing different numbers off one dial is
  /// the same defect as two parts of a screen disagreeing, arriving somewhere
  /// nobody looks.
  String _semanticValue(double v) => formatGaugeReadout(v);
}

/// The number a dial prints, and says.
///
/// Coarser than `Reading.formatted`, which is a separate decision rather than
/// drift: a list read at rest can afford two decimals below ten, and a dial
/// glanced at from a driving seat is easier to read with one. What must not
/// differ is what this dial shows and what it announces.
String formatGaugeReadout(double value) {
  if (value.isNaN || value.isInfinite) return '--';
  return value.toStringAsFixed(value.abs() >= 100 ? 0 : 1);
}

String _formatBound(double value, double span) {
  if (span >= 100) return value.round().toString();
  if (span >= 10) return value.toStringAsFixed(0);
  return value.toStringAsFixed(1);
}

class _EndpointLabels extends StatelessWidget {
  const _EndpointLabels({
    required this.minValue,
    required this.maxValue,
    required this.diameter,
  });

  final double minValue;
  final double maxValue;
  final double diameter;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final span = (maxValue - minValue).abs();
    // Deliberately the display face, not the mono one: JetBrains Mono's dotted
    // zero is unreadable at the ~9px these labels get and reads as a 6 or an 8.
    final style = TextStyle(
      fontFamily: AppTypography.display,
      fontSize: math.max(9, diameter * 0.056),
      fontWeight: FontWeight.w600,
      height: 1,
      color: palette.textTertiary,
      fontFeatures: AppTypography.tabular,
    );

    // The arc ends at 135° and 45° from centre; place the labels just inside
    // those two points.
    final inset = diameter * 0.135;
    return Padding(
      padding: EdgeInsets.only(
        left: inset,
        right: inset,
        bottom: diameter * 0.035,
      ),
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(_formatBound(minValue, span), style: style),
            Text(_formatBound(maxValue, span), style: style),
          ],
        ),
      ),
    );
  }
}

class _GaugeReadout extends StatelessWidget {
  const _GaugeReadout({
    required this.value,
    required this.units,
    required this.label,
    required this.footnote,
    required this.diameter,
    required this.inRedline,
    required this.colors,
  });

  final double? value;
  final String units;
  final String label;
  final String? footnote;
  final double diameter;
  final bool inRedline;
  final GaugeColors colors;

  String get _formatted {
    final v = value;
    if (v == null) return '--';
    return formatGaugeReadout(v);
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    // Everything lives inside the circle the ticks leave free. A square
    // inscribed in a circle of radius r has side r·√2, so 0.62 × diameter is
    // comfortably clear of the innermost tick.
    final inner = diameter * 0.62;

    return SizedBox.square(
      dimension: inner,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Flexible(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label.toUpperCase(),
                maxLines: 1,
                style: context.texts.labelSmall?.copyWith(
                  fontSize: math.max(8.5, diameter * 0.056),
                  color: palette.textTertiary,
                ),
              ),
            ),
          ),
          SizedBox(height: diameter * 0.012),
          Flexible(
            flex: 3,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                _formatted,
                maxLines: 1,
                style: AppTypography.readout(palette, diameter * 0.20).copyWith(
                  color: inRedline ? palette.danger : palette.textPrimary,
                ),
              ),
            ),
          ),
          if (units.isNotEmpty) ...[
            SizedBox(height: diameter * 0.008),
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  units,
                  maxLines: 1,
                  style: context.texts.labelMedium?.copyWith(
                    fontSize: math.max(9, diameter * 0.062),
                    color: inRedline ? palette.danger : colors.bright,
                  ),
                ),
              ),
            ),
          ],
          if (footnote != null)
            Flexible(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  footnote!,
                  maxLines: 1,
                  style: context.texts.labelSmall?.copyWith(
                    fontSize: math.max(8, diameter * 0.048),
                    color: palette.derived,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Face, track, redline zone and tick marks.
/// What to fill the dial face with, or null to leave the tile showing through.
///
/// Extracted so it can be held to something. The painter drew the recessed
/// disc unconditionally for a whole release — `GaugeFace` was declared on the
/// skin, passed down and never read, so three skins got a treatment they
/// explicitly refuse and `classic` never got its plate — and no test went red,
/// because a painter's output is not something a unit test can see. A `Paint`
/// is.
@visibleForTesting
Paint? faceFillFor(
  GaugeFace face, {
  required AppPalette palette,
  required GaugeColors colors,
  required Offset centre,
  required double radius,
  required double arcRadius,
}) {
  switch (face) {
    case GaugeFace.recessed:
      // A barely-there radial lift so the dial reads as a recessed face rather
      // than a hole cut in the card.
      return Paint()
        ..shader = ui.Gradient.radial(
          centre.translate(0, -radius * 0.2),
          arcRadius,
          [
            Color.alphaBlend(
                colors.dim.withValues(alpha: 0.18), palette.surface),
            palette.surface,
          ],
        );
    case GaugeFace.plate:
      // A printed dial plate sits *above* the panel it is mounted on, so it is
      // lighter than the card rather than darker. Flat, because a printed face
      // has no depth of its own — the numerals do the work.
      return Paint()..color = palette.surfaceHigh;
    case GaugeFace.flat:
      // Nothing. The tile's own surface shows through, which is the whole
      // point of the skins that ask for it: no disc, no edge, no second shape
      // competing with the arc.
      return null;
  }
}

/// Paints the static layer onto [canvas], for a test that needs real pixels.
///
/// The face rule lives in `faceFillFor`, which is pure and testable — and a
/// pure function nobody calls is still a rule nobody enforces. Commenting out
/// the `drawCircle` below left every face test green while every gauge in the
/// app lost its face, which is the gap this seam closes: pixels are the only
/// thing that can say whether a canvas was drawn on.
@visibleForTesting
void paintGaugeChromeForTest(
  Canvas canvas,
  Size size, {
  required AppPalette palette,
  required GaugeSkin skin,
  required GaugeColors colors,
  int majorTicks = 7,
  int minorPerMajor = 4,
  double minValue = 0,
  double maxValue = 100,
}) {
  _GaugeChromePainter(
    palette: palette,
    skin: skin,
    colors: colors,
    majorTicks: majorTicks,
    minorPerMajor: minorPerMajor,
    redlineFraction: null,
    minValue: minValue,
    maxValue: maxValue,
  ).paint(canvas, size);
}

class _GaugeChromePainter extends CustomPainter {
  _GaugeChromePainter({
    required this.palette,
    required this.skin,
    required this.colors,
    required this.majorTicks,
    required this.minorPerMajor,
    required this.redlineFraction,
    required this.minValue,
    required this.maxValue,
  });

  final AppPalette palette;

  /// The instrument being drawn — arc geometry, tick style, face treatment.
  /// Everything that used to be a file-level constant lives here, because a
  /// skin that could only change colour would not be a different instrument.
  final GaugeSkin skin;
  final GaugeColors colors;
  final int majorTicks;
  final int minorPerMajor;
  final double? redlineFraction;

  /// The span the numerals count across. Only [GaugeTicks.numerals] uses them,
  /// and without them that style could not exist — which is why it did not:
  /// the case was declared, the picker promised 整圈數字, and `_paintTicks`
  /// fell through to `graduated` because the painter had no idea what numbers
  /// to draw. Same shape as the face treatment that was declared and never
  /// painted.
  final double minValue;
  final double maxValue;

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final radius = size.width / 2;
    final strokeWidth = radius * skin.trackFraction;
    final arcRadius = radius - strokeWidth / 2 - radius * 0.02;
    final rect = Rect.fromCircle(center: centre, radius: arcRadius);

    // The face, which is one of the things that makes these five different
    // instruments rather than one instrument in five colours.
    //
    // This was drawing the recessed disc unconditionally — `GaugeFace` was
    // declared on the skin, passed down here, and never read, so `minimal`,
    // `track` and `night` all got a treatment they explicitly do not ask for
    // and `classic` never got its plate. The commit that introduced the skins
    // claimed a per-skin face treatment it had not implemented; a reviewer
    // found it by reading the painter against the message.
    final facePaint = faceFillFor(
      skin.face,
      palette: palette,
      colors: colors,
      centre: centre,
      radius: radius,
      arcRadius: arcRadius,
    );
    if (facePaint != null) {
      canvas.drawCircle(centre, arcRadius - strokeWidth * 0.5, facePaint);
    }

    canvas.drawArc(
      rect,
      skin.startAngle,
      skin.sweepAngle,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..color = palette.gaugeTrack,
    );

    final redline = redlineFraction;
    if (redline != null) {
      canvas.drawArc(
        rect,
        skin.startAngle + skin.sweepAngle * redline,
        skin.sweepAngle * (1 - redline),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round
          ..color = palette.danger.withValues(alpha: 0.28),
      );
    }

    _paintTicks(canvas, centre, arcRadius, strokeWidth);
  }

  void _paintTicks(Canvas canvas, Offset centre, double arcRadius, double strokeWidth) {
    // Ticks live just inside the track, and are short: they are texture that
    // tells you where you are on the sweep, not a readable scale.
    final tickOuter = arcRadius - strokeWidth * 0.78;
    final majorPaint = Paint()
      ..color = palette.textTertiary.withValues(alpha: 0.85)
      ..strokeWidth = math.max(1.3, arcRadius * 0.016)
      ..strokeCap = StrokeCap.round;
    final minorPaint = Paint()
      ..color = palette.textTertiary.withValues(alpha: 0.32)
      ..strokeWidth = math.max(0.9, arcRadius * 0.008)
      ..strokeCap = StrokeCap.round;

    // A skin that prints no scale prints no scale. `minimal` and `night` both
    // rely on the numeral and the filled arc alone, and drawing marks they did
    // not ask for is how five instruments collapse back into one.
    if (skin.ticks == GaugeTicks.none || skin.ticks == GaugeTicks.segmented) {
      return;
    }
    final numbered = skin.ticks == GaugeTicks.numerals;
    final totalSteps = (majorTicks - 1) * minorPerMajor;
    if (totalSteps <= 0) return;

    for (var step = 0; step <= totalSteps; step++) {
      final fraction = step / totalSteps;
      final angle = skin.startAngle + skin.sweepAngle * fraction;
      final isMajor = step % minorPerMajor == 0;
      final length = isMajor ? arcRadius * 0.085 : arcRadius * 0.042;

      final direction = Offset(math.cos(angle), math.sin(angle));
      if (numbered && isMajor) {
        _paintNumeral(canvas, centre, arcRadius, direction, fraction);
      }
      canvas.drawLine(
        centre + direction * (tickOuter - length),
        centre + direction * tickOuter,
        isMajor ? majorPaint : minorPaint,
      );
    }
  }

  /// The value at a major tick, printed inside the scale.
  ///
  /// What makes `GaugeTicks.numerals` a different instrument rather than a
  /// relabelled one: a printed dial is read by its numbers, and the classic
  /// skin's own description says so. Placed inside the ticks, upright rather
  /// than rotated — a rotated numeral is authentic to a real gauge and
  /// unreadable at a glance, which is the opposite of what this screen is for.
  void _paintNumeral(
    Canvas canvas,
    Offset centre,
    double arcRadius,
    Offset direction,
    double fraction,
  ) {
    final value = minValue + (maxValue - minValue) * fraction;
    final span = (maxValue - minValue).abs();
    final text = span >= 100 || value == value.roundToDouble()
        ? value.round().toString()
        : value.toStringAsFixed(1);
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: palette.textTertiary,
          fontSize: math.max(8, arcRadius * 0.115),
          fontWeight: FontWeight.w500,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // Just inside the ticks, not half way to the middle. At 0.70 the numerals
    // crowded the value in the centre — on the coolant dial `3` and `88` sat
    // against the reading itself — and this is a face somebody glances at from
    // a driving seat, where a busy centre costs more than an empty rim.
    final at = centre + direction * (arcRadius * 0.775);
    painter.paint(
      canvas,
      at - Offset(painter.width / 2, painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(_GaugeChromePainter old) =>
      old.palette != palette ||
      // Without this the dial keeps the previous instrument's geometry until
      // something else happens to dirty it — the arc, the ticks and the face
      // all come from here now.
      old.skin != skin ||
      old.colors != colors ||
      old.majorTicks != majorTicks ||
      old.minorPerMajor != minorPerMajor ||
      old.redlineFraction != redlineFraction;
}

/// Value arc and needle — the only layer that repaints at telemetry rate.
class _GaugeValuePainter extends CustomPainter {
  _GaugeValuePainter({
    required this.animation,
    required this.palette,
    required this.skin,
    required this.colors,
    required this.inRedline,
  }) : super(repaint: animation);

  final GaugeSkin skin;

  /// Repainting is driven by the animation itself.
  ///
  /// `super(repaint:)` subscribes the painter to the `Listenable`, so each tick
  /// schedules a paint and nothing above it rebuilds. The previous arrangement
  /// ran the animation through a builder, which reconstructed the `CustomPaint`
  /// widget, allocated a new painter and re-diffed the element on every frame —
  /// 120 times a second, per gauge.
  final Animation<double> animation;

  double get fraction => animation.value;

  final AppPalette palette;
  final GaugeColors colors;
  final bool inRedline;

  /// The sweep gradient, kept between frames.
  ///
  /// `ui.Gradient.sweep` allocates a native shader. Building it inside `paint`
  /// meant one allocation per gauge per frame — around 720 a second across a
  /// six-gauge dashboard — for an object whose inputs only change when the
  /// theme or the redline state does.
  ui.Shader? _shader;
  Size? _shaderSize;

  ui.Shader _sweepShader(Offset centre, Size size) {
    final cached = _shader;
    if (cached != null && _shaderSize == size) return cached;
    _shaderSize = size;
    return _shader = ui.Gradient.sweep(
      centre,
      [colors.dim, colors.bright, inRedline ? palette.danger : colors.bright],
      const [0.0, 0.70, 1.0],
      TileMode.clamp,
      skin.startAngle,
      skin.startAngle + skin.sweepAngle,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final centre = size.center(Offset.zero);
    final radius = size.width / 2;
    final strokeWidth = radius * skin.trackFraction;
    final arcRadius = radius - strokeWidth / 2 - radius * 0.02;
    final rect = Rect.fromCircle(center: centre, radius: arcRadius);

    if (fraction > 0.0005 && skin.ticks == GaugeTicks.segmented) {
      _paintSegments(canvas, rect, strokeWidth, size, centre);
    } else if (fraction > 0.0005) {
      final sweep = skin.sweepAngle * fraction;

      // The gradient runs along the arc, so the lit portion brightens as the
      // value climbs rather than being a flat band of colour.
      final shader = _sweepShader(centre, size);

      // The glow was a `MaskFilter.blur`, which forces an offscreen render
      // target and a convolution — the most expensive thing a tile-based mobile
      // GPU does, and there were two per gauge, so twelve per frame across the
      // dashboard. Two progressively wider translucent strokes read the same at
      // this size and stay on the same render pass.
      for (final layer in _glowLayers) {
        canvas.drawArc(
          rect,
          skin.startAngle,
          sweep,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = strokeWidth * layer.$1
            ..strokeCap = StrokeCap.round
            ..shader = shader
            ..color = const Color(0xFFFFFFFF).withValues(alpha: layer.$2)
            ..blendMode = BlendMode.plus,
        );
      }

      canvas.drawArc(
        rect,
        skin.startAngle,
        sweep,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round
          ..shader = shader,
      );
    }

    // Three of the five skins want no pointer at all, or want one drawn as
    // part of the scale rather than over it. `minimal` reads from the filled
    // arc and the numeral; a pointer there would be a third thing saying the
    // same thing.
    if (skin.pointer != GaugePointer.none) {
      _paintNeedle(canvas, centre, arcRadius, strokeWidth, radius);
    }
    // The hub belongs to a needle radiating from the centre. A marker riding
    // the track has nothing to be anchored to, and a disc in the middle of an
    // otherwise empty dial reads as a component that failed to draw.
    if (skin.pointer == GaugePointer.needle) {
      _paintHub(canvas, centre, radius);
    }
  }

  /// The arc as discrete blocks, in the manner of a shift light.
  ///
  /// Coarser than a continuous sweep on purpose. A driver glancing down reads
  /// "seven of twelve" faster and far more reliably than a length, and cannot
  /// misjudge it by a few percent — which is the trade a racing instrument
  /// makes and a diagnostic dial does not.
  void _paintSegments(
    Canvas canvas,
    Rect rect,
    double strokeWidth,
    Size size,
    Offset centre,
  ) {
    const count = 14;
    const gap = 0.16; // of one segment's angular width
    final step = skin.sweepAngle / count;
    final lit = (fraction * count).ceil().clamp(0, count);
    final shader = _sweepShader(centre, size);
    for (var i = 0; i < lit; i++) {
      canvas.drawArc(
        rect,
        skin.startAngle + step * (i + gap / 2),
        step * (1 - gap),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.butt
          ..shader = shader,
      );
    }
  }

  /// A thin bright bar crossing the track at the current value, rather than a
  /// pointer radiating from the centre.
  ///
  /// A classic needle sweeping from the hub would cut straight through the
  /// readout, and a wedge thick enough to be visible at tile size reads as a
  /// blob. A crisp perpendicular marker states the position more precisely,
  /// costs almost no pixels, and leaves the middle of the dial clean.
  void _paintNeedle(
    Canvas canvas,
    Offset centre,
    double arcRadius,
    double strokeWidth,
    double radius,
  ) {
    final angle = skin.startAngle + skin.sweepAngle * fraction;
    final direction = Offset(math.cos(angle), math.sin(angle));

    final inner = arcRadius - strokeWidth * 0.66;
    final outer = arcRadius + strokeWidth * 0.66;
    final start = centre + direction * inner;
    final end = centre + direction * outer;

    final needleColour = inRedline ? palette.danger : palette.textPrimary;
    final width = math.max(2.0, radius * 0.026);

    // Same substitution as the arc: two widening translucent passes instead of
    // an offscreen blur.
    canvas.drawLine(
      start,
      end,
      Paint()
        ..strokeWidth = width * 3.0
        ..strokeCap = StrokeCap.round
        ..color = needleColour.withValues(alpha: 0.14),
    );
    canvas.drawLine(
      start,
      end,
      Paint()
        ..strokeWidth = width * 1.9
        ..strokeCap = StrokeCap.round
        ..color = needleColour.withValues(alpha: 0.30),
    );
    canvas.drawLine(
      start,
      end,
      Paint()
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..color = needleColour,
    );
  }

  void _paintHub(Canvas canvas, Offset centre, double radius) {
    // A thin ring rather than a filled cap: at tile size a solid hub would sit
    // on top of the readout's first digit.
    canvas.drawCircle(
      centre,
      radius * 0.70,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.8, radius * 0.006)
        ..color = palette.hairline.withValues(alpha: 0.7),
    );
  }

  /// Widths and opacities of the glow passes, as multiples of the arc stroke.
  static const List<(double, double)> _glowLayers = [
    (2.05, 0.05),
    (1.5, 0.09),
  ];

  @override
  bool shouldRepaint(_GaugeValuePainter old) =>
      // The animation drives repaints through `super(repaint:)`, so this only
      // has to answer for the things that change when the widget rebuilds.
      old.animation != animation ||
      old.palette != palette ||
      old.skin != skin ||
      old.colors != colors ||
      old.inRedline != inRedline;
}
