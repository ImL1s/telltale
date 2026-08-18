/// Live telemetry value types shared between the polling engine and the UI.
library;

import 'pid/pid.dart';

/// One evaluated reading.
class Reading {
  final Pid pid;
  final double value;

  /// Raw response bytes the value was computed from, shown in the PID editor's
  /// live preview so the user can see what their formula is acting on.
  final List<int> rawBytes;

  final DateTime timestamp;

  const Reading({
    required this.pid,
    required this.value,
    required this.rawBytes,
    required this.timestamp,
  });

  String get formatted {
    final magnitude = value.abs();
    // Pick decimals by magnitude so a 6500 rpm readout is not "6500.00" and a
    // 0.85 lambda is not "1".
    final decimals = switch (magnitude) {
      >= 1000 => 0,
      >= 100 => magnitude == magnitude.roundToDouble() ? 0 : 1,
      >= 10 => 1,
      _ => 2,
    };
    return value.toStringAsFixed(decimals);
  }

  String get formattedWithUnits =>
      pid.units.isEmpty ? formatted : '$formatted ${pid.units}';

  /// The age past which this value must not be presented as live.
  ///
  /// Derived from the PID's own refresh target rather than one flat number: a
  /// high-priority gauge aiming at 60 ms is visibly wrong after a second, while
  /// a low-priority trip signal legitimately updates every few seconds. The
  /// two-second floor keeps a momentary hiccup from flickering every gauge.
  ///
  /// Without this the dashboard's only test for staleness was `reading ==
  /// null`, so a sensor that stopped answering kept its last believable number
  /// on screen, styled exactly like a live one.
  Duration get maxAge {
    final slack = pid.priority.targetInterval * 8;
    if (slack < const Duration(seconds: 2)) return const Duration(seconds: 2);
    if (slack > const Duration(seconds: 10)) return const Duration(seconds: 10);
    return slack;
  }

  bool isStaleAt(DateTime now) => now.difference(timestamp) > maxAge;
}

/// Why a PID stopped being polled.
enum PidFault {
  /// The vehicle's own support mask says it does not implement this PID.
  ///
  /// The only state that justifies telling the user the car lacks the sensor.
  unsupported,

  formulaError,
  busError,

  /// The PID's header cannot exist on the bus this vehicle actually uses.
  ///
  /// Kept apart from [unsupported], which is a statement about the *car*. This
  /// one is a statement about the *definition*: a three-digit CAN header on a
  /// six-digit legacy bus, or the reverse. Both used to render as
  /// 此車輛不支援, which sends somebody looking at their vehicle for a problem
  /// that is in a field they can edit — and the edit is a ten-second one once
  /// they know.
  headerNotOnThisBus,

  /// The request was never transmitted, because its service is not a read-only
  /// query.
  ///
  /// Kept apart from [unsupported] on the same grounds as [headerNotOnThisBus],
  /// and it is the sharper case of the two: the app declined to ask, so there
  /// is not even a silence from the vehicle to interpret. `02 05` — a Mode 02
  /// request missing its frame number — reached the poller from a definition an
  /// older build had stored, was correctly refused by the safety allowlist, and
  /// was then reported as 此車輛不支援: an assertion about the car with nothing
  /// about the car behind it.
  ///
  /// The refusal itself stands. What the user is told changes: the definition
  /// asks for something a gauge may not send, and that is a field they can fix.
  refusedUnsafeService,

  /// Repeated `NO DATA` with no capability evidence either way.
  ///
  /// The ELM327 generates `NO DATA` itself when nothing arrived before its own
  /// timeout — a busy ECU, a receive filter, or one aggressive timing window
  /// produces it just as well as an absent sensor. Treating a run of them as
  /// proof of absence retired PIDs the vehicle actually had, for the rest of
  /// the session, with no way back short of reconnecting. This one backs off
  /// and tries again.
  noAnswer,
}

/// A snapshot of everything the dashboard needs for one frame.
class TelemetrySnapshot {
  /// Latest reading per PID id.
  final Map<String, Reading> readings;

  /// PIDs the ECU rejected, with the reason. Kept so the PID manager can show
  /// "this car does not have that sensor" rather than silently dropping it.
  final Map<String, PidFault> faults;

