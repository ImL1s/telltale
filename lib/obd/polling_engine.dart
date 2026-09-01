/// The polling loop: turns a connected [Elm327Client] into a stream of
/// evaluated telemetry.
///
/// Each cycle pulls the highest-priority batch off the scheduler, sends it as
/// one frame where fastMode allows, splits the reply back into per-PID slices,
/// evaluates each formula and publishes a snapshot. PIDs that the ECU rejects
/// are struck off so the loop stops paying for them.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import 'addressing.dart';
import 'dtc/dtc.dart';
import 'freeze_frame.dart';
import 'readiness.dart';
import 'elm327_client.dart';
import 'physics/physics_engine.dart';
import 'pid/formula_engine.dart';
import 'pid/pid.dart';
import 'pid/pid_library.dart';
import 'pid/priority_scheduler.dart';
import 'telemetry.dart';
import 'transport/obd_transport.dart';

/// What a Mode 04 clear actually achieved.
///
/// A boolean could not say the thing that matters most. `7E8 01 44` followed
/// by `<RX ERROR>` returned false and the screen read 清除失敗，ECU 未接受指令
/// — but `44` is the J1979 completion byte, so that controller *did* erase its
/// fault memory. Telling somebody it failed invites a second global clear,
/// which reaches the module that already succeeded and resets its readiness
/// monitors again, costing the vehicle another drive cycle before it can pass
/// an emissions test.
///
/// Three states, because there are three: it worked, something worked and the
/// rest is unknown, and nothing worked.
enum ClearOutcome {
  /// Every known controller returned exactly `44`.
  confirmed,

  /// At least one controller returned `44`, and the rest could not be
  /// confirmed — a damaged exchange, a refusal, a silence.
  ///
  /// The command is on the wire and part of the vehicle has acted on it.
  /// Repeating it is the one thing that must not be recommended.
  partiallyConfirmed,

  /// The command went out and nothing readable came back.
  ///
  /// Distinct from [notAccepted], and the distinction is the whole reason this
  /// value exists: an exchange the adapter marked damaged is *unknown*, not
  /// refused. A controller may have erased its memory and had its reply
  /// destroyed on the way back, so a blind repeat can still cost a drive
  /// cycle — but treating it as permanently harmful would strand somebody who
  /// genuinely could not clear at all. A rescan is what turns it into an
  /// answer, and a rescan is what the screen asks for before the button comes
  /// back.
  sentUnconfirmed,

  /// Nothing was transmitted to the vehicle at all.
  ///
  /// The adapter said so legibly and in its own voice: it did not understand
  /// the command (`?`), could not connect to the bus, or failed to initialise
  /// it. That is positive evidence nothing was erased, which is what makes
  /// trying again free.
  ///
  /// Deliberately *not* the destination for a reply this app cannot read. A
  /// malformed answer arrived on an exchange that did reach the vehicle, so it
  /// is [sentUnconfirmed] — anything else treats intact-looking damage as
  /// safer to repeat than damage the adapter admitted to.
  notAccepted;

  /// Whether the app may tell the user the vehicle was cleared.
  bool get isSuccess => this == ClearOutcome.confirmed;

  /// Whether re-sending a global clear could reach a controller that may
  /// already have finished.
  bool get repeatWouldHarm =>
      this == ClearOutcome.partiallyConfirmed ||
      this == ClearOutcome.sentUnconfirmed;
}

/// What one controller says about its own fault memory, via Mode 01 PID 01.
///
/// Byte A of the J1979 response: bit 7 is the malfunction indicator lamp, bits
/// 0 to 6 the number of confirmed emissions-related fault codes.
///
/// Per controller, not per vehicle. The count is each module's own — the
/// datasheet's example is one module's reply — so combining several modules'
/// counts with `max` reported a number no controller had claimed and made the
/// figure impossible to check against any one module's Mode 03 answer. Keeping
/// them apart is what lets the scan ask the only question worth asking: does
/// *this* controller's summary agree with *this* controller's fault codes.
class MilSummary {
  const MilSummary({
    required this.milOn,
    required this.confirmedCount,
    this.readiness,
  });

  /// The emissions readiness monitors from the same reply.
  ///
  /// Null only when the reply was too short to carry them — which the caller
  /// already refuses, so in practice this is present whenever the summary is.
  /// Kept nullable rather than required because a summary is a claim about a
  /// fault and the monitors are a claim about a test schedule; a future caller
  /// that has one and not the other should not have to invent the other.
  final Readiness? readiness;

  /// Whether this controller commands the dashboard fault lamp on.
  final bool milOn;

  /// How many confirmed emissions codes this controller says it holds.
  final int confirmedCount;

  /// Whether this controller is claiming a fault by either measure.
  bool get claimsFault => milOn || confirmedCount > 0;

  @override
  String toString() => 'MilSummary(mil: $milOn, count: $confirmedCount)';
}

/// Every controller's Mode 01 PID 01 summary from one exchange.
class MilStatus {
  const MilStatus(this.bySource);

  /// Keyed by responding controller. A reply with no identifiable source is
  /// not here at all: an unattributed summary cannot be checked against any
  /// controller's fault codes, and a whole-vehicle claim built on one would be
  /// exactly the kind this app refuses.
  final Map<String, MilSummary> bySource;

  /// Whether any controller commands the lamp on.
  bool get milOn => bySource.values.any((s) => s.milOn);

  /// Whether any controller claims a fault.
  bool get claimsFault => bySource.values.any((s) => s.claimsFault);

  /// The sum across controllers, which is what "how many confirmed codes does
  /// this vehicle hold" actually means — each module counts its own.
  int get totalConfirmed =>
      bySource.values.fold(0, (sum, s) => sum + s.confirmedCount);

  @override
  String toString() => 'MilStatus($bySource)';
}

enum ObdCapabilityDiscoveryPhase {
  notStarted,
  running,
  attemptFinished,
  interrupted,
}

enum PidCapabilityStatus { positive, unsupported, unknown }

/// Immutable evidence snapshot for one connection's Mode 01 capability scan.
///
/// A mask answer proves only the engine controller's wire PID. A direct value
/// answer may additionally prove the exact definition that produced it, but it
/// never extends support-block coverage.
final class ObdCapabilitySummary {
  ObdCapabilitySummary({
    required this.phase,
    required Iterable<String> verifiedBlockIds,
    required Iterable<String> supportedMode01Requests,
    required Iterable<String> directlyAnsweredDefinitionIds,
  }) : verifiedBlockIds = Set<String>.unmodifiable(
         verifiedBlockIds.map((value) => value.toUpperCase()),
       ),
       _supportedMode01Requests = Set<String>.unmodifiable(
         supportedMode01Requests.map((value) => value.toUpperCase()),
       ),
       _directlyAnsweredDefinitionIds = Set<String>.unmodifiable(
         directlyAnsweredDefinitionIds.map(Pid.canonicalId),
       );

  factory ObdCapabilitySummary.notStarted() => ObdCapabilitySummary(
    phase: ObdCapabilityDiscoveryPhase.notStarted,
    verifiedBlockIds: const <String>{},
    supportedMode01Requests: const <String>{},
    directlyAnsweredDefinitionIds: const <String>{},
  );

  final ObdCapabilityDiscoveryPhase phase;
  final Set<String> verifiedBlockIds;
  final Set<String> _supportedMode01Requests;
  final Set<String> _directlyAnsweredDefinitionIds;

  int get unknownOrUnverifiedBlockCount {
    var unknown = 0;
    for (final query in PidLibrary.supportQueries) {
      if (!verifiedBlockIds.contains(query)) {
        unknown++;
        continue;
      }
      final base = int.parse(query.substring(2), radix: 16);
      final continuation =
          '01${(base + 0x20).toRadixString(16).toUpperCase().padLeft(2, '0')}';
      if (!_supportedMode01Requests.contains(continuation)) break;
    }
    return unknown;
  }

  List<String> get contiguousVerifiedBlockIds {
    final result = <String>[];
    for (final query in PidLibrary.supportQueries) {
      if (!verifiedBlockIds.contains(query)) break;
      result.add(query);
      final base = int.parse(query.substring(2), radix: 16);
      final continuation =
          '01${(base + 0x20).toRadixString(16).toUpperCase().padLeft(2, '0')}';
      if (!_supportedMode01Requests.contains(continuation)) break;
    }
    return List<String>.unmodifiable(result);
  }

  int? get contiguousCoverageThroughPid {
    final blocks = contiguousVerifiedBlockIds;
    if (blocks.isEmpty) return null;
    return int.parse(blocks.last.substring(2), radix: 16) + 0x20;
  }

  bool get contiguousCoverageReachedVerifiedTerminal {
    final blocks = contiguousVerifiedBlockIds;
    if (blocks.isEmpty) return false;
    final base = int.parse(blocks.last.substring(2), radix: 16);
    final continuation =
        '01${(base + 0x20).toRadixString(16).toUpperCase().padLeft(2, '0')}';
    return !_supportedMode01Requests.contains(continuation);
  }

  PidCapabilityStatus statusFor(Pid pid) {
    if (_directlyAnsweredDefinitionIds.contains(Pid.canonicalId(pid.id))) {
      return PidCapabilityStatus.positive;
    }
    if (!pid.isMode01 || !BusAddressing.isAppDefault(pid.header)) {
      return PidCapabilityStatus.unknown;
    }
    final block = PidLibrary.supportBlockFor(pid.modeAndPid);
    if (block == null || !verifiedBlockIds.contains(block)) {
      return PidCapabilityStatus.unknown;
    }
    return _supportedMode01Requests.contains(pid.modeAndPid.toUpperCase())
        ? PidCapabilityStatus.positive
        : PidCapabilityStatus.unsupported;
  }

  List<Pid> get positivelyConfirmedShippedDirectPids => List<Pid>.unmodifiable(
    PidLibrary.all.where(
      (pid) =>
          !pid.isCustom &&
          pid.isMode01 &&
          pid.header == kDefaultHeader &&
          pid.variant == null &&
          statusFor(pid) == PidCapabilityStatus.positive,
    ),
  );
}

class PollingEngine {
  PollingEngine(
    this.client, {
    FormulaEngine? formulaEngine,
    PriorityScheduler? scheduler,
  }) : formula = formulaEngine ?? FormulaEngine(),
       scheduler = scheduler ?? PriorityScheduler();

  final Elm327Client client;
  final FormulaEngine formula;
  final PriorityScheduler scheduler;

  final _snapshots = StreamController<TelemetrySnapshot>.broadcast();
  final _capabilitySummaries = StreamController<ObdCapabilitySummary>.broadcast(
    sync: true,
  );
  final Map<String, Reading> _readings = {};
  final Map<String, PidFault> _faults = {};

  List<Pid> _active = const [];
  Set<String>? _supported;
  ObdCapabilityDiscoveryPhase _capabilityPhase =
      ObdCapabilityDiscoveryPhase.notStarted;
  int _capabilityDiscoveryEpoch = 0;
  bool _running = false;

  Stream<TelemetrySnapshot> get snapshots => _snapshots.stream;

  TelemetrySnapshot get current => TelemetrySnapshot(
    readings: Map.unmodifiable(_readings),
    faults: Map.unmodifiable(_faults),
    pidsPerSecond: scheduler.stats.pidsPerSecond,
    fastModeEnabled: scheduler.fastModeEnabled,
    batteryVoltage: client.batteryVoltage,
    accelerationMs2: accelerationMs2,
    capturedAt: DateTime.now(),
  );

  /// Smoothed longitudinal acceleration derived from road speed.
  ///
  /// OBD speed is a whole number of km/h, so raw differentiation is a staircase
  /// — a 1 km/h step over a 100 ms sample is 2.8 m/s², roughly a hard launch,
  /// from a car holding a steady cruise. The EMA is what makes the derived
  /// horsepower readable rather than a strobe.
  final EmaFilter _acceleration = EmaFilter(alpha: 0.18);
  double? _lastSpeedKmh;
  DateTime? _lastSpeedAt;
  DateTime? _accelerationAt;

  /// Longest gap after which the smoothed figure no longer describes now.
  static const Duration accelerationMaxAge = Duration(seconds: 2);

  /// Smoothed longitudinal acceleration, or null when it is not known.
  ///
  /// Null rather than zero. Zero is "steady cruise", a real measurement, and
  /// exporting it whenever speed had not been read let the physics strip pair
  /// an absent value with fresh RPM and present the product as current power.
  double? get accelerationMs2 {
    if (!_acceleration.isSeeded) return null;
    final at = _accelerationAt;
    if (at == null) return null;
    if (DateTime.now().difference(at) > accelerationMaxAge) return null;
    return _acceleration.value;
  }

  /// Forgets the smoothed history and the speed baseline.
  ///
  /// Called wherever continuity breaks. A derivative is a statement about two
  /// moments; if the app was not watching between them it has nothing to say.
  void _resetAcceleration() {
    _acceleration.reset();
    _accelerationAt = null;
    _lastSpeedKmh = null;
    _lastSpeedAt = null;
  }

  /// Feeds one speed sample to the acceleration tracker.
  ///
  /// A seam, because the interesting behaviour is about the *spacing* of
  /// samples and driving that through the poller means controlling an
  /// adapter's round-trip time — which is the one thing a fake cannot make
  /// faithful. The bug this exposes was invisible for four review rounds
  /// precisely because the simulator's timing sits on the threshold.
  @visibleForTesting
  void trackAccelerationForTest(double speedKmh, DateTime at) =>
      _trackAcceleration(speedKmh, at);

  void _trackAcceleration(double speedKmh, DateTime at) {
    final previousSpeed = _lastSpeedKmh;
    final previousAt = _lastSpeedAt;
    if (previousSpeed == null || previousAt == null) {
      _lastSpeedKmh = speedKmh;
      _lastSpeedAt = at;
      return;
    }

    final dt = at.difference(previousAt).inMicroseconds / 1e6;
    if (dt > 3) {
      // A gap. Updating the baseline and returning left the EMA holding a
      // value from before it: a hard launch that ended four seconds ago was
      // still exported as +2 m/s², combined with a fresh 60 km/h cruise, and
      // shown as current horsepower until later samples decayed it away.
      _acceleration.reset();
      _accelerationAt = null;
      _lastSpeedKmh = speedKmh;
      _lastSpeedAt = at;
      return;
    }

    // Too short and quantisation dominates — OBD speed is whole km/h.
    //
    // **The baseline stays where it is.** Advancing it before this check, which
    // is what this did, defeated the check with itself: every sample became the
    // new reference, so the interval could never grow past the threshold, so on
    // a link fast enough to deliver speed more often than every 80 ms the EMA
    // was never updated at all. `accelerationMs2` then aged out after two
    // seconds and the whole derived row — power, torque, fuel rate, airflow —
    // went to 「等待引擎轉速與車速資料」 while the rev counter and speedometer
    // above it were plainly moving.
    //
    // The relationship that gives it away is backwards: the better the adapter,
    // the emptier the panel. The simulator sits at roughly 78–98 ms, either
    // side of the threshold, which is why nothing here ever caught it — and why
    // a real adapter that is merely *quick* is worse off than the fake one.
    if (dt < 0.08) return;

    _lastSpeedKmh = speedKmh;
    _lastSpeedAt = at;
    final dv = (speedKmh - previousSpeed) * PhysicsEngine.kmhToMs;
    _acceleration.update(dv / dt);
    _accelerationAt = at;
  }

  bool get isRunning => _running;

  /// PIDs the ECU reported as supported, or null before discovery has run.
  Set<String>? get supportedPids => _supported;

  ObdCapabilitySummary get capabilitySummary => ObdCapabilitySummary(
    phase: _capabilityPhase,
    verifiedBlockIds: _verifiedSupportBlocks,
    supportedMode01Requests: _supported ?? const <String>{},
    directlyAnsweredDefinitionIds: _answeredAtLeastOnce,
  );

  Stream<ObdCapabilitySummary> get capabilitySummaries =>
      _capabilitySummaries.stream;

  void _publishCapabilitySummary() {
    if (!_capabilitySummaries.isClosed) {
      _capabilitySummaries.add(capabilitySummary);
    }
  }

  /// Replaces the polling set. Safe to call while running.
  ///
  /// Profile-derived inputs are merged only after the driver confirms the
  /// complete vehicle assumptions. Until then, only speed and the ECU's own
  /// fuel-rate PID are supplemental: they can produce a profile-independent
  /// measured consumption figure without spending legacy-bus bandwidth on
  /// hidden MAP/MAF speed-density inputs.
  void setActivePids(
    List<Pid> pids, {
    bool includeProfileDerivedInputs = true,
    Set<String> authorizedProfilePidIds = const {},
  }) {
    // The definition set gets its own generation, separate from the polling
    // epoch. Clearing the formula cache when definitions change is right and
    // was not enough: a removed variant's reply is often already in flight,
    // and it landed in the freshly cleared cache as the sole value for its
    // header and PID — after which a dependent `VAL{}` formula consumed the
    // removed definition as unambiguous truth for the cache's whole lifetime.
    //
    // Two variants of `7E0:010B`, `A` and `A*10`, with a third gauge reading
    // `VAL{010B}`: remove the second while its request is outstanding and its
    // reply caches 100 under a key whose only surviving definition says 10.
    // Plausible, and usable for five seconds.
    _definitions++;
    // A catalog/profile PID polls only under the session's explicit,
    // per-connection authorization, named PID by PID. A legacy preference or
    // a forged caller that merely marks a definition profile-owned is still
    // rejected: the poller trusts the id set its owner handed it for this
    // exact definition change, never the definitions themselves.
    // Experimental profile reads stay on their own one-shot probe path with
    // per-command consent.
    //
    // The *object* is remembered, not just the id. A profile PID's id is
    // built from ownerProfileId + sourceSignalId alone, so a forged queued
    // definition could collide with an authorized id while carrying its own
    // modeAndPid, header and formula — and an id-membership check would have
    // waved its bytes onto the wire under the user's grant. The sink guard
    // therefore requires the exact authorized instance.
    final rejectedProfiles = <String, Pid>{
      for (final pid in pids)
        if (pid.ownerProfileId != null &&
            !authorizedProfilePidIds.contains(pid.id))
          pid.id: pid,
    };
    final merged = <String, Pid>{
      for (final pid in pids)
        if (pid.ownerProfileId == null ||
            authorizedProfilePidIds.contains(pid.id))
          pid.id: pid,
    };
    _authorizedProfileDefinitions = Map.unmodifiable({
      for (final pid in merged.values)
        if (pid.ownerProfileId != null) pid.id: pid,
    });

    // Requests already queued were built from the definitions being replaced.
    // Stamping the generation stopped an *in-flight* reply from writing back,
    // and left the queue itself full of work nobody asked for any more — a
    // removed variant's request still gets sent, still costs a cycle on the
    // bus, and still lands in a cache that was cleared for it. Retired here,
    // where the definitions change, so the next cycle rebuilds from what is
    // actually active.
    final supplemental = includeProfileDerivedInputs
        ? PidLibrary.physicsInputs
        : const [PidLibrary.vehicleSpeed, PidLibrary.engineFuelRate];
    for (final required in supplemental) {
      merged.putIfAbsent(required.id, () => required);
    }
    _scheduleFormulaDependencies(merged);
    // After the merge, not before it. The physics inputs and the formula
    // dependencies are part of what is active, and retiring against the raw
    // dashboard set dropped every queued one of them on each edit — so
    // changing a gauge's name restarted the schedule for speed, MAP and the
    // rest, which is the churn this was written to avoid.
    scheduler.retireQueuedRequests(merged);
    _active = List.unmodifiable(merged.values);

    // Ambiguity is a property of what is being polled, so it is recomputed
    // with the poll set. Two definitions of one hex on one controller make a
    // `VAL{}` reference unresolvable — but removing one of them from the
    // dashboard resolves it again, and an add-only record would have kept the
    // reference dead for the rest of the session.
    formula.clearCache();

    // Drop faults for PIDs no longer polled so re-adding one retries it.
    final activeIds = {...merged.keys, ...rejectedProfiles.keys};
    _faults.removeWhere((id, _) => !activeIds.contains(id));
    for (final pid in rejectedProfiles.values) {
      _invalidate(pid.id, PidFault.refusedUnsafeService);
    }
  }

  /// Adds the PIDs that the active formulas reference but nobody polls.
  ///
  /// Only the hard-coded physics inputs were ever scheduled, so a formula's own
  /// dependencies were left to chance: the built-in boost gauge is
  /// `A-VAL{0133}`, and putting it on the dashboard alone produced a permanent
  /// formula error because nothing ever requested `0133`. `BARO` has the same
  /// problem and is worse, because it used to resolve to sea level instead of
  /// failing.
  ///
  /// Dependencies are scheduled on the *requesting* PID's controller, matching
  /// how `VAL{}` now resolves. A reference the built-in library does not know
  /// is left alone — the formula will report it as unavailable, which is the
  /// truth and is visible, rather than being silently satisfied by some other
  /// controller's value.
  void _scheduleFormulaDependencies(Map<String, Pid> merged) {
    // A worklist rather than one pass over a snapshot. A dependency can have
    // dependencies — `A-VAL{X}` where X is itself defined as `B-VAL{Y}` — and
    // scheduling only the first level leaves the chain broken one link down,
    // which presents as a formula error on a gauge whose own reference *was*
    // satisfied.
    //
    // `visited` also makes a cycle terminate. `A` referencing `B` referencing
    // `A` is a definition a user can write, and it must not hang the poll set
    // being assembled.
    final queue = [...merged.values];
    final visited = <String>{};

    while (queue.isNotEmpty) {
      final pid = queue.removeLast();
      if (!visited.add(pid.id)) continue;

      final equation = pid.equation.toUpperCase();
      final wanted = <String>{
        ...FormulaEngine.valReferences(equation),
        if (equation.contains('BARO')) PidLibrary.barometricPressure.modeAndPid,
      };
      for (final hex in wanted) {
        final definition = PidLibrary.byModeAndPid(hex);
        if (definition == null) continue;
        final onSameController = definition.header == pid.header
            ? definition
            : definition.copyWith(header: pid.header);
        if (merged.containsKey(onSameController.id)) continue;
        merged[onSameController.id] = onSameController;
        queue.add(onSameController);
      }
    }
  }

  /// Asks the ECU which Mode 01 PIDs it answers (`0100`, `0120`, ...).
  ///
  /// Each reply is a 32-bit mask whose lowest bit says whether the next block
  /// exists, so the walk stops as soon as a block declines to continue.
  /// Asked before each block, so a paused session stops discovering too.
  bool Function()? shouldContinue;

  /// True once every support block has either answered or been asked and
  /// failed, so nothing is left to learn from a repeat.
  bool get supportDiscoveryComplete => _discoveryAttempted;
  bool _discoveryAttempted = false;

  /// The lifecycle epoch a long operation belongs to.
  ///
  /// `mayTransmit` asks "is this session in the foreground *right now*", which
  /// is a sample and not an ownership claim. An operation that expired while
  /// the app was away passes that gate the moment the app returns: a Mode 03
  /// retry sleeping two seconds across a background-and-resume wakes up, finds
  /// the app in front of someone again, and transmits on behalf of a scan
  /// whose screen is long gone.
  ///
  /// The poll loop does not need this — a pause calls `stop()`, which retires
  /// it by epoch. The fault-code operations run outside that loop and had
  /// nothing.
  int Function()? lifecycleEpoch;

