/// Horizontal bar gauge — the compact form used where a dial would waste space
/// (secondary signals, list rows, the PID editor preview).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';

class LinearGauge extends StatelessWidget {
  const LinearGauge({
    required this.value,
    required this.minValue,
    required this.maxValue,
    required this.label,
    required this.units,
    this.hue = GaugeHue.aqua,
    this.redlineFrom,
    this.isStale = false,
    this.showBounds = true,
    super.key,
  });

  final double value;
  final double minValue;
  final double maxValue;
  final String label;
  final String units;
  final GaugeHue hue;
  final double? redlineFrom;
  final bool isStale;

  /// Shows the min/max endpoints beneath the bar. Off in dense lists.
  final bool showBounds;

  double get _span => (maxValue - minValue).abs() < 1e-9 ? 1 : maxValue - minValue;

  double get _fraction => ((value - minValue) / _span).clamp(0.0, 1.0);

  bool get _inRedline => redlineFrom != null && value >= redlineFrom!;

  String get _formatted {
    if (value.isNaN || value.isInfinite) return '--';
    final magnitude = value.abs();
    return value.toStringAsFixed(magnitude >= 100 ? 0 : (magnitude >= 10 ? 1 : 2));
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final colors = context.gaugeColors(hue);
    return Opacity(
      opacity: isStale ? kStaleOpacity : 1,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.titleSmall?.copyWith(color: palette.textSecondary),
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Text(
                _formatted,
                style: AppTypography.readout(palette, 19).copyWith(
                  color: _inRedline ? palette.danger : palette.textPrimary,
                ),
              ),
              if (units.isNotEmpty) ...[
                const SizedBox(width: 3),
                Text(
                  units,
                  style: context.texts.labelMedium?.copyWith(color: palette.textTertiary),
                ),
              ],
            ],
          ),
          const SizedBox(height: Spacing.sm),
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: _fraction),
            duration: Motion.fast,
            curve: Motion.standard,
            builder: (context, animated, _) => CustomPaint(
              size: const Size(double.infinity, 8),
              painter: _LinearGaugePainter(
                fraction: animated,
                redlineFraction: redlineFrom == null
                    ? null
                    : ((redlineFrom! - minValue) / _span).clamp(0.0, 1.0),
                palette: palette,
                colors: colors,
                inRedline: _inRedline,
              ),
            ),
          ),
          if (showBounds) ...[
            const SizedBox(height: Spacing.xs),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(_bound(minValue), style: context.texts.labelSmall),
                Text(_bound(maxValue), style: context.texts.labelSmall),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _bound(double v) => _span >= 20 ? v.round().toString() : v.toStringAsFixed(1);
}

class _LinearGaugePainter extends CustomPainter {
  _LinearGaugePainter({
    required this.fraction,
    required this.redlineFraction,
    required this.palette,
    required this.colors,
    required this.inRedline,
  });

  final double fraction;
  final double? redlineFraction;
  final AppPalette palette;
  final GaugeColors colors;
  final bool inRedline;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = Radius.circular(size.height / 2);
    final track = RRect.fromRectAndRadius(Offset.zero & size, radius);
    canvas.drawRRect(track, Paint()..color = palette.gaugeTrack);

    final redline = redlineFraction;
    if (redline != null && redline < 1) {
      final start = size.width * redline;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(start, 0, size.width - start, size.height),
          radius,
        ),
        Paint()..color = palette.danger.withValues(alpha: 0.22),
      );
    }

    if (fraction <= 0) return;
    // Always paint at least a rounded stub so a zero-ish value still shows the
    // bar's colour identity rather than vanishing.
    final width = math.max(size.height, size.width * fraction);
    final fill = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, 0, width, size.height),
      radius,
    );

    canvas.drawRRect(
      fill,
      Paint()
        ..shader = LinearGradient(
          colors: [colors.dim, inRedline ? palette.danger : colors.bright],
        ).createShader(Rect.fromLTWH(0, 0, width, size.height))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    canvas.drawRRect(
      fill,
      Paint()
        ..shader = LinearGradient(
          colors: [colors.dim, inRedline ? palette.danger : colors.bright],
        ).createShader(Rect.fromLTWH(0, 0, width, size.height)),
    );
  }

  @override
  bool shouldRepaint(_LinearGaugePainter old) =>
      old.fraction != fraction ||
      old.redlineFraction != redlineFraction ||
      old.palette != palette ||
      old.colors != colors ||
      old.inRedline != inRedline;
}
