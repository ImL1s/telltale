/// Bounded live-trend projection for the Dashboard.
library;

import 'dart:async';
import 'dart:collection';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../obd/pid/pid.dart';
import '../obd/telemetry.dart';
import '../telemetry/session/telemetry_session.dart';
import '../telemetry/session/timeline_downsampler.dart';
import 'obd_session.dart';
import 'pid_registry.dart';
import 'telemetry_recorder.dart';

const telemetryTrendPidIdsKey = 'telemetry_trend_pid_ids_v1';
const telemetryTrendWindow = Duration(seconds: 60);
const maximumTelemetryTrendLanes = 4;
const maximumTelemetryTrendPrimitives = 1200;

enum TelemetryTrendSelectionOutcome {
  applied,
  noChange,
  tooMany,
  unavailable,
  storageFailure,
}

final class TelemetryTrendLane {
  TelemetryTrendLane({
    required this.pid,
    required List<TimelinePrimitive> primitives,
    required this.currentValue,
    required this.currentStatus,
  }) : primitives = List<TimelinePrimitive>.unmodifiable(primitives);

  final Pid pid;
  final List<TimelinePrimitive> primitives;
  final double? currentValue;
  final TelemetryStatus? currentStatus;

  bool get isAvailable => currentValue != null && currentStatus == null;
}

final class TelemetryTrendsState {
  TelemetryTrendsState({
    required List<String> selectedIds,
    required Map<String, TelemetryTrendLane> lanes,
    required this.windowEndElapsedUs,
  }) : selectedIds = List<String>.unmodifiable(selectedIds),
       lanes = UnmodifiableMapView<String, TelemetryTrendLane>(lanes);

  factory TelemetryTrendsState.empty() => TelemetryTrendsState(
    selectedIds: const [],
    lanes: const {},
    windowEndElapsedUs: 0,
  );

  final List<String> selectedIds;
  final Map<String, TelemetryTrendLane> lanes;
  final int windowEndElapsedUs;

  int get primitiveCount =>
      lanes.values.fold<int>(0, (sum, lane) => sum + lane.primitives.length);
}

final class TelemetryTrendsClock {
  const TelemetryTrendsClock({required this.nowUtc, required this.elapsedUs});

  final DateTime Function() nowUtc;
  final int Function() elapsedUs;
}

final telemetryTrendsClockProvider = Provider<TelemetryTrendsClock>((ref) {
  final stopwatch = Stopwatch()..start();
  return TelemetryTrendsClock(
    nowUtc: () => DateTime.now().toUtc(),
    elapsedUs: () => stopwatch.elapsedMicroseconds,
  );
});

/// Pure bounded controller; Riverpod below supplies persistence and streams.
final class TelemetryTrendsController {
  TelemetryTrendsController({
    required List<Pid> activePids,
    required List<String>? storedIds,
  }) {
    _active = List<Pid>.unmodifiable(activePids);
    _selectedIds = _resolveSelection(storedIds);
    _syncLanes();
  }

  late List<Pid> _active;
  late List<String> _selectedIds;
  final Map<String, _MutableTrendLane> _lanes = {};
  int _windowEndElapsedUs = 0;

  TelemetryTrendsState get state => TelemetryTrendsState(
    selectedIds: _selectedIds,
    lanes: {
      for (final id in _selectedIds)
        if (_lanes[id] case final lane?) id: lane.snapshot(),
    },
    windowEndElapsedUs: _windowEndElapsedUs,
  );

  bool updateActivePids(List<Pid> activePids) {
    _active = List<Pid>.unmodifiable(activePids);
    final resolved = _resolveSelection(_selectedIds);
    final changed = !_sameIds(resolved, _selectedIds);
    _selectedIds = resolved;
    _syncLanes();
    return changed;
  }

