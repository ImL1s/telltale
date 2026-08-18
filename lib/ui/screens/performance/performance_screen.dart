/// Acceleration timing.
///
/// Times a run from a standing start to a target speed using OBD road speed.
/// The timer arms itself when the car is stationary and starts on first
/// movement, because a driver cannot press a button and launch at once.
library;

import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../obd/pid/pid_library.dart';
import '../../../obd/telemetry.dart';
import '../../../state/obd_session.dart';
import '../../widgets/gauges/dial_gauge.dart';
import '../../widgets/panel.dart';

enum RunState {
  idle,

  /// Armed, but the vehicle is still moving. Timing cannot begin from here —
  /// arming at 70 km/h and starting immediately would record 0→50 and 0→60 as
  /// having taken no time at all, which is worse than refusing to time.
  awaitingStandstill,

  /// Stationary and ready. The clock starts on the first sample that shows
  /// movement, because a driver cannot press a button and launch at once.
  staged,

  running,
  finished,

  /// The speed signal stopped while a run was in progress.
  ///
  /// A distinct state rather than a silent return to idle. The old behaviour
  /// erased elapsed time, splits and the trace the moment the reading went
  /// stale — which happens on a disconnect, and takes the evidence of the run
  /// with it. What was measured before the signal went is still what was
  /// measured; it just cannot be completed.
  aborted,
}

class PerformanceScreen extends ConsumerStatefulWidget {
  const PerformanceScreen({super.key});

  static const String path = '/performance';

  @override
  ConsumerState<PerformanceScreen> createState() => _PerformanceScreenState();
}

class _PerformanceScreenState extends ConsumerState<PerformanceScreen> {
  static const List<int> _targets = [50, 60, 80, 100];

  RunState _state = RunState.idle;
  int _target = 100;
  DateTime? _startedAt;
  Duration? _elapsed;
  double _peakSpeed = 0;
  final Map<int, Duration> _splits = {};

  /// (seconds since launch, km/h) samples for the trace chart.
  final List<FlSpot> _trace = [];

  /// A provider subscription rather than a raw stream one, so this screen
  /// shares the heartbeat that makes staleness observable.
  ProviderSubscription<AsyncValue<TelemetrySnapshot>>? _sub;

  @override
  void dispose() {
    _sub?.close();
    super.dispose();
  }

  /// Speed at or below which the vehicle counts as stopped, in km/h. OBD road
  /// speed is a whole number, so anything under 2 is a genuine standstill.
  static const double _standstillKmh = 1;
  static const double _launchKmh = 2;

  void _arm() {
    setState(() {
      _state = RunState.awaitingStandstill;
      _startedAt = null;
      _elapsed = null;
      _peakSpeed = 0;
      _splits.clear();
      _trace.clear();
    });

    _sub?.close();
    // The heartbeat source, not the raw engine stream. Subscribing directly
    // meant that when snapshots simply stopped — no teardown, no event — this
    // screen received no clock tick with which to notice, and a run could stay
    // "計時中" indefinitely against a signal that had gone.
    _sub = ref.listenManual(telemetryProvider, (_, next) {
      final snapshot = next.value;
      if (snapshot != null) _onSample(snapshot);
    });
  }

  /// Timestamp of the last speed reading actually consumed.
  ///
  /// Snapshots are published on every PID completion, not only speed ones, so
  /// the same speed value arrives many times over. Recording each arrival would
  /// grow the trace without bound and flatten the chart with duplicate points.
  DateTime? _lastConsumedSpeedAt;

  /// How long speed may be *absent* before a run is abandoned.
  ///
  /// Long enough to ride out one dropped reply and short enough that a link
  /// which has actually gone is noticed within a second of the gauges saying
  /// so.
  static const Duration _speedAbsenceGrace = Duration(milliseconds: 1500);

