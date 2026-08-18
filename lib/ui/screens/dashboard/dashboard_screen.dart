/// The live dashboard.
///
/// A responsive wall of dials plus a strip of figures the physics engine
/// derived. Column count follows available width rather than a device-class
/// guess, so a phone rotated into landscape on a windscreen mount gets the
/// wider layout automatically.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../obd/physics/physics_engine.dart';
import '../../../obd/pid/pid.dart';
import '../../../obd/pid/pid_library.dart';
import '../../../obd/telemetry.dart';
import '../../../state/obd_session.dart';
import '../../../state/pid_registry.dart';
import '../../../state/settings.dart';
import '../../widgets/gauges/dial_gauge.dart';
import '../../widgets/panel.dart';
import '../pids/pid_manager_screen.dart';

class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  static const String path = '/dashboard';

  /// Tiles below this width stop being legible at arm's length.
  static const double _minTileWidth = 156;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connection = ref.watch(obdSessionProvider);
    final activePids = ref.watch(activePidsProvider);
    final telemetry = ref.watch(telemetryProvider);
    final snapshot = telemetry.value ?? const TelemetrySnapshot();

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: _StatusStrip(connection: connection, snapshot: snapshot),
            ),
            if (activePids.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyState(
                  icon: Icons.tune,
                  title: '儀表板是空的',
                  message: '到 PID 頁面挑選想要監看的訊號，它們會出現在這裡。',
                  action: FilledButton.icon(
                    onPressed: () => context.go(PidManagerScreen.path),
                    icon: const Icon(Icons.add, size: 20),
                    label: const Text('選擇 PID'),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(
                  Spacing.lg,
                  0,
                  Spacing.lg,
                  Spacing.md,
                ),
                sliver: _GaugeGrid(pids: activePids, snapshot: snapshot),
              ),
            SliverToBoxAdapter(
              child: _DerivedStrip(snapshot: snapshot),
            ),
            // Clears the navigation bar so the derived figures can be scrolled
            // fully into view rather than sitting half-under it.
            SliverToBoxAdapter(
              child: SizedBox(
                height: Spacing.xl + MediaQuery.paddingOf(context).bottom,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _GaugeGrid extends StatelessWidget {
  const _GaugeGrid({required this.pids, required this.snapshot});

  final List<Pid> pids;
  final TelemetrySnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.crossAxisExtent;
        // The dial's readout is sized from the tile, not from the text scale,
        // so honouring an accessibility setting means giving each tile more
        // room rather than growing type inside a fixed box. At 2x scale on a
        // narrow phone this correctly drops to a single column of large dials
        // instead of two cramped ones.
        final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final minWidth = DashboardScreen._minTileWidth * scale;
        final columns = math.max(1, (width / minWidth).floor());

        return SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            mainAxisSpacing: Spacing.md,
            crossAxisSpacing: Spacing.md,
            // Square tiles: the dial is circular and its label and units live
            // inside the ring, so extra vertical room would only be padding.
            childAspectRatio: 1,
          ),
          delegate: SliverChildBuilderDelegate(
            childCount: pids.length,
            (context, index) {
              final pid = pids[index];
              final reading = snapshot[pid.id];
              final fault = snapshot.faults[pid.id];
              return _GaugeTile(
                pid: pid,
                reading: reading,
                fault: fault,
                // Computed here, where the snapshot's own capture time is in
                // scope, so every tile in a frame judges age against the same
                // instant rather than each reading the clock separately.
                isStale: snapshot.isStale(pid),
                // Stagger the entrance so the wall assembles rather than
                // popping in all at once.
                delay: Duration(milliseconds: 28 * index),
              );
            },
          ),
        );
      },
    );
  }
}

class _GaugeTile extends StatelessWidget {
  const _GaugeTile({
    required this.pid,
    required this.reading,
    required this.fault,
    required this.isStale,
    required this.delay,
  });

  final Pid pid;
  final Reading? reading;
  final PidFault? fault;
  final bool isStale;
  final Duration delay;