  final double pidsPerSecond;
  final bool fastModeEnabled;
  /// Adapter supply voltage, or null when it has not been read or the adapter
  /// reported a value no vehicle produces. Zero would be a claim about the
  /// battery; null is the absence of one.
  final double? batteryVoltage;

  /// Longitudinal acceleration in m/s², differentiated from road speed.
  ///
  /// Needed for the inertial term of the horsepower estimate. Without it the
  /// derived figures only ever account for drag and rolling resistance, which
  /// under-reports badly under acceleration — the one condition where anyone
  /// is looking at a horsepower readout.
  final double? accelerationMs2;

  /// When this snapshot was published.
  ///
  /// Carried on the snapshot rather than read from the clock at build time so
  /// staleness is a property of the data, deterministic in tests, and the same
  /// for every widget rendering the same frame.
  final DateTime? capturedAt;

  const TelemetrySnapshot({
    this.readings = const {},
    this.faults = const {},
    this.pidsPerSecond = 0,
    this.fastModeEnabled = true,
    this.batteryVoltage,
    this.accelerationMs2,
    this.capturedAt,
  });

  Reading? operator [](String pidId) => readings[pidId];

  /// The value, or null when there is none *or* it is too old to be presented
  /// as live.
  ///
  /// Staleness is enforced here rather than at each call site because the
  /// alternative — every consumer remembering to check — is how a sensor that
  /// stopped answering kept feeding the horsepower estimate.
  double? valueOf(Pid pid, {DateTime? now}) {
    final reading = readings[pid.id];
    if (reading == null) return null;
    return reading.isStaleAt(_reference(now)) ? null : reading.value;
  }

  /// True when [pid] has no reading, or one too old to show as live.
  bool isStale(Pid pid, {DateTime? now}) {
    final reading = readings[pid.id];
    if (reading == null) return true;
    return reading.isStaleAt(_reference(now));
  }

  /// The clock staleness is measured against.
  ///
  /// Wall time, not [capturedAt]. Anchoring to the snapshot's own build time
  /// meant a snapshot that stopped being rebuilt could never age: the polling
  /// loop's exception path returns without publishing, and during a protocol
  /// re-search `SEARCHING...` keeps the link looking alive for 25 seconds — so
  /// both timestamps froze together and every gauge stayed at full brightness
  /// showing values from before the trouble started. The one case staleness
  /// exists for is exactly the case where nothing is recomputing it.
  ///
  /// [capturedAt] is still the anchor when it is *ahead* of wall time, which
  /// happens in tests that construct snapshots with explicit clocks — and, in
  /// production, if the device clock steps backwards.
  ///
  /// `DateTime.now()` is not monotonic. An NTP correction mid-drive can jump
  /// it forward, which marks every reading stale for one cycle before the next
  /// publication heals it, or backwards, which puts timestamps in the future
  /// and takes the branch below. Both are visible for a moment and neither
  /// fabricates a value, so the trade is accepted: a monotonic clock would have
  /// to be injected through every constructor and every test, to remove a
  /// flicker. Worth revisiting if it is ever observed on a real drive.
  DateTime _reference(DateTime? now) {
    if (now != null) return now;
    final wall = DateTime.now();
    final at = capturedAt;
    return (at != null && at.isAfter(wall)) ? at : wall;
  }

  TelemetrySnapshot copyWith({
    Map<String, Reading>? readings,
    Map<String, PidFault>? faults,
    double? pidsPerSecond,
    bool? fastModeEnabled,
    DateTime? capturedAt,
    double? batteryVoltage,
    double? accelerationMs2,
  }) {
    return TelemetrySnapshot(
      readings: readings ?? this.readings,
      faults: faults ?? this.faults,
      pidsPerSecond: pidsPerSecond ?? this.pidsPerSecond,
      fastModeEnabled: fastModeEnabled ?? this.fastModeEnabled,
      batteryVoltage: batteryVoltage ?? this.batteryVoltage,
      accelerationMs2: accelerationMs2 ?? this.accelerationMs2,
      capturedAt: capturedAt ?? this.capturedAt,
    );
  }
}