  /// Refuses an exchange there is no longer time to finish.
  ///
  /// The deadline used to be consulted only when deciding whether to sleep and
  /// retry, so a category entered with ten milliseconds left still opened a
  /// full global exchange — `ATH1`, `ATSH 7DF`, the mode, and the `ATH0`
  /// restore — and the caller's `.timeout()` then detached it. The screen said
  /// the scan had finished while the app was still transmitting, and an
  /// immediate rescan queued behind work the UI had disowned.
  ///
  /// A global exchange is four commands, so anything less than one command
  /// timeout is not enough to start one, never mind finish it.
  void _requireTimeToWork(DateTime? deadline) {
    if (deadline == null) return;
    // A cheap early-out, and only that. It bars an exchange that cannot fit
    // even one response window; the transaction is four commands and their sum
    // is not knowable in advance, so sizing this against the whole thing would
    // refuse work that would have finished. What it used to be doing was
    // guarding the *whole* exchange with one command's budget and then handing
    // over to nothing — `Future.timeout` on the caller's side cannot cancel a
    // command chain, so a scan that had reported a category finished went on
    // transmitting it. The deadline is now carried into every write, which is
    // where that has to be enforced; this line just avoids starting work with
    // no chance at all.
    if (DateTime.now().add(client.globalTimeout).isBefore(deadline)) return;
    throw const DtcReadException(
      '掃描已達時間上限，這個項目沒有開始查詢。請重新掃描。',
      kind: DtcReadFailure.noAnswer,
    );
  }

  void _requireStillOwned(
    int? captured, {
    String? message,
    bool repeatWouldHarm = false,
  }) {
    if (captured == null) return;
    if (lifecycleEpoch?.call() == captured) return;
    throw DtcReadException(
      message ?? '這次操作在中途被中斷（App 退到背景或連線變更），已停止。請重新操作。',
      kind: DtcReadFailure.disconnected,
      repeatWouldHarm: repeatWouldHarm,
    );
  }

  /// Controllers that answered the vehicle-wide capability probe.
  ///
  /// Attribution establishes *who answered*. It never established *who should
  /// have*, and a controller that stays entirely silent contributes to no
  /// count at all — not to `answered`, not to `refused`, not to
  /// `pendingSources`. So a transmission with a stored P0715 that simply does
  /// not reply leaves the engine's clean `43 00` as the only evidence, and the
  /// screen says 未偵測到故障碼 over a green panel.
  ///
  /// `0100` is a functional request and every emissions-related controller
  /// answers it, so with headers on it is a census. Taken once per connection,
  /// against the vehicle that is actually attached.
  ///
  /// Null means no census was possible — an adapter that will not print
  /// headers — which is a different claim from an empty one and is not used to
  /// convict anybody.
  Set<String>? _responders;

  /// Whether a census has been attempted at all.
  ///
  /// Separate from [_responders] being null, which conflated "never asked"
  /// with "asked and got nothing" — and those deserve opposite answers.
  bool _censusAttempted = false;

  /// Controllers known to be on this bus, or null if that was never
  /// established.
  Set<String>? get responders => _responders;

  Future<Set<String>?>? _censusInFlight;