  @override
  Widget build(BuildContext context) {
    final hue = GaugeHue.forKey(pid.id);
    final accent = context.gaugeColors(hue).bright;
    final isUnsupported = fault == PidFault.unsupported;

    return _FadeInUp(
      delay: delay,
      child: Panel(
        accent: accent,
        padding: const EdgeInsets.all(Spacing.sm),
        child: isUnsupported
            ? _UnsupportedTile(pid: pid)
            : DialGauge(
                value: reading?.value,
                minValue: pid.minValue,
                maxValue: pid.maxValue,
                label: pid.shortName.isEmpty ? pid.name : pid.shortName,
                units: pid.units,
                hue: hue,
                redlineFrom: pid.redlineFrom,
                // A value older than its PID's own refresh target is not live,
                // however plausible it looks.
                isStale: isStale,
                footnote: switch (fault) {
                  PidFault.formulaError => '公式錯誤',
                  PidFault.busError => '匯流排錯誤',
                  // Not "unsupported": nothing has established that. The
                  // sensor stopped answering and will be tried again.
                  PidFault.noAnswer => '無回應，稍後重試',
                  // Nor this one, which is about the definition rather than
                  // the car — and the fix is in a field the user can edit.
                  PidFault.headerNotOnThisBus => '標頭不符本車匯流排',
                  // Nor this one, and least of all this one: the request was
                  // never transmitted, so the vehicle has not been consulted at
                  // all. The dial stays, because the definition — not the car —
                  // is what has to change.
                  PidFault.refusedUnsafeService => '此服務不是唯讀查詢，已停止發送',
                  _ => null,
                },
              ),
      ),
    );
  }
}

class _UnsupportedTile extends StatelessWidget {
  const _UnsupportedTile({required this.pid});