  TelemetryTrendSelectionOutcome setSelectedIds(List<String> ids) {
    final unique = <String>[];
    for (final id in ids) {
      if (!unique.contains(id)) unique.add(id);
    }
    if (unique.length > maximumTelemetryTrendLanes) {
      return TelemetryTrendSelectionOutcome.tooMany;
    }
    final activeIds = _active.map((pid) => pid.id).toSet();
    if (unique.any((id) => !activeIds.contains(id))) {
      return TelemetryTrendSelectionOutcome.unavailable;
    }
    if (_sameIds(unique, _selectedIds)) {
      return TelemetryTrendSelectionOutcome.noChange;
    }
    _selectedIds = List<String>.unmodifiable(unique);
    _syncLanes();
    return TelemetryTrendSelectionOutcome.applied;
  }

  void ingest(
    TelemetrySnapshot snapshot, {
    required DateTime observedAtUtc,
    required int elapsedUs,
  }) {
    if (elapsedUs > _windowEndElapsedUs) _windowEndElapsedUs = elapsedUs;
    final windowStart =
        _windowEndElapsedUs - telemetryTrendWindow.inMicroseconds;
    for (final id in _selectedIds) {
      final lane = _lanes[id]!;
      lane.ingest(
        snapshot,
        observedAtUtc: observedAtUtc.toUtc(),
        elapsedUs: _windowEndElapsedUs,
      );
      lane.pruneAndBound(windowStart);
    }
  }

  List<String> _resolveSelection(List<String>? requested) {
    final byId = <String, Pid>{for (final pid in _active) pid.id: pid};
    final valid = <String>[];
    for (final id in requested ?? const <String>[]) {
      if (byId.containsKey(id) && !valid.contains(id)) valid.add(id);
      if (valid.length == maximumTelemetryTrendLanes) break;
    }
    // Any non-null persisted selection is authoritative after filtering —
    // including "all stored IDs became invalid" (empty after filter) and an
    // explicit empty list. Only a missing preference (`null`) receives the
    // first-run direct-PID default.
    if (requested != null || valid.isNotEmpty || _active.isEmpty) {
      return List.unmodifiable(valid);
    }
    final direct = _active.where(
      (pid) =>
          !pid.isCustom &&
          pid.isMode01 &&
          pid.header == kDefaultHeader &&
          pid.variant == null,
    );
    final fallback = direct
        .take(maximumTelemetryTrendLanes)
        .map((pid) => pid.id);
    return List.unmodifiable(fallback);
  }

  void _syncLanes() {
    final byId = <String, Pid>{for (final pid in _active) pid.id: pid};
    _lanes.removeWhere((id, _) => !_selectedIds.contains(id));
    for (final id in _selectedIds) {
      final pid = byId[id];
      if (pid == null) continue;
      final existing = _lanes[id];
      if (existing == null || !identical(existing.pid, pid)) {
        _lanes[id] = _MutableTrendLane(pid);
      }
    }
  }
}

final class _MutableTrendLane {
  _MutableTrendLane(this.pid);

  final Pid pid;
  List<TimelinePrimitive> primitives = [];
  int? lastSourceTimestampUs;
  TelemetryStatus? lastStatus;
  bool available = false;
  int segment = 0;
  double? currentValue;
  TelemetryStatus? currentStatus;

  void ingest(
    TelemetrySnapshot snapshot, {
    required DateTime observedAtUtc,
    required int elapsedUs,
  }) {
    final reading = snapshot.readings[pid.id];
    final fresh =
        reading != null &&
        reading.value.isFinite &&
        !reading.timestamp.toUtc().isAfter(observedAtUtc) &&
        !reading.isStaleAt(observedAtUtc);
    if (fresh) {
      final timestampUs = reading.timestamp.toUtc().microsecondsSinceEpoch;
      // Same source timestamp after an unavailable interval is usually wall-
      // clock skew making an old sample look fresh again. Reopening without a
      // new TimelineValue invents a second gap when it ages out again.
      if (lastSourceTimestampUs == timestampUs) {
        if (available) {
          currentValue = reading.value;
          currentStatus = null;
          lastStatus = null;
        }
        return;
      }
      currentValue = reading.value;
      currentStatus = null;
      lastStatus = null;
      final breakBefore = !available && lastSourceTimestampUs != null;
      if (breakBefore) segment++;
      primitives.add(
        TimelineValue(
          elapsedUs: elapsedUs,
          value: reading.value,
          segmentId: '${pid.id}-$segment',
          breakBefore: breakBefore,
        ),
      );
      lastSourceTimestampUs = timestampUs;
      available = true;
      return;
    }

    currentValue = null;
    final status = _statusFor(snapshot.faults[pid.id]);
    currentStatus = status;
    if (lastStatus == status && !available) return;
    if (available) {
      primitives.add(
        TimelineGap(elapsedUs: elapsedUs, gapId: '${pid.id}-gap-$segment'),
      );
    }
    primitives.add(
      TimelineStatus(elapsedUs: elapsedUs, status: status.wireName),
    );
    lastStatus = status;
    available = false;
  }

