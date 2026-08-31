import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torque_obd/obd/pid/pid.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
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