  final Pid pid;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.sm),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.block, size: 22, color: palette.textTertiary),
            const SizedBox(height: Spacing.sm),
            Text(
              pid.shortName.isEmpty ? pid.name : pid.shortName,
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.texts.titleSmall,
            ),
            const SizedBox(height: Spacing.xs),
            Text(
              '此車輛不支援',
              textAlign: TextAlign.center,
              style: context.texts.bodySmall?.copyWith(color: palette.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}

/// Connection identity, throughput and battery voltage.
class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.connection, required this.snapshot});

  final ObdConnectionState connection;
  final TelemetrySnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    // Null means the adapter has not reported a plausible supply voltage, so
    // the pill is omitted rather than showing a number nobody measured.
    // No fallback to the handshake reading. Ageing the live value in the
    // client and then resurrecting the connect-time figure here defeats the
    // whole thing: an adapter that stops answering `ATRV` produced
    // `snapshot.batteryVoltage == null`, and the pill immediately substituted
    // 13.9 V from the handshake and held it indefinitely. `null` renders as
    // "--", which is what not knowing looks like.
    final voltage = snapshot.batteryVoltage;

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.lg,
        Spacing.md,
        Spacing.lg,
        Spacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _LiveDot(active: connection.isConnected),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      connection.deviceName.isEmpty ? '未連線' : connection.deviceName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: context.texts.titleMedium,
                    ),
                    if (connection.protocol.isNotEmpty)
                      Text(
                        connection.protocol,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: context.texts.bodySmall,
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Spacing.md),
          Wrap(
            spacing: Spacing.sm,
            runSpacing: Spacing.sm,
            children: [
              StatusPill(
                label: '${snapshot.pidsPerSecond.round()} PIDs/s',
                icon: Icons.bolt,
                tone: snapshot.pidsPerSecond > 0 ? StatusTone.accent : StatusTone.neutral,
              ),
              // Only once something has actually been polled.
              //
              // The flag defaults to on, and an empty snapshot is published
              // verbatim when the app connects while backgrounded — so the
              // pill read fastMode, in good tone, before a single request had
              // gone out. It describes observed behaviour and must not be the
              // first thing on screen.
              if (snapshot.capturedAt != null)
                StatusPill(
                  label: snapshot.fastModeEnabled ? 'fastMode' : '單筆模式',
                  icon: snapshot.fastModeEnabled
                      ? Icons.fast_forward
                      : Icons.slow_motion_video,
                  tone: snapshot.fastModeEnabled
                      ? StatusTone.good
                      : StatusTone.warn,
                ),
              // Shown even when unknown. Hiding the pill would make "the
              // adapter stopped reporting voltage" look identical to "this
              // screen has no voltage pill", and the whole point of ageing the
              // value is that its absence should be visible.
              StatusPill(
                label: voltage == null
                    ? '-- V'
                    : '${voltage.toStringAsFixed(1)} V',
                icon: Icons.battery_charging_full,
                tone: voltage == null
                    ? StatusTone.warn
                    : (voltage < 11.8 ? StatusTone.bad : StatusTone.good),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LiveDot extends StatefulWidget {
  const _LiveDot({required this.active});

  final bool active;

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final colour = widget.active ? palette.success : palette.textTertiary;

    if (!widget.active) {
      return Container(
        width: 9,
        height: 9,
        decoration: BoxDecoration(shape: BoxShape.circle, color: colour),
      );
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        return SizedBox(
          width: 18,
          height: 18,
          child: Center(
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 9 + 9 * t,
                  height: 9 + 9 * t,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colour.withValues(alpha: 0.28 * (1 - t)),
                  ),
                ),
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(shape: BoxShape.circle, color: colour),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Figures the physics engine computed rather than read off the bus. Marked in
/// the derived colour throughout so nobody mistakes an estimate for a sensor.
class _DerivedStrip extends ConsumerWidget {
  const _DerivedStrip({required this.snapshot});

  final TelemetrySnapshot snapshot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    final profile = ref.watch(vehicleProfileProvider);

    final rpm = snapshot.valueOf(PidLibrary.engineRpm);
    final speed = snapshot.valueOf(PidLibrary.vehicleSpeed);
    final maf = snapshot.valueOf(PidLibrary.mafRate);
    final map = snapshot.valueOf(PidLibrary.manifoldPressure);
    final iat = snapshot.valueOf(PidLibrary.intakeAirTemp);

    // Every derived figure needs engine speed and road speed. Substituting
    // zero for a missing input does not produce a conservative estimate — it
    // produces a confident wrong one, and there is no way to tell it apart
    // from a genuine reading on the tile.
    // Acceleration joins the required inputs. It used to arrive as a
    // non-nullable 0 whenever it was unknown, which the force terms consume as
    // a real steady-cruise measurement — so a gap in speed replies produced
    // confident horsepower derived from a number nobody measured.
    final accel = snapshot.accelerationMs2;
    final hasInputs = rpm != null && speed != null && accel != null;
    if (!hasInputs) {
      return const _DerivedUnavailable();
    }

    final metrics = PhysicsEngine.derive(
      profile: profile,
      rpm: rpm,
      speedKmh: speed,
      accelMs2: accel,
      mafSensorGps: maf,
      mapKpa: map,
      intakeTempC: iat,
      // The vehicle's own figure where it reports one: it accounts for the
      // mixture actually being run, where the stoichiometric estimate assumes
      // lambda 1 and is wrong by roughly lambda on anything that is not.
      fuelRateSensorLPerHour: snapshot.valueOf(PidLibrary.engineFuelRate),
    );

    // `--` rather than a number nobody measured.
    final consumption = metrics.isMoving
        ? metrics.litresPer100Km!.toStringAsFixed(1)
        : metrics.fuelRateLPerHour?.toStringAsFixed(1) ?? '--';
    final consumptionUnits = metrics.isMoving ? 'L/100km' : 'L/h';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
      child: Panel(
        accent: palette.derived,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.functions, size: 15, color: palette.derived),
                const SizedBox(width: Spacing.sm),
                Text(
                  '推算數值',
                  style: context.texts.labelSmall?.copyWith(color: palette.derived),
                ),
                const Spacer(),
                // Provenance, not decoration: a speed-density figure and a
                // sensor reading look identical on the tile, and one of them
                // depends on a volumetric-efficiency number the user typed in.
                if (metrics.airflowSource != AirflowSource.unavailable)
                  StatusPill(
                    label: metrics.fuelSource == FuelSource.measured
                        ? metrics.airflowSource.label
                        : '${metrics.airflowSource.label} · ${metrics.fuelSource.label}',
                    tone: StatusTone.neutral,
                    dense: true,
                  ),
              ],
            ),
            const SizedBox(height: Spacing.md),
            // Reflows instead of shrinking.
            //
            // Four cells in one row meant that at 320dp with 200% text scaling
            // the labels ellipsised and `FittedBox.scaleDown` shrank the
            // numbers — making telemetry smaller at precisely the moment the
            // user asked for it to be larger. The gauge grid above already
            // adapts by column count; this now follows the same policy.
            LayoutBuilder(
              builder: (context, constraints) {
                final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
                final cells = [
                  _DerivedCell(
                    label: '空氣流量',
                    value:
                        metrics.mafGramsPerSecond?.toStringAsFixed(1) ?? '--',
                    units: 'g/s',
                  ),
                  _DerivedCell(
                    label: '油耗',
                    value: consumption,
                    units: consumptionUnits,
                  ),
                  _DerivedCell(
                    label: '引擎馬力',
                    value: metrics.engineHorsepower
                        .clamp(0, 2000)
                        .toStringAsFixed(0),
                    units: 'hp',
                  ),
                  _DerivedCell(
                    label: '扭力',
                    value:
                        metrics.torqueNm.clamp(0, 5000).toStringAsFixed(0),
                    units: 'N·m',
                  ),
                ];

                // Each cell needs roughly this much to render its label
                // without truncation at the current text size.
                final perCell = 88 * scale;
                final columns =
                    (constraints.maxWidth / perCell).floor().clamp(1, 4);

                final rows = <Widget>[];
                for (var i = 0; i < cells.length; i += columns) {
                  final slice = cells.sublist(
                    i,
                    math.min(i + columns, cells.length),
                  );
                  rows.add(
                    Padding(
                      padding: EdgeInsets.only(top: i == 0 ? 0 : Spacing.md),
                      child: Row(
                        children: [
                          for (var j = 0; j < slice.length; j++)
                            slice[j].copyWith(
                              isLast: j == slice.length - 1,
                            ),
                          // Keeps a short final row aligned with the ones
                          // above rather than stretching its cells.
                          for (var j = slice.length; j < columns; j++)
                            const Expanded(child: SizedBox.shrink()),
                        ],
                      ),
                    ),
                  );
                }
                return Column(children: rows);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _DerivedCell extends StatelessWidget {
  const _DerivedCell({
    required this.label,
    required this.value,
    required this.units,
    this.isLast = false,
  });

  final String label;
  final String value;
  final String units;

  /// Suppresses the trailing divider. Which cell is last depends on how many
  /// columns the row ended up with, so it is decided at layout time.
  final bool isLast;

  _DerivedCell copyWith({required bool isLast}) => _DerivedCell(
        label: label,
        value: value,
        units: units,
        isLast: isLast,
      );

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Expanded(
      child: Container(
        decoration: isLast
            ? null
            : BoxDecoration(
                border: Border(right: BorderSide(color: palette.hairline)),
              ),
        padding: EdgeInsets.only(right: isLast ? 0 : Spacing.sm),
        margin: EdgeInsets.only(right: isLast ? 0 : Spacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.texts.labelSmall,
            ),
            const SizedBox(height: Spacing.xs),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(value, style: AppTypography.readout(palette, 20)),
                  const SizedBox(width: 3),
                  Text(
                    units,
                    style: context.texts.labelSmall?.copyWith(
                      color: palette.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One-shot entrance: fade plus a short rise, staggered by [delay].
class _FadeInUp extends StatefulWidget {
  const _FadeInUp({required this.child, required this.delay});

  final Widget child;
  final Duration delay;

  @override
  State<_FadeInUp> createState() => _FadeInUpState();
}

class _FadeInUpState extends State<_FadeInUp> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Motion.slow,
  );

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(widget.delay, () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final curved = CurvedAnimation(parent: _controller, curve: Motion.emphasised);
    return AnimatedBuilder(
      animation: curved,
      builder: (context, child) => Opacity(
        opacity: curved.value,
        child: Transform.translate(
          offset: Offset(0, 14 * (1 - curved.value)),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}

/// Stands in for the derived-metrics strip when its inputs are not available.
///
/// Deliberately a distinct state rather than a row of zeroes: "we cannot work
/// this out yet" and "your engine is producing no power" look identical when
/// both render as 0 hp.
class _DerivedUnavailable extends StatelessWidget {
  const _DerivedUnavailable();

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Spacing.lg),
      child: Panel(
        child: Row(
          children: [
            Icon(Icons.functions, size: 15, color: palette.textTertiary),
            const SizedBox(width: Spacing.sm),
            Expanded(
              child: Text(
                '等待引擎轉速與車速資料後才能推算馬力、扭力與油耗',
                style: context.texts.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
