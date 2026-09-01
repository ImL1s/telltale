library;

import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../obd/pid/pid.dart';
import '../../../state/telemetry_trends.dart';
import '../../../telemetry/session/timeline_downsampler.dart';
import '../../widgets/panel.dart';
import 'telemetry_status_copy.dart';

class LiveTrendCard extends StatelessWidget {
  const LiveTrendCard({
    required this.lane,
    required this.windowEndElapsedUs,
    required this.recordingLabel,
    this.isConnected = true,
    super.key,
  });

  final TelemetryTrendLane lane;
  final int windowEndElapsedUs;
  final String recordingLabel;
  final bool isConnected;

  @override
  Widget build(BuildContext context) {
    final pid = lane.pid;
    final accent = context.gaugeColors(GaugeHue.forKey(pid.id)).bright;
    final status = isConnected ? lane.currentStatus : null;
    final value = isConnected ? lane.currentValue : null;
    final valueLabel = value == null ? '--' : _formatValue(value);
    final availability = !isConnected
        ? '目前未連線'
        : status == null
        ? '即時資料'
        : telemetryStatusLabel(status);
    final semantics = [
      _signalName(pid),
      value == null
          ? availability
          : pid.units.isEmpty
          ? valueLabel
          : '$valueLabel ${pid.units}',
      recordingLabel,
      '顯示最近 60 秒趨勢',
    ].join('，');

    return Semantics(
      container: true,
      label: semantics,
      child: Panel(
        accent: accent,
        padding: const EdgeInsets.all(Spacing.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.end,
              spacing: Spacing.md,
              runSpacing: Spacing.sm,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 280),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_signalName(pid), style: context.texts.titleMedium),
                      const SizedBox(height: 2),
                      Text(
                        availability,
                        style: context.texts.bodySmall?.copyWith(
                          color: status == null && isConnected
                              ? context.palette.textSecondary
                              : context.palette.warning,
                        ),
                      ),
                    ],
                  ),
                ),
                ExcludeSemantics(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        valueLabel,
                        style: AppTypography.readout(context.palette, 30)
                            .copyWith(
                              color: value == null
                                  ? context.palette.textTertiary
                                  : accent,
                            ),
                      ),
                      Text(
                        pid.units.isEmpty ? '無單位' : pid.units,
                        style: context.texts.labelSmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: Spacing.md),
            ExcludeSemantics(
              child: SizedBox(
                height: 176,
                child: _TrendChart(
                  lane: lane,
                  windowEndElapsedUs: windowEndElapsedUs,
                  accent: accent,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _signalName(Pid pid) =>
      pid.shortName.isEmpty ? pid.name : pid.shortName;

  static String _formatValue(double value) {
    final magnitude = value.abs();
    final decimals = switch (magnitude) {
      >= 1000 => 0,
      >= 100 => value == value.roundToDouble() ? 0 : 1,
      >= 10 => 1,
      _ => 2,
    };
    return value.toStringAsFixed(decimals);
  }
}

class _TrendChart extends StatelessWidget {
  const _TrendChart({
    required this.lane,
    required this.windowEndElapsedUs,
    required this.accent,
  });

  final TelemetryTrendLane lane;
  final int windowEndElapsedUs;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final segments = _segments();
    final allValues = segments
        .expand((segment) => segment)
        .map((spot) => spot.y)
        .toList();
    final bounds = _bounds(allValues, lane.pid);
    final markers = lane.primitives
        .where(
          (primitive) =>
              primitive is TimelineGap || primitive is TimelineStatus,
        )
        .map(
          (primitive) => VerticalLine(
            x: _x(primitive.elapsedUs),
            color: primitive is TimelineGap
                ? context.palette.warning.withValues(alpha: 0.55)
                : context.palette.danger.withValues(alpha: 0.38),
            strokeWidth: primitive is TimelineGap ? 2 : 1,
            dashArray: const [4, 4],
          ),
        )
        .toList(growable: false);

    return LineChart(
      LineChartData(
        minX: -60,
        maxX: 0,
        minY: bounds.$1,
        maxY: bounds.$2,
        clipData: const FlClipData.all(),
        lineTouchData: const LineTouchData(enabled: false),
        extraLinesData: ExtraLinesData(verticalLines: markers),
        gridData: FlGridData(
          drawVerticalLine: true,
          verticalInterval: 30,
          horizontalInterval: (bounds.$2 - bounds.$1) / 2,
          getDrawingHorizontalLine: (_) =>
              FlLine(color: context.palette.hairline, strokeWidth: 1),
          getDrawingVerticalLine: (_) =>
              FlLine(color: context.palette.hairline, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 44,
              interval: (bounds.$2 - bounds.$1) / 2,
              getTitlesWidget: (value, meta) {
                if ((value - bounds.$1).abs() > 0.001 &&
                    (value - bounds.$2).abs() > 0.001) {
                  return const SizedBox.shrink();
                }
                return Text(_axisValue(value), style: context.texts.labelSmall);
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              interval: 30,
              getTitlesWidget: (value, meta) => Text(
                value == 0 ? '現在' : '${value.round()}s',
                style: context.texts.labelSmall,
              ),
            ),
          ),
        ),
        lineBarsData: [
          for (final segment in segments)
            if (segment.isNotEmpty)
              LineChartBarData(
                spots: segment,
                isCurved: false,
                barWidth: 2.5,
                color: accent,
                isStrokeCapRound: true,
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(show: false),
              ),
        ],
      ),
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : Motion.fast,
      curve: Motion.standard,
    );
  }

  List<List<FlSpot>> _segments() {
    final result = <List<FlSpot>>[];
    var current = <FlSpot>[];
    void close() {
      if (current.isNotEmpty) result.add(current);
      current = <FlSpot>[];
    }

    for (final primitive in lane.primitives) {
      switch (primitive) {
        case TimelineValue(:final elapsedUs, :final value, :final breakBefore):
          if (breakBefore) close();
          current.add(FlSpot(_x(elapsedUs), value));
        case TimelineGap():
        case TimelineStatus():
          close();
      }
    }
    close();
    return result;
  }

  double _x(int elapsedUs) =>
      (elapsedUs - windowEndElapsedUs) / Duration.microsecondsPerSecond;

  static (double, double) _bounds(List<double> values, Pid pid) {
    if (values.isEmpty) {
      final min = pid.minValue.isFinite ? pid.minValue : 0.0;
      final max = pid.maxValue.isFinite && pid.maxValue > min
          ? pid.maxValue
          : min + 1;
      return (min, max);
    }
    var min = values.reduce(math.min);
    var max = values.reduce(math.max);
    if ((max - min).abs() < 1e-9) {
      final padding = math.max(1.0, max.abs() * 0.08);
      min -= padding;
      max += padding;
      return (min, max);
    }
    final padding = (max - min) * 0.08;
    return (min - padding, max + padding);
  }

  static String _axisValue(double value) {
    final magnitude = value.abs();
    return value.toStringAsFixed(
      magnitude >= 100
          ? 0
          : magnitude >= 10
          ? 1
          : 2,
    );
  }
}