  void pruneAndBound(int windowStartElapsedUs) {
    if (primitives.isNotEmpty) {
      primitives = primitives
          .where((primitive) => primitive.elapsedUs >= windowStartElapsedUs)
          .toList(growable: true);
    }
    if (primitives.length > maximumTelemetryTrendPrimitives) {
      primitives = downsampleTimeline(
        primitives,
        maximumPrimitives: maximumTelemetryTrendPrimitives,
      ).toList(growable: true);
    }
  }

  TelemetryTrendLane snapshot() => TelemetryTrendLane(
    pid: pid,
    primitives: primitives,
    currentValue: currentValue,
    currentStatus: currentStatus,
  );

  static TelemetryStatus _statusFor(PidFault? fault) => switch (fault) {
    null => TelemetryStatus.stale,
    PidFault.unsupported => TelemetryStatus.unsupported,
    PidFault.noAnswer => TelemetryStatus.noAnswer,
    PidFault.formulaError => TelemetryStatus.formulaError,
    PidFault.busError => TelemetryStatus.busError,
    PidFault.headerNotOnThisBus => TelemetryStatus.headerMismatch,
    PidFault.refusedUnsafeService => TelemetryStatus.unsafeServiceRefusal,
  };
}

bool _sameIds(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

class TelemetryTrendsNotifier extends Notifier<TelemetryTrendsState> {
  late final TelemetryTrendsController _controller;

  void _ingest(AsyncValue<TelemetrySnapshot> telemetry) {
    final clock = ref.read(telemetryTrendsClockProvider);
    _controller.ingest(
      authoritativeTelemetryValue(telemetry) ?? const TelemetrySnapshot(),
      observedAtUtc: clock.nowUtc(),
      elapsedUs: clock.elapsedUs(),
    );
  }

  @override
  TelemetryTrendsState build() {
    final preferences = ref.read(sharedPreferencesProvider);
    _controller = TelemetryTrendsController(
      activePids: ref.read(activePidsProvider),
      storedIds: preferences.getStringList(telemetryTrendPidIdsKey),
    );
    ref.listen<List<Pid>>(activePidsProvider, (_, next) {
      final changed = _controller.updateActivePids(next);
      state = _controller.state;
      if (changed) {
        unawaited(
          ref
              .read(sharedPreferencesProvider)
              .setStringList(telemetryTrendPidIdsKey, state.selectedIds),
        );
      }
    });
    ref.listen<AsyncValue<TelemetrySnapshot>>(telemetryProvider, (_, next) {
      _ingest(next);
      state = _controller.state;
    });
    _ingest(ref.read(telemetryProvider));
    return _controller.state;
  }

  Future<TelemetryTrendSelectionOutcome> setSelectedIds(
    List<String> ids,
  ) async {
    final outcome = _controller.setSelectedIds(ids);
    if (outcome != TelemetryTrendSelectionOutcome.applied) return outcome;
    state = _controller.state;
    final saved = await ref
        .read(sharedPreferencesProvider)
        .setStringList(telemetryTrendPidIdsKey, state.selectedIds);
    return saved ? outcome : TelemetryTrendSelectionOutcome.storageFailure;
  }
}

final telemetryTrendsProvider =
    NotifierProvider<TelemetryTrendsNotifier, TelemetryTrendsState>(
      TelemetryTrendsNotifier.new,
    );