  void _onSample(TelemetrySnapshot snapshot) {
    // The subscription is cancelled in dispose(), but cancellation is async and
    // an event already in flight can still land here after the screen is gone.
    if (!mounted) return;
    void abort() {
      if (_state == RunState.running || _state == RunState.staged) {
        // Kept, not erased. The splits and trace recorded before the signal
        // went are real measurements, and a driver who has just made a run
        // deserves to see how far it got rather than a screen that quietly
        // returns to the start.
        setState(() => _state = RunState.aborted);
        // Terminal, like `finished`. Nothing that arrives now can move the
        // state, so the samples were being decoded and discarded for the rest
        // of the screen's life.
        _sub?.close();
        _sub = null;
      }
    }

    final reading = snapshot[PidLibrary.vehicleSpeed.id];
    if (reading == null) {
      // Absence and staleness are different here, and treating them alike made
      // the abort threshold a single `NO DATA`.
      //
      // The poller removes a reading on the *first* strike of three, so a
      // momentary unstable reply — ordinary on a marginal Bluetooth link —
      // emptied the map, `isStale` answered true for the missing entry, and a
      // run in progress went to a terminal `aborted` that needs re-staging.
      // The fragility of a 0-100 timer was out of all proportion to the actual
      // signal quality.
      //
      // So an absence is aged rather than acted on. A link that has genuinely
      // gone stops producing samples entirely, and this fires a moment later.
      final last = _lastConsumedSpeedAt;
      if (last == null ||
          DateTime.now().difference(last) > _speedAbsenceGrace) {
        abort();
      }
      return;
    }

    // A reading that is present but old is different: the sensor answered and
    // the answer describes a moment that has passed. Timing a run against that
    // produces a confident number from a sensor that stopped answering half
    // way down the road, so it aborts at once.
    if (snapshot.isStale(PidLibrary.vehicleSpeed)) {
      abort();
      return;
    }
    if (reading.timestamp == _lastConsumedSpeedAt) return;
    _lastConsumedSpeedAt = reading.timestamp;
    final speed = reading.value;

    switch (_state) {
      // A finished or abandoned run is not listening for anything; the driver
      // arms the next one explicitly.
      case RunState.idle:
      case RunState.finished:
      case RunState.aborted:
        break;
      case RunState.awaitingStandstill:
        if (speed <= _standstillKmh) {
          setState(() => _state = RunState.staged);
        }
      case RunState.staged:
        if (speed >= _launchKmh) {
          setState(() {
            _state = RunState.running;
            _startedAt = DateTime.now();
          });
        }
      case RunState.running:
        final startedAt = _startedAt;
        if (startedAt == null) return;
        final elapsed = DateTime.now().difference(startedAt);

        setState(() {
          _peakSpeed = speed > _peakSpeed ? speed : _peakSpeed;
          _elapsed = elapsed;
          _trace.add(FlSpot(elapsed.inMilliseconds / 1000, speed));
          // A run that never reaches its target would otherwise accumulate
          // points for as long as the car keeps moving.
          if (_trace.length > _maxTracePoints) _trace.removeAt(0);
          for (final split in _targets) {
            if (speed >= split && !_splits.containsKey(split)) {
              _splits[split] = elapsed;
            }
          }
          if (speed >= _target) {
            _state = RunState.finished;
            _sub?.close();
          }
        });
    }
  }

  void _reset() {
    _sub?.close();
    setState(() {
      _state = RunState.idle;
      _startedAt = null;
      _elapsed = null;
      _peakSpeed = 0;
      _splits.clear();
      _trace.clear();
    });
  }

  /// Roughly two minutes at ten samples a second — far longer than any real
  /// 0-100 run, short enough that a forgotten session cannot grow unbounded.
  static const int _maxTracePoints = 1200;