  /// Takes the responder census, joining one already running.
  ///
  /// Coalesced for the same reason discovery is, and *awaitable* for a
  /// sharper one: the census is fired unawaited at connect, and a fault-code
  /// scan started before it lands finds `_responders` still null — which skips
  /// the silence check entirely and restores the exact false all-clear the
  /// census exists to prevent. A caller that needs the answer has to be able
  /// to wait for it.
  ///
  /// [deadline] is the caller's whole-operation budget. A scan advertises 45
  /// seconds and used to spend an unbounded amount of time here first, because
  /// the census was awaited before that budget was even captured — so a slow
  /// adapter's four-command exchange was free. It is the same window every
  /// other exchange is measured against and there is no reason this one is
  /// exempt.
  ///
  /// A census already in flight is joined rather than re-issued, so a second
  /// caller's deadline cannot shorten the first one's exchange. The caller
  /// rechecks its own ownership afterwards, which is the part that matters.
  Future<Set<String>?> discoverResponders({DateTime? deadline}) {
    final running = _censusInFlight;
    if (running != null) {
      // Joined, not restarted — but not waited on past the joiner's own
      // budget either. The census fired at connect carries no deadline, and a
      // scan that arrives a moment later used to inherit that: its 45 seconds
      // never bound the exchange it was blocked on, so an adapter dribbling
      // `7F 01 78` at the handshake held the scan indefinitely while the
      // screen showed its own advertised limit.
      //
      // The census keeps running for whoever started it. This caller simply
      // stops waiting and proceeds on the evidence it has, which is what the
      // scan path already does with a census that fails.
      if (deadline == null) return running;
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) return Future.value(_responders);
      return running.timeout(left, onTimeout: () => _responders);
    }
    final started = _discoverRespondersOnce(deadline);
    _censusInFlight = started;
    return started.whenComplete(() {
      if (identical(_censusInFlight, started)) _censusInFlight = null;
    });
  }

  Future<Set<String>?> _discoverRespondersOnce(DateTime? deadline) async {
    // One policy, every consumer. J1939 was refused here and an *unidentified*
    // bus was not, so a protocol B slot whose PP 2C could not be read had its
    // fault-code reads refused while these probes went on sending `0100` — and
    // the poll loop went on publishing whatever came back. PP 2C format `000`
    // means no formatting at all, so those bytes can look like a J1979 reply
    // and become a plausible 1726 rpm.
    if (!client.addressing.supportsObd2) return _responders;
    final owner = lifecycleEpoch?.call();
    _requireStillOwned(owner);
    _requireTimeToWork(deadline);
    _censusAttempted = true;
    final ObdResponse response;
    try {
      response = await client.sendGlobal(
        '0100',
        owner: owner,
        deadline: deadline,
      );
    } on Object {
      return _responders;
    }
    if (!response.isSuccess || !response.headersEnabled) return _responders;

    // A responder is a controller that answered *this* request, in the shape
    // this request has an answer in.
    //
    // Crediting every parsed frame let a headerless line that the parser had
    // split into an invented header establish a controller — and an eight-bit
    // checksum cannot rule that out, because a fabricated split's last byte
    // collides with its own sum roughly once in 256. `41 00 BE 1F A8 C6` is
    // one such line: it is not a `0100` response at all, and it registered
    // controller `BE`, after which every DTC class from `BE` read clean and
    // the screen showed a verified all-clear for a car with three codes on the
    // wire.
    //
    // The shape is not a heuristic: a positive Mode 01 PID 00 response is
    // `41 00` followed by the four-byte support mask.
    final seen = <String>{
      for (final frame in response.frames)
        if (frame.sourceId != null &&
            frame.bytes.length >= 6 &&
            frame.bytes[0] == 0x41 &&
            frame.bytes[1] == 0x00)
          frame.sourceId!,
    };
    // Never narrowed by a later, worse probe: a controller that answered once
    // exists, and a reply that missed it is evidence about the reply.
    if (seen.isNotEmpty) {
      _responders = Set.unmodifiable({...?_responders, ...seen});
    }
    return _responders;
  }

  /// The discovery currently running, so a second caller joins it rather than
  /// starting a rival.
  Future<Set<String>>? _discoveryInFlight;

  /// Runs support discovery, coalescing concurrent callers.
  ///
  /// The initial discovery is unawaited and a resume starts another, so two
  /// could overlap — and each used to take a local snapshot of `_supported` at
  /// entry and assign it back wholesale at the end. The later finisher won,
  /// whatever it had learned:
  ///
  /// Discovery A is awaiting a slow `0120`. The app pauses and resumes.
  /// Discovery B starts on a snapshot that predates A's results, transiently
  /// times out on `0100` and `0120`, succeeds on a later block, and finishes
  /// last. `_supported` loses every bit A had established — while
  /// `_verifiedSupportBlocks`, which is shared and additive, still says those
  /// blocks were verified. `_knownUnsupported` then declares every PID in them
  /// absent from the vehicle, on the strength of positive evidence that only
  /// the race destroyed.
  ///
  /// Coalescing removes the overlap; accumulating into the shared set instead
  /// of assigning a snapshot removes the erasure even if one ever reappeared.
  Future<Set<String>> discoverSupportedPids() {
    final running = _discoveryInFlight;
    if (running != null) return running;
    final started = _discoverSupportedPidsOnce();
    _discoveryInFlight = started;
    return started.whenComplete(() {
      if (identical(_discoveryInFlight, started)) _discoveryInFlight = null;
    });
  }

  Future<Set<String>> _discoverSupportedPidsOnce() async {
    final attemptEpoch = ++_capabilityDiscoveryEpoch;
    _capabilityPhase = ObdCapabilityDiscoveryPhase.running;
    _publishCapabilitySummary();
    // One policy, every consumer. J1939 was refused here and an *unidentified*
    // bus was not, so a protocol B slot whose PP 2C could not be read had its
    // fault-code reads refused while these probes went on sending `0100` — and
    // the poll loop went on publishing whatever came back. PP 2C format `000`
    // means no formatting at all, so those bytes can look like a J1979 reply
    // and become a plausible 1726 rpm.
    if (!client.addressing.supportsObd2) {
      _capabilityPhase = ObdCapabilityDiscoveryPhase.attemptFinished;
      _discoveryAttempted = true;
      _publishCapabilitySummary();
      return _supported ??= <String>{};
    }

    // Accumulated, not reset. Clearing up front and then breaking out —
    // which a pause does — left the verified set permanently empty, so
    // batching never opened and fast mode was dead for the session. That is
    // the failure the batching gate exists to prevent, re-entered through the
    // pause that was added to stop discovery running in the background.
    //
    // Resuming re-runs this; a block that already answered is simply
    // re-confirmed, and one that never did gets another chance.
    // The shared set itself, mutated in place. A local copy assigned back at
    // the end is what let a slow run overwrite a fast one's findings.
    final supported = _supported ??= <String>{};
    var completed = true;

    for (final query in PidLibrary.supportQueries) {
      // Discovery has its own command chain and was not covered by anything
      // that pauses the poll loop, so it went on questioning the vehicle from
      // the background. Interrupting it is a pause, not an answer.
      if (!(shouldContinue?.call() ?? true)) {
        completed = false;
        if (attemptEpoch == _capabilityDiscoveryEpoch) {
          _capabilityPhase = ObdCapabilityDiscoveryPhase.interrupted;
          _publishCapabilitySummary();
        }
        break;
      }
      final raw = await _readSupportBlock(query);
      if (attemptEpoch != _capabilityDiscoveryEpoch) {
        completed = false;
        break;
      }
      if (raw == null) {
        // One transient timeout used to `break`, storing whatever partial set
        // existed as though it were the vehicle's full capability — every PID
        // from the failed block upward greyed out as "此車輛不支援". An
        // unverified block simply stays unknown: its PIDs remain pollable and
        // are never labelled unsupported. Later blocks are still attempted,
        // because a failure here says nothing about whether they exist.
        continue;
      }
      _verifiedSupportBlocks.add(query);
      supported.addAll(PidLibrary.decodeSupportMask(query, raw.sublist(2)));
      _publishCapabilitySummary();
      // Bit 0 of the mask says whether a further block exists.
      if ((raw[5] & 0x01) == 0) break;
    }
    // Never cleared by an interrupted run: "discovery finished once" is a
    // fact about the past that a later pause cannot undo.
    if (completed && attemptEpoch == _capabilityDiscoveryEpoch) {
      _discoveryAttempted = true;
      _capabilityPhase = ObdCapabilityDiscoveryPhase.attemptFinished;
      _publishCapabilitySummary();
    }
    return supported;
  }

  /// Synchronously retires capability work at a connection boundary.
  void interruptCapabilityDiscovery() {
    if (_capabilityPhase != ObdCapabilityDiscoveryPhase.running) return;
    _capabilityDiscoveryEpoch++;
    _capabilityPhase = ObdCapabilityDiscoveryPhase.interrupted;
    // Drop the coalescer slot so a resume can start a fresh scan instead of
    // joining the retired in-flight future that is about to exit on epoch
    // mismatch and leave discovery incomplete for the rest of the connection.
    _discoveryInFlight = null;
    _publishCapabilitySummary();
  }

  /// Blocks whose mask this session positively verified.
  ///
  /// Only inside one of these may a PID be declared unsupported. Absence from
  /// `_supported` otherwise means "never established", which is a different
  /// claim and must not be rendered as the vehicle lacking the sensor.
  final Set<String> _verifiedSupportBlocks = {};

  /// Reads one support block, retrying once, and only accepting a reply that
  /// is unmistakably the answer to *this* query.
  ///
  /// The old check was `data.length >= 4`, which a delayed reply to the
  /// previous block satisfies: `0120` receiving a stale `41 00 BE 1F A8 13`
  /// decoded the `0100` mask as the `0120` block and produced a plausible,
  /// entirely false support map.
  Future<List<int>?> _readSupportBlock(String query) async {
    final expectedBase = int.tryParse(query.substring(2), radix: 16);
    if (expectedBase == null) return null;

    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        // Explicitly addressed to the engine rather than to whatever header
        // the previous request left selected. A support mask attributed to the
        // wrong controller marks PIDs the vehicle has as unsupported, and the
        // gauges then stay grey with no explanation.
        final response = await client.sendAddressed(kDefaultHeader, query);
        final raw = response.bytes;
        if (response.isSuccess &&
            raw.length == 6 &&
            raw[0] == 0x41 &&
            raw[1] == expectedBase) {
          return raw;
        }
      } on Object {
        // Retried below. `NO DATA` here is the adapter's timeout, not the
        // vehicle declaring it has no such block.
      }
      if (attempt == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
    return null;
  }

  /// True when the vehicle has *positively said* it does not implement [pid].
  ///
  /// The support mask was decoded, exposed to the UI, and then never consulted
  /// by the poller. So the poll set kept every physics input regardless — and
  /// since most vehicles lack at least one of `015E`, `0110` or `010B`, the
  /// first batch came back short of what was asked, tripped the corruption
  /// handler, and disabled fast mode for the rest of the session. On nearly
  /// every real car, batching destroyed itself moments after connecting.
  /// Whether the vehicle has positively disclaimed [pid].
  ///
  /// Public because the PID manager used to decide this itself, as "absent
  /// from the supported set" — which labels every PID in a block that was
  /// never successfully read as "此車輛不支援", including custom ones the
  /// masks say nothing about. Absence from the set is not evidence.
  bool isKnownUnsupported(Pid pid) => _knownUnsupported(pid);

  bool _knownUnsupported(Pid pid) {
    final supported = _supported;
    if (supported == null || !pid.isMode01) return false;

    // The mask was read from the engine controller, addressed explicitly. It
    // describes what *that* controller implements and says nothing about a
    // transmission or a body module — so a custom `7E1:010D` was being
    // suppressed on the strength of the ECM's answer, and a PID the vehicle
    // could actually deliver went unread.
    if (!BusAddressing.isAppDefault(pid.header)) return false;

    // A direct positive answer outranks an absent mask bit. Discovery runs
    // concurrently with the first poll cycles, so a clone with a partial or
    // inaccurate map could let RPM display and then retire it — the app
    // choosing a stale claim about the vehicle over an answer the vehicle had
    // just given it.
    if (_answeredAtLeastOnce.contains(pid.id)) return false;

    final block = PidLibrary.supportBlockFor(pid.modeAndPid);
    if (block == null || !_verifiedSupportBlocks.contains(block)) return false;
    return !supported.contains(pid.modeAndPid.toUpperCase());
  }

  /// Whether the vehicle has *confirmed* it answers [pid].
  ///
  /// Batching asserts that every member will be answered, so a member nothing
  /// has confirmed does not belong in one. A PID from a block that failed to
  /// read is unknown, not absent — it stays pollable, just on its own.
  /// Whether this PID may share a request with others.
  ///
  /// Two questions were being answered by one predicate. "Does the vehicle
  /// have this PID" is about support, and a direct answer or the controller's
  /// own mask settles it. "Can a batched reply be split back into per-PID
  /// slices" is about *width*, and nothing settles it for a custom formula:
  /// the formula says which bytes the author cares about, not how many the
  /// wire carries.
  ///
  /// `dataByteCount` already said so — "a guess, and is why a PID without a
  /// declared width never joins a batch" — and nothing enforced it. What the
  /// gap produces is a plausible wrong number rather than a failure. Define a
  /// custom `010C` as `A` and poll built-in `010D` beside it; the ECM's mask
  /// says both exist, so `010C0D` goes out and a valid compact reply comes
  /// back:
  ///
  ///     41 0C 1A 0D 0D 00
  ///
  /// The real RPM data is `1A 0D` and the real speed is `00`. The guessed
  /// width of one consumes `1A`, mistakes the RPM low byte `0D` for the next
  /// PID identifier, eats the real identifier as its data, and publishes
  /// **13 km/h for a stationary car**. Every structural check passes.
  ///
  /// So an unknown width polls alone — always, including after a direct
  /// answer, because answering proves the PID exists and says nothing about
  /// how many bytes it returns.
  bool _isBatchable(Pid pid) =>
      pid.declaredDataBytes != null && _isPositivelySupported(pid);

  bool _isPositivelySupported(Pid pid) {
    if (!pid.isMode01) return false;
    // A direct answer is evidence about this exact PID on this exact
    // controller, so it stands on its own.
    if (_answeredAtLeastOnce.contains(pid.id)) return true;
    // The mask is not. It was read from the engine and describes the engine —
    // the same scoping `_knownUnsupported` got, and which this predicate was
    // written without. Without it the ECM's map licensed a *transmission* PID
    // into a batch, the TCM did not answer about it, and the short reply
    // disabled fast mode for the session: the failure the per-member gate
    // exists to prevent, arriving through the gate itself.
    if (!BusAddressing.isAppDefault(pid.header)) return false;
    final supported = _supported;
    if (supported == null) return false;
    final block = PidLibrary.supportBlockFor(pid.modeAndPid);
    if (block == null || !_verifiedSupportBlocks.contains(block)) return false;
    return supported.contains(pid.modeAndPid.toUpperCase());
  }

  /// PIDs that have returned a usable value at least once this session.
  ///
  /// Evidence the app gathered itself, which no support map can overrule: the
  /// vehicle answered.
  ///
  /// Scoped to this engine, and an engine belongs to one connection —
  /// `_connectInner` constructs a fresh one every time — so it cannot carry a
  /// previous vehicle's answers into the next. That is worth stating because
  /// three separate pieces of per-connection state have leaked across
  /// reconnects in earlier rounds.
  final Set<String> _answeredAtLeastOnce = {};

  /// Refuses a global reply whose frames cannot be attributed to a controller.
  ///
  /// Round 5 stopped a clone that *refuses* `ATH1` — it answers `?`, the state
  /// is no longer committed on send, and `sendGlobal` aborts. It did nothing
  /// about the clone that *lies*: answers `OK`, prints no header, and leaves
  /// the client believing attribution is on.
  ///
  /// The parser deliberately falls through to unattributed parsing when
  /// headers were expected and none arrived, and for ordinary polling that is
  /// right — refusing a reply merely because it was not recognised is the same
  /// mistake pointing the other way. For a *global* request it is not: the
  /// whole premise of the operation is knowing who answered. Without it a
  /// single anonymous `43 00` — which might be one controller of five, or the
  /// adapter talking to itself — becomes a verified whole-vehicle all-clear,
  /// and round 5's rule that one controller's refusal cannot be outvoted has
  /// nothing to count.
  /// Why this bus cannot be read, or null when it can.
  ///
  /// Two states were sharing one message. "Not determined yet" is temporary
  /// and reconnecting may well fix it; J1939 is determined, permanent, and
  /// telling its owner to reconnect sends them round a loop with no exit.
  ///
  /// That distinction is the whole point of `supportsObd2`, which was added
  /// with the J1939 split and then wired to nothing — so the refusal it
  /// existed for went on speaking with the other one's voice.
  String? _busRefusal(String subject) {
    if (client.addressing.family == ObdBusFamily.j1939) {
      return '這條匯流排是 SAE J1939（大型商用車與機具用），'
          '不是這個 App 讀取的 OBD2 診斷協定，因此無法讀取$subject。';
    }
    // Asked of the resolved addressing, not of the protocol letter.
    //
    // `B` and `C` do not answer this question by themselves — the framing
    // lives in PP 2C / PP 2E — so `DtcDecoder`, which sees only the letter,
    // now calls them unknown. Addressing has the options byte and can tell a
    // configured ISO 15765-4 user protocol from an unformatted one, so asking
    // it keeps a genuinely readable bus readable while the string API stays
    // honest about what a letter alone establishes.
    if (!client.addressing.supportsObd2) {
      // Name the parameter when there is one to name. `B` and `C` are user
      // CAN slots and their framing lives in PP 2C / PP 2E; an adapter that
      // will not print `AT PPS` leaves that unknowable, and "reconnect" would
      // send someone round a loop with no exit.
      final protocol = BusAddressing.normaliseProtocolNumber(
        client.protocolNumber,
      );
      if (protocol == 'B' || protocol == 'C') {
        final parameter = protocol == 'B' ? 'PP 2C' : 'PP 2E';
        return '這個轉接器設定為使用者自訂 CAN 協定 $protocol，'
            '而它的框架格式由 $parameter 決定 —— 轉接器沒有回報這項設定'
            '（AT PPS 無回應），因此無法確認匯流排格式，也就無法安全解讀$subject。';
      }
      return '尚未確定車輛使用的匯流排協定，無法安全解讀$subject。請重新連線。';
    }
    return null;
  }

  /// Rejects a reply the adapter has contradicted itself about.
  ///
  /// Headers were on and a frame still arrived with no source. Nothing this
  /// adapter says can be trusted to describe the vehicle, so the read fails
  /// outright rather than being qualified — a lying adapter is not a limited
  /// one.
  void _rejectAnonymous(ObdResponse response, {bool repeatWouldHarm = false}) {
    if (!response.headersEnabled) return;
    final anonymous = response.frames.where((f) => f.sourceId == null).length;
    if (anonymous == 0) return;
    throw DtcReadException(
      '轉接器回報了 $anonymous 筆無法辨識來源的回應。'
      '無法判斷有幾個控制器答覆，因此不能當作全車結果。'
      '${repeatWouldHarm ? '其中有控制器回報清除完成，所以不要直接再清除一次。' : ''}'
      '請重新連線，或改用其他轉接器。',
      repeatWouldHarm: repeatWouldHarm,
    );
  }

  /// Degrades a read whose replies could not be attributed at all.
  ///
  /// The two gates used to be one, keyed on `functionalHeader == null` — a
  /// stand-in for "is this a legacy bus" that was a proxy twice over. Legacy
  /// buses then gained functional headers of their own, at which point the
  /// proxy would have silently begun hard-failing every scan on an adapter
  /// that will not print headers: a working vehicle turned into a permanent
  /// error by a change two files away.
  ///
  /// They are different states and deserve opposite answers. An adapter that
  /// refuses `ATH1` is limited, not lying. The request still reached the bus,
  /// and [found] are real faults worth showing. What cannot be claimed is
  /// coverage: "no codes" must not be promoted to "the vehicle is clean" when
  /// nobody knows whether one controller answered or five. So the category
  /// reports as unanswered, carries its codes out on the exception, and
  /// `ScanVerdict` renders the scan partial.
  ///
  /// This is what `docs/verification/test-evidence.md` recorded as a known gap awaiting
  /// hardware. It needed no hardware — only for the two states to stop
  /// sharing one branch.
  void _requireAttributable(
    ObdResponse response,
    List<Dtc> found, {
    bool repeatWouldHarm = false,
  }) {
    if (response.headersEnabled) return;
    throw DtcReadException(
      '轉接器不支援顯示回應標頭，無法分辨有幾個控制器答覆。'
      '${repeatWouldHarm ? '但回應中有控制器回報清除完成，所以不要直接再清除一次 —— 請重新掃描確認。' : '已讀到的故障碼仍然有效，但這次掃描不能當作全車結果。'}',
      kind: DtcReadFailure.unattributed,
      partial: List.unmodifiable(found),
      repeatWouldHarm: repeatWouldHarm,
    );
  }

  /// Reads one class of fault codes.
  ///
  /// Every non-answer is a failure, never an empty list. "No codes found" is a
  /// clinical statement about the car, and the only reply that justifies it is
  /// a positive response that genuinely contained zero codes — not `NO DATA`,
  /// not a negative response, not an empty prompt. A false all-clear on a
  /// diagnostic screen is something a person could drive away on.
  /// How long to wait after a controller says it is still working.
  ///
  /// ISO 14229 lets a server extend its own deadline by answering `7F xx 78`,
  /// and expects the tester to keep waiting rather than treat it as a result.
  /// Two seconds and two extra attempts is a bounded version of that: enough
  /// for a legacy module erasing fault memory, short of hanging the screen on
  /// a controller that never finishes.
  static const Duration pendingRetryDelay = Duration(seconds: 2);
  static const int pendingRetries = 2;

  /// Whether re-asking can obtain anything the adapter has not already waited
  /// for.
  ///
  /// `7F xx 78` does not transfer ownership to a fresh request — the original
  /// one was accepted and its answer is still coming — so retransmitting the
  /// service is not what ISO 14229 asks of a tester, and a module may restart
  /// work it had nearly finished. It is also, on most buses, redundant. From
  /// firmware v2.1 the adapter handles this itself:
  ///
  /// > If bit 2 of PP 2A is set (it is by default), the ELM327 will support
  /// > this part of J1979, changing the timeout to 5 seconds for you if it
  /// > sees a Response Pending message. This will only occur for the CAN and
  /// > ISO14230 (KWP) protocols as per the standard.
  ///
  /// So on those buses a bare pending reply has *already* outlasted the five
  /// seconds the standard prescribes, and asking again asks for nothing new.
  ///
  /// Two cases are left, and the datasheet names the first itself:
  ///
  /// > Note that the current implementation of this feature does not keep
  /// > track of multiple ECUs, some of which may reply immediately, and some
  /// > that may reply with response pending messages.
  ///
  /// A mixed reply therefore returns early on any bus — the adapter got *an*
  /// answer and printed its prompt — and the controller still working never
  /// got its five seconds. The second case is J1850 and ISO 9141-2, which the
  /// feature does not cover at all; there the app supplies the wait the
  /// adapter does not.
  bool _worthReasking(DtcReadException e) {
    if (e.terminalSources.isNotEmpty) return true;
    // Whether the adapter already waited is a property of the *adapter*, not
    // of the bus. The datasheet says so in the same breath as the feature:
    // "Beginning with v2.1, that is changing." A genuine v1.3a talking to a
    // CAN vehicle does none of this, so keying the decision on CAN-versus-
    // legacy read the standard and forgot the device — and the app stopped
    // asking for a P0301 a second request would have returned.
    if (!client.adapterHandlesResponsePending) return true;
    return switch (client.addressing.family) {
      ObdBusFamily.can11 || ObdBusFamily.can29 || ObdBusFamily.kwp2000 => false,
      _ => true,
    };
  }

  /// Reads one class of fault codes, waiting out a controller that says it is
  /// still working.
  ///
  /// Only reads retry. A Mode 04 clear that comes back pending is *not*
  /// repeated: re-issuing it resets the readiness monitors a second time, and
  /// the vehicle then needs another full drive cycle before it can pass an
  /// emissions test. The user is told to rescan instead, which establishes the
  /// same thing at no cost.
  /// [deadline] bounds the whole read, retries included.
  ///
  /// The scan screen used to wrap this in `Future.timeout`, which bounds the
  /// *spinner* and not the bus work: the detached read went on sleeping two
  /// seconds and transmitting again in the background, and an immediate rescan
  /// queued behind the operation it thought it had abandoned. A deadline has
  /// to reach the code that decides to send again, so it is passed in rather
  /// than wrapped around.
  Future<List<Dtc>> readDtcs(DtcKind kind, {DateTime? deadline}) async {
    client.transcript.recordNote('開始讀取${kind.label}故障碼（Mode ${kind.mode}）');
    // Captured, not sampled. Re-checked before every attempt, so a retry that
    // slept across an interruption does not resume on the other side of it.
    final owner = lifecycleEpoch?.call();
    // What *this* read could not account for, accumulated across its retries.
    //
    // Not a reset of the stored set at entry, which is where this started. A
    // read that never reaches its own conclusion — `NO DATA`, a bus refusal,
    // an interruption — has established nothing, and letting it clear the
    // doubt raised by an earlier exchange meant a rescan that failed outright
    // was enough to make the next clear proceed. The stored set is *replaced*
    // in `finish`, by a read that got far enough to say what it saw.
    final doubts = <String>{};
    // One logical read, one accumulator. Each attempt used to return only its
    // own codes, so the sequence that matters most lost the fault it had
    // already proven: the engine reports P0301 while the transmission says it
    // is still working, the retry draws only the transmission's clean `43 00`,
    // and the category closes as clean with P0301 decoded, discarded, and
    // never shown. Waiting out a pending controller must not cost the answers
    // that arrived while waiting.
    //
    // Keyed by controller *and* code, because the same code from two modules
    // is two observations, and the same code from one module across two
    // attempts is one.
    final found = <String, Dtc>{};
    void collect(Iterable<Dtc> codes) {
      for (final dtc in codes) {
        found['${dtc.sourceId ?? ''}|${dtc.kind.name}|${dtc.code}'] = dtc;
      }
    }

    /// Every successful return goes through here.
    ///
    /// There were two exits — the straight-line success and the one that
    /// notices the pending debt has settled — and the coverage and attribution
    /// rules were placed on the first only. So a vehicle where a known
    /// controller stayed silent throughout, but the *pending* bookkeeping
    /// happened to settle, returned an empty list past both checks and the
    /// screen went green. One rule, one place, or the sibling drifts: this is
    /// the twelfth time that shape has been found in this project.
    List<Dtc> finish(Set<String> heard, Iterable<Dtc> codes) {
      final result = List<Dtc>.unmodifiable(codes);

      // Coverage. All three classes: 07 and 0A are optional in J1979, so a
      // controller that implements neither may ignore them — but "this silence
      // is legitimate" and "everyone answered" are different statements, and
      // only the second earns a green panel.
      // The handshake census, widened by what fault-code exchanges have heard
      // — and *only* when there was a census.
      //
      // `_knownResponders` falls back to observed sources when the census
      // failed, which is right for a clear (the evidence comes from an earlier
      // exchange) and wrong here. A read cannot vouch for its own coverage
      // with a controller it discovered while being judged: a fabricated
      // header split from headerless bytes established source `BE`, and `BE`
      // then satisfied the check that was supposed to catch it. With no
      // census, coverage is unknowable, which is the branch below.
      final census = _responders?.union(_observedResponders);
      if (census != null) {
        // Mode 03 is owed by every emissions controller. Modes 07 and 0A are
        // not.
        //
        // J1979 makes the pending and permanent classes optional, and plenty
        // of ordinary vehicles have a module that answers `0100` and Mode 03
        // and implements neither — a MY2010 car whose transmission has no
        // permanent-code support is standards-compliant and completely
        // healthy. Holding every controller to all three services meant those
        // cars could never produce anything but 部分未確認, which on screen is
        // indistinguishable from a broken app. The owner would spend the
        // afternoon debugging behaviour that was right.
        //
        // So for an optional class, silence is only a hole when *this*
        // controller has answered *this* class before. A module that has
        // demonstrated Mode 0A and then goes quiet is a real gap; one that
        // never had it is a vehicle, not a fault. Mode 03 keeps the full
        // census, because a controller that skips it is not exercising an
        // option.
        final owed = kind == DtcKind.stored
            ? census
            : census.intersection(_everHeardOf[kind] ?? const <String>{});
        // Recorded, not discarded. The category completing is what stops an
        // ordinary car looking broken; it is not a claim that every module was
        // asked, and the scan needs the difference to render an honest
        // verdict rather than an unqualified one.
        optionalNotCovered[kind] = kind == DtcKind.stored
            ? const <String>{}
            : Set.unmodifiable(census.difference(owed).difference(heard));
        final silent = owed.difference(heard);
        if (silent.isNotEmpty) {
          throw DtcReadException(
            kind == DtcKind.stored
                ? '有 ${silent.length} 個控制器完全沒有回應這次查詢'
                      '（${silent.join('、')}）。'
                      '已回應的部分沒有問題，但這不能當作全車結果。'
                : '有 ${silent.length} 個控制器沒有回應${kind.label}故障碼查詢'
                      '（${silent.join('、')}）。'
                      '這個類別是選配的，沉默可能只代表它沒有實作 —— '
                      '但也因此無法當作全車都沒有${kind.label}故障碼。',
            kind: DtcReadFailure.noAnswer,
            partial: result,
            terminalSources: Set.unmodifiable(heard),
            silentSources: Set.unmodifiable(silent),
          );
        }
      } else if (_censusAttempted && _lastReadWasAttributed) {
        // Attempted and failed, which is not the same as never asked.
        //
        // `_responders == null` meant both, and answering them alike is the
        // mistake `supportsObd2` was added for elsewhere in this file. A
        // census nobody tried to take makes no claim about coverage in either
        // direction; one that was tried and came back empty means coverage is
        // *unknown*, and unknown is not complete — which is what was being
        // reported as a clean bill.
        throw DtcReadException(
          '無法確認這輛車上有哪些控制器，因此不能判斷是否每一個都回應了。'
          '已讀到的結果仍然有效，但不能當作全車結果。',
          kind: DtcReadFailure.noAnswer,
          partial: result,
          terminalSources: Set.unmodifiable(heard),
        );
      }

      // The coverage question the census cannot ask.
      //
      // `census.difference(heard)` only catches controllers the app can name.
      // A token it could not resolve is a controller it cannot even put on the
      // list — so the difference comes back empty, every named module has
      // answered, and the panel goes green with a reply nobody could account
      // for still sitting in the log. This was reaching the clear alone, which
      // is one operation too late: the screen had already said 沒有故障碼.
      //
      // This read reached a conclusion, so what it saw replaces what the
      // category was previously carrying. That is the only thing that ever
      // lifts a doubt wholesale, and it is deliberately the hardest way: a
      // read has to complete, not merely be attempted.
      _unresolvedIdentities[kind] = <String>{...doubts};

      // This category's own doubt, not the whole vehicle's.
      //
      // A token seen during Mode 03 *is* a statement about the vehicle, and
      // checking the union here made that statement unanswerable in one pass:
      // a candidate raised by Mode 0A survived through the next scan's Mode 03
      // and Mode 07, failing both before Mode 0A finally replaced its own
      // stale set. The app said 請重新掃描 and one rescan was not enough.
      //
      // A category answers for itself here. The whole-vehicle question is
      // asked once, by the scan, after every category has staged its result —
      // see [openIdentityQuestions] — and by the clear, which needs it most.
      final unresolved = _unresolvedIdentities[kind] ?? const <String>{};
      if (unresolved.isNotEmpty) {
        throw DtcReadException(
          '有 ${unresolved.length} 筆回應無法判斷是哪個控制器送出的'
          '（未能辨識的位址：${unresolved.join('、')}）。'
          '因此無法確認是不是每個控制器都回應了。'
          '已讀到的結果仍然有效，但不能當作全車結果。請重新掃描。',
          kind: DtcReadFailure.noAnswer,
          partial: result,
          terminalSources: Set.unmodifiable(heard),
        );
      }

      // Attribution, last, for the reason it always was: it only qualifies a
      // result and a qualification wants the codes it is qualifying.
      if (!_lastReadWasAttributed) {
        throw DtcReadException(
          '轉接器不支援顯示回應標頭，無法分辨有幾個控制器答覆。'
          '已讀到的故障碼仍然有效，但這次掃描不能當作全車結果。',
          kind: DtcReadFailure.unattributed,
          partial: result,
        );
      }
      return result;
    }

    final owed = <String>{};
    // Cumulative, and the counterpart to `found`. A controller that has given
    // a terminal answer during this logical read has answered, full stop — and
    // the retry is a *global* re-request, so it reaches controllers that were
    // never owing. One of those answering `7F 03 78` the second time round
    // reopened a debt the app had already collected and had no need to ask
    // for, and the category stayed pending with a P0301 the engine had cleanly
    // reported on the first attempt.
    //
    // The deeper point is that discharging one responder by broadcasting to
    // all of them is a poor instrument; this makes the instrument stop
    // manufacturing its own debts.
    final finished = <String>{};
    // Everyone whose reply was about this service, readable or not. Kept apart
    // from `finished`, which is a trustworthy terminal answer: an errored
    // exchange is not data, and the controller that printed a Mode 03 response
    // into it still answered Mode 03.
    final heardOfService = <String>{};
    // Once per read. The point of asking by name is to rule out a broadcast
    // that went astray; asking twice would only be re-asking a module that has
    // now declined the question directly, which is an answer.
    var sweptPhysically = false;
    for (var attempt = 0; attempt <= pendingRetries; attempt++) {
      try {
        _requireStillOwned(owner);
        _requireTimeToWork(deadline);
        final codes = await _readDtcsOnce(
          kind,
          owner: owner,
          deadline: deadline,
        );
        heardOfService.addAll(_lastHeardOfService);
        doubts.addAll(_lastUnresolvedIdentities);
        collect(codes);
        // A controller that promised an answer has to be the one that gives
        // it. Accepting any later reply let the engine's clean `43 00`
        // discharge a transmission that had said `7F 03 78` and then never
        // spoke again — a category closed as clean on a controller that was
        // still thinking.
        finished.addAll(_lastTerminalSources);
        owed.removeAll(finished);
        if (owed.isEmpty) {
          // Silence is not a clean answer — asked here, where the cumulative
          // record lives.
          //
          // Every check inside a single exchange counts something a controller
          // *did*: answered, refused, promised, sent something unreadable. A
          // controller that says nothing appears in none of them, so a
          // transmission holding P0715 that simply never replies would leave
          // the engine's `43 00` standing as the whole vehicle's result.
          //
          return finish(finished, found.values);
        }
        throw DtcReadException(
          '有 ${owed.length} 個控制器承諾稍後回覆，但一直沒有給出結果。'
          '這次掃描並不完整，請稍候再試一次。',
          kind: DtcReadFailure.pending,
          partial: List.unmodifiable(found.values),
          pendingSources: Set.unmodifiable(owed),
        );
      } on DtcReadException catch (e) {
        heardOfService.addAll(_lastHeardOfService);
        doubts.addAll(_lastUnresolvedIdentities);
        collect(e.partial);
        finished.addAll(e.terminalSources);
        owed
          // A source that already answered this read cannot be put back in
          // debt by a broadcast it did not need to receive — `finished` is
          // subtracted after the additions, which covers it.
          ..addAll(e.pendingSources)
          ..removeAll(finished);
        // Settled. Every controller that promised an answer has given one at
        // some point during this read, so the read is finished whatever the
        // last attempt threw. Retrying here asks a question nobody owes an
        // answer to — and on the third pass a vehicle that had answered
        // everything reported the PID unsupported instead.
        if (e.kind == DtcReadFailure.pending && owed.isEmpty) {
          return finish(finished, found.values);
        }
        // Ask the silent ones by name, once, before giving up on them.
        //
        // A functional broadcast is one request and one window. A module can
        // miss it for reasons that say nothing about whether it would answer:
        // a long reply from another controller filling the adapter's buffer, a
        // flow-control frame lost, a slow module still waking. The scan then
        // refuses — correctly, because silence is not an answer — and the user
        // is told the vehicle could not be read when one more question would
        // have read it.
        //
        // Strictly additive, on the failure path only. It runs after the
        // broadcast has already come up short, it can only *add* controllers
        // to the answered set, and if it produces nothing the read fails
        // exactly as it did before. Nothing here can turn silence into a
        // clean bill of health: a module that does not answer its own
        // physically addressed request stays owed.
        //
        // Confined to 11-bit CAN because that is the only bus where the
        // mapping is standardised — ISO 15765-4 assigns request `7E0`–`7E7`
        // to response `7E8`–`7EF`. Deriving an address anywhere else would be
        // inventing one, and a request sent to an invented address is answered
        // by whoever happens to own it.
        if (!sweptPhysically && e.silentSources.isNotEmpty) {
          sweptPhysically = true;
          final reached = await _askSilentDirectly(
            e.silentSources,
            kind,
            found,
            owner: owner,
            deadline: deadline,
          );
          if (reached.isNotEmpty) {
            finished.addAll(reached);
            owed.removeAll(reached);
            final stillSilent = e.silentSources.difference(reached);
            if (stillSilent.isEmpty) return finish(finished, found.values);
          }
        }
        final outOfTime =
            deadline != null &&
            !DateTime.now().add(pendingRetryDelay).isBefore(deadline);
        if (e.kind != DtcReadFailure.pending ||
            attempt == pendingRetries ||
            outOfTime ||
            !_worthReasking(e)) {
          // Rethrowing verbatim would drop everything earlier attempts read.
          // A failure is a reason to qualify what was found, never to hide it.
          //
          // The cumulative set, not the last attempt's. `finished` is what
          // this read has heard across every attempt; `e.terminalSources` is
          // what the final one heard, which on a retry that got `NO DATA` is
          // nothing at all. That emptiness then reached the screen as "nobody
          // answered this category" — for a class one controller had finished
          // cleanly and another had said it was still working on.
          throw DtcReadException(
            e.message,
            kind: e.kind,
            partial: List.unmodifiable(found.values),
            pendingSources: Set.unmodifiable(owed),
            terminalSources: Set.unmodifiable(finished),
            heardAboutService: Set.unmodifiable(heardOfService),
          );
        }
        await Future<void>.delayed(pendingRetryDelay);
      }
    }
    // Unreachable: the loop either returns or rethrows.
    throw const DtcReadException('故障碼查詢未完成');
  }

  /// Controllers whose reply was about the service of the last exchange,
  /// readable or not.
  Set<String> _lastHeardOfService = const {};

  /// Which controllers gave a terminal answer on the last completed read.
  Set<String> _lastTerminalSources = const {};

  /// Every controller heard giving a terminal answer to *any* fault-code
  /// exchange this session.
  ///
  /// The handshake census is the better source and this is the fallback for
  /// when it could not be taken: `0100` answered `NO DATA`, or the exchange
  /// threw. `_responders == null` then meant "no coverage question exists",
  /// and a Mode 04 acknowledged by the engine controller alone reported the
  /// whole vehicle cleared — while the transmission that had just been shown
  /// holding P0715, on this same screen, seconds earlier, kept it.
  ///
  /// The evidence was already in hand. A controller that answered a Mode 03 is
  /// on this bus by demonstration, which is a stronger fact than a census
  /// reply, not a weaker one. Cumulative and never cleared, because a
  /// controller does not leave the bus between two exchanges.
  final Set<String> _observedResponders = <String>{};

  /// Every controller this session has evidence for, or null if there is none.
  ///
  /// The handshake census and the replies seen since are both *lower bounds*,
  /// and they were being treated as alternatives: the read checked only the
  /// census, the clear preferred it whenever it was non-null, and a census
  /// that found one controller therefore masked a Mode 03 that had just heard
  /// from two. `7E9` answers the stored class, stays silent through the
  /// optional ones, and the panel goes green — with the evidence that it
  /// exists sitting one field away.
  ///
  /// Monotonic on purpose. A controller does not leave the bus between two
  /// exchanges, so this only ever grows, and growing is what makes each
  /// category's coverage question harder to pass rather than easier.
  Set<String>? get _knownResponders {
    // The handshake census, plus every controller heard on a *fault-code*
    // exchange. Not every controller heard on anything.
    //
    // This was briefly widened to the whole connection's attributed traffic,
    // on the reasoning that a controller which answered the VIN request is on
    // this bus by the same demonstration. It is — and that is not the question
    // being asked. Existing is not implementing: a gateway that supplies a VIN
    // has demonstrated Mode 09 and nothing about Mode 03 or Mode 04, and
    // requiring it to acknowledge a clear refused clears that vehicles had
    // plainly performed. Two successive reviews asked for opposite behaviour
    // here; this is the reading that survives, because the other one converts
    // ordinary vehicle behaviour into a refusal.
    final census = _responders;
    if (census == null) {
      return _observedResponders.isEmpty ? null : _observedResponders;
    }
    return census.union(_observedResponders);
  }

  /// Whether the last exchange's replies could be attributed at all.
  bool _lastReadWasAttributed = true;

  /// Tokens the last exchange could not resolve into a source.
  ///
  /// A side channel beside [_lastHeardOfService], and for the same reason: the
  /// exchange may throw, and what it observed on the way is still a fact the
  /// caller has to account for.
  Set<String> _lastUnresolvedIdentities = const {};

  Future<List<Dtc>> _readDtcsOnce(
    DtcKind kind, {
    Object? owner,
    DateTime? deadline,
  }) async {
    // Cleared before anything that can throw. It is a side channel, and a
    // header switch failing before the service byte went out left the previous
    // category's value standing — so a Mode 07 the adapter never transmitted
    // reported that somebody had answered it.
    _lastHeardOfService = const {};
    _lastUnresolvedIdentities = const {};
    // What the client may treat as definite. An ambiguous token is only ever
    // promoted to a source by having spoken before, and this is where "before"
    // is supplied — refreshed every exchange, because a controller heard from
    // during category 03 is corroboration for the token seen in 07.
    client.knownResponders = _knownResponders ?? const {};
    // Before the request, not after the reply.
    //
    // Framing depends on the bus, so an undetermined protocol cannot be
    // decoded at all — picking a default reads a legacy reply with CAN rules
    // and invents codes the car never set. And a J1939 bus should never be
    // *asked*: sitting after the exchange, this refusal was pre-empted by the
    // `NO DATA` the question itself produced, so the user was told the vehicle
    // might not support the PID when the truth is that the app cannot speak
    // this bus at all.
    final refusal = _busRefusal('故障碼');
    if (refusal != null) throw DtcReadException(refusal);

    // Asked of the whole emissions system, not of the engine controller. A
    // physical request reaches the ECM alone, so a transmission fault never
    // appears and the screen reports a clean scan.
    final ObdResponse response;
    try {
      response = await client.sendGlobal(
        kind.mode,
        owner: owner,
        deadline: deadline,
      );
      // Recorded the moment the reply exists, not on the way out.
      //
      // Setting it beside the successful return meant an exchange that threw —
      // a pending reply, say — left the previous exchange's value standing,
      // and the finaliser then qualified this read using a fact about the last
      // one. The same shape as the rule it records.
      _lastReadWasAttributed = response.headersEnabled;
    } on TransportException catch (e) {
      // The adapter refused to put the scan on a footing where its answers
      // could be attributed. That is a diagnosable condition with a specific
      // remedy, so it reaches the screen as a message rather than as a bare
      // exception the UI renders generically.
      throw DtcReadException(e.message);
    }
    // Before the outcome is judged, and by disposition.
    //
    // Payload validity and responder identity are independent facts: a legacy
    // exchange with one good TCM frame beside one damaged ECM line is rejected
    // as a whole — correctly — while the TCM plainly answered. Forgetting it
    // let a later clear be measured against a set this very scan had heard
    // more than.
    //
    // But "answered something" is not "answers this service". A stale
    // `7EA 03 41 0C 00` — a complete Mode 01 reply arriving during a Mode 03
    // exchange — used to make `7EA` a session-long fault-code debt, and every
    // later category and the clear were then refused for its silence. It never
    // participated in Mode 03 at all.
    //
    // So: a frame counts when its payload is about *this* service, and an
    // identity with no readable payload counts too, because a bare header is
    // exactly the damage that must not erase a real module. A complete frame
    // about something else counts as neither.
    // From `observedFrames`, which survives an adapter error marker; `frames`
    // does not, and reading disposition from an empty list made every token in
    // an errored reply a bare identity. That put a stale Mode 01 responder —
    // and once, a multi-frame envelope's length line — into the fault-code
    // debt for the rest of the session.
    final expectingService = int.parse(kind.mode, radix: 16);
    // Two shapes, and only one of them needs interpreting here.
    //
    // `frames` has been through ISO-TP reassembly: its payload starts at the
    // service byte. `observedFrames` is what could be identified in a reply
    // the parser refused, and the parser has already worked out what each one
    // is *about* — because the frame type decides where that byte sits, and
    // a second rule in this file got it wrong for First Frames in both
    // directions at once.
    final reassembled = response.frames.isNotEmpty;
    final heardAboutThis = <String>{};
    final unresolved = <String>{};
    if (reassembled) {
      for (final frame in response.frames) {
        final source = frame.sourceId;
        if (source == null || source.isEmpty) continue;
        _resolveIdentity(source);
        final bytes = frame.bytes;
        if (bytes.isEmpty) continue;
        final about =
            bytes.first == expectingService + 0x40 ||
            (bytes.first == 0x7F &&
                bytes.length >= 2 &&
                bytes[1] == expectingService);
        if (about) {
          _observedResponders.add(source);
          heardAboutThis.add(source);
        }
      }
    } else {
      for (final frame in response.observedFrames) {
        final source = frame.sourceId;
        if (source == null || source.isEmpty) continue;
        // By what the line established, not by whether bytes survived.
        //
        // Those two came apart on an orphan continuation frame: bytes present,
        // service unreadable because a continuation frame has no service byte.
        // Keying on `bytes.isEmpty` meant it matched neither branch and the
        // controller vanished from a scan it had demonstrably taken part in.
        switch (frame.evidence) {
          case ObservedEvidence.candidate:
            // Not named, not discarded. The read cannot claim to cover a
            // vehicle it could not finish counting.
            //
            unresolved.add(source);
          case ObservedEvidence.present:
            // A definite source that said nothing intelligible: damage, and
            // the case that must not erase a real module. It is coverage, not
            // an answer to this service.
            _resolveIdentity(source);
            _observedResponders.add(source);
          case ObservedEvidence.answered:
            _resolveIdentity(source);
            // A complete frame about something else is definite evidence that
            // this controller exists and no evidence at all that it answered
            // *this* question. A stale `7EA 03 41 0C 00` arriving during a
            // Mode 03 exchange used to make `7EA` a session-long fault-code
            // debt it had never incurred.
            if (frame.service == expectingService) {
              _observedResponders.add(source);
              heardAboutThis.add(source);
            }
        }
      }
    }
    _lastHeardOfService = Set.unmodifiable(heardAboutThis);
    // Monotonic, per class. A controller that answered Mode 0A once is owed
    // Mode 0A from then on; one that never has is exercising an option J1979
    // gives it.
    (_everHeardOf[kind] ??= <String>{}).addAll(heardAboutThis);
    // Order-independent, because a reply is not a sequence of events. If the
    // same identifier also arrived on a line that established it — a headered
    // frame, or a bare header this connection had already heard from — then
    // the question that token raised has been answered, whichever line came
    // first.
    unresolved.removeWhere(_observedResponders.contains);
    // Into the stored set now, and not only into the side channel: an exchange
    // that throws never reaches `finish`, and a clear can follow it directly.
    // `finish` replaces this with the read's own account when it gets there.
    final stored = _unresolvedIdentities[kind] ??= <String>{};
    stored
      ..addAll(unresolved)
      ..removeWhere(_observedResponders.contains);
    _lastUnresolvedIdentities = Set.unmodifiable(unresolved);

    if (!response.isSuccess) {
      // `NO DATA` is the adapter's own report that nothing arrived before its
      // timeout — not a statement that the class is unsupported, and certainly
      // not that the car is clean. Kept apart from a refusal so an optional
      // class staying silent does not read as a failure.
      throw DtcReadException(
        response.errorCode.description,
        kind: response.errorCode == Elm327ErrorCode.noData
            ? DtcReadFailure.noAnswer
            : DtcReadFailure.error,
      );
    }
    if (response.frames.isEmpty) {
      throw const DtcReadException(
        'ECU 沒有回應故障碼查詢',
        kind: DtcReadFailure.noAnswer,
      );
    }

    _rejectAnonymous(response);

    final expectedMode = int.parse(kind.mode, radix: 16) + 0x40;
    // The count byte exists only on CAN. Datasheet p.35: "the ISO 15765-4
    // (CAN) protocol is very similar, but it adds an extra data byte (in the
    // second position), showing how many data items (DTCs) are to follow."
    //
    // Every bus is then handled the same way, because each frame is one
    // controller's complete message: on CAN with headers on that is one ECU's
    // reassembled ISO-TP payload, and on a legacy bus it is one printed line.
    // What must never happen is decoding the *concatenation* of legacy lines,
    // which leaves each later `43` in the data and shifts the pairing:
    //
    //   43 01 43 01 96 02 34      P0143 P0196 P0234
    //   43 01 33 00 00 00 00      P0133
    //
    // flattened gives P0143 P0196 P0234 C0301 P3300 — the real fourth fault
    // lost and two invented, each rendered with the same confident red chip.
    // From the resolved family, for the reason `_busRefusal` gives: the
    // count byte is an ISO 15765-4 property, and on `B`/`C` only the options
    // byte says whether that is what is on the wire.
    final hasCountByte = client.addressing.isCan;

    final codes = <Dtc>[];
    final seen = <String>{};
    var answered = 0;
    var refused = 0;
    var unrecognised = 0;
    String? decodeFailure;
    // By source, not by count. A retry has to know *which* controller is still
    // owing, or another one's answer discharges the debt.
    final pendingSources = <String>{};
    final terminalSources = <String>{};

    for (final frame in response.frames) {
      final message = frame.bytes;
      if (message.isEmpty) continue;
      // 0x7F is the negative-response service identifier. One controller
      // refusing does not invalidate another's answer.
      if (message.first == 0x7F) {
        // A negative response names the service it is about, and it has to be
        // this one. `7E9 03 7F 01 11` is a Mode 01 refusal; counting it here
        // reported that a controller had answered Mode 03 and rejected it,
        // which is a claim about a conversation that never happened.
        if (message.length < 2 || message[1] != expectedMode - 0x40) {
          unrecognised++;
          continue;
        }
        // …except NRC 0x78, which is not a refusal at all: ISO 14229's
        // `requestCorrectlyReceived-ResponsePending`. A controller sends it to
        // say the real answer is still coming, which is ordinary during a
        // Mode 04 clear and on slower modules. Counting it as a refusal
        // reported "the ECU rejected the request" for a request it had
        // accepted and was working on.
        if (message.length >= 3 && message[2] == 0x78) {
          pendingSources.add(frame.sourceId ?? '');
          continue;
        }
        refused++;
        terminalSources.add(frame.sourceId ?? '');
        continue;
      }
      if (message.first != expectedMode) {
        // Not a refusal and not an answer to this question. Counting it as
        // neither would let an unattributable frame vanish from the tally and
        // the category still close as complete.
        unrecognised++;
        continue;
      }

      answered++;
      terminalSources.add(frame.sourceId ?? '');
      final List<Dtc> decoded;
      try {
        decoded = DtcDecoder.decodeResponse(
          message,
          kind,
          hasCountByte: hasCountByte,
          sourceId: frame.sourceId,
        );
      } on StateError catch (e) {
        // The decoder's refusals are diagnoses — a declared count the payload
        // does not honour, data outside that window, an odd remainder.
        //
        // Recorded against *this* controller and not thrown, because throwing
        // ended the loop and every controller after it was never examined. One
        // controller sending half a code hid a complete `43 01 07 00` — a real
        // P0700 — from the controller behind it, and swapping the order of the
        // two frames changed which faults the user was shown. A result that
        // depends on bus ordering is not a result.
        //
        // The category still fails: `unrecognised` makes it incomplete below,
        // with the message and every code that *was* read carried out. What
        // changes is that the reading continues far enough to find them.
        unrecognised++;
        decodeFailure ??= e.message;
        continue;
      }
      for (final dtc in decoded) {
        // Deduplicated per controller, not globally. A fault reported by both
        // the engine and the transmission is two observations of two modules
        // seeing it, which is often the difference between one fault and two —
        // collapsing them to a single anonymous entry threw that away.
        if (seen.add('${dtc.sourceId ?? ''}:${dtc.code}')) codes.add(dtc);
      }
    }

    if (answered == 0) {
      throw DtcReadException(
        pendingSources.isNotEmpty
            ? 'ECU 已收到查詢但尚未回覆完成（response pending）。請稍候再試一次。'
            : refused > 0
            ? 'ECU 拒絕了故障碼查詢（negative response）'
            : '故障碼回應的模式位元組不符（期望 '
                  '0x${expectedMode.toRadixString(16).toUpperCase()}）',
        kind: pendingSources.isNotEmpty
            ? DtcReadFailure.pending
            : DtcReadFailure.error,
        pendingSources: Set.unmodifiable(pendingSources),
        terminalSources: Set.unmodifiable(terminalSources),
      );
    }

    // `refused` used to be consulted only when nothing had answered, so one
    // positive reply closed the category. On an 11-bit CAN functional request
    // the ECM's `43 00` and the TCM's `7F 03 11` gave answered == 1 and
    // refused == 1, and the method returned an empty list — which the screen
    // renders as a verified clean scan while a controller has explicitly said
    // it cannot tell us. A refusal anywhere makes the vehicle-wide result
    // unknown, whatever else came back.
    if (refused > 0 || unrecognised > 0 || pendingSources.isNotEmpty) {
      throw DtcReadException(
        refused > 0
            ? '有 $refused 個控制器拒絕回答（$answered 個已回應）。'
                  '這次掃描無法涵蓋全車，結果並不完整。'
            : pendingSources.isNotEmpty
            ? '有 ${pendingSources.length} 個控制器還在處理這次查詢'
                  '（response pending），'
                  '$answered 個已回應。結果尚不完整，請稍候再掃描一次。'
            : decodeFailure != null
            ? '有 $unrecognised 筆回應無法解讀（$decodeFailure）。'
                  '其餘控制器的結果仍然有效，但這次掃描並不完整。'
            : '有 $unrecognised 筆回應無法辨識（$answered 個已回應）。'
                  '這次掃描結果並不完整。',
        kind: pendingSources.isNotEmpty && refused == 0 && unrecognised == 0
            ? DtcReadFailure.pending
            : DtcReadFailure.error,
        partial: List.unmodifiable(codes),
        pendingSources: Set.unmodifiable(pendingSources),
        // A mixed exchange fails, so the success path below never runs and
        // `_lastTerminalSources` is not updated. Without carrying the
        // controllers that *did* finish, a debt could only ever grow.
        terminalSources: Set.unmodifiable(terminalSources),
      );
    }
    // Silence is not a clean answer.
    //
    // Every check above counts something a controller *did* — answered,
    // refused, promised, sent something unreadable. A controller that says
    // nothing at all appears in none of them, so a transmission holding
    // P0715 that simply does not reply left the engine's `43 00` standing as
    // the whole vehicle's result. Attribution made every reply traceable and
    // still could not notice an absence.
    //
    // The census is checked by `readDtcs`, not here — for all three classes.
    // This note used to say "Mode 03 only", on the reasoning that 07 and 0A
    // are optional in J1979 so a controller implementing neither may ignore
    // them. True, and beside the point: "this silence is legitimate" and
    // "everyone answered" are different statements and only the second earns a
    // green panel. A pending misfire in a silent transmission was a
    // vehicle-wide all-clear for as long as that sentence stood.
    //
    // It used to sit at this line and compare against *this attempt's*
    // terminal sources — which is the sibling-branch defect again, and against
    // a rule this same file had established four hours earlier. The retry is a
    // global re-ask, so a controller that answered on attempt one is under no
    // obligation to answer again; requiring it failed a vehicle where every
    // controller had answered, and named the one that answered *first* as
    // completely unresponsive.
    //
    // Only the caller holds the cumulative record, so only the caller can ask
    // this question.

    // Last, because it is the only gate whose answer depends on what was
    // decoded. Everything above can fail the read outright; this one only
    // qualifies it, and a qualification wants the codes it is qualifying.
    _lastTerminalSources = Set.unmodifiable(terminalSources);
    return codes;
  }

  /// Mode 04. Clears stored codes and turns off the MIL.
  ///
  /// Success requires the ECU's `44` acknowledgement. An empty reply parses as
  /// "no error" but means the request was never acted on, and reporting that as
  /// cleared would leave the driver believing a fault was dealt with.
  /// Tokens that might have been an address, by the category that saw them.
  ///
  /// A legal-width hex token is ambiguous — a real controller whose payload
  /// was lost, or a fragment of a headerless payload — and the app refuses to
  /// guess. That refusal is right and it leaves a hole: the coverage set no
  /// longer describes everyone who may be out there, so neither a completed
  /// read nor a clear measured against it can speak for the whole vehicle.
  ///
  /// Kept per category and per identifier rather than as one latching flag,
  /// because a flag could only ever be set. One corrupted line then disabled
  /// every clear for the rest of the connection, and a rescan — the very thing
  /// the error message asks for — could not lift it. Each category's doubt is
  /// cleared when that category is read again, and an individual token stops
  /// being a doubt the moment *that identifier* is heard from properly.
  final Map<DtcKind, Set<String>> _unresolvedIdentities = {};

  /// Which controllers have ever answered each class, this connection.
  ///
  /// The pending and permanent classes are optional in J1979, so "did not
  /// answer" and "does not implement" look identical on the wire the first
  /// time. Once a controller has answered a class, its later silence on that
  /// class is a hole rather than an option.
  final Map<DtcKind, Set<String>> _everHeardOf = {};

  /// Controllers an optional class did not reach, by class.
  ///
  /// Empty for Mode 03, which every emissions controller owes. For Modes 07
  /// and 0A this is the set the scan must not quietly treat as covered: they
  /// may simply not implement the class — which is legal and common — but that
  /// is not the same as having been asked and answered, and only the second
  /// earns an unqualified whole-vehicle statement.
  final Map<DtcKind, Set<String>> optionalNotCovered = {};

  /// Tokens a clear could not resolve into a source.
  ///
  /// Kept apart from the categories because a clear is not one of them and
  /// runs once. A clear whose reply carried an unnameable token has to leave
  /// that fact behind for the *next* clear, or a user who taps 清除 again gets
  /// told the whole vehicle was cleared by the one controller that answered.
  /// Lifted only by hearing from that identifier, never by a clean read.
  ///
  /// A completed category read used to clear this wholesale, on the reasoning
  /// that the read had just looked at the bus and would have re-raised the
  /// doubt if it were still there. It would not: a `7E9` the *clear* could not
  /// name is not something a Mode 03 exchange that only `7E8` answers has any
  /// view on. So a damaged clear left `7E9` in doubt, one clean `7E8 02 43 00`
  /// wiped it, and the next clear reported the whole vehicle cleared on `7E8`
  /// alone — the refusal bypassed by the very action its message recommends.
  ///
  /// There is no clean-read shortcut back, and that is deliberate on the one
  /// operation that cannot be undone. It resolves when that exact identifier
  /// is heard from — at which point it also joins the coverage set and the
  /// clear must have its acknowledgement anyway — and otherwise it lasts as
  /// long as the connection. Reconnecting builds a fresh engine, which is what
  /// the message now says.
  final Set<String> _clearUnresolved = <String>{};

  /// Every open question about who is on this bus.
  ///
  /// The whole-vehicle version, asked by the scan once all its categories have
  /// staged their results and by the clear before it changes anything. A
  /// category's own `finish` asks the narrower question.
  Set<String> get openIdentityQuestions => {
    for (final doubts in _unresolvedIdentities.values) ...doubts,
    ..._clearUnresolved,
  };

  /// The read's disposition rules, applied to a clear's reply.
  ///
  /// Deliberately narrower than the read's: a clear is not a fault-code
  /// *question*, so nothing here discharges a service obligation. What it does
  /// establish is who was on the bus while the vehicle was being changed, and
  /// that is the fact the next clear needs.
  void _recordClearEvidence(ObdResponse response) {
    if (response.frames.isNotEmpty) {
      for (final frame in response.frames) {
        final source = frame.sourceId;
        if (source == null || source.isEmpty) continue;
        _resolveIdentity(source);
        // Only what this exchange was about.
        //
        // `_resolveIdentity` promotes an identifier that was already in
        // question, so a controller nobody had ever heard from was dropped:
        // `7E9` answering `01 44` beside `7E8` proved it is on this bus and
        // took part in the clear, and the coverage set kept neither. The next
        // scan then went green on `7E8` alone.
        //
        // Fixing that by promoting *every* frame went too far in the other
        // direction. A stale `7E9 04 41 0C 1A F8` — a complete Mode 01 RPM
        // reply that happened to arrive during the clear — became a fault-code
        // obligation for the rest of the connection, and every later scan was
        // refused for the silence of a controller that had only ever reported
        // engine speed. That is the same mistake the read path names in its
        // own disposition loop: a complete frame about something else is
        // evidence that a controller exists and no evidence about this
        // question.
        //
        // So: did this frame answer *the clear*? Nothing more. It does not
        // prove the controller previously held a fault code, nor that it
        // implements Modes 03, 07 and 0A — what it proves is that the clear
        // reached it, which is exactly what the acknowledgement check needs to
        // be measured against.
        //
        // The same question the damaged branch below asks, asked the same way,
        // because the previous attempt asked it two different ways and the
        // gap was a false all-clear. This branch used to test the *content*:
        // `44` alone, or a three-byte `7F 04 NRC`. Two shapes slipped through
        // — `7E9 02 44 DE` and `7E9 02 7F 04`, both complete Single Frames
        // whose PCI matches what arrived, so neither is ever marked damaged
        // and the repair below never ran for them. Both name Mode 04.
        //
        // Completion stays a separate, stricter question, asked of content by
        // `_clearCompleted`, because "this controller erased its memory" is a
        // claim about what was said and not about who said it.
        if (frame.service == 0x04) _observedResponders.add(source);
      }
      return;
    }
    for (final frame in response.observedFrames) {
      final source = frame.sourceId;
      if (source == null || source.isEmpty) continue;
      switch (frame.evidence) {
        case ObservedEvidence.candidate:
          _clearUnresolved.add(source);
        case ObservedEvidence.present:
        case ObservedEvidence.answered:
          // The same correlation the successful path applies.
          //
          // This branch runs when the adapter marked the exchange damaged, and
          // it was adding every identifiable source without asking what the
          // frame was about. So a stale `7E9 04 41 0C 1A F8` arriving during a
          // clear became global fault-code debt, and every later scan was
          // refused for the silence of a controller that had only reported
          // engine speed. One rule, both paths, or the two drift.
          //
          // Asked of the framing, which is the only thing that can answer it.
          //
          // Two rounds were spent getting this wrong in both directions. It
          // first read `frame.bytes`, which on CAN still carries the ISO-TP
          // PCI, so `7E9 01 44` and `7E9 03 7F 04 22` both failed a predicate
          // written for reassembled payloads and *nothing* counted as
          // participation. Requiring `payload` fixed those two and broke the
          // one below, which is worse because it is the same false all-clear
          // wearing a different hat:
          //
          //   04 -> 7E8 01 44
          //         7E9 03 7F 04      three declared, two arrived
          //         <RX ERROR
          //
          // `7E9` said, unambiguously, "negative response, service 04" — and
          // then the line was cut before the reason byte. `payload` is
          // correctly null for that, so `7E9` was dropped, and the rescan
          // accepted `7E8`'s empty answer as the whole vehicle.
          //
          // The mistake was asking the wrong question. Coverage does not need
          // to know *what* a controller said about the clear, only that it
          // answered the clear at all — and that is exactly what `service` is:
          // computed by the parser at the offset the framing puts it, for
          // Single Frames and First Frames alike, and null for a reply about
          // anything else. A stale `7E9 04 41 0C 1A F8` arriving mid-clear is
          // service 0x01 and still excluded, which was the reason the payload
          // check existed.
          //
          // Completion is the separate question, and it keeps the strict
          // rule: `_clearCompleted` on a validated `payload`, because "this
          // controller erased its memory" is a claim about content.
          if (frame.service != 0x04) break;
          // Into the coverage set, which the read path is deliberately
          // stingier about.
          //
          // The rule there is that existing is not implementing: a gateway
          // that supplies a VIN has demonstrated Mode 09 and nothing about
          // Mode 03, and requiring it to acknowledge a clear refused clears
          // that vehicles had plainly performed. This is the case that rule
          // does not cover. The identifier is on a *Mode 04 exchange*, which
          // is the one question being asked — so it is a participant in the
          // clear by the same demonstration the rule is built on, not by
          // association with a different service.
          _resolveIdentity(source);
          _observedResponders.add(source);
      }
    }
    _clearUnresolved.removeWhere(_observedResponders.contains);
  }

  /// The request address a controller answering on [responseId] listens on.
  ///
  /// ISO 15765-4 pairs `7E0`–`7E7` with `7E8`–`7EF`, and nothing else. This
  /// returns null for every other identifier — including 29-bit CAN, whose
  /// identifiers are eight hex digits and cannot land in that window, and
  /// every legacy bus, whose three-byte headers cannot either. Subtracting
  /// eight from an arbitrary identifier produces a valid-looking address
  /// belonging to somebody else.
  ///
  /// This range *is* the rule. There was a bus-family check above the caller
  /// as well, and it was removed rather than kept: deleting it changed no test
  /// because no identifier outside 11-bit CAN can reach this window anyway,
  /// and a second guard that cannot be observed is a second place for the two
  /// to disagree.
  static String? _physicalRequestFor(String responseId) {
    final id = int.tryParse(responseId.trim(), radix: 16);
    if (id == null || id < 0x7E8 || id > 0x7EF) return null;
    return (id - 8).toRadixString(16).toUpperCase();
  }

  /// Asks named controllers for this category directly, and reports who
  /// answered.
  ///
  /// Only ever called after a functional broadcast has already failed
  /// coverage, and only on 11-bit CAN, where ISO 15765-4 fixes the mapping:
  /// a module answering on `7E8`–`7EF` receives on `7E0`–`7E7`. Outside that
  /// range, and on every other bus, there is no derivation — there is a guess,
  /// and a request sent to a guessed address is answered by whoever owns it.
  ///
  /// Codes found here are merged into [found] under the controller that sent
  /// them. The returned set is only those that gave a *terminal* answer to
  /// their own request; anything unreadable leaves the controller owed, which
  /// is where it already was.
  Future<Set<String>> _askSilentDirectly(
    Set<String> silent,
    DtcKind kind,
    Map<String, Dtc> found, {
    int? owner,
    DateTime? deadline,
  }) async {
    final reached = <String>{};
    for (final source in silent) {
      final request = _physicalRequestFor(source);
      if (request == null) continue;
      if (deadline != null && !deadline.isAfter(DateTime.now())) break;
      try {
        _requireStillOwned(owner);
        final response = await client.sendGlobal(
          kind.mode,
          header: request,
          owner: owner,
          deadline: deadline,
        );
        if (!response.isSuccess || response.frames.isEmpty) continue;
        // It has to be this controller answering. A physically addressed
        // request should only ever be answered by its target, and "should"
        // is not a thing to build an all-clear on — an unattributed reply
        // here would let some other module's `43 00` discharge the debt of
        // the one that is silent.
        final mine = response.frames
            .where((f) => f.sourceId == source)
            .toList(growable: false);
        if (mine.isEmpty) continue;
        final expected = int.parse(kind.mode, radix: 16) + 0x40;
        var answered = false;
        for (final frame in mine) {
          final bytes = frame.bytes;
          // The reply has to be about the question. A physically addressed
          // Mode 03 answered by a stale Mode 01 frame is not an answer, and
          // treating it as one would discharge the debt this exists to settle.
          if (bytes.isEmpty || bytes.first != expected) continue;
          answered = true;
          try {
            for (final dtc in DtcDecoder.decodeResponse(
              bytes,
              kind,
              hasCountByte: client.addressing.isCan,
              sourceId: source,
            )) {
              found['${dtc.code}@$source'] = dtc;
            }
          } on StateError {
            // A malformed payload is not a clean answer. The controller stays
            // owed, exactly as the broadcast left it.
            answered = false;
          }
        }
        if (answered) {
          reached.add(source);
          _observedResponders.add(source);
        }
      } on Object {
        // A controller that cannot be reached by name is exactly as silent as
        // it was before this ran. The broadcast's own failure is what gets
        // reported.
        continue;
      }
    }
    return reached;
  }

  /// Records that [source] has now been heard from definitely.
  ///
  /// Resolution is by exact identifier. A reply that establishes `7E9` says
  /// nothing about the `430` seen earlier, and treating any clean exchange as
  /// a general amnesty is how an unanswered question quietly became an answer.
  ///
  /// Resolving is a *promotion*, not a deletion. The token was seen during a
  /// fault-code exchange, so the two readings of it were "a controller that
  /// took part" and "noise" — and evidence that the identifier exists settles
  /// that in favour of the first. Merely dropping it discharged an obligation
  /// nobody had met: a `7E9` seen during Mode 03 and later heard answering
  /// *Mode 01* had its question deleted, and the clear then passed on `7E8`'s
  /// acknowledgement alone.
  void _resolveIdentity(String source) {
    var wasDoubted = _clearUnresolved.remove(source);
    for (final doubts in _unresolvedIdentities.values) {
      if (doubts.remove(source)) wasDoubted = true;
    }
    if (wasDoubted) _observedResponders.add(source);
  }

  /// Whether one frame is a controller reporting the clear finished.
  ///
  /// J1979 Mode 04 has no response parameter, so completion is exactly the
  /// single positive service byte and nothing else. This is the same judgement
  /// the final loop makes, extracted because the error path used to make a
  /// looser one — `44 DE AD BE` counted as finished there and as malformed
  /// here, so the same reply meant two different things depending on whether
  /// the exchange also carried an error marker.
  static bool _clearCompleted(List<int> bytes) =>
      bytes.length == 1 && bytes.first == 0x44;

  Future<ClearOutcome> clearDtcs() async {
    // Set for the same reason the read sets it, and it was missing here: the
    // clear's own reply goes through the same ambiguity, and without this a
    // bare `7E8` acknowledging the clear would be an open question instead of
    // the acknowledgement it is.
    client.knownResponders = _knownResponders ?? const {};
    final unresolved = openIdentityQuestions;
    if (unresolved.isNotEmpty) {
      throw DtcReadException(
        '掃描時有回應無法判斷是哪個控制器送出的'
        '（未能辨識的位址：${unresolved.join('、')}）。'
        '因此無法確認清除指令會送到哪些控制器。'
        '請重新掃描；若該位址一直沒有再出現，請重新連線後再試。',
        kind: DtcReadFailure.noAnswer,
      );
    }
    // The gate its read and VIN siblings have had all along, and the one that
    // matters most: this is the request that changes the vehicle. A J1939 bus
    // has no Mode 04, and an undetermined one cannot be shown to have carried
    // the request at all.
    final refusal = _busRefusal('故障碼');
    if (refusal != null) throw DtcReadException(refusal);
    final owner = lifecycleEpoch?.call();
    _requireStillOwned(owner);
    final ObdResponse response;
    client.beginWriteAudit();
    try {
      response = await client.sendGlobal('04', owner: owner);
    } on OperationRetiredException {
      // Refused before any write — the proof is where the refusal is, and the
      // caller has a type that says so.
      rethrow;
    } on Object catch (e) {
      // Whether a repeat is safe is a question about the wire, not about the
      // Dart type that came back.
      //
      // Three cases were being decided by exception class and two were wrong.
      // `socket.add` hands bytes to the kernel before `flush()` is awaited, so
      // a `SocketException` from the flush happens *after* the adapter may
      // already have the clear — and that escaped as an ordinary failure with
      // the retry left enabled. Meanwhile a `TimeoutException` from `ATH1`,
      // before `04` was written at all, was read as "already sent" and locked
      // a retry that was perfectly safe, stranding somebody who could still
      // have cleared the car.
      //
      // The write audit is the fact instead of the guess: the exchange is
      // `ATH1`, `ATSH`, the service and `ATH0`, so if `04`'s bytes never
      // reached the transport then `04` never went out. Asked as a window
      // rather than as "the last write", because the header restore runs even
      // when the service write failed.
      final reached = client.wroteSinceAudit('04');
      throw DtcReadException(
        reached
            ? '清除指令送出後連線中斷，無法確認車輛是否已清除。'
                  '請重新掃描確認結果，不要直接再清除一次 —— '
                  '如果其實已經清除成功，再清一次會重置排放就緒狀態。'
            : '清除指令還沒送出就失敗了'
                  '（${e is TransportException ? e.message : e}）。'
                  '車輛沒有任何變化，可以再試一次。',
        kind: DtcReadFailure.disconnected,
        repeatWouldHarm: reached,
      );
    }
    // Re-checked after the await as well as before it: a clear is
    // state-changing, and the interval that matters is the one it spent on the
    // wire.
    //
    // With its own sentence, because the general one — 請重新操作 — is advice
    // to do it again, and this is the one operation where doing it again may
    // be exactly wrong. The command has already been transmitted; whether the
    // vehicle acted on it is unknown, and a second clear resets the readiness
    // monitors a second time and costs another drive cycle.
    _requireStillOwned(
      owner,
      message:
          '清除指令已經送出，但 App 在等待回覆時被中斷，'
          '因此無法確認車輛是否已經清除。'
          '請重新掃描確認結果，不要直接再清除一次 —— '
          '重複清除會再一次重置排放就緒狀態。',
      // The sentence said so and the button did not, which is the same
      // mismatch the flag was introduced to close. The command is already on
      // the wire; being interrupted while waiting for the answer is exactly
      // the state where a second tap costs a drive cycle.
      repeatWouldHarm: true,
    );
    // Before the outcome is judged, exactly as the read does it.
    //
    // The clear used to return on `isSuccess` and `frames.isEmpty` without
    // ever looking at what the reply contained, so the state-changing
    // operation was the one place the evidence model did not reach. A clear
    // answered by `7E8 01 44` beside a bare `7E9` and an error marker returned
    // false and forgot `7E9`; the user tapped 清除 again, `7E8` answered alone,
    // and that was reported as the whole vehicle cleared.
    _recordClearEvidence(response);
    // Whether anybody actually finished — asked once, and used by every
    // sentence below that would otherwise assert it.
    final someoneFinished =
        response.frames.any((f) => _clearCompleted(f.bytes)) ||
        response.observedFrames.any(
          (f) =>
              f.service == 0x04 &&
              f.payload != null &&
              _clearCompleted(f.payload!),
        );
    // …and whether anybody *may* have, which is the question the button needs.
    //
    // `someoneFinished` is an exact-`44` claim, and it feeds the attribution
    // gates below, where the only thing being decided is whether a repeat can
    // do harm. Two shapes that are plainly not "nothing happened" were falling
    // through it, both found by codex in round 32 and both leaving 清除 live:
    //
    //   04 -> 7F 04 78        response pending: accepted, still working
    //   04 -> 7E9 02 44 DE    the completion byte, with junk after it
    //
    // On an adapter that will not print headers, either one reaches
    // `_requireAttributable` with `repeatWouldHarm: false`, and the second
    // global `04` lands on a controller mid-erase or already done.
    //
    // Deliberately looser than `someoneFinished`, and used only where the
    // question is "could repeating this hurt". Nothing here may be reported as
    // success — `ClearOutcome.confirmed` still requires the exact byte.
    bool mayHaveActed(List<int> bytes) =>
        bytes.isNotEmpty &&
        (bytes.first == 0x44 ||
            (bytes.length >= 3 &&
                bytes.first == 0x7F &&
                bytes[1] == 0x04 &&
                bytes[2] == 0x78));
    final someoneMayHaveActed =
        someoneFinished ||
        response.frames.any((f) => mayHaveActed(f.bytes)) ||
        response.observedFrames.any(
          (f) =>
              f.service == 0x04 &&
              f.payload != null &&
              mayHaveActed(f.payload!),
        );
    if (openIdentityQuestions.isNotEmpty) {
      // The middle sentence used to be unconditional, so
      //
      //   04 -> 7E8 03 7F 04 22
      //         7E9
      //         <RX ERROR
      //
      // — one controller explicitly refusing, one bare identifier — told the
      // user 有回應的控制器已清除 when nothing on the bus had cleared anything.
      // That reads as "most of it worked", and somebody who believes it stops
      // looking while the fault is still set.
      throw DtcReadException(
        '清除指令的回應中有無法判斷來源的資料'
        '（未能辨識的位址：${openIdentityQuestions.join('、')}）。'
        '${someoneFinished ? '已有控制器回報清除完成，但無法確認其餘控制器。' : '沒有任何控制器回報清除完成。'}'
        '請重新掃描確認，不要重複清除。',
        kind: DtcReadFailure.noAnswer,
        repeatWouldHarm: true,
      );
    }
    // A damaged exchange is not automatically a failed clear.
    //
    // `7E8 01 44` followed by `<RX ERROR>` used to return false, and the
    // screen said 清除失敗，ECU 未接受指令 — about a controller that had just
    // sent the J1979 completion byte. The retry that invites resets its
    // readiness monitors a second time.
    //
    // So the error path asks the only question that matters here: did anybody
    // finish? What could not be read stays unknown, which is what
    // `partiallyConfirmed` says.
    if (!response.isSuccess || response.frames.isEmpty) {
      // `7F 04 78` is acceptance, not refusal, and this branch did not know
      // it — the clean path has handled response-pending since round 27 and
      // this one returned before ever reaching it. A controller saying
      // "received, still working on it" was reported as 清除失敗，沒有控制器接
      // 受指令, with the button live to invite the repeat.
      final pending = response.observedFrames.any((f) {
        final message = f.payload;
        return f.service == 0x04 &&
            message != null &&
            message.length >= 3 &&
            message[0] == 0x7F &&
            message[1] == 0x04 &&
            message[2] == 0x78;
      });
      if (pending) {
        throw const DtcReadException(
          'ECU 已接受清除指令但尚未回報完成（response pending）。'
          '請稍候再重新掃描確認，不要立刻重複清除。',
          kind: DtcReadFailure.pending,
          repeatWouldHarm: true,
        );
      }
      if (someoneFinished) return ClearOutcome.partiallyConfirmed;
      // An intact refusal from the adapter is not a destroyed reply.
      //
      // `04 -> ?` is the adapter saying it did not understand the command, and
      // `UNABLE TO CONNECT` / `BUS INIT: ERROR` are it saying it never reached
      // the vehicle. All three arrived legibly and all three mean nothing was
      // erased — so calling them 回應在傳輸過程中損毀 and locking the retry
      // strands somebody whose next step is simply to try again.
      const nothingTransmitted = {
        Elm327ErrorCode.unknownCommand,
        Elm327ErrorCode.unableToConnect,
        Elm327ErrorCode.busInitError,
      };
      if (nothingTransmitted.contains(response.errorCode)) {
        return ClearOutcome.notAccepted;
      }
      // Not `notAccepted`. The command was transmitted and the reply was
      // destroyed, so nothing here is evidence that nothing happened — a
      // controller may have erased its memory and had its acknowledgement lost
      // on the way back. Unknown is its own answer, and a rescan settles it.
      return ClearOutcome.sentUnconfirmed;
    }
    // An unattributable acknowledgement cannot show that every controller
    // acted on the clear — and reporting success here tells a driver a fault
    // was dealt with.
    //
    // But it is still an acknowledgement. On an adapter that refuses `ATH1`:
    //
    //   ATH1 -> ?
    //   04   -> 44
    //
    // nobody can say *which* controller finished, or how many did not, and
    // both gates are right to refuse the exchange. What they were also doing
    // was throwing with the default `repeatWouldHarm: false`, which leaves 清
    // 除 live under a message about adapter limitations — and the exact `44`
    // is J1979's completion byte. Something on that bus erased its fault
    // memory, so a second global clear reaches it again and costs another
    // drive cycle.
    //
    // Not knowing who did it is not evidence that nobody did.
    _rejectAnonymous(response, repeatWouldHarm: someoneMayHaveActed);
    _requireAttributable(
      response,
      const [],
      repeatWouldHarm: someoneMayHaveActed,
    );

    // The same absence the read had to learn about, and it matters more here.
    //
    // "Every controller that answered acknowledged" is not the question a
    // driver is asking. They are asking whether the fault memory is clear —
    // and a controller that stays silent through a Mode 04 has neither
    // acknowledged nor refused. Reporting success sends someone away believing
    // a transmission fault was dealt with by a module that never heard the
    // request, and the light coming back later reads as a new problem.
    //
    // A clear is also state-changing, so this is not something to retry
    // blindly: re-issuing Mode 04 resets the readiness monitors a second time
    // and costs the vehicle another drive cycle. Saying which controller did
    // not answer is the useful thing.
    // Two sources, and the second was the hole. `_responders` is the handshake
    // census; when `0100` came back `NO DATA` it stays null, and a null census
    // used to mean no coverage question was asked at all. The clear is only
    // reachable from a completed scan, so at that moment the app had just
    // rendered `7E8` and `7E9` side by side with a code each — and then let
    // `7E8 01 44` alone stand for both. 已送出清除指令, with the transmission
    // fault still in the transmission.
    //
    // A controller that answered Mode 03 is on this bus by demonstration.
    // Refusing to use that because a different request failed is not caution.
    final census = _knownResponders;
    if (census != null) {
      final acknowledged = <String>{
        for (final frame in response.frames)
          if (frame.sourceId != null) frame.sourceId!,
      };
      final silent = census.difference(acknowledged);
      if (silent.isNotEmpty) {
        throw DtcReadException(
          '有 ${silent.length} 個控制器沒有回應清除指令'
          '（${silent.join('、')}）。'
          '已回應的控制器已清除，但其餘控制器的故障碼可能仍在。'
          '請重新掃描確認，不要重複清除。',
          kind: DtcReadFailure.noAnswer,
          repeatWouldHarm: true,
        );
      }
    } else if (_censusAttempted) {
      // The read path's rule, which the clear was exempt from. Attempted and
      // failed is not the same as never asked: the first leaves coverage
      // *unknown*, and an unknown must not be reported as a vehicle cleared.
      // Nothing was heard on a scan either, so there is not one controller
      // this acknowledgement can be said to cover.
      throw const DtcReadException(
        '無法確認這輛車上有哪些控制器，因此不能確定每一個都收到了清除指令。'
        '有回應的控制器已清除。請重新掃描確認，不要重複清除。',
        kind: DtcReadFailure.noAnswer,
        repeatWouldHarm: true,
      );
    }

    // Every controller that answered has to acknowledge. Reporting a partial
    // clear as success leaves faults in a module the driver now believes is
    // clean — and the fault light coming back on later reads as a new problem.
    for (final frame in response.frames) {
      final bytes = frame.bytes;
      // A frame with no bytes is unknown, not "nothing was sent".
      //
      // Left over from when `notAccepted` was the general failure. It now
      // means specifically that the adapter said, in its own voice, that the
      // command never reached the vehicle — and a frame appearing in
      // `response.frames` at all means an exchange happened on the bus.
      // Reachable only if a parser ever produces one, which none does today
      // (agy, round 31); the semantics still have to be the ones this branch
      // would need if one did, because `notAccepted` leaves the retry unlocked.
      if (bytes.isEmpty) return ClearOutcome.sentUnconfirmed;
      // `7F 04 78` is not a refusal: the controller has accepted the clear and
      // is still working on it. Reporting failure told the driver the ECU had
      // rejected a command it was in the middle of carrying out — and invited
      // a blind retry of an operation that resets readiness monitors.
      //
      // How *often* a module answers a clear this way is not something the
      // sources here settle. The datasheet describes the form and says nothing
      // about frequency; the Mode 04 section documents `44` as the completion
      // reply. An earlier version of this comment called it "common for Mode
      // 04 because erasing fault memory takes time", which is plausible and
      // unsourced. Possible is enough to handle it.
      //
      // What the datasheet does settle is where the service is: "The Response
      // Pending reply will always be of the form: 7F xx 78 where the xx
      // represents the Mode (or SID) that was being requested." So this has to
      // be about Mode 04. `7E8 03 7F 01 78` says Mode 01 is still working, and
      // telling the driver the ECU accepted their *clear* on the strength of
      // it is a claim about a different request entirely.
      if (bytes.first == 0x7F &&
          bytes.length >= 3 &&
          bytes[1] == 0x04 &&
          bytes[2] == 0x78) {
        throw const DtcReadException(
          'ECU 已接受清除指令但尚未回報完成（response pending）。'
          '請稍候再重新掃描確認，不要立刻重複清除。',
          kind: DtcReadFailure.pending,
          repeatWouldHarm: true,
        );
      }
      // A refusal that names its reason is worth repeating to the user.
      //
      // Everything that was not `44` collapsed into 清除失敗，ECU 未接受指令,
      // which tells somebody standing at a car nothing they can act on. The
      // commonest reason by far is the first one below: most ECUs will not
      // erase fault memory with the engine turning, and the fix is to switch
      // the ignition to ON with the engine off — a ten-second action nobody
      // can guess from "the ECU did not accept it".
      //
      // Codes from ISO 14229's negative-response table. Only the ones that
      // change what a person should do next are named; the rest keep the
      // general message rather than reciting a number.
      if (bytes.first == 0x7F && bytes.length >= 3 && bytes[1] == 0x04) {
        final source = frame.sourceId == null ? '' : '控制器 ${frame.sourceId} ';
        // Whether anybody already did it.
        //
        // These messages used to end in 「再試一次」 unconditionally. On a
        // mixed reply — one controller acknowledges, another refuses — that is
        // advice to re-send a *global* clear, which reaches the module that
        // already erased its memory and resets its readiness monitors a second
        // time. The vehicle then needs another full drive cycle before it can
        // pass an emissions test, for a retry that could not help the module
        // that refused anyway.
        final someoneCleared = response.frames.any(
          (f) => _clearCompleted(f.bytes),
        );
        // Asked of the whole reply, not of the frames read so far.
        //
        // Codex round 32: the same two controllers gave opposite button
        // safety depending on which spoke first.
        //
        //   04 -> 7E8 03 7F 04 22
        //         7E9 02 44 DE      the completion byte, with junk after it
        //
        // This loop throws at `7E8`, and `someoneCleared` is an exact-`44`
        // test that `44 DE` fails — so the button stayed live. Reverse the two
        // lines and the malformed positive is reached first, returns
        // `sentUnconfirmed`, and the button locks. Identical evidence about
        // identical controllers, decided by bus ordering.
        //
        // `someoneMayHaveActed` scans every frame in the reply, so the order
        // no longer matters. It stays separate from `someoneCleared` because
        // the two answer different questions: this one may lock a button, and
        // only `someoneCleared` may say a controller *finished*.
        final couldHaveActed = someoneMayHaveActed;
        // The flag has to agree with the sentence, or the screen contradicts
        // itself: `repeatWouldHarm` disables the button and relabels it 請先重
        // 新掃描, and these messages end in 請稍候再試一次 when nobody cleared
        // anything. Telling somebody to try again beside a control they cannot
        // press is worse than either half alone — it reads as a broken app on
        // the screen where that guess costs the most.
        //
        // Refusals are the one clear failure where nothing was erased, so
        // there is genuinely nothing to protect: the whole exchange arrived,
        // every frame was read, and none of them was a completion.
        // Existential, because `someoneCleared` is.
        //
        // These sentences used to read 其他控制器已經清除完成 — every other
        // controller finished — from a fact that says only that *one* did. On
        //
        //   04 -> 7E8 01 44          completed
        //         7E9 03 7F 04 22    conditionsNotCorrect
        //         7EA 03 7F 04 11    serviceNotSupported
        //
        // the loop stops at `7E9` and reports that `7EA` cleared, which `7EA`
        // had just explicitly declined to do. The warning against repeating is
        // still right — `7E8` really did erase — so only the quantifier was
        // wrong, and only the quantifier changes.
        //
        // Written once and shared, because every branch that locks the button
        // has to say why. `0x33` did not — it described the security
        // requirement, said nothing about repeating, and on a mixed reply the
        // flag disabled 清除 anyway. A dead control with no explanation is the
        // same failure as an explanation with a live control, from the other
        // side.
        const harmWarning =
            '已有其他控制器完成清除，所以不要再送一次全車清除 —— '
            '重複清除會讓已完成的控制器再一次重置排放就緒狀態。';
        // Three states, because there are three, and the middle one used to
        // borrow the wrong sentence from whichever side it fell on.
        const unreadableWarning =
            '另有控制器的回覆無法判讀，可能已經清除，'
            '所以不要再送一次全車清除 —— '
            '重複清除會讓已完成的控制器再一次重置排放就緒狀態。';
        final prohibition = someoneCleared
            ? harmWarning
            : couldHaveActed
            ? unreadableWarning
            : '';
        final retry = couldHaveActed
            ? '$prohibition請重新掃描確認哪些故障碼還在。'
            : '請稍候再試一次。';
        switch (bytes[2]) {
          case 0x22: // conditionsNotCorrect
            // Composed rather than suffixed, because the order of these two
            // sentences is the whole message.
            //
            // The general form appends `$retry` after the ignition advice, and
            // on a mixed reply that reads as: turn the key to ON, but do not
            // send the clear again. The actionable instruction comes first and
            // the prohibition looks like a footnote to it, so the obvious next
            // action is to do exactly the thing being warned against — and
            // that re-clears the controller which already finished, costing
            // another drive cycle.
            final why =
                '$source拒絕清除，因為目前的車輛狀態不允許。'
                '多數控制器在引擎運轉時不會清除故障記憶。';
            throw DtcReadException(
              couldHaveActed
                  ? '$why$prohibition'
                        '請先將電門轉到 ON 但不要發動引擎，'
                        '再重新掃描確認哪些故障碼還在。'
                  : '$why請將電門轉到 ON 但不要發動引擎，然後再試一次。',
              kind: DtcReadFailure.error,
              repeatWouldHarm: couldHaveActed,
            );
          case 0x11: // serviceNotSupported
          case 0x12: // subFunctionNotSupported
            // Conditional for the same reason 0x22 is, and it was missed
            // when 0x22 was fixed: 其餘控制器可能已經清除 is a guess, and when
            // nobody cleared anything the app is telling somebody not to
            // repeat an operation it has just left the button live for. The
            // two halves of one instruction have to agree.
            throw DtcReadException(
              couldHaveActed
                  ? '$source不支援清除服務（Mode 04）。'
                        '$prohibition請重新掃描確認哪些故障碼還在。'
                  : '$source不支援清除服務（Mode 04），這輛車的故障碼可能要用'
                        '原廠設備才能清除。',
              kind: DtcReadFailure.error,
              repeatWouldHarm: couldHaveActed,
            );
          case 0x21: // busyRepeatRequest
            throw DtcReadException(
              '$source目前忙碌中。$retry',
              kind: DtcReadFailure.error,
              repeatWouldHarm: couldHaveActed,
            );
          case 0x33: // securityAccessDenied
            // No 請稍候再試一次 here even when nothing was erased: waiting
            // does not grant security access, and this one really does need
            // dealer equipment. The button stays live because a retry costs
            // nothing, not because it is likely to work.
            throw DtcReadException(
              '$source要求先通過安全認證才允許清除，'
              '這需要原廠或專用診斷設備。'
              '$prohibition',
              kind: DtcReadFailure.error,
              repeatWouldHarm: couldHaveActed,
            );
          default:
            // Every other ISO 14229 refusal, including the ones a
            // manufacturer defines for itself.
            //
            // Without this the switch fell out into the malformed branch
            // below, whose comment asserted that a clean refusal could not
            // reach it. `7E8 03 7F 04 10` — generalReject, a complete,
            // attributed, perfectly legible "no" — was reported as a damaged
            // reply and locked the button until a rescan. The parser had the
            // whole message; only this switch did not recognise the number.
            //
            // The code is printed rather than named because guessing at a
            // manufacturer-specific NRC is worse than quoting it: this is the
            // sentence somebody reads out over the phone.
            throw DtcReadException(
              '$source拒絕清除（原因碼 '
              '0x${bytes[2].toRadixString(16).toUpperCase().padLeft(2, '0')}）。'
              '$retry',
              kind: DtcReadFailure.error,
              repeatWouldHarm: couldHaveActed,
            );
        }
      }
      // Exactly `44`, not `44` followed by anything.
      //
      // J1979 Mode 04 has no response parameter: completion is the single
      // positive service byte. `7E8 04 44 DE AD BE` declares four application
      // bytes and was accepted as a whole-vehicle success on the strength of
      // the first one — a malformed reply reported as 已送出清除指令 on the
      // operation that cannot be undone.
      if (!_clearCompleted(bytes)) {
        // Somebody else may already have finished, and that changes the
        // advice from "try again" to "do not".
        final anyDone = response.frames.any((f) => _clearCompleted(f.bytes));
        // And when nobody visibly did, this is still *unknown* rather than
        // refused.
        //
        // Everything that reaches here is malformed: a clean refusal is a
        // negative response and was thrown above, so what is left is a reply
        // this app cannot read. `7E8 04 44 DE AD BE` is a `44` with junk after
        // it on an exchange that was transmitted — the controller may well
        // have erased its memory and produced a bad frame — and calling that
        // `notAccepted` left the button live while its damaged twin, the same
        // bytes plus `<RX ERROR>`, locked it. Intact-looking damage was being
        // treated as safer to repeat than damage the adapter admitted to.
        return anyDone
            ? ClearOutcome.partiallyConfirmed
            : ClearOutcome.sentUnconfirmed;
      }
    }
    return ClearOutcome.confirmed;
  }

  /// The VIN alphabet: `I`, `O` and `Q` are excluded by ISO 3779 because they
  /// are confusable with `1` and `0`.
  static final RegExp _vinPattern = RegExp(r'^[A-HJ-NPR-Z0-9]{17}$');

  /// Mode 09 PID 02.
  ///
  /// Mode 01 PID 01 — the vehicle's own summary of its fault memory.
  ///
  /// J1979 defines byte A as the malfunction indicator lamp in bit 7 and the
  /// number of confirmed emissions-related fault codes in bits 0 to 6. It is
  /// the one place the vehicle states, in a single byte, that something is
  /// wrong — and this app read Modes 03, 07 and 0A and never asked.
  ///
  /// Why that matters: a car whose MIL is lit while Mode 03 answers `43 00`
  /// is not a contradiction the app may quietly resolve in favour of the empty
  /// list. It happens — a controller outside the functional request's reach, a
  /// gateway that does not forward Mode 03, a clone filtering replies. The
  /// screen said 未偵測到故障碼 with the lamp on the dashboard in front of the
  /// user.
  ///
  /// Null means the question could not be answered, which is not the same as
  /// "no". Every caller has to treat it that way.
  Future<MilStatus?> readMilStatus({DateTime? deadline}) async {
    if (_busRefusal('故障燈狀態') != null) return null;
    final owner = lifecycleEpoch?.call();
    _requireStillOwned(owner);
    client.knownResponders = _knownResponders ?? const {};
    final ObdResponse response;
    try {
      response = await client.sendGlobal(
        '0101',
        owner: owner,
        deadline: deadline,
      );
    } on Object {
      return null;
    }
    _requireStillOwned(owner);

    // An errored exchange still says who was there.
    //
    // Third round on this same class, and the last place it was hiding.
    // `readMilStatus` returned on `!isSuccess` before looking at anything, so
    // an `<RX ERROR>` on the `0101` reply discarded a `7E9` that had visibly
    // answered `41 01` — and the three DTC categories then completed against
    // `7E8` alone and the panel went green. The adapter's error marker means
    // the *payload* is not data; it does not unsay who sent the lines printed
    // before it.
    //
    // Identity only. Nothing here becomes a summary, because a reply the
    // adapter marked damaged cannot qualify a whole-vehicle verdict.
    if (!response.isSuccess) {
      for (final frame in response.observedFrames) {
        final source = frame.sourceId;
        if (source == null || source.isEmpty) continue;
        if (frame.evidence == ObservedEvidence.candidate) continue;
        // Correlated to the request, so an unrelated frame that happened to
        // arrive during this exchange does not become a fault-code
        // obligation.
        //
        // Exactly, at the position the framing puts it — not by looking for
        // `41 01` in the first three bytes, which is what this did. An
        // observed frame carries its ISO-TP framing, so `06 41 41 01 …` — a
        // perfectly ordinary reply to `0141`, monitor status this drive cycle,
        // whose first data byte happens to be `01` — has `41` at offset 2 and
        // `01` at offset 3, and was read as a PID 01 answer. The controller
        // then owed a fault-code answer it had never been asked for, and the
        // scan refused to call the vehicle clean because of it.
        //
        // Asked of the framing, not of the completed message.
        //
        // The first repair required `payload`, which is bounded by the whole
        // declared message having arrived — and that pointed the rule the
        // wrong way round. A line cut short:
        //
        //   0101 -> 7E8 06 41 01 00 07 65 04
        //           7E9 06 41 01 82 07 65     six declared, five arrived
        //           <RX ERROR
        //
        // has `7E9` visibly answering PID 01 with the fault lamp bit set, and
        // a null payload made the harvest forget it. Mode 03 then completed on
        // `7E8` alone and the panel went green — a false all-clear, which is
        // the failure this whole path exists to prevent, reintroduced by the
        // fix for a spurious refusal. `operand` asks only what the framing can
        // answer: which service, and which PID.
        if (frame.service != 0x01 || frame.operand != 0x01) continue;
        {
          _resolveIdentity(source);
          _observedResponders.add(source);
        }
      }
      return null;
    }

    final bySource = <String, MilSummary>{};
    for (final frame in response.frames) {
      final bytes = frame.bytes;
      // The whole payload, not a prefix of it.
      //
      // J1979 PID 01 is four data bytes — `41 01 A B C D`, where B, C and D
      // are the readiness monitors. Requiring only three accepted a reply
      // whose declared payload stopped after `A`, and read the CAN frame's
      // zero padding as the rest. That is the same class of mistake as
      // reading padding as a service byte, in a reply this app then uses to
      // qualify a whole-vehicle verdict.
      if (bytes.length < 2) continue;
      if (bytes[0] != 0x41 || bytes[1] != 0x01) continue;
      final source = frame.sourceId;
      // An unattributed summary cannot be checked against anybody's fault
      // codes. `_rejectAnonymous` covers the read path; here it is enough to
      // decline the frame, because a summary with no owner can only ever
      // become a claim about a controller nobody can name.
      if (source == null || source.isEmpty) continue;
      // Identity first, payload validity second — the separation this
      // codebase keeps everywhere else and lost right here.
      //
      // A controller that answered `41 01` from a nameable address is on this
      // bus whatever happened to the rest of its reply. Checking the length
      // before recording it meant a truncated summary from `7E9` was dropped
      // *with its identity*, the categories then completed on `7E8` alone, and
      // the panel went green while a module that had visibly answered during
      // that very scan went unaccounted for. Damaged bytes must not become a
      // status value; a definite source must not disappear.
      //
      // PID 01 is mandatory for emissions-related modules, and those are the
      // ones J1979 requires to answer Mode 03.
      _resolveIdentity(source);
      _observedResponders.add(source);

      // The whole payload, and only now.
      //
      // J1979 PID 01 is four data bytes — `41 01 A B C D`, where B, C and D
      // are the readiness monitors. Accepting three read the CAN frame's zero
      // padding as the rest, in a reply this app uses to qualify a
      // whole-vehicle verdict.
      if (bytes.length < 6) continue;
      final a = bytes[2];
      final summary = MilSummary(
        milOn: a & 0x80 != 0,
        confirmedCount: a & 0x7F,
        // B, C and D, which this method has always required to be present and
        // has always thrown away. They are the readiness monitors — the thing
        // every clear in this app warns it is about to reset.
        readiness: Readiness.decode(bytes[3], bytes[4], bytes[5]),
      );
      // A duplicate frame from one controller is one controller. Where two
      // disagree, the one claiming more is kept: a summary is a claim about a
      // fault, and the larger claim is the one that must not be lost.
      final existing = bySource[source];
      if (existing == null ||
          summary.confirmedCount > existing.confirmedCount ||
          (summary.milOn && !existing.milOn)) {
        bySource[source] = summary;
      }
    }
    if (bySource.isEmpty) return null;
    return MilStatus(Map.unmodifiable(bySource));
  }

  /// The stored freeze frames — the car as it was when a fault was confirmed.
  ///
  /// One per controller, never merged, for the reason `readMilStatus` keeps its
  /// summaries apart: these are per-controller claims and combining them makes
  /// one module's snapshot into the vehicle's.
  ///
  /// **The causing code is read first and gates everything else.** A controller
  /// with no frame answers `42 02 00 00 00` — no code, so no frame — and then
  /// answers every other Mode 02 PID with zeroes, which decode into perfectly
  /// well-formed readings: 0 rpm, −40 °C, 0% load. Displayed under 故障發生當下
  /// that is a precise and entirely fictional account of a moment that never
  /// happened, and it is the kind somebody would diagnose against. `decodePair`
  /// already returns null for `0x0000`, so the gate is the same rule Mode 03
  /// uses for its padding rather than a new one.
  Future<FreezeFrameRead> readFreezeFrames({
    int frameNumber = 0,
    DateTime? deadline,
  }) async {
    // Throws rather than returning an empty list, and that distinction is the
    // whole point of this method's contract.
    //
    // `readDtcs`' own doc comment states the rule: "returning [] for 'not
    // executed' is how a mid-scan disconnect became a green no-faults result".
    // Fault codes obeyed it; freeze frames did not, and the consequence was
    // worse than a green panel. An empty list here means 這個控制器沒有儲存凍結
    // 幀 on screen, FIELD_GUIDE tells the reader that is not bad news, and the
    // next thing the screen offers is a clear — which destroys the frame that
    // was there all along and could not be read this time. One Mode 02 timeout
    // on a clone adapter, and the one record of the fault happening is gone.
    final refusal = _busRefusal('凍結幀');
    if (refusal != null) throw DtcReadException(refusal);
    final owner = lifecycleEpoch?.call();
    _requireStillOwned(owner);
    client.knownResponders = _knownResponders ?? const {};

    final frameHex = frameNumber
        .toRadixString(16)
        .toUpperCase()
        .padLeft(2, '0');

    Future<ObdResponse?> ask(String request) async {
      try {
        final r = await client.sendGlobal(
          request,
          owner: owner,
          deadline: deadline,
        );
        _requireStillOwned(owner);
        return r.isSuccess ? r : null;
      } on OperationRetiredException {
        rethrow;
      } on Object {
        return null;
      }
    }

    final causeRequest = '0202$frameHex';
    final causeReply = await ask(causeRequest);
    if (causeReply == null) {
      // The wording that reaches a driver lives on the screen, not here.
      //
      // A previous commit put a "the vehicle may not support it" hedge in this
      // message and claimed it as the fix. `DtcScanNotifier` catches this with
      // `on Object` and keeps only a boolean, so the sentence went nowhere —
      // the panel and the clear dialog render their own static text. Claiming a
      // user-visible change that no user can reach is the same mistake as the
      // gauge-face commit that claimed a treatment it never drew.
      throw const DtcReadException(
        '凍結幀沒有讀到 —— 這不代表車上沒有。',
        kind: DtcReadFailure.noAnswer,
      );
    }

    final causes = <String, Dtc>{};
    // Damage inside a reply the adapter called successful.
    //
    // Three things end this loop early and only one of them is an answer.
    // `00 00` is a controller saying it has no stored code and therefore no
    // frame — silence on the right side of the line. A truncated payload and a
    // frame with no header are the adapter or the bus losing part of the reply,
    // and dropping those without a word is how a damaged read became
    // 沒有儲存凍結幀 on a screen whose next control destroys the frame.
    var damaged = false;
    for (final frame in causeReply.frames) {
      final source = frame.sourceId;
      // An unattributed frame cannot be tied to the controller whose fault it
      // describes, and a snapshot belonging to nobody is not evidence.
      if (source == null || source.isEmpty) {
        damaged = true;
        continue;
      }
      // A negative response is an answer, and it is separable — `7F` is the
      // first byte, and `_dataForNonMode01`'s own first branch rejects on it,
      // so nothing truncated can arrive looking like one.
      //
      // The comment that used to sit here claimed the two were inseparable and
      // folded every negative response into damage. The consequence was that a
      // controller which simply declines Mode 02 produced 「這次沒有讀到凍結幀，
      // 請重新掃描」 on every single scan, advising a retry that could never
      // work.
      //
      // `11` service not supported, `12` sub-function not supported and `31`
      // request out of range are the controller stating that this request has
      // no answer — silence on the right side of the line. Anything else,
      // including a reply that stops before the code, is the exchange breaking.
      final bytes = frame.bytes;
      if (bytes.isNotEmpty && bytes.first == 0x7F) {
        final nrc = bytes.length >= 3 ? bytes[2] : null;
        if (nrc == 0x11 || nrc == 0x12 || nrc == 0x31) continue;
        damaged = true;
        continue;
      }
      final data = _dataForNonMode01(causeRequest, frame.bytes);
      if (data == null) {
        damaged = true;
        continue;
      }
      if (data.length < 2) {
        damaged = true;
        continue;
      }
      final cause = DtcDecoder.decodePair(
        data[0],
        data[1],
        DtcKind.stored,
        sourceId: source,
      );
      // `00 00`: no stored code, so no frame. The one branch that is an
      // answer, and it stays on the silent side.
      if (cause == null) continue;
      causes[source] = cause;
    }
    if (causes.isEmpty) {
      return FreezeFrameRead(frames: const [], incomplete: damaged);
    }

    // Which PIDs each controller froze. Mode 02's mask has the same bit layout
    // as Mode 01's, and names the same PID numbers, so it decodes with the
    // same function — the frame carries different *values* for the same
    // sensors, not different sensors.
    final supported = <String, Set<String>>{};
    // Which controllers answered the support question at all.
    //
    // Separate from [supported] having an entry, because a controller whose
    // mask request timed out and a controller that reported an empty frame end
    // up looking identical otherwise — and the screen then says 「有凍結幀，但
    // 沒有本 App 能解讀的項目」 about a frame nobody read. That is a claim about
    // the contents made from a failure to fetch them.
    final maskAnswered = <String>{};

    // Every published block, not just the first.
    //
    // Bit 0 of each mask is the *next* block's base — `0120` set in the reply
    // to `0200` means `0220` exists — and stopping at one block dropped every
    // frozen PID above 0x20. `0121` distance travelled with the lamp on is in
    // that range and is exactly the sort of thing a frame is read for.
    for (var i = 0; i < PidLibrary.supportQueries.length; i++) {
      final block = PidLibrary.supportQueries[i];
      final next = i + 1 < PidLibrary.supportQueries.length
          ? PidLibrary.supportQueries[i + 1]
          : null;
      final maskReply = await ask('02${block.substring(2)}$frameHex');
      if (maskReply == null) break;
      var continues = false;
      for (final frame in maskReply.frames) {
        final source = frame.sourceId;
        if (source == null || !causes.containsKey(source)) continue;
        final data = _dataForNonMode01(
          '02${block.substring(2)}$frameHex',
          frame.bytes,
        );
        if (data == null || data.length < 4) continue;
        maskAnswered.add(source);
        final decoded = PidLibrary.decodeSupportMask(block, data);
        (supported[source] ??= <String>{}).addAll(decoded);
        // The last bit of each mask is the next block's base, which the
        // vehicle sets to say that mask exists. No controller claiming it
        // means there is nothing further to ask for.
        if (next != null && decoded.contains(next)) continues = true;
      }
      if (!continues) break;
    }
    for (final entry in supported.entries) {
      // PID 02 is the causing code. It is in the mask because it is in the
      // frame, and it has already been read and is already on screen — asking
      // for it again would waste a round trip, and leaving it in the set would
      // count it among the values this app cannot decode when it is the one
      // value it decoded first.
      entry.value.remove('0102');
      // The block bases themselves are "the next mask exists", not sensors.
      entry.value.removeAll(PidLibrary.supportQueries);
    }

    // A controller that named its causing code and then would not say what is
    // in the frame is asked directly instead of given up on.
    //
    // J1979 requires PID 00 support in any service that uses PIDs, so a
    // conforming ECU answers `0200`. Not everything on a real bus conforms:
    // a gateway can filter it, a clone adapter can drop it, and the
    // third-party ELM327 simulator this project checks itself against
    // implements the Mode 02 data PIDs with no mask at all. In every one of
    // those the frame is readable and the app was showing nothing — a car
    // refused for a reply it did not need.
    //
    // Only the conventional frame contents, only where there is a formula, and
    // only for a controller that has already proved a frame exists.
    const probeSet = [
      '0104',
      '0105',
      '0106',
      '0107',
      '010B',
      '010C',
      '010D',
      '010E',
      '010F',
      '0110',
      '0111',
      '011F',
    ];
    final probed = <String>{};
    for (final source in causes.keys) {
      if (maskAnswered.contains(source)) continue;
      probed.add(source);
      supported[source] = probeSet.toSet();
    }

    // Asked once each, broadcast, and attributed on the way back — two
    // controllers with frames cost the same round trips as one.
    final wanted = <String>{for (final s in supported.values) ...s};
    final readings = <String, List<FreezeReading>>{};

    bool decodable(String id) => PidLibrary.all.any((p) => p.modeAndPid == id);

    for (final id in wanted.toList()..sort()) {
      // Present in the frame and this app has no formula for it. Not asked
      // for, and accounted for at the end by difference rather than counted
      // here.
      if (!decodable(id)) continue;
      final pid = PidLibrary.all.firstWhere((p) => p.modeAndPid == id);
      final request = '02${id.substring(2)}$frameHex';
      final reply = await ask(request);
      if (reply == null) continue;
      for (final frame in reply.frames) {
        final source = frame.sourceId;
        if (source == null || !causes.containsKey(source)) continue;
        if (!(supported[source]?.contains(id) ?? false)) continue;
        final data = _dataForNonMode01(request, frame.bytes);
        if (data == null || data.isEmpty) continue;
        final double value;
        try {
          value = formula.evaluateBytes(pid.equation, data, requester: pid);
        } on FormulaException {
          continue;
        }
        // One question, one answer.
        //
        // `_splitBatchedResponse` already refuses a Mode 01 reply where two
        // frames answer the same PID — "picking one is picking at random" — and
        // this path had no such rule, so a controller that answered `020C00`
        // twice put two engine speeds in one card, side by side, differing.
        // Same rule here: a repeat that agrees is a duplicate and is dropped; a
        // repeat that disagrees means neither can be trusted, so the PID goes.
        final already = (readings[source] ??= []).indexWhere(
          (r) => r.pid.modeAndPid == pid.modeAndPid,
        );
        if (already >= 0) {
          if (readings[source]![already].value != value) {
            readings[source]!.removeAt(already);
          }
          continue;
        }
        readings[source]!.add(
          FreezeReading(pid: pid, value: value, raw: List.unmodifiable(data)),
        );
      }
    }

    return FreezeFrameRead(
      incomplete: damaged,
      frames: [
        for (final entry in causes.entries)
          () {
            // Both counts by difference, at one place, from what the controller
            // claimed against what actually came back.
            //
            // The first version incremented a counter at four call sites — the
            // no-formula branch, the formula failure, the conflicting repeat, and
            // nothing at all for a read that timed out. That is one rule in four
            // places with a hole in it, which is the shape this file's comments
            // are mostly about, and the hole was the one that mattered: the
            // freeze read runs last under the scan's shared deadline, so on a
            // slow adapter the early PIDs land, the late ones expire, and the
            // table just gets shorter with nothing saying so.
            final values = readings[entry.key] ?? const <FreezeReading>[];
            // A probed controller never told us what its frame holds, so there
            // is no denominator: a PID that did not answer is one this vehicle
            // does not freeze, not one that went missing. Counting those as
            // 沒有讀回來 would invent a shortfall out of the app's own guess.
            if (probed.contains(entry.key)) {
              return FreezeFrame(
                source: entry.key,
                frameNumber: frameNumber,
                cause: entry.value,
                readings: List.unmodifiable(values),
                undecodable: 0,
                unread: 0,
                contentsUnknown: values.isEmpty,
              );
            }
            final claimed = supported[entry.key] ?? const <String>{};
            final got = values.map((r) => r.pid.modeAndPid).toSet();
            final noFormula = claimed.where((id) => !decodable(id)).length;
            return FreezeFrame(
              source: entry.key,
              frameNumber: frameNumber,
              cause: entry.value,
              readings: List.unmodifiable(values),
              undecodable: noFormula,
              unread: claimed.length - got.length - noFormula,
              contentsUnknown: false,
            );
          }(),
      ],
    );
  }

  /// Returns null rather than a best effort. A VIN is an identity: a shortened
  /// or repaired one is not a lesser answer, it is a different vehicle.
  Future<String?> readVin({DateTime? deadline}) async {
    final owner = lifecycleEpoch?.call();
    _requireStillOwned(owner);
    _requireTimeToWork(deadline);
    // The same gate `readDtcs` has. VIN decoding branches on bus family —
    // legacy replies carry a `49 02 <seq>` envelope per line where CAN sends
    // one reassembled message — so an undetermined protocol means picking a
    // parser at random, and the failure mode is a plausible-looking 17
    // characters rather than an error.
    final refusal = _busRefusal('車身碼');
    if (refusal != null) throw DtcReadException(refusal);
    final response = await client.sendGlobal(
      '0902',
      owner: owner,
      deadline: deadline,
    );
    if (!response.isSuccess) return null;
    // `0902` is a global request like any other, and was the one consumer left
    // outside the attribution gate.
    //
    // Only the anonymity check applies. A fault-code scan asks "is anything
    // wrong anywhere", so not knowing how many controllers answered destroys
    // the answer; a VIN is one value that one controller either gave or did
    // not, and the risk of two responders disagreeing is already refused
    // below by name. Requiring attributability here would drop the VIN on
    // every adapter that will not print headers, for no gain in truth.
    _rejectAnonymous(response);

    if (client.addressing.isCan) {
      // CAN: ISO-TP reassembles each controller's reply into one message whose
      // envelope `49 02 01` appears once. The `01` is a count of data items —
      // a vehicle has one VIN — not a sequence number.
      //
      // Each responder is decoded on its own. Reading `response.bytes` took
      // the first frame, so two controllers answering with *different* valid
      // VINs — a replaced or misconfigured module is exactly when this
      // happens — resolved the vehicle's identity by bus ordering. A conflict
      // is the moment identity becomes unknown, not the moment to pick one.
      final decoded = <String>{};
      for (final frame in response.frames) {
        final bytes = frame.bytes;
        if (bytes.length < 4) continue;
        if (bytes[0] != 0x49 || bytes[1] != 0x02) continue;
        final vin = _vinFromData(bytes.sublist(3));
        if (vin != null) decoded.add(vin);
      }
      if (decoded.isEmpty) return null;
      if (decoded.length > 1) {
        throw VinIdentityConflictException(
          '有 ${decoded.length} 個控制器回報了不同的車身碼（VIN），'
          '無法確認這輛車的身分。可能有模組被更換或設定錯誤。',
        );
      }
      return decoded.first;
    } else {
      // Legacy: every line carries its own `49 02 <seq>` envelope and four
      // data bytes. Stripping three bytes once — the CAN rule — leaves the
      // later envelopes inside the payload, and `0x49` is ASCII `I`, so the
      // old printable-character filter turned them into letters and produced a
      // longer string that still read as a VIN.
      // Grouped by responder first, and that is the whole point. The sequence
      // number orders one controller's lines; it says nothing about which
      // controller sent them. Collecting every frame into one map by sequence
      // alone let two modules divide the numbering between them —
      //
      //   486B10 49 02 01 …   486B10 49 02 02 …
      //   486B18 49 02 03 …   486B18 49 02 04 …   486B18 49 02 05 …
      //
      // — and be spliced into a single syntactically perfect VIN belonging to
      // no vehicle. The parser had preserved both identities; the read then
      // discarded them at exactly the boundary they existed for.
      final perSource = <String, Map<int, List<int>>>{};
      for (final obdFrame in response.frames) {
        final frame = obdFrame.bytes;
        if (frame.length < 4) continue;
        if (frame[0] != 0x49 || frame[1] != 0x02) continue;
        final segments = perSource.putIfAbsent(
          obdFrame.sourceId ?? '',
          () => {},
        );
        final seq = frame[2];
        if (segments.containsKey(seq)) return null; // duplicate line
        segments[seq] = frame.sublist(3);
      }
      if (perSource.isEmpty) return null;

      // An unattributed multi-line reply cannot be bounded to one responder.
      //
      // Grouping by `sourceId ?? ''` restores the identity when headers are
      // on. When `ATH1` was refused every frame carries the same empty source,
      // they all land in one group, and complementary fragments from two
      // controllers are spliced: A supplies segments 1-2, B supplies 3-5, the
      // sequence check sees a contiguous 1..5, and out comes a syntactically
      // perfect VIN that neither module gave.
      //
      // The completeness rule catches the easy version of this — two
      // controllers both answering 1-5 produce duplicates and are already
      // refused — and cannot catch a disjoint split, because there is nothing
      // left to tell it from one controller answering properly.
      //
      // One line is always fine: on a legacy bus one line is one complete
      // message, so it has exactly one author whether or not it is named.
      // …unless something else bounds it to one author. The handshake's `0100`
      // is functional too, and on a legacy bus each reply is one complete
      // line — so the number of lines it drew is a responder count that needs
      // no headers at all. One responder means an unattributed multi-line
      // reply has exactly one possible author, which is the datasheet's own
      // worked example and must keep working.
      final anonymous = perSource.length == 1 && perSource.containsKey('');
      if (anonymous && perSource['']!.length > 1) {
        if (client.responderCount != 1) return null;
      }

      final decoded = <String>{};
      for (final segments in perSource.values) {
        // Assemble in the order the third byte specifies, and require this
        // responder's sequence to be complete: a dropped line must fail the
        // read, not shorten the identity. An incomplete responder is skipped
        // rather than failing the whole read, because another controller may
        // have answered properly — but it can never contribute bytes.
        final order = segments.keys.toList()..sort();
        var complete = true;
        for (var i = 0; i < order.length; i++) {
          if (order[i] != i + 1) complete = false;
        }
        if (!complete) continue;
        final vin = _vinFromData([for (final seq in order) ...segments[seq]!]);
        if (vin != null) decoded.add(vin);
      }
      if (decoded.isEmpty) return null;
      if (decoded.length > 1) {
        // Same rule as CAN: a conflict is the moment identity becomes
        // unknown, not the moment to pick one.
        throw VinIdentityConflictException(
          '有 ${decoded.length} 個控制器回報了不同的車身碼（VIN），'
          '無法確認這輛車的身分。可能有模組被更換或設定錯誤。',
        );
      }
      return decoded.first;
    }
  }

  /// Turns one responder's `49 02` payload into a VIN, or null if it is not one.
  static String? _vinFromData(List<int> data) {
    // J1979 pads the front with 00s — five legacy lines carry 20 bytes for a
    // 17-character VIN.
    var start = 0;
    while (start < data.length && data[start] == 0x00) {
      start++;
    }
    final body = data.sublist(start);

    if (body.length != 17) return null;
    final vin = String.fromCharCodes(body);
    return _vinPattern.hasMatch(vin) ? vin : null;
  }

  /// Identifies the current polling loop.
  ///
  /// Pause and resume are independent and neither awaited the other, so two
  /// loops could exist at once: `start()` set `_running = true` and replaced
  /// the shared completer while the previous loop was still parked on a
  /// command, and that loop's `finally` then completed the *new* loop's
  /// completer — after which a `stop()` returned immediately while polling
  /// carried on. Two loops on one half-duplex link also double the bus load
  /// and race their publications.
  ///
  /// Every loop carries an immutable epoch, checks it after each await, and
  /// can only ever complete its own barrier.
  int _epoch = 0;
  final Map<int, Completer<void>> _loopDone = {};

  void start() {
    if (_running) return;
    // Corruption fallback is per-connection state. Carrying a previous
    // session's disabled fastMode into a fresh one would silently cap
    // throughput at single-PID rates with nothing in the UI explaining why.
    scheduler.resetThrottle();
    _running = true;
    final epoch = ++_epoch;
    _loopDone[epoch] = Completer<void>();
    unawaited(_loop(epoch));
  }

  Future<void> stop() async {
    interruptCapabilityDiscovery();
    if (!_running) return;
    _running = false;
    final epoch = _epoch;
    // Retired here rather than when the next loop starts. The barrier below is
    // bounded at two seconds and a command may take longer, so a reply that
    // lands afterwards still belonged to this epoch — and suppressing only its
    // *publication* left it free to write readings, faults, the formula cache,
    // the acceleration baseline and the scheduler's statistics. The resumed
    // loop's very next snapshot then carried the old result with a fresh
    // timestamp, which is the same stale value the suppression was for.
    _epoch++;
    // Bounded: the loop may be parked on a command that has up to the protocol
    // search deadline to answer, and a disconnect must not appear frozen for
    // that long. The loop's own `finally` still tidies up afterwards.
    await _loopDone[epoch]?.future.timeout(
      const Duration(seconds: 2),
      onTimeout: () {},
    );
    _loopDone.remove(epoch);
    // A pause is a gap by definition. Keeping the smoothed derivative across
    // one pairs a value measured before the pause with the first speed sample
    // after it — and the formula cache has the same problem, so both go.
    _resetAcceleration();
    formula.clearCache();
  }

  Future<void> dispose() async {
    await stop();
    await _snapshots.close();
    await _capabilitySummaries.close();
  }

  Future<void> _loop(int epoch) async {
    try {
      while (_running && epoch == _epoch) {
        // One bad cycle must not end the loop. Without this, a single throw —
        // a timeout on the header switch, a transport hiccup — exits here with
        // `_running` still true, so `isRunning` lies, `start()` no-ops, and the
        // dashboard freezes with no way back short of reconnecting.
        try {
          if (_active.isEmpty) {
            await Future<void>.delayed(const Duration(milliseconds: 120));
            continue;
          }

          await _refreshVoltageIfDue();
          _refillQueue();
          final batch = scheduler.popBatch();
          if (batch.isEmpty) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            continue;
          }

          await _pollBatch(batch, epoch);
          await Future<void>.delayed(scheduler.interCommandDelay);
        } on Object {
          // The client's watchdog owns link recovery; back off and retry.
          await Future<void>.delayed(const Duration(milliseconds: 250));
        }
      }
    } finally {
      // Its own barrier, never whichever one happens to be current — the
      // shared completer let a departing loop release a `stop()` that was
      // waiting on the loop that replaced it.
      final done = _loopDone[epoch];
      if (done != null && !done.isCompleted) done.complete();
    }
  }

  /// How often `ATRV` is re-read. Battery voltage moves slowly but it does
  /// move — it is the first thing that sags when an alternator is failing, and
  /// a figure frozen at whatever it was during the handshake would never show
  /// it. Rare enough not to cost measurable throughput.
  static const Duration voltageInterval = Duration(seconds: 15);
  DateTime? _lastVoltageAt;

  /// Backoff after a failed voltage read, so a refusing adapter is retried
  /// sooner than the steady-state interval rather than left for 15 seconds.
  static const Duration voltageRetryInterval = Duration(seconds: 3);
  DateTime? _lastVoltageFailureAt;

  Future<void> _refreshVoltageIfDue() async {
    final now = DateTime.now();
    final lastSuccess = _lastVoltageAt;
    final lastFailure = _lastVoltageFailureAt;

    // The gate is the last *attempt*, not the last success. Keying it on
    // success alone meant an adapter that never answers `ATRV` — and plenty of
    // clones do not — left `_lastVoltageAt` null forever, so the guard never
    // applied and the command went out on every single cycle. Roughly half the
    // link's throughput, spent on a figure that was never going to arrive.
    final due =
        lastSuccess == null || now.difference(lastSuccess) >= voltageInterval;
    if (!due) return;
    if (lastFailure != null &&
        now.difference(lastFailure) < voltageRetryInterval) {
      // Backing off after a failure, so as not to spend the link on retries.
      return;
    }

    // The timestamp used to be stamped here, before the attempt, so a run of
    // failures still looked like a run of successful refreshes.
    try {
      final response = await client.send(
        'ATRV',
        timeout: const Duration(seconds: 2),
      );
      if (response.batteryVoltage == null) {
        _lastVoltageFailureAt = now;
        return;
      }
      _lastVoltageAt = now;
      _lastVoltageFailureAt = null;
    } on Object {
      _lastVoltageFailureAt = now;
    }
  }

  /// Tops the queue up with any active PID whose target interval has elapsed.
  void _refillQueue() {
    if (scheduler.isNotEmpty) return;
    final now = DateTime.now();
    for (final pid in _active) {
      // Demoted, not retired.
      //
      // A PID the mask denies was invalidated and then skipped forever by the
      // fault it had just been given — so `_answeredAtLeastOnce`, the rule
      // that lets a direct answer outrank an absent mask bit, could never
      // fire. On a clone with a partial or inaccurate support map that is a
      // sensor the vehicle actually has, dark for the whole connection, with
      // no way back short of reconnecting.
      //
      // It keeps the 不支援 label, because nothing has contradicted the mask
      // yet. It just gets asked again occasionally, alone and rarely enough
      // to cost nothing — and if the vehicle answers, the answer wins.
      if (_knownUnsupported(pid)) {
        if (_faults[pid.id] != PidFault.unsupported) {
          _invalidate(pid.id, PidFault.unsupported);
          _retryAfter[pid.id] = now.add(recheckInterval);
          continue;
        }
      }
      final retryAt = _retryAfter[pid.id];
      if (retryAt != null) {
        if (now.isBefore(retryAt)) continue;
        _retryAfter.remove(pid.id);
      }
      final last = _readings[pid.id]?.timestamp;
      final due =
          last == null || now.difference(last) >= pid.priority.targetInterval;
      if (due) scheduler.enqueue(pid, pid.priority);
    }
  }

  /// Increments whenever the active definitions change.
  int _definitions = 0;

  /// The exact authorized profile PID instances for the current definitions.
  ///
  /// Replaced wholesale on every [setActivePids]; the sink guard in
  /// [_pollBatch] requires object identity, not id membership, so forged or
  /// stale queued work cannot transmit a profile command the session never
  /// authorized — including a forgery whose id collides with an authorized
  /// definition while carrying different wire bytes.
  Map<String, Pid> _authorizedProfileDefinitions = const {};

  Future<void> _pollBatch(List<QueuedRequest> batch, [int? epoch]) async {
    // Absolute sink guard for catalog/profile commands. Filtering the active
    // set is not sufficient because a caller can inject a scheduler carrying
    // old or forged queued work. One unauthorized profile-owned member makes
    // the entire batch non-transmittable. Returning before command assembly
    // is intentional: a malformed mixed batch must not smuggle profile bytes
    // into an otherwise ordinary request.
    final unauthorizedProfile = batch.where(
      (request) =>
          request.pid.ownerProfileId != null &&
          !identical(
            request.pid,
            _authorizedProfileDefinitions[request.pid.id],
          ),
    );
    if (unauthorizedProfile.isNotEmpty) {
      for (final request in batch) {
        if (request.pid.ownerProfileId != null) {
          _invalidate(request.pid.id, PidFault.refusedUnsafeService);
        }
      }
      _publish(epoch);
      return;
    }

    // J1979 requests mean nothing on a J1939 bus, and this was the path the
    // J1939 split never reached: the fix was wired into the fault-code and VIN
    // reads and into the tests, and not into the telemetry it was about. On a
    // permissive bridge that lets the `0100` probe through, `010C` still went
    // out and anything that happened to parse became a number on a gauge.
    if (!client.addressing.supportsObd2) {
      for (final request in batch) {
        _invalidate(request.pid.id, PidFault.busError);
      }
      _publish(epoch);
      return;
    }

    final definitions = _definitions;
    // Multi-PID requests are an ISO 15765 feature. On a legacy bus the adapter
    // answers with one PID's data, which would then be mis-split across the
    // batch's members.
    //
    // Also held off until capability is known. Support discovery runs
    // concurrently with the first poll cycles, so batching before it lands
    // means asking about PIDs the vehicle may not implement — a J1979 ECU
    // answers about the ones it has and omits the rest, the batch comes back
    // short, and the corruption handler disables fast mode for the entire
    // session. That happens on nearly every real car, seconds after
    // connecting. Single-PID polling until then costs a few cycles; a session
    // with fast mode permanently off costs the whole drive.
    // At least one block has to have *answered*. `_supported` becoming an
    // empty set — which is what a discovery where every block failed produces
    // — is not the same as knowing the vehicle implements nothing, but it is
    // non-null, so it used to open the batching gate with zero verified
    // capability. The first batch then asked about PIDs nothing had confirmed,
    // came back short, and disabled fast mode for the rest of the session:
    // precisely the failure the gate was added to prevent, reached by the
    // other door.
    scheduler.canBatch =
        client.addressing.isCan && _verifiedSupportBlocks.isNotEmpty;
    scheduler.isBatchable = _isBatchable;

    final command = scheduler.buildCommand(batch);
    if (command.isEmpty) return;

    // Last line of defence for the safety allowlist. The editor and the CSV
    // importer both refuse a write or control service, but a definition stored
    // by an older build would otherwise be scheduled here — repeatedly, for as
    // long as its gauge is on the dashboard.
    final unsafe = batch.where(
      (r) => !PollableServices.isPollable(r.pid.modeAndPid),
    );
    if (unsafe.isNotEmpty) {
      for (final request in unsafe) {
        // Its own fault kind, for the reason `headerNotOnThisBus` has one
        // thirty lines below: nothing was sent, so nothing about the vehicle
        // was learned. Reporting this as `unsupported` put 此車輛不支援 under a
        // blanked-out dial on the strength of a decision this app made about a
        // definition the user can edit.
        _invalidate(request.pid.id, PidFault.refusedUnsafeService);
      }
      if (unsafe.length == batch.length) {
        _publish(epoch);
        return;
      }
    }

    final header = batch.first.pid.header;
    final addressing = client.addressing;

    // A header only goes on the wire when it means something on the detected
    // bus. The app's stored default is `7E0`, which is the engine's address on
    // 11-bit CAN and not a header at all anywhere else; transmitting it there
    // would discard the addressing `ATSP0` established.
    if (!addressing.shouldTransmit(header) &&
        !BusAddressing.isAppDefault(header)) {
      // A custom header that cannot exist on this bus. Polling it anyway would
      // answer from whichever controller the adapter happens to be addressing,
      // and that reply is indistinguishable from the right one.
      //
      // Its own fault kind, because it is not a statement about the car. The
      // definition asks for an address this bus cannot carry, and rendering
      // that as 此車輛不支援 sent people looking at their vehicle for a problem
      // sitting in a field they can edit.
      for (final request in batch) {
        _invalidate(request.pid.id, PidFault.headerNotOnThisBus);
      }
      _publish(epoch);
      return;
    }

    final ObdResponse response;
    try {
      // Header and query in one chain slot, so nothing else can execute
      // against a header that was selected for this batch.
      final expectedResponseId = batch.first.pid.expectedResponseId;
      response = expectedResponseId == null
          ? await client.sendAddressed(header, command)
          : await client.sendGlobal(
              command,
              header: header,
              timeout: client.commandTimeout,
            );
      if (epoch != null && epoch != _epoch) return;
      // The definitions this request was built from are gone, so its answer
      // describes a question nobody is asking any more. Writing it to the
      // cache would answer a *different* definition's `VAL{}` reference.
      if (definitions != _definitions) return;
    } on OperationRetiredException {
      // Nothing was transmitted and nothing is wrong; the app simply stopped
      // asking. Marking the PID faulty here would put an error on a gauge for
      // the act of backgrounding the app.
      return;
    } on UnaddressableRequestException {
      // Not a timeout: there is no header on this bus that would reach the
      // controller this request is about, and no amount of waiting changes
      // that. Yielding to the watchdog would retry it every cycle for the rest
      // of the session behind a gauge that is simply dark — the silence being
      // exactly what makes a wrong reading and a missing one hard to tell
      // apart. It is recorded as a fault so the screen can say so.
      for (final request in batch) {
        _invalidate(request.pid.id, PidFault.busError);
      }
      _publish(epoch);
      return;
    } on Object {
      // A timeout or dropped link — the watchdog owns recovery, so just yield.
      await Future<void>.delayed(const Duration(milliseconds: 200));
      return;
    }

    if (!response.isSuccess) {
      _handleErrorResponse(batch, response, epoch);
      return;
    }

    // Some ECUs reject an unsupported Mode 01 PID with the UDS-shaped
    // `7F 01 12` response instead of staying silent. That is explicit
    // capability evidence, not a damaged bus and not sensor bytes. The GT86
    // field trace uses this exact shape for PID 015E. Back it off like a
    // support-mask denial so it cannot consume a low-speed bus in a hot loop,
    // while retaining the normal finite recheck that lets a later answer win.
    if (batch.length == 1 &&
        _isUnsupportedMode01Negative(response, batch.single.pid)) {
      final id = batch.single.pid.id;
      _invalidate(id, PidFault.unsupported);
      _retryAfter[id] = DateTime.now().add(recheckInterval);
      _noDataStrikes.remove(id);
      _publish(epoch);
      return;
    }

    final slices = _splitBatchedResponse(response, batch);

    // A batch is all-or-nothing. Accepting a reply that only contained the
    // first two of six PIDs leaves the other four showing their previous
    // numbers with no fault and no requeue — stale values that look live. Any
    // shortfall means the frame was truncated or mis-aligned, so fastMode goes
    // off and the whole batch is retried one PID at a time.
    if (slices.length != batch.length &&
        batch.length > 1 &&
        !_isProfileResponseBatch(batch)) {
      scheduler.handleCorruptionEvent();
      for (final request in batch) {
        scheduler.enqueueRequest(request);
      }
      return;
    }
    if (slices.length != batch.length && _isProfileResponseBatch(batch)) {
      for (final request in batch) {
        _invalidate(request.pid.id, PidFault.busError);
      }
      _publish(epoch);
      return;
    }

    final now = DateTime.now();
    var completed = 0;
    for (final request in batch) {
      final bytes = slices[request.pid.id];
      if (bytes == null) {
        // A requested PID with no matching slice means the reply did not
        // contain the answer — truncated, misaligned, or about something else.
        // Skipping it silently was how a gauge kept its last good number:
        // the tile still had a value, the value was plausible, and nothing on
        // screen said the sensor had stopped answering minutes ago.
        _invalidate(request.pid.id, PidFault.busError);
        continue;
      }
      try {
        final value = formula.evaluateBytes(
          request.pid.equation,
          bytes,
          requester: request.pid,
          now: now,
        );
        // Catalog profile ranges are part of the reviewed source contract,
        // not merely gauge display bounds. A correctly attributed frame can
        // still be the wrong variant, firmware or byte layout; publishing a
        // numerically valid but source-impossible value would turn that
        // mismatch into confident telemetry. Fail before either cache can
        // make the value visible to this PID or a dependent formula.
        //
        // Ordinary built-in and user-authored PIDs retain their historical
        // behavior: their min/max values are presentation bounds and may be
        // exceeded by a real sensor or a deliberately wider formula.
        if (request.pid.ownerProfileId != null &&
            (!value.isFinite ||
                value < request.pid.minValue ||
                value > request.pid.maxValue)) {
          _invalidate(request.pid.id, PidFault.formulaError);
          continue;
        }
        formula.cachePidValue(request.pid, value, now);
        // `BARO` is the one formula input with no byte of its own to bind to,
        // so it has to be routed here from the PID that measures it. Without
        // this, removing the sea-level default would leave every BARO formula
        // permanently unavailable — trading a wrong answer for no answer,
        // which is better but still not the fix.
        if (request.pid.modeAndPid.toUpperCase() ==
            PidLibrary.barometricPressure.modeAndPid) {
          formula.setBaroPressure(request.pid, value, now);
        }
        _readings[request.pid.id] = Reading(
          pid: request.pid,
          value: value,
          rawBytes: bytes,
          timestamp: now,
        );
        if (request.pid.id == PidLibrary.vehicleSpeed.id) {
          _trackAcceleration(value, now);
        }
        _faults.remove(request.pid.id);
        _noDataStrikes.remove(request.pid.id);
        _formulaStrikes.remove(request.pid.id);
        _retryAfter.remove(request.pid.id);
        // Before `_answeredAtLeastOnce`, so the next `_refillQueue` sees a PID
        // with no fault and a vehicle that has just answered it.

        if (_answeredAtLeastOnce.add(request.pid.id)) {
          _publishCapabilitySummary();
        }
        completed++;
      } on FormulaException {
        _invalidate(request.pid.id, PidFault.formulaError);
        // Rested only once it has stopped looking temporary.
        //
        // Only `NO DATA` had a backoff, so a formula that always throws — one
        // referencing a `VAL{...}` PID nothing polls, say — was invalidated,
        // immediately due again, and took a bus slot at its own priority every
        // cycle for the rest of the session. The reply arrived perfectly well;
        // it is the arithmetic that cannot succeed, and re-asking the vehicle
        // is not what fixes that.
        //
        // But the *first* failures of a `VAL{}` gauge are ordinary: its
        // dependency has not been read yet, and it starts working a cycle or
        // two later. Backing off immediately delayed exactly the case that was
        // about to succeed. Strikes, like `NO DATA`, and reset on any success.
        final strikes = (_formulaStrikes[request.pid.id] ?? 0) + 1;
        _formulaStrikes[request.pid.id] = strikes;
        if (strikes >= _formulaStrikesBeforeBackoff) {
          _retryAfter[request.pid.id] = DateTime.now().add(formulaErrorBackoff);
        }
      }
    }

    scheduler.recordCompletions(completed);
    _publish(epoch);
  }

  static bool _isUnsupportedMode01Negative(ObdResponse response, Pid pid) {
    final request = pid.modeAndPid.toUpperCase();
    if (!request.startsWith('01') || response.frames.isEmpty) return false;

    // Judge complete logical messages, never the flattened byte prefix.
    // Headerless legacy replies preserve one [ObdFrame] per response line but
    // concatenate all of them in `response.bytes`. Treating that concatenation
    // as one message lets `7F 01 12` from one controller hide a valid positive
    // reply from another, and lets a damaged `7F 01 12 DE AD` look like exact
    // capability evidence. The finite five-minute backoff is warranted only
    // when every complete response is exactly the observed three-byte refusal.
    return response.frames.every((frame) {
      final bytes = frame.bytes;
      return bytes.length == 3 &&
          bytes[0] == 0x7F &&
          bytes[1] == 0x01 &&
          bytes[2] == 0x12;
    });
  }

  /// Consecutive `NO DATA` answers per PID, reset by any successful read.
  final Map<String, int> _noDataStrikes = {};

  /// When a backed-off PID may be tried again.
  final Map<String, DateTime> _retryAfter = {};

  /// How long a PID rests after a run of unanswered requests.
  ///
  /// Long enough that a genuinely absent sensor costs almost nothing, short
  /// enough that one recovers within a drive rather than needing a reconnect.
  static const Duration noAnswerBackoff = Duration(seconds: 60);

  /// How long a mask-denied PID waits before being asked once more.
  ///
  /// Long, because the mask is usually right and a wrong guess here costs bus
  /// time on every cycle. Finite, because when the mask is wrong the
  /// alternative is a sensor the vehicle has staying dark for the whole
  /// connection.
  static const Duration unsupportedRecheckInterval = Duration(minutes: 5);

  /// The interval actually used, so a test can reach the retry.
  ///
  /// Five minutes is right for a car and impossible for a test, so the rule —
  /// that a mask-denied PID is asked again and that a real answer outranks the
  /// mask — was pinned only by asserting the constant is positive. That is not
  /// the rule; it is the number. A reviewer named the gap, and the same day a
  /// different unpinned rule was deleted by accident and nothing noticed.
  @visibleForTesting
  Duration recheckInterval = unsupportedRecheckInterval;

  /// How long a PID rests after its formula fails.
  ///
  /// Shorter than [noAnswerBackoff], because a formula error is often about a
  /// value that has not arrived *yet* — a `VAL{...}` dependency scheduled at a
  /// lower priority, a physics input still warming up — and those resolve on
  /// their own within a second or two.
  static const Duration formulaErrorBackoff = Duration(seconds: 5);

  /// Consecutive formula failures before a PID is rested.
  ///
  /// A `VAL{}` gauge legitimately fails its first evaluations while the PID it
  /// references is still being read for the first time, so resting on the
  /// first one delays the case that was about to start working.
  static const int _formulaStrikesBeforeBackoff = 4;

  final Map<String, int> _formulaStrikes = {};

  /// How many in a row before a PID is written off as unsupported.
  ///
  /// Three rather than one: the ELM327 datasheet defines `NO DATA` as no
  /// accepted response before the timeout, which a slow or busy ECU can produce
  /// on a PID it fully supports.
  static const int _noDataStrikesBeforeUnsupported = 3;

  /// Marks a PID as faulted and drops its last reading.
  ///
  /// Keeping the previous value alongside a fault is how a frozen gauge ends up
  /// looking live: the tile has a number, the number is plausible, and nothing
  /// on screen says it stopped updating three minutes ago.
  void _invalidate(String pidId, PidFault fault) {
    _faults[pidId] = fault;
    _readings.remove(pidId);
  }

  void _handleErrorResponse(
    List<QueuedRequest> batch,
    ObdResponse response, [
    int? epoch,
  ]) {
    if (response.errorCode == Elm327ErrorCode.bufferFull) {
      scheduler.handleCorruptionEvent();
      return;
    }
    if (response.errorCode.countsAgainstThisPid) {
      // A batch that returns NO DATA does not say which member was at fault, so
      // only a single-PID request is conclusive. Batches get retried one by one.
      if (batch.length == 1) {
        final id = batch.first.pid.id;
        final strikes = (_noDataStrikes[id] ?? 0) + 1;
        _noDataStrikes[id] = strikes;

        // `NO DATA` is generated by the *adapter* when nothing arrived before
        // its own timeout, not by the vehicle saying it does not implement the
        // PID. A busy ECU, a filtered message, or one aggressive timing window
        // produces it just as well — and treating the first one as final meant
        // a real gauge went grey for the rest of the session with nothing on
        // screen explaining why, and no way back short of reconnecting.
        if (strikes < _noDataStrikesBeforeUnsupported) {
          _invalidate(id, PidFault.busError);
          scheduler.enqueueRequest(batch.first);
          _publish(epoch);
          return;
        }
        // Repeated silence is still not the vehicle saying it lacks the
        // sensor — only the support mask says that, and a PID the mask
        // disclaimed never reaches this path because it is filtered out of the
        // poll set. So this backs off rather than retiring the PID: a slow ECU
        // or a receive filter used to grey a working gauge out for the rest of
        // the session, with nothing on screen explaining why.
        _invalidate(id, PidFault.noAnswer);
        _retryAfter[id] = DateTime.now().add(noAnswerBackoff);
        _noDataStrikes.remove(id);
      } else {
        scheduler.handleCorruptionEvent();
        for (final request in batch) {
          scheduler.enqueueRequest(request);
        }
      }
      _publish(epoch);
      return;
    }
    for (final request in batch) {
      _invalidate(request.pid.id, PidFault.busError);
    }
    _publish(epoch);
  }

  /// Extracts the data bytes of a non-Mode-01 reply, or null if the reply does
  /// not belong to [pid].
  ///
  /// Three ways a reply can fail to be this PID's data, all of which used to
  /// reach the formula as sensor bytes:
  ///
  ///  * `7F <service> <NRC>` is the ECU refusing. With formula `A` that made
  ///    `7F` display as 127 — a plausible reading manufactured out of a
  ///    refusal. NRC `0x78` in particular means "response pending", a reason
  ///    to keep waiting, never a value.
  ///  * a positive reply to a *different* service.
  ///  * a positive reply echoing a different identifier — a late or
  ///    interleaved answer to some other request, which on a shared bus is an
  ///    ordinary occurrence rather than an exotic one.
  /// Takes the request string rather than the [Pid] that carried it, because
  /// the freeze-frame reader asks the same PIDs under service 02 — `02 0C 00`
  /// for the RPM that was frozen, against `01 0C` for the RPM now — and the
  /// only difference that matters is which bytes the ECU echoes before its
  /// data. Writing that rule a second time over there is exactly how one rule
  /// in two places drifts, which is the shape of most of what this file's
  /// comments are about.
  static List<int>? _dataForNonMode01(String modeAndPid, List<int> bytes) {
    if (bytes.isEmpty) return null;
    if (bytes.first == 0x7F) return null;

    final request = modeAndPid.toUpperCase();
    if (request.length < 4 || request.length.isOdd) return null;

    final mode = int.tryParse(request.substring(0, 2), radix: 16);
    if (mode == null) return null;
    if (bytes.first != mode + 0x40) return null;

    // Everything after the mode in the request is the identifier the ECU
    // echoes back before its data.
    final identifier = <int>[];
    for (var i = 2; i + 1 < request.length; i += 2) {
      final b = int.tryParse(request.substring(i, i + 2), radix: 16);
      if (b == null) return null;
      identifier.add(b);
    }

    if (bytes.length <= 1 + identifier.length) return null;
    for (var i = 0; i < identifier.length; i++) {
      if (bytes[1 + i] != identifier[i]) return null;
    }

    return bytes.sublist(1 + identifier.length);
  }

  static bool _isProfileResponseBatch(List<QueuedRequest> batch) {
    if (batch.isEmpty) return false;
    final first = batch.first.pid;
    final profile = first.ownerProfileId;
    final response = first.expectedResponseId;
    if (first.isMode01 ||
        profile == null ||
        profile.isEmpty ||
        response == null ||
        response.isEmpty) {
      return false;
    }
    return batch.every(
      (request) =>
          request.pid.ownerProfileId == profile &&
          request.pid.header == first.header &&
          request.pid.modeAndPid == first.modeAndPid &&
          request.pid.expectedResponseId == response &&
          request.pid.responseDataLengthBytes == first.responseDataLengthBytes,
    );
  }

  /// Applies a catalog signal's byte window after the response envelope has
  /// been removed. Invalid or incomplete source data is never shortened into
  /// something that still looks formula-compatible.
  static List<int>? _dataWindow(Pid pid, List<int> data) {
    final offset = pid.dataOffsetBytes ?? 0;
    final length = pid.dataLengthBytes;
    if (offset < 0 || (length != null && length <= 0)) return null;
    if (offset > data.length) return null;
    final end = length == null ? data.length : offset + length;
    if (end > data.length || end <= offset) return null;
    return data.sublist(offset, end);
  }

  /// Returns the one envelope-valid response from exactly the controller a
  /// profile names. Any anonymous, wrong-source or duplicate frame makes the
  /// exchange unattributable and therefore unusable.
  static List<int>? _attributedData(ObdResponse response, Pid pid) {
    final expected = pid.expectedResponseId?.toUpperCase();
    if (expected == null || expected.isEmpty) return null;

    final matches = <List<int>>[];
    for (final frame in response.frames) {
      if (frame.bytes.isEmpty) continue;
      if (frame.sourceId?.toUpperCase() != expected) return null;
      final data = _dataForNonMode01(pid.modeAndPid, frame.bytes);
      final declaredLength = pid.responseDataLengthBytes;
      if (data == null ||
          declaredLength == null ||
          declaredLength <= 0 ||
          data.length != declaredLength) {
        return null;
      }
      matches.add(data);
    }
    return matches.length == 1 ? matches.single : null;
  }

  /// Splits a reply into per-PID data slices, keyed by [Pid.id].
  ///
  /// Adapters differ on batched replies: some repeat the `41` mode byte before
  /// every PID (`41 0C 1A F0 41 0D 3C`), others emit it once (`41 0C 1A F0 0D
  /// 3C`). Both are accepted by treating a `41` as optional at each step.
  Map<String, List<int>> _splitBatchedResponse(
    ObdResponse response,
    List<QueuedRequest> batch,
  ) {
    final bytes = response.bytes;
    if (bytes.isEmpty) return const {};

    final expected = <int, Pid>{};
    for (final request in batch) {
      final code = request.pid.pidByte;
      if (code != null) expected[code] = request.pid;
    }

    final result = <String, List<int>>{};

    if (_isProfileResponseBatch(batch)) {
      final data = _attributedData(response, batch.first.pid);
      if (data == null) return const {};
      for (final request in batch) {
        final window = _dataWindow(request.pid, data);
        if (window == null) return const {};
        result[request.pid.id] = window;
      }
      return result;
    }

    // A single Mode 01 request whose PID has no declared width: everything
    // after `41 <pid>` is that PID's data by construction, however much of it
    // the author's formula references. Enforcing an inferred width here
    // rejected valid replies — `41 0C 1A F8` for a custom `010C` defined as
    // `A` — which is the app declining to read something it demonstrably can.
    //
    // Only reachable for custom PIDs, and only outside a batch, where nothing
    // depends on knowing where this PID's bytes end.
    if (batch.length == 1 &&
        batch.first.pid.isMode01 &&
        batch.first.pid.declaredDataBytes == null) {
      final pid = batch.first.pid;
      final code = pid.pidByte;
      if (code == null) return const {};

      // Bounded by the frame, not by a sentinel hunted through flattened
      // bytes. `response.bytes` is every line glued together, and searching it
      // for `41 <code>` was wrong in both directions at once.
      //
      // It let contamination in: a delayed `41 0D 3C` arriving before the same
      // prompt concatenates to `41 0C 1A F8 41 0D 3C`, the scan finds no
      // second `41 0C`, five bytes clears the length cap, and a formula
      // referencing `C` reads the unrelated service byte `0x41` and publishes
      // 65. The requested reply had no `C` byte at all and should have failed.
      //
      // And it refused valid data: a controller legitimately answering
      // `41 0C 41 0C` has data bytes `41 0C` — 4163 rpm under the standard
      // formula — which the scan mistook for a second responder and discarded.
      // A byte sentinel cannot recover a frame boundary that was thrown away;
      // only the boundary can.
      final matching = <List<int>>[];
      var extra = 0;
      for (final frame in response.frames) {
        final data = frame.bytes;
        if (data.length >= 2 && data[0] == 0x41 && data[1] == code) {
          matching.add(data.sublist(2));
        } else if (data.isNotEmpty) {
          extra++;
        }
      }
      // Two answers to one question means two controllers, and without a
      // declared width there is nothing to say which bytes are whose. Anything
      // else in the exchange is something this request cannot account for —
      // the same "consume the payload completely" rule the declared-width path
      // below already enforces.
      if (matching.length != 1 || extra > 0) return const {};
      final data = matching.first;
      if (data.isEmpty) return const {};
      // One responder's data cannot outrun a single frame.
      if (data.length > 7) return const {};

      // The frame boundary is authoritative only when the adapter drew one.
      // Some print two responders on a single line, headers off, and then the
      // glue is invisible: `41 0C 1A F8 41 0C 05 00` is one frame carrying two
      // answers. So a second envelope inside the data is still refused —
      // but on the one property that distinguishes an envelope from a byte
      // that happens to be `0x41`.
      //
      // A second responder's `41 <pid>` must be followed by at least one data
      // byte, because an answer with no data is not an answer. That is what
      // separates the two cases the old scan got wrong in opposite
      // directions: `1A F8 41 0D 3C` has three bytes after the `41`, so it is
      // contamination; data of exactly `41 0C` has none after the pair, so it
      // is 4163 rpm and must be read.
      //
      // The residual is real and its cost is a concrete J1979 PID, not a
      // hypothetical. Round 8 supplied the example: a custom definition on
      // `0122` whose controller answers `41 22 41 00 01`. The data `41 00 01`
      // is one complete answer, and this refuses it, because it is
      // indistinguishable from `41 00` followed by the start of a second
      // reply.
      //
      // Narrowing the sentinel to `41 <this pid>` would accept that and
      // reopen the case it was built for: an adapter gluing a *different*
      // PID's late reply onto the same line, where a formula referencing a
      // byte it never received reads the unrelated service byte instead. This
      // app ranks a confident wrong number below a visible refusal, so the
      // refusal stays — but it is a limitation of the parser and not of the
      // vehicle, and the fault must say so rather than implying a missing
      // sensor.
      for (var i = 0; i + 2 < data.length; i++) {
        if (data[i] == 0x41) return const {};
      }

      return {pid.id: data};
    }

    var i = 0;
    // Non-Mode-01 replies (custom headers, Mode 22) are single-PID by
    // construction, but "single" is not the same as "whatever came back is the
    // answer". The reply has to identify itself as belonging to this request.
    if (batch.length == 1 && !batch.first.pid.isMode01) {
      // Per frame, not on the flattened payload — the same rule the widthless
      // Mode 01 path was given and this sibling was not.
      //
      // A custom PID may use a functional header, `7DF` say, and two
      // controllers then answer `22 F1 90` with different values. Concatenated
      // that is `62 F1 90 10 62 F1 90 50`; validating the first envelope and
      // returning everything after it publishes `A = 0x10 = 16`, a confident
      // number from whichever controller happened to print first, while the
      // equally valid `0x50` is silently swallowed into its tail.
      final pid = batch.first.pid;
      if (pid.expectedResponseId != null) {
        final data = _attributedData(response, pid);
        if (data == null) return const {};
        final window = _dataWindow(pid, data);
        return window == null ? const {} : {pid.id: window};
      }
      final matches = <List<int>>[];
      for (final frame in response.frames) {
        final data = _dataForNonMode01(pid.modeAndPid, frame.bytes);
        if (data != null) matches.add(data);
      }
      // Two answers to a question that has one answer means the request
      // reached more than one controller, and nothing in the definition says
      // which was meant. Picking one is picking at random.
      if (matches.length != 1) return const {};
      final window = _dataWindow(pid, matches.first);
      if (window == null) return const {};
      result[pid.id] = window;
      return result;
    }

    // The payload must be consumed completely. Returning whatever had been
    // collected when parsing went wrong is how `41 0C 1A F8 DE AD` displayed
    // 1726 RPM and reported no fault: the prefix parsed, `DE AD` was dropped,
    // and nothing required the frame to make sense as a whole. A frame the app
    // cannot fully account for is not the answer to the question it asked.
    while (i < bytes.length) {
      // Zero padding is legal here and only here — at a PID-byte boundary,
      // after everything asked for has been answered. A CAN frame is eight
      // bytes whatever the payload occupies.
      //
      // `0100` has PID byte 0x00 and would be indistinguishable from padding,
      // but support discovery is never batched, so it cannot reach this path.
      var padded = true;
      for (var j = i; j < bytes.length; j++) {
        if (bytes[j] != 0) {
          padded = false;
          break;
        }
      }
      if (padded) break;

      if (bytes[i] == 0x41) {
        i++;
        // A service byte with nothing after it is a truncated frame, not a
        // complete one that happens to end early.
        if (i >= bytes.length) return const {};
      }
      final pid = expected[bytes[i]];
      if (pid == null) {
        // Unknown PID byte: the frame is not aligned to what we asked for.
        return const {};
      }
      if (result.containsKey(pid.id)) {
        // The same PID answered twice in one frame. With headers off and a
        // functional request that is two controllers replying — the ECM's
        // `41 0D 3C` and the TCM's `41 0D 00` concatenate — and the second
        // assignment used to overwrite the first, so a car doing 60 km/h
        // displayed zero while every downstream check passed. Neither answer
        // can be attributed, so neither is used.
        return const {};
      }
      i++;
      final width = pid.dataByteCount;
      if (i + width > bytes.length) return const {};
      result[pid.id] = bytes.sublist(i, i + width);
      i += width;
    }
    return result;
  }

  /// Publishes the current snapshot, unless [epoch] has been superseded.
  ///
  /// `stop()`'s barrier is bounded at two seconds, but a command may have up to
  /// five — or twenty-five during a protocol search. Pausing while the loop is
  /// parked on one therefore returns before that command resolves, and its
  /// completion path then published a full snapshot *over* the empty one the
  /// pause had just emitted. The pre-pause values came back at full opacity,
  /// stamped with the time they finished arriving, so the wall-clock staleness
  /// check could not catch them either.
  ///
  /// This is finding M5-5, narrowed by awaiting the stop and then surviving in
  /// the window the timeout leaves open.
  void _publish([int? epoch]) {
    // Both conditions, and the history is why. The first attempt checked only
    // the epoch and did nothing, because `stop()` did not touch `_epoch` —
    // a late publish on a plain pause still carried the current one and sailed
    // through. `stop()` retires the epoch now, so that check works; `!_running`
    // stays because it is the cheaper and more direct statement of the same
    // thing, and because a comment claiming one guard is redundant is how the
    // other one gets removed later.
    if (epoch != null && (epoch != _epoch || !_running)) return;
    _publishNow();
  }

  void _publishNow() {
    if (_snapshots.isClosed) return;
    _snapshots.add(current);
  }
}
