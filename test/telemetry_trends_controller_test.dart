import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torque_obd/obd/pid/pid.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/session_boundary.dart';
import 'package:torque_obd/obd/telemetry.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/state/telemetry_trends.dart';
import 'package:torque_obd/telemetry/session/telemetry_session.dart';
import 'package:torque_obd/telemetry/session/timeline_downsampler.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('defaults to four direct active signals and refuses a fifth', () {
    final active = PidLibrary.all
        .where(
          (pid) =>
              pid.isMode01 &&
              pid.header == kDefaultHeader &&
              pid.variant == null,
        )
        .take(5)
        .toList();
    final controller = TelemetryTrendsController(
      activePids: active,
      storedIds: null,
    );

    expect(controller.state.selectedIds, active.take(4).map((pid) => pid.id));
    expect(
      controller.setSelectedIds(active.map((pid) => pid.id).toList()),
      TelemetryTrendSelectionOutcome.tooMany,
    );
    expect(controller.state.selectedIds, hasLength(4));
  });

  test('stored ids drop invalid entries without changing active polling', () {
    final active = [PidLibrary.engineRpm, PidLibrary.vehicleSpeed];
    final controller = TelemetryTrendsController(
      activePids: active,
      storedIds: ['missing', PidLibrary.vehicleSpeed.id],
    );

    expect(controller.state.selectedIds, [PidLibrary.vehicleSpeed.id]);
    expect(active, [PidLibrary.engineRpm, PidLibrary.vehicleSpeed]);
  });

  test('explicit empty stored selection survives restart instead of defaulting', () {
    final active = [PidLibrary.engineRpm, PidLibrary.vehicleSpeed];
    final controller = TelemetryTrendsController(
      activePids: active,
      storedIds: const <String>[],
    );

    expect(
      controller.state.selectedIds,
      isEmpty,
      reason: 'persisted [] must not be treated like a missing preference',
    );
    expect(
      controller.setSelectedIds(const <String>[]),
      TelemetryTrendSelectionOutcome.noChange,
    );
  });

  test('all-invalid stored selection stays empty instead of first-run fallback', () {
    final active = [PidLibrary.engineRpm, PidLibrary.vehicleSpeed];
    final controller = TelemetryTrendsController(
      activePids: active,
      storedIds: const ['gone-custom-a', 'gone-custom-b'],
    );

    expect(
      controller.state.selectedIds,
      isEmpty,
      reason: 'filtering every stored id out must not silently pick unrelated PIDs',
    );
  });

  test(
    'deduplicates source timestamps and never carries a value over a gap',
    () {
      final controller = TelemetryTrendsController(
        activePids: [PidLibrary.engineRpm],
        storedIds: [PidLibrary.engineRpm.id],
      );
      final at = DateTime.utc(2026, 8, 30);
      final fresh = _snapshot(PidLibrary.engineRpm, 2000, at);

      controller.ingest(fresh, observedAtUtc: at, elapsedUs: 1);
      controller.ingest(fresh, observedAtUtc: at, elapsedUs: 2);
      controller.ingest(
        const TelemetrySnapshot(),
        observedAtUtc: at.add(const Duration(seconds: 3)),
        elapsedUs: 3,
      );

      final unavailable = controller.state.lanes[PidLibrary.engineRpm.id]!;
      expect(unavailable.currentValue, isNull);
      expect(unavailable.currentStatus, TelemetryStatus.stale);
      expect(unavailable.primitives.whereType<TimelineValue>(), hasLength(1));
      expect(unavailable.primitives.whereType<TimelineGap>(), hasLength(1));

      final resumedAt = at.add(const Duration(seconds: 4));
      controller.ingest(
        _snapshot(PidLibrary.engineRpm, 2200, resumedAt),
        observedAtUtc: resumedAt,
        elapsedUs: 4,
      );
      final values = controller.state.lanes[PidLibrary.engineRpm.id]!.primitives
          .whereType<TimelineValue>()
          .toList();
      expect(values, hasLength(2));
      expect(values.last.breakBefore, isTrue);
    },
  );

  test(
    'clock skew does not reopen an unavailable trend lane without a new value',
    () {
      final controller = TelemetryTrendsController(
        activePids: [PidLibrary.engineRpm],
        storedIds: [PidLibrary.engineRpm.id],
      );
      final source = DateTime.utc(2026, 8, 30);
      controller.ingest(
        _snapshot(PidLibrary.engineRpm, 900, source),
        observedAtUtc: source,
        elapsedUs: 1,
      );
      controller.ingest(
        const TelemetrySnapshot(),
        observedAtUtc: source.add(const Duration(seconds: 3)),
        elapsedUs: 2,
      );
      expect(
        controller.state.lanes[PidLibrary.engineRpm.id]!.primitives
            .whereType<TimelineGap>(),
        hasLength(1),
      );

      // Wall clock jumps backward so the old sample looks fresh again.
      controller.ingest(
        _snapshot(PidLibrary.engineRpm, 900, source),
        observedAtUtc: source.add(const Duration(milliseconds: 100)),
        elapsedUs: 3,
      );
      expect(
        controller.state.lanes[PidLibrary.engineRpm.id]!.primitives
            .whereType<TimelineValue>(),
        hasLength(1),
        reason: 'same source timestamp must not invent a recovery value',
      );
      expect(
        controller.state.lanes[PidLibrary.engineRpm.id]!.currentValue,
        isNull,
        reason: 'lane must stay unavailable until a new source timestamp',
      );
      expect(
        controller.state.lanes[PidLibrary.engineRpm.id]!.currentStatus,
        TelemetryStatus.stale,
      );

      controller.ingest(
        const TelemetrySnapshot(),
        observedAtUtc: source.add(const Duration(seconds: 4)),
        elapsedUs: 4,
      );
      expect(
        controller.state.lanes[PidLibrary.engineRpm.id]!.primitives
            .whereType<TimelineGap>(),
        hasLength(1),
        reason: 'reopening without a value would invent a second gap',
      );
    },
  );

  test('future-dated readings stay unavailable on trend lanes', () {
    final controller = TelemetryTrendsController(
      activePids: [PidLibrary.engineRpm],
      storedIds: [PidLibrary.engineRpm.id],
    );
    final observed = DateTime.utc(2026, 8, 30);
    controller.ingest(
      _snapshot(
        PidLibrary.engineRpm,
        900,
        observed.add(const Duration(seconds: 1)),
      ),
      observedAtUtc: observed,
      elapsedUs: 1,
    );

    final lane = controller.state.lanes[PidLibrary.engineRpm.id]!;
    expect(
      lane.primitives.whereType<TimelineValue>(),
      isEmpty,
      reason: 'source after observedAt must match driving-safety / recorder',
    );
    expect(lane.currentValue, isNull);
    expect(lane.currentStatus, TelemetryStatus.stale);
  });

  test(
    'session boundary reset clears prior vehicle samples without changing selection',
    () {
      final controller = TelemetryTrendsController(
        activePids: [PidLibrary.engineRpm, PidLibrary.vehicleSpeed],
        storedIds: [PidLibrary.engineRpm.id, PidLibrary.vehicleSpeed.id],
      );
      final vehicleA = DateTime.utc(2026, 8, 30, 10);
      controller.ingest(
        TelemetrySnapshot(
          readings: {
            PidLibrary.engineRpm.id: Reading(
              pid: PidLibrary.engineRpm,
              value: 800,
              rawBytes: const [0],
              timestamp: vehicleA,
            ),
            PidLibrary.vehicleSpeed.id: Reading(
              pid: PidLibrary.vehicleSpeed,
              value: 40,
              rawBytes: const [0],
              timestamp: vehicleA,
            ),
          },
          capturedAt: vehicleA,
        ),
        observedAtUtc: vehicleA,
        elapsedUs: 1,
      );
      expect(
        controller.state.lanes[PidLibrary.engineRpm.id]!.currentValue,
        800,
      );
      expect(
        controller.state.lanes[PidLibrary.engineRpm.id]!.primitives
            .whereType<TimelineValue>(),
        hasLength(1),
      );

      // Disconnect/reconnect within the 60s window must not keep vehicle A.
      controller.resetForSessionBoundary();
      expect(
        controller.state.selectedIds,
        [PidLibrary.engineRpm.id, PidLibrary.vehicleSpeed.id],
      );
      expect(
        controller.state.lanes[PidLibrary.engineRpm.id]!.primitives,
        isEmpty,
      );
      expect(
        controller.state.lanes[PidLibrary.engineRpm.id]!.currentValue,
        isNull,
      );

      final vehicleB = vehicleA.add(const Duration(seconds: 15));
      controller.ingest(
        _snapshot(PidLibrary.engineRpm, 3200, vehicleB),
        observedAtUtc: vehicleB,
        elapsedUs: 3,
      );
      final lane = controller.state.lanes[PidLibrary.engineRpm.id]!;
      final values = lane.primitives.whereType<TimelineValue>().toList();
      expect(values, hasLength(1));
      expect(values.single.value, 3200);
      expect(lane.currentValue, 3200);
    },
  );

  test(
    'OBD session boundary stream resets live trend histories',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final snapshots = StreamController<TelemetrySnapshot>.broadcast(
        sync: true,
      );
      final boundaries = StreamController<ObdSessionBoundary>.broadcast(
        sync: true,
      );
      var elapsedUs = 0;
      var nowUtc = DateTime.utc(2026, 8, 30);
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          activePidsProvider.overrideWith(
            () => _FixedActivePids(const [PidLibrary.engineRpm]),
          ),
          telemetryProvider.overrideWith((ref) => snapshots.stream),
          telemetryTrendsBoundaryStreamProvider.overrideWithValue(
            boundaries.stream,
          ),
          telemetryTrendsClockProvider.overrideWithValue(
            TelemetryTrendsClock(
              nowUtc: () => nowUtc,
              elapsedUs: () => ++elapsedUs,
            ),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await snapshots.close();
        await boundaries.close();
      });
      final subscription = container.listen(
        telemetryTrendsProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      nowUtc = DateTime.utc(2026, 8, 30);
      snapshots.add(_snapshot(PidLibrary.engineRpm, 1500, nowUtc));
      await container.pump();
      expect(
        container
            .read(telemetryTrendsProvider)
            .lanes[PidLibrary.engineRpm.id]!
            .currentValue,
        1500,
      );

      nowUtc = nowUtc.add(const Duration(seconds: 1));
      boundaries.add(
        ObdSessionBoundary(
          generation: 1,
          observedAtUtc: nowUtc,
          reason: ObdSessionBoundaryReason.userDisconnect,
        ),
      );
      await container.pump();

      final afterBoundary = container
          .read(telemetryTrendsProvider)
          .lanes[PidLibrary.engineRpm.id]!;
      expect(afterBoundary.primitives, isEmpty);
      expect(afterBoundary.currentValue, isNull);
      expect(
        container.read(telemetryTrendsProvider).selectedIds,
        [PidLibrary.engineRpm.id],
      );

      nowUtc = nowUtc.add(const Duration(seconds: 1));
      snapshots.add(_snapshot(PidLibrary.engineRpm, 4100, nowUtc));
      await container.pump();
      final values = container
          .read(telemetryTrendsProvider)
          .lanes[PidLibrary.engineRpm.id]!
          .primitives
          .whereType<TimelineValue>()
          .toList();
      expect(values, hasLength(1));
      expect(values.single.value, 4100);
    },
  );

  test('prunes to 60 seconds and bounds every lane to 1200 primitives', () {
    final controller = TelemetryTrendsController(
      activePids: [PidLibrary.engineRpm],
      storedIds: [PidLibrary.engineRpm.id],
    );
    final start = DateTime.utc(2026, 8, 30);
    for (var index = 0; index < 3000; index++) {
      final at = start.add(Duration(milliseconds: index * 30));
      controller.ingest(
        _snapshot(PidLibrary.engineRpm, index.toDouble(), at),
        observedAtUtc: at,
        elapsedUs: index * 30000,
      );
    }

    final primitives =
        controller.state.lanes[PidLibrary.engineRpm.id]!.primitives;
    expect(primitives.length, lessThanOrEqualTo(1200));
    expect(
      primitives.every(
        (primitive) =>
            primitive.elapsedUs >=
            controller.state.windowEndElapsedUs -
                telemetryTrendWindow.inMicroseconds,
      ),
      isTrue,
    );
  });

  test(
    'first build synchronously seeds an already-warmed telemetry value',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final snapshots = StreamController<TelemetrySnapshot>.broadcast(
        sync: true,
      );
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          activePidsProvider.overrideWith(
            () => _FixedActivePids(const [PidLibrary.engineRpm]),
          ),
          telemetryProvider.overrideWith((ref) => snapshots.stream),
          telemetryTrendsClockProvider.overrideWithValue(
            TelemetryTrendsClock(
              nowUtc: () => DateTime.utc(2026, 8, 30),
              elapsedUs: () => 7,
            ),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await snapshots.close();
      });
      final telemetrySubscription = container.listen(
        telemetryProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(telemetrySubscription.close);
      final at = DateTime.utc(2026, 8, 30);
      snapshots.add(_snapshot(PidLibrary.engineRpm, 1800, at));
      await container.pump();
      expect(
        container.read(telemetryProvider),
        isA<AsyncData<TelemetrySnapshot>>(),
      );

      final trends = container.read(telemetryTrendsProvider);
      final lane = trends.lanes[PidLibrary.engineRpm.id]!;
      expect(lane.currentValue, 1800);
      expect(lane.currentStatus, isNull);
      expect(lane.primitives.whereType<TimelineValue>(), hasLength(1));
    },
  );

  test('retained AsyncError immediately makes the trend unavailable', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final snapshots = StreamController<TelemetrySnapshot>.broadcast(sync: true);
    var elapsedUs = 0;
    final container = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        activePidsProvider.overrideWith(
          () => _FixedActivePids(const [PidLibrary.engineRpm]),
        ),
        telemetryProvider.overrideWith((ref) => snapshots.stream),
        telemetryTrendsClockProvider.overrideWithValue(
          TelemetryTrendsClock(
            nowUtc: () => DateTime.utc(2026, 8, 30),
            elapsedUs: () => ++elapsedUs,
          ),
        ),
      ],
    );
    addTearDown(() async {
      container.dispose();
      await snapshots.close();
    });
    final subscription = container.listen(
      telemetryTrendsProvider,
      (_, _) {},
      fireImmediately: true,
    );
    addTearDown(subscription.close);

    final at = DateTime.utc(2026, 8, 30);
    snapshots.add(_snapshot(PidLibrary.engineRpm, 2000, at));
    await container.pump();
    expect(
      container
          .read(telemetryTrendsProvider)
          .lanes[PidLibrary.engineRpm.id]!
          .currentValue,
      2000,
    );

    snapshots.addError(StateError('transport failed'), StackTrace.current);
    await container.pump();
    final telemetry = container.read(telemetryProvider);
    expect(telemetry.hasError, isTrue);
    expect(
      telemetry.value,
      isNotNull,
      reason: 'sanity: Riverpod retained data',
    );
    final lane = container
        .read(telemetryTrendsProvider)
        .lanes[PidLibrary.engineRpm.id]!;
    expect(lane.currentValue, isNull);
    expect(lane.currentStatus, TelemetryStatus.stale);
    expect(lane.primitives.whereType<TimelineGap>(), hasLength(1));
  });

  test(
    'retained AsyncLoading immediately makes the trend unavailable',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final snapshots = StreamController<TelemetrySnapshot>.broadcast(
        sync: true,
      );
      var elapsedUs = 0;
      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          activePidsProvider.overrideWith(
            () => _FixedActivePids(const [PidLibrary.engineRpm]),
          ),
          telemetryProvider.overrideWith((ref) => snapshots.stream),
          telemetryTrendsClockProvider.overrideWithValue(
            TelemetryTrendsClock(
              nowUtc: () => DateTime.utc(2026, 8, 30),
              elapsedUs: () => ++elapsedUs,
            ),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await snapshots.close();
      });
      final subscription = container.listen(
        telemetryTrendsProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      final at = DateTime.utc(2026, 8, 30);
      snapshots.add(_snapshot(PidLibrary.engineRpm, 2200, at));
      await container.pump();
      container.invalidate(telemetryProvider);
      expect(container.read(telemetryProvider).isLoading, isTrue);
      expect(
        container.read(telemetryProvider).value,
        isNotNull,
        reason: 'sanity: refresh retained the previous snapshot',
      );
      await container.pump();

      final lane = container
          .read(telemetryTrendsProvider)
          .lanes[PidLibrary.engineRpm.id]!;
      expect(lane.currentValue, isNull);
      expect(lane.currentStatus, TelemetryStatus.stale);
      expect(lane.primitives.whereType<TimelineGap>(), hasLength(1));
    },
  );
}

TelemetrySnapshot _snapshot(Pid pid, double value, DateTime at) =>
    TelemetrySnapshot(
      readings: {
        pid.id: Reading(
          pid: pid,
          value: value,
          rawBytes: const [0],
          timestamp: at,
        ),
      },
      capturedAt: at,
    );

class _FixedActivePids extends ActivePids {
  _FixedActivePids(this.value);

  final List<Pid> value;

  @override
  List<Pid> build() => value;
}