  /// One decimal, because that is what the sampling supports.
  ///
  /// The clock starts and stops on speed *samples*, which arrive around ten
  /// times a second on a good link — so the elapsed figure is only ever
  /// accurate to roughly a tenth. Printing hundredths implied a precision of
  /// about five milliseconds that nothing here measures, and a 0-100 time is
  /// exactly the number someone will quote or compare.
  String _format(Duration? d) =>
      d == null ? '--.-' : (d.inMilliseconds / 1000).toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final connected = ref.watch(obdSessionProvider).isConnected;
    final snapshot = ref.watch(telemetryProvider).value ?? const TelemetrySnapshot();
    // Nullable on purpose. Coercing an absent speed to zero told the user the
    // car was stationary and let them arm a run with no valid speed stream
    // behind it — the timer would then never start, or start on the first
    // number that happened to arrive.
    final speed = snapshot.valueOf(PidLibrary.vehicleSpeed);
    final hasSpeed = speed != null;

    if (!connected) {
      return const Scaffold(
        body: SafeArea(
          child: EmptyState(
            icon: Icons.link_off,
            title: '尚未連線',
            message: '加速測試需要即時車速資料，請先連線或啟動模擬器。',
          ),
        ),
      );
    }

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.md,
            Spacing.lg,
            Spacing.xxl,
          ),
          children: [
            Text('加速測試', style: context.texts.headlineMedium),
            Text('由靜止起步計時至目標車速', style: context.texts.bodySmall),
            const SizedBox(height: Spacing.xl),

            Center(
              child: SizedBox(
                width: 230,
                height: 230,
                child: DialGauge(
                  value: speed,
                  minValue: 0,
                  // The needle pins at the top of the scale while the readout
                  // keeps climbing unless the scale can hold the whole run.
                  maxValue: math.max(_target.toDouble() * 1.3, 260),
                  label: '車速',
                  units: 'km/h',
                  hue: GaugeHue.blue,
                  isStale: !hasSpeed,
                ),
              ),
            ),
            const SizedBox(height: Spacing.xl),

            Panel(
              accent: switch (_state) {
                RunState.running => palette.warning,
                RunState.finished => palette.success,
                RunState.aborted => palette.danger,
                _ => palette.accent,
              },
              isActive: _state != RunState.idle,
              child: Column(
                children: [
                  Text(
                    switch (_state) {
                      RunState.idle => '選擇目標車速後開始',
                      RunState.awaitingStandstill => hasSpeed
                          ? '請先完全停車 — 目前 ${speed.toStringAsFixed(0)} km/h'
                          : '等待車速訊號',
                      RunState.staged => '已就緒 — 起步即開始計時',
                      RunState.running => '計時中',
                      RunState.finished => '完成 0 → $_target km/h',
                      RunState.aborted => '車速訊號中斷 — 這次計時未完成，'
                          '以下為中斷前的紀錄',
                    },
                    style: context.texts.labelSmall,
                  ),
                  const SizedBox(height: Spacing.sm),
                  Text(
                    _format(_elapsed),
                    style: AppTypography.readout(palette, 56).copyWith(
                      color: switch (_state) {
                        RunState.finished => palette.success,
                        RunState.running => palette.warning,
                        RunState.aborted => palette.danger,
                        _ => palette.textPrimary,
                      },
                    ),
                  ),
                  Text('秒', style: context.texts.labelMedium),
                ],
              ),
            ),
            const SizedBox(height: Spacing.lg),

            const SectionHeading('目標車速'),
            SegmentedButton<int>(
              segments: [
                for (final target in _targets)
                  ButtonSegment(value: target, label: Text('$target')),
              ],
              selected: {_target},
              onSelectionChanged: _state == RunState.running
                  ? null
                  : (s) => setState(() => _target = s.first),
              showSelectedIcon: false,
            ),
            const SizedBox(height: Spacing.lg),

            if (_trace.length > 1) ...[
              const SectionHeading('速度軌跡'),
              Panel(
                child: SizedBox(
                  height: 170,
                  child: _SpeedTrace(spots: _trace, target: _target.toDouble()),
                ),
              ),
              const SizedBox(height: Spacing.lg),
            ],

            if (_splits.isNotEmpty) ...[
              const SectionHeading('分段成績'),
              Panel(
                child: Column(
                  children: [
                    for (final target in _targets)
                      if (_splits.containsKey(target))
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
                          child: Row(
                            children: [
                              Text('0 → $target km/h', style: context.texts.bodyMedium),
                              const Spacer(),
                              Text(
                                '${_format(_splits[target])} s',
                                style: AppTypography.readout(palette, 17),
                              ),
                            ],
                          ),
                        ),
                    Divider(color: palette.hairline),
                    Padding(
                      padding: const EdgeInsets.only(top: Spacing.sm),
                      child: Row(
                        children: [
                          Text('最高車速', style: context.texts.bodyMedium),
                          const Spacer(),
                          Text(
                            '${_peakSpeed.toStringAsFixed(0)} km/h',
                            style: AppTypography.readout(palette, 17),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Spacing.lg),
            ],

            if (_state == RunState.idle) ...[
              FilledButton.icon(
                // Arming without a live speed stream produces a run that never
                // starts, or one that starts on whichever number arrives first.
                onPressed: hasSpeed ? _arm : null,
                icon: const Icon(Icons.play_arrow, size: 20),
                label: const Text('準備計時'),
              ),
              if (!hasSpeed) ...[
                const SizedBox(height: Spacing.md),
                Text(
                  '目前沒有有效的車速訊號（PID 010D）。加速測試需要它才能計時。',
                  textAlign: TextAlign.center,
                  style: context.texts.bodySmall,
                ),
              ],
            ]
            else
              OutlinedButton.icon(
                onPressed: _reset,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('重置'),
              ),

            const SizedBox(height: Spacing.lg),
            Text(
              '成績以 OBD 車速訊號為準。多數車輛的車速表本身有 1–3 km/h 的正偏差，'
              '且訊號更新率約每秒 10–20 次，因此結果僅供參考，不等同於專業測試設備。',
              style: context.texts.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// Speed against time for the current run.
///
/// The shape is what makes a run readable: gear changes show as flat spots,
/// wheelspin as a step, and a bogged launch as a slow first second — none of
/// which the single elapsed number can tell you.
class _SpeedTrace extends StatelessWidget {
  const _SpeedTrace({required this.spots, required this.target});

  final List<FlSpot> spots;
  final double target;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final maxX = spots.last.x <= 0 ? 1.0 : spots.last.x;
    final maxY = target * 1.15;

    final labelStyle = context.texts.labelSmall?.copyWith(
      color: palette.textTertiary,
      fontFeatures: AppTypography.tabular,
    );

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: maxX,
        minY: 0,
        maxY: maxY,
        clipData: const FlClipData.all(),
        gridData: FlGridData(
          drawVerticalLine: false,
          horizontalInterval: maxY / 3,
          getDrawingHorizontalLine: (_) => FlLine(
            color: palette.hairline,
            strokeWidth: 1,
          ),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(),
          rightTitles: const AxisTitles(),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 34,
              interval: maxY / 3,
              getTitlesWidget: (value, _) => Text(
                value.round().toString(),
                style: labelStyle,
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              // Roughly four labels regardless of run length, so a 4-second
              // sprint and a 20-second pull are equally readable.
              interval: (maxX / 4).clamp(0.5, 60),
              getTitlesWidget: (value, _) => Text(
                '${value.toStringAsFixed(value >= 10 ? 0 : 1)}s',
                style: labelStyle,
              ),
            ),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            curveSmoothness: 0.2,
            preventCurveOverShooting: true,
            barWidth: 3,
            isStrokeCapRound: true,
            gradient: LinearGradient(
              colors: [
                context.gaugeColors(GaugeHue.blue).dim,
                context.gaugeColors(GaugeHue.blue).bright,
              ],
            ),
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  context.gaugeColors(GaugeHue.blue).bright.withValues(alpha: 0.28),
                  context.gaugeColors(GaugeHue.blue).bright.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        ],
        extraLinesData: ExtraLinesData(
          horizontalLines: [
            HorizontalLine(
              y: target,
              color: palette.success.withValues(alpha: 0.7),
              strokeWidth: 1.5,
              dashArray: const [6, 5],
            ),
          ],
        ),
        lineTouchData: const LineTouchData(enabled: false),
      ),
    );
  }
}
