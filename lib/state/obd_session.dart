/// Connection lifecycle and live telemetry.
///
/// One controller owns the whole chain — transport → [Elm327Client] →
/// [PollingEngine] — because their lifetimes are identical and splitting them
/// across providers would mean three places that each have to know when the
/// other two are valid.
library;

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/field_evidence/evidence_text.dart';
import '../core/field_evidence/platform_metadata.dart';
import '../core/network/android_wifi_route_binder.dart';
import '../obd/dtc/dtc.dart';
import '../obd/elm327_client.dart';
import '../obd/pid/pid.dart';
import '../obd/freeze_frame.dart';
import '../obd/polling_engine.dart';
import '../obd/session_evidence.dart';
import '../obd/transcript_store.dart';
import '../obd/telemetry.dart';
import '../obd/transcript.dart';
import '../obd/transport/ble_transport.dart';
import '../obd/transport/classic_transport.dart';
import '../obd/transport/demo_transport.dart';
import '../obd/transport/obd_transport.dart';
import '../obd/transport/wifi_transport.dart';
import 'pid_registry.dart';
import 'settings.dart';

enum ConnectionPhase {
  disconnected,
  connecting,
  handshaking,
  connected,
  failed,
}

/// Physical events a passenger can stamp into the same timeline as OBD bytes.
///
/// These are intentionally presets rather than free text: one large tap while
/// parked is safer and less error-prone than typing beside a running vehicle.
enum FieldEventMarker {
  ignitionOn('電門 ON'),
  engineStarted('引擎發動'),
  throttleBlip('輕踩油門'),
  roadTestStarted('道路測試開始');

  const FieldEventMarker(this.label);

  final String label;
}

enum FieldEventRecordResult { persisted, memoryOnly, unavailable }

class ObdConnectionState {
  final ConnectionPhase phase;
  final TransportKind? kind;
  final String deviceName;
  final String protocol;

  /// What the connection is waiting on right now, for the phase where nothing
  /// else moves — the transport's own attempt, before any handshake step has
  /// been sent.
  final String detail;

  /// Adapter supply voltage at the handshake, or null if it was never read.
  ///
  /// Nullable for the reason `TelemetrySnapshot` gives for the same quantity:
  /// zero volts is a *claim* about the battery, and an unread value is the
  /// absence of one. It was a non-nullable double defaulting to 0 — no current
  /// consumer was misled, because the dashboard reads the snapshot's value,
  /// and that is exactly the shape a future one falls into.
  final double? batteryVoltage;
  final String? error;

  /// Handshake steps observed so far, in order, for the wizard's live list.
  final List<InitProgress> initSteps;

  const ObdConnectionState({
    this.phase = ConnectionPhase.disconnected,
    this.kind,
    this.deviceName = '',
    this.protocol = '',
    this.detail = '',
    this.batteryVoltage,
    this.error,
    this.initSteps = const [],
  });

  bool get isConnected => phase == ConnectionPhase.connected;
  bool get isBusy =>
      phase == ConnectionPhase.connecting ||
      phase == ConnectionPhase.handshaking;

  ObdConnectionState copyWith({
    ConnectionPhase? phase,
    TransportKind? kind,
    String? deviceName,
    String? protocol,
    String? detail,
    double? batteryVoltage,
    String? error,
    bool clearError = false,
    List<InitProgress>? initSteps,
  }) {
    return ObdConnectionState(
      phase: phase ?? this.phase,
      kind: kind ?? this.kind,
      deviceName: deviceName ?? this.deviceName,
      protocol: protocol ?? this.protocol,
      detail: detail ?? this.detail,
      batteryVoltage: batteryVoltage ?? this.batteryVoltage,
      error: clearError ? null : (error ?? this.error),
      initSteps: initSteps ?? this.initSteps,
    );
  }
}

/// Turns an exception thrown while connecting into a sentence for a driver.
///
/// `'$e'` used to reach the screen directly. Measured on a phone, 2026-08-20,
/// against a BLE peripheral that accepts a GATT connection and then answers
/// nothing:
///
///     TimeoutException after 0:00:10.000000: Future not completed
///
/// One branch away, a failed handshake says 轉接器可能不相容 — something a
/// person at a car can act on. This path had no equivalent, so anything that
/// was not a `TransportException` arrived verbatim.
///
/// The raw text is not discarded: `_failAttempt` writes it into the transcript,
/// which is where a maintainer reads it. This decides only what the driver sees.
String describeConnectException(Object error) {
  if (error is TimeoutException) {
    return '轉接器接受了連線，但在時限內沒有回應。'
        '通常是它還沒通電 —— 多數 OBD 插座要電門轉到 ON 才供電；'
        '也可能是它正被另一個 App 連著，先關掉那個再試。';
  }
  return '連線在建立過程中失敗了。請確認轉接器已通電、就在附近，'
      '然後再試一次。完整的錯誤留在下方的紀錄裡。';
}

class ObdSession extends Notifier<ObdConnectionState> {
  Elm327Client? _client;
  PollingEngine? _engine;

  /// Build provenance is compile-time in production and injectable only so
  /// unit tests can lock the safety boundary without launching an APK.
  @visibleForTesting
  bool testRigBuild = isObdTestRigBuild;

  /// Frozen into [_sessionEvidence] when an attempt starts. The exact Android
  /// application ID is authoritative. Only the exact production Android ID is
  /// field eligible; every other Android ID fails closed as simulated.
  @visibleForTesting
  PlatformMetadata platformMetadata = platformMetadataCache.value;

  bool get _currentSessionIsTestRig =>
      _sessionEvidence?.testRig ??
      (testRigBuild || platformMetadata.requiresSimulatedEvidence);

  StreamSubscription<InitProgress>? _initSub;
  StreamSubscription<TelemetrySnapshot>? _snapshotSub;

  final _telemetry = StreamController<TelemetrySnapshot>.broadcast();

  @override
  ObdConnectionState build() {
    // Keep the running poller in step with the user's PID selection. Without
    // this the polling set is frozen at whatever it was when the session
    // connected: a gauge added from the PID manager shows dashes forever, and
    // one removed keeps consuming bus bandwidth.
    ref.listen(activePidsProvider, (previous, next) => syncActivePids(next));

    // A vehicle session is foreground-only, and saying so explicitly is the
    // fix for two problems at once: the app must stop putting traffic on a
    // car's bus while the user is elsewhere, and it must not present values
    // captured before the interruption as current when they come back.
    _lifecycle = AppLifecycleListener(
      onPause: _onAppPaused,
      onResume: () => unawaited(_onAppResumed()),
    );

    ref.onDispose(() {
      // First, so anything still in flight is already superseded.
      //
      // A resume probe outlives the provider: it is a three-second `ATRV` on
      // an unawaited chain, and if the container is disposed while it is out
      // there, its failure path used to run against a dead `Ref` and throw
      // "Cannot use the Ref … after it has been disposed" out of a zone
      // nobody catches. The generation counter is exactly the token for "this
      // session is over"; disposal is the strongest form of that and was the
      // one case not stamping it.
      _generation++;
      _lifecycle?.dispose();
      _lifecycle = null;
      unawaited(_teardown());
      unawaited(_telemetry.close());
    });
    return const ObdConnectionState();
  }

  AppLifecycleListener? _lifecycle;

  /// True when the poller was stopped by the app going to the background,
  /// as opposed to by the user or a failure.
  bool _pausedByLifecycle = false;

  /// Whether the app is in the foreground *now*.
  ///
  /// Tracked separately from [_pausedByLifecycle] and from whether an engine
  /// exists. `_onAppPaused` used to return early when `_engine == null`, so a
  /// connection still running its protocol search — up to 25 seconds — would
  /// finish in the background, install an engine and start polling with no
  /// record that the app had ever been backgrounded. The next resume then saw
  /// nothing to recover and skipped revalidation entirely.
  /// How long the census fired at connect may take before it gives up.
  ///
  /// Generous — it competes with the first poll and a slow adapter's four
  /// commands — but finite, which is the point.
  static const Duration censusBudget = Duration(seconds: 20);

  bool _foreground = true;

  /// Whether the app is in the foreground.
  ///
  /// Public because the poll loop is not the only thing that talks to the
  /// vehicle. A fault-code scan spans three code classes and a VIN, support
  /// discovery runs its own command chain, and a protocol search can hold one
  /// for twenty-five seconds — none of which `_onAppPaused` was stopping. The
  /// app's foreground-only policy has to cover every producer, or the comments
  /// claiming the session is parked are describing one of them.
  bool get isForeground => _foreground;

  /// Serialises lifecycle transitions.
  ///
  /// Pause and resume had independent asynchronous owners: `_pauseNow` ran
  /// unawaited, so a quick resume could complete its `ATRV` probe and start a
  /// new polling loop before the old `stop()` had returned. The old stop then
  /// reset the acceleration baseline and formula cache belonging to the *new*
  /// loop, and the pause's empty snapshot landed after it had begun
  /// publishing. One chain means a resume cannot overtake the pause it
  /// follows.
  Future<void> _lifecycleChain = Future<void>.value();

  /// How many times the app has been backgrounded this session.
  ///
  /// `isForeground` is a *sample*, and a scan checking it at each checkpoint
  /// cannot see a suspension that began and ended between two of them — every
  /// check passes and the verdict is assembled across a gap nobody owned,
  /// which is the exact reason the check was added. A counter cannot miss it:
  /// the interruption leaves a mark whether or not anyone was looking.
  int _pauseEpoch = 0;

  /// The value a long operation should capture and re-compare.
  int get pauseEpoch => _pauseEpoch;

  void _onAppPaused() {
    // Snapshot first, before anything else this method does.
    //
    // `onPause` is the last callback Android reliably delivers before it is
    // free to kill the process, and a session killed in a car park is exactly
    // the one somebody would want to read afterwards — it went wrong in a way
    // the user could not sit and watch. Unawaited because the freeze can begin
    // as soon as this returns; a write that does not finish leaves the
    // previous snapshot intact, which is the whole reason it is staged and
    // renamed rather than written in place.
    _client?.transcript.recordNote('App 進入背景');
    unawaited(_saveTranscriptSnapshot());
    _pauseEpoch++;
    _foreground = false;
    // Synchronously, and before anything is queued. The freeze can start at
    // any moment after this callback returns, and the watchdog's next tick
    // will be delivered after it against a wall clock that moved on — so the
    // flag has to be set now, not by whatever the lifecycle chain gets round
    // to.
    _client?.suspendLiveness();
    final engine = _engine;
    if (engine == null || !engine.isRunning) return;
    _pausedByLifecycle = true;
    _lifecycleChain = _lifecycleChain.then((_) => _pauseNow(engine));
  }

  /// Stops the poller, then says so on screen.
  ///
  /// In that order. Publishing the empty snapshot first left it to be
  /// overwritten by whichever full snapshot the still-running loop had in
  /// flight — so the gauges went blank and then repopulated with pre-pause
  /// values at full opacity, and `isStale` could not tell because both
  /// timestamps came from the same source.
  Future<void> _pauseNow(PollingEngine engine) async {
    await engine.stop();
    // Everything on screen describes a moment that has passed. Publishing an
    // empty snapshot is what makes the gauges say so instead of holding their
    // last numbers at full opacity.
    //
    // Unless the app came back while the stop was draining — announcing a
    // pause over a session that is already live again is its own wrong
    // answer, and the resumed loop would have to overwrite it.
    //
    // The condition was inverted, which reversed both halves: the empty
    // snapshot was withheld on an ordinary pause (so returning to the app
    // showed pre-pause values at full brightness until the first new reading)
    // and published on the one occasion it should not have been.
    if (_foreground) return;
    if (!_telemetry.isClosed) _telemetry.add(const TelemetrySnapshot());
  }

  Future<void> _onAppResumed() {
    _foreground = true;
    _client?.transcript.recordNote('App 回到前景');
    // First thing, and unconditionally. Timers that came due while the process
    // was frozen are delivered now, in expiry order, and the watchdog's is
    // among them; `_resumeNow` is queued behind the pause still unwinding and
    // is far too late to beat it.
    _client?.markAlive();
    if (!_pausedByLifecycle) return Future<void>.value();
    // Queued behind whatever pause is still unwinding.
    _lifecycleChain = _lifecycleChain.then((_) => _resumeNow());
    return _lifecycleChain;
  }

  Future<void> _resumeNow() async {
    final client = _client;
    final engine = _engine;
    if (client == null || engine == null) {
      _pausedByLifecycle = false;
      return;
    }

    // Time passed with nothing running to receive bytes. That is not the
    // adapter going quiet, but the watchdog compares against a wall clock and
    // cannot tell the difference — every resume would otherwise tear down a
    // healthy link.
    client.markAlive();

    // Prove the link before showing live numbers again. A user who plugged the
    // adapter into a different car, or drove out of Bluetooth range while the
    // app was backgrounded, should not see the old vehicle's values resume.
    final generation = _generation;
    try {
      final probe = await client.send(
        'ATRV',
        timeout: const Duration(seconds: 3),
      );
      if (_superseded(generation)) return;
      if (!probe.isSuccess) {
        _handleConnectionLost(generation);
        return;
      }
    } on Object {
      _handleConnectionLost(generation);
      return;
    }

    if (_superseded(generation)) return;
    // Backgrounded again while the probe was in flight. Starting here would
    // poll the vehicle from the background — and because the flag used to be
    // cleared on entry rather than here, the next resume would see nothing to
    // recover and skip the link check altogether.
    if (!_foreground) return;

    _pausedByLifecycle = false;
    engine.start();

    // Discovery is interrupted by a pause rather than answered by one, and
    // nothing else would ever ask again — `_connectInner` fires it once. An
    // incomplete capability map keeps batching shut, so leaving it incomplete
    // costs the session its throughput for no reason.
    if (!engine.supportDiscoveryComplete) {
      unawaited(engine.discoverSupportedPids());
      // The responder census, taken once against the vehicle actually attached.
      // A fault-code scan can tell who answered but not who should have, and a
      // controller that stays silent shows up in no count at all.
      // Bounded, because nothing else bounds it. Fired unawaited, this had no
      // deadline at all — and a scan starting a moment later joined it, so the
      // census the scan was blocked on could outlive the scan's own budget.
      unawaited(
        engine.discoverResponders(deadline: DateTime.now().add(censusBudget)),
      );
    }
  }

  Stream<TelemetrySnapshot> get telemetryStream => _telemetry.stream;

  PollingEngine? get engine => _engine;

  /// The live client, for the two things that talk to the adapter directly:
  /// the transcript export and the manual command box.
  Elm327Client? get client => _client;

  /// This attempt's record, created at the tap rather than at the handshake.
  ObdTranscript? _attemptTranscript;

  /// The last session's traffic, kept after the client is gone.
  ObdTranscript? _lastTranscript;
  String _lastTranscriptHeader = '';

  /// Facts frozen for the attempt whose bytes are in [_attemptTranscript].
  ///
  /// Kept beside the transcript rather than rebuilt at export: by then the
  /// user may have changed vehicle settings or selected another adapter, and a
  /// plausible header describing the wrong session is worse than no header.
  SessionEvidenceMetadata? _sessionEvidence;
  int _evidenceSequence = 0;

  /// The transcript worth exporting right now: the live one if there is a
  /// session, otherwise the last one that ended.
  ///
  /// Never null once anything has been attempted, which is the property that
  /// matters — a failed connection is exactly when somebody needs this and
  /// exactly when there is no client to hang it off.
  ObdTranscript? get exportableTranscript =>
      _client?.transcript ?? _attemptTranscript ?? _lastTranscript;

  /// The header for [exportableTranscript].
  String get exportableTranscriptHeader => exportableRecord?.header ?? '';

  /// The transcript and the header that describes it, read together.
  ///
  /// Two accessors could not be used safely: the export reads the transcript,
  /// awaits a temporary directory, and only then reads the header — and a
  /// connection begun in that gap gives it the *new* session's adapter,
  /// protocol and bus over the *old* session's bytes. A record whose heading
  /// describes a different car is worse than no record, because nothing in it
  /// looks wrong.
  ///
  /// Also fixes which header a live attempt gets. The old rule keyed on
  /// `_client`, so a failure before the client exists — a refused Wi-Fi
  /// socket, a Bluetooth cascade that timed out — exported this attempt's
  /// bytes under the *previous* session's heading. `transcriptHeader` renders
  /// from the attempt's own cached connection facts and is right with or
  /// without a client; only a fall back to `_lastTranscript` wants the stored
  /// one.
  ({ObdTranscript transcript, String header})? get exportableRecord {
    final current = _client?.transcript ?? _attemptTranscript;
    if (current != null && !current.isEmpty) {
      return (transcript: current, header: transcriptHeader);
    }
    final last = _lastTranscript;
    if (last != null && !last.isEmpty) {
      return (transcript: last, header: _lastTranscriptHeader);
    }
    return null;
  }

  /// Whether there is anything to export at all.
  bool get hasTranscript => exportableRecord != null;

  /// A one-line description of what produced a transcript.
  ///
  /// A record with no idea what made it is most of the way to useless — the
  /// first question anybody asks of a log is which adapter and which protocol.
  /// Connection facts kept outside `state`.
  ///
  /// The header is rendered during teardown, and teardown can run from
  /// `ref.onDispose`, where reading `state` throws "Cannot use Ref … inside
  /// life-cycles". Caching the three strings as they are set costs nothing and
  /// keeps the one render that matters — the one for a session that is ending
  /// — out of that trap.
  String _sessionKind = '';

  /// Which transport this recording came off, cached alongside the header's
  /// other facts.
  ///
  /// Read from the cache rather than from `state`, and that is not a
  /// preference: `_saveTranscriptSnapshot` runs from `dispose` and from the
  /// app-pause handler, and Riverpod asserts on reading a notifier's `state`
  /// inside a life-cycle callback. Doing it the obvious way took out fifty
  /// tests at once with an assertion nowhere near the cause.
  TransportKind? _sessionTransport;
  String _sessionDevice = '';
  String _sessionProtocol = '';

  static String _evidenceHeaderValue(
    String value, {
    required String whenEmpty,
  }) {
    final trimmed = value.trim();
    return trimmed.isEmpty ? whenEmpty : escapeEvidenceText(trimmed);
  }

  String get transcriptHeader {
    final c = _client;
    final evidence = _sessionEvidence;
    final buffer = StringBuffer();
    if (evidence == null) {
      buffer
        ..writeln('# Telltale 傳輸紀錄')
        ..writeln(
          '# 連線方式：${_evidenceHeaderValue(_sessionKind, whenEmpty: '未連線')}',
        )
        ..writeln(
          '# 裝置：${_evidenceHeaderValue(_sessionDevice, whenEmpty: '—')}',
        );
    } else if (evidence.transportMetadataCompleted) {
      buffer.write(evidence.renderHeader());
    } else {
      buffer.write(
        evidence.renderHeader(
          latestTransportMetadata: c?.transport.diagnosticMetadata ?? const {},
        ),
      );
    }
    buffer.writeln(
      '# 協定：${_evidenceHeaderValue(_sessionProtocol, whenEmpty: 'unknown')}',
    );
    if (c != null) {
      buffer
        ..writeln(
          '# 轉接器回報：${_evidenceHeaderValue(c.deviceVersion, whenEmpty: '—')}',
        )
        ..writeln(
          '# ATDPN：${_evidenceHeaderValue(c.protocolNumber, whenEmpty: '—')}',
        )
        ..writeln(
          '# 匯流排：${c.addressing.family.name}，'
          '標頭 ${c.addressing.headerHexDigits} 位，'
          '接收寬度 ${c.addressing.acceptedReceiveWidths.join('/')}',
        );
      // Whether the adapter's account of itself holds together.
      //
      // In the log rather than on a gauge, deliberately. `v1.5` is printed on
      // a very large share of the adapters people actually buy and most of
      // them work — so this is a fact about the device for whoever reads the
      // transcript afterwards, not a verdict to put in front of a driver. It
      // also cannot say anything about whether the *readings* are true, and a
      // note that looked like it could would be worse than none.
      final identity = c.adapterIdentity;
      buffer.writeln('# 轉接器自述：${escapeEvidenceText(identity.summaryLine)}');
      for (final concern in identity.concerns) {
        buffer.writeln('#   ⚠ ${escapeEvidenceText(concern.summary)}');
      }
    }
    return buffer.toString();
  }

  /// Sends one command exactly as typed.
  ///
  /// Goes through the ordinary command chain rather than around it. A manual
  /// command that bypassed the chain would interleave with the polling loop's
  /// traffic and produce replies neither side could attribute — which is the
  /// failure this whole codebase is organised against, arriving through the
  /// one screen meant for diagnosing it.
  Future<String> sendManualCommand(String command) async {
    final c = _client;
    if (c == null) throw const TransportException('尚未連線');
    final trimmed = command.trim();
    if (trimmed.isEmpty) throw const TransportException('沒有輸入指令');
    final refusal = manualCommandRefusal(trimmed);
    if (refusal != null) throw TransportException(refusal);
    c.transcript.recordNote('手動送出：$trimmed');
    final response = await c.send(trimmed);
    return response.rawLines.join('\n');
  }

  /// Adds a passenger-entered physical event and persists it immediately.
  Future<FieldEventRecordResult> recordFieldEvent(
    FieldEventMarker marker,
  ) async {
    final client = _client;
    if (!state.isConnected ||
        client == null ||
        _sessionTransport == TransportKind.demo ||
        _currentSessionIsTestRig) {
      return FieldEventRecordResult.unavailable;
    }
    client.transcript.recordNote('實車事件：${marker.label}');
    final persisted = await _saveTranscriptSnapshot();
    return persisted
        ? FieldEventRecordResult.persisted
        : FieldEventRecordResult.memoryOnly;
  }

  /// Why a typed command will not be sent, or null if it will.
  ///
  /// Serialising the box onto the ordinary command chain stopped it
  /// *interleaving* with the poll loop. It did not stop it changing the
  /// adapter underneath the app's model of it, and that is the part that
  /// produces a wrong number:
  ///
  ///   a poll selects `7E0` and the client caches it
  ///   the user types `ATSH 7E1`, the adapter says OK
  ///   the next built-in `010C` trusts the cache, sends no `ATSH`,
  ///   and the transmission answers 1000 rpm as the engine's
  ///
  /// Nothing on screen says which controller replied, and the number is
  /// entirely plausible. `ATZ`, `ATD`, `ATSP`, `ATE1`, the filter and mask
  /// commands and the monitoring commands all invalidate the negotiated model
  /// the same way.
  ///
  /// And Mode 04 is worse than a wrong number: typed here it skips the
  /// confirmation dialog, the coverage check, the acknowledgement check and
  /// the lifecycle guard, clears whichever controller happens to be selected,
  /// and resets the readiness monitors while the app's own model of the scan
  /// knows nothing happened.
  ///
  /// So the box asks questions. It does not change anything.
  static String? manualCommandRefusal(String command) {
    final c = command.trim().toUpperCase().replaceAll(' ', '');
    if (c.isEmpty) return '沒有輸入指令。';
    // Before anything is classified, because everything below classifies *one*
    // command and a control character means there is more than one.
    //
    // `\r` is the ELM327's command terminator, so `03\r04` is not a Mode 03
    // request containing an odd character — it is two requests, and the second
    // is a Mode 04 clear. Every check below reads the first two characters,
    // saw `03`, and let the whole string through: the read-only box erased the
    // vehicle's fault memory, skipping the confirmation, the coverage check
    // and the response validation that the 清除 button exists to enforce.
    //
    // Nobody types this. Pasting is how it arrives — a command copied off a
    // forum post or out of a log brings its line ending with it, and the
    // trailing one is harmless only because `trim` already took it.
    if (c.codeUnits.any((u) => u < 0x20 || u == 0x7F)) {
      return '指令裡有換行或控制字元，這樣會一次送出多個指令。'
          '轉接器以換行分隔指令，所以第二個指令不會經過這裡的任何檢查 —— '
          '包括禁止清除故障碼的那一項。請一次只輸入一個指令。';
    }
    if (c.startsWith('AT')) {
      final at = c.substring(2);
      // Named individually rather than by prefix: `ATDP` and `ATDPN` ask which
      // protocol is in use, `ATD` resets everything to defaults, and a prefix
      // rule would get that exactly backwards.
      const readOnly = {
        'I',
        '@1',
        '@2',
        '@3',
        'RV',
        'DP',
        'DPN',
        'PPS',
        'IGN',
        'DESC',
        'CS',
        'CV',
        'RD',
      };
      if (readOnly.contains(at)) return null;
      return '手動指令只接受查詢，不接受會改變轉接器設定的指令。'
          '「$command」會改動轉接器狀態，而 App 對轉接器的認知不會跟著更新 —— '
          '接下來的讀數可能來自另一個控制器，而畫面上看不出來。\n'
          '可用的查詢：ATI、AT@1、ATRV、ATDP、ATDPN、ATPPS、ATIGN。';
    }
    // OBD services. Only the read-only ones, and never Mode 04 — clearing has
    // its own button, and that button is where every safeguard lives.
    final service = c.length >= 2 ? c.substring(0, 2) : '';
    // Mode 08 is not on this list, and its absence is the point.
    //
    // J1979 names it "request control of on-board system, test or component" —
    // it *actuates* things: evaporative-system leak tests, solenoids, pumps.
    // It was sitting on a whitelist whose contract is read-only because its
    // number looks like its neighbours', which is exactly how a control
    // service ends up being sent by a box labelled 查詢.
    //
    // `05` is on it, and was missing. J1979 defines it as "request oxygen
    // sensor monitoring test results" — stored results from completed tests,
    // read-only, with a sensor byte rather than a PID. Leaving it out refused
    // a legitimate query on the buses where it is the *only* way to ask: it is
    // defined for pre-CAN implementations only, ISO 9141-2 and the J1850
    // pair, where Mode 06 does not replace it.
    const readOnlyServices = {
      '01',
      '02',
      '03',
      '05',
      '06',
      '07',
      '09',
      '0A',
      '22',
    };
    if (c == '04' || c.startsWith('04')) {
      return '清除故障碼請用故障碼畫面的「清除」按鈕。'
          '從這裡送出會跳過確認、覆蓋率檢查與回應驗證，'
          '而且只會清到目前選中的那一個控制器。';
    }
    // The whole command, not its first two characters.
    //
    // Everything above is a whitelist and this line was not: it matched a
    // prefix and passed the rest through unread, so `03;04` was a Mode 03
    // request as far as this was concerned. A reviewer names `;` as a command
    // separator on STN-based adapters (OBDLink); the datasheet search did not
    // confirm that, and the decision does not depend on it — no legal OBD
    // request contains a character outside `0-9A-F`, so requiring them costs
    // nothing, and being wrong in the other direction sends a clear.
    //
    // The same rule the response parser uses, pointed the other way: accept
    // what is recognisably legal rather than reject what is recognisably not.
    // A blacklist of separators is a list somebody has to keep complete.
    if (!RegExp(r'^[0-9A-F]+$').hasMatch(c)) {
      return '指令「$command」含有 OBD 指令不會出現的字元。'
          '這裡只接受十六進位的服務碼與參數（例如 0100、03、2211A6），'
          '或 AT 開頭的轉接器查詢。';
    }
    if (readOnlyServices.contains(service)) return null;
    // Listed from the set rather than written out beside it. They had already
    // drifted: Mode 05 was admitted and the help text still omitted it, so
    // somebody whose command was refused was told 05 was not allowed by the
    // same sentence that was supposed to tell them what is.
    final allowed = (readOnlyServices.toList()..sort()).join('/');
    return '不認得的指令「$command」。'
        '這裡只接受唯讀查詢（Mode $allowed）與轉接器查詢指令。';
  }

  /// Starts the built-in simulator. Needs no permissions and no hardware, so
  /// it is also what the app falls back to when the user just wants to look
  /// around.
  Future<bool> connectDemo() => _connect(DemoTransport(), TransportKind.demo);

  /// Connects an arbitrary transport. Tests only.
  ///
  /// The seam exists because two whole classes of defect live *above* the
  /// engine and had no way to be reached: the scan's cross-check against the
  /// vehicle's own PID 01 summary, and the ordering between the census and the
  /// first category read. Both are notifier behaviour, and every notifier test
  /// had to go through `connectDemo`, whose simulator derives its PID 01 count
  /// from its own Mode 03 list and therefore cannot disagree with itself.
  ///
  /// Reviewers named that gap in two consecutive rounds. A seam this thin is a
  /// smaller price than a rule nothing can test.
  @visibleForTesting
  Future<bool> connectForTest(ObdTransport transport, TransportKind kind) =>
      _connect(transport, kind);

  Future<bool> connectWifi({String? host, int? port}) => _connect(
    WifiTransport(
      host: host ?? WifiTransport.defaultHost,
      port: port ?? WifiTransport.defaultPort,
      // Only Android reroutes sockets away from an internet-less Wi-Fi, so
      // only Android gets a binder. dart:io Platform, not
      // defaultTargetPlatform: the flutter_test harness pretends every host
      // is Android, and a host-run test must not acquire a phantom lease.
      routeBinder: Platform.isAndroid ? AndroidWifiRouteBinder() : null,
    ),
    TransportKind.wifi,
  );

  Future<bool> connectClassic(DiscoveredDevice device) {
    // Self-referencing, so the callback can ask whether the transport it
    // belongs to is still the one being connected.
    //
    // The generation number cannot answer that here: this runs *before*
    // `_connect` bumps it, so a closure over `generation` reads the getter and
    // compares the field with itself — always false, a guard that compiles and
    // checks nothing. Identity is the fact actually available at this point.
    late final ClassicTransport transport;
    transport = ClassicTransport(
      address: device.id,
      name: device.name,
      // Published so the screen can say what the wait is for. Three tiers
      // of up to twelve seconds each is a long time to show nothing.
      onAttempt: (tier) {
        // A cascade the user abandoned goes on announcing its tiers until the
        // tier in flight ends. Both destinations belong to whoever is current:
        // the wizard showed 未加密 SPP 連線 for a device nobody was connecting
        // to any more, and the note landed in the *next* attempt's transcript,
        // which is the one record that has to be trustworthy afterwards.
        if (!identical(_inFlightTransport, transport)) return;
        _attemptTranscript?.recordNote(tier);
        if (state.isBusy) state = state.copyWith(detail: tier);
      },
    );
    return _connect(transport, TransportKind.bluetoothClassic);
  }

  Future<bool> connectBle(BleAdapterHandle device) =>
      _connect(BleTransport(device), TransportKind.bluetoothLe);

  /// Guards against overlapping connect attempts.
  ///
  /// Set synchronously, before the first `await`. Two quick taps on a device
  /// row would otherwise both reach `_teardown()`, and the second would dispose
  /// the client the first is still handshaking through, leaving `_client` and
  /// `_engine` pointing at different sessions.
  bool _connecting = false;

  /// The attempt currently unwinding or in flight, so a later tap can wait for
  /// it rather than be refused by it.
  Future<bool>? _inFlight;

  /// The transport that attempt is using, for callbacks that have to ask
  /// whether they still speak for the current connection.
  ObdTransport? _inFlightTransport;

  /// How long an abandoned attempt is given to unwind before the new one gives
  /// up on waiting for it.
  ///
  /// Sized from the transports' own ceilings rather than picked: a Bluetooth
  /// Classic tier is capped at 12 seconds, a Wi-Fi socket at 8, and a BLE
  /// connect at 15 — and the BLE one is cut short in practice because
  /// `device.disconnect()` aborts an in-flight connect. Twenty leaves margin
  /// over the slowest of those without being a wait anybody would sit through
  /// twice.
  /// Overridable so a test can put a slow teardown *inside* the budget.
  ///
  /// The number itself was pinned by nothing: the cancellation tests unwind in
  /// milliseconds, so moving the stopwatch back below `_teardown()` — which is
  /// the bug this budget was introduced to fix — left the suite green.
  @visibleForTesting
  static Duration abandonTimeout = const Duration(seconds: 20);

  /// Incremented by every connect, disconnect and link loss.
  ///
  /// The `_connecting` flag only stops two connects overlapping. It does
  /// nothing about a link dropping, or the user tapping disconnect, *while* a
  /// handshake is still running: `_teardown()` would dispose the client and the
  /// older path would carry on, install an engine and publish `connected`,
  /// leaving a session whose client no longer exists. Async work therefore
  /// captures the generation and re-checks it after every await before
  /// installing anything.
  int _generation = 0;

  /// Identifies the current connection.
  ///
  /// Public because a multi-step operation that outlives a single await — a
  /// fault-code scan reads three classes and then a VIN — has to be able to
  /// tell that the car it started on is still the car it is talking to.
  int get generation => _generation;

  /// How many times a *new connection* has been started.
  ///
  /// [generation] answers "is the work I started still the current work", and
  /// is bumped by anything that invalidates in-flight work — including losing
  /// the link. That makes it the wrong token for "is the screen still about
  /// the same vehicle", and using it for that suppressed the one message a
  /// dropped clear exists to show: the drop *is* a generation change, so the
  /// clear's own continuation refused to publish 清除指令送出後連線中斷 and the
  /// user was left with a blank panel and a live button over a controller that
  /// may already have erased its memory.
  ///
  /// This counter moves only when somebody starts connecting to something. A
  /// clear whose link died still describes the car it was sent to; a clear
  /// that finishes after the user has connected to a different one does not.
  int get connectEpoch => _connectEpoch;
  int _connectEpoch = 0;

  Future<bool> _connect(ObdTransport transport, TransportKind kind) async {
    // A tap that arrives while another attempt is running used to be dropped
    // on the floor: `return false`, no state change, no message.
    //
    // That is the wizard's worst failure, because of who hits it. The bonded
    // device list is the phone's, so it holds headphones, a car stereo and a
    // laptop beside the adapter, and tapping the wrong row is the ordinary
    // mistake. 取消 invalidated the attempt but could not stop it — so for up
    // to three twelve-second tiers afterwards the *correct* adapter did
    // nothing when tapped, silently, on the app's first screen. The reasonable
    // reading is that the app is broken, and the reasonable response is to
    // force-quit it.
    //
    // Clearing `_connecting` here instead — which is the obvious fix — is
    // worse than the bug. Two native connects would then race for one adapter,
    // and an ELM327 accepts exactly one link: the loser wedges the winner. So
    // the attempts stay serialised, and what changes is that the new one
    // *cancels and waits for* its predecessor instead of being refused by it.
    if (_connecting) {
      // Synchronously, before any await: from this instant every older attempt
      // is superseded and can publish nothing, whatever it goes on to
      // discover. Kept, because it is also this caller's claim on being the
      // one the user is waiting for.
      _connectEpoch++;
      final mine = ++_generation;
      // Said out loud, because the wait is the part that looks broken.
      //
      // 取消 returns the screen to idle, so a tap during the abandoned tier's
      // remaining seconds produced nothing at all on screen until it ended —
      // the same silence the cancel was supposed to end, moved a few seconds
      // later. Naming the device makes it clear the tap registered and which
      // one it was for.
      state = ObdConnectionState(
        phase: ConnectionPhase.connecting,
        kind: kind,
        deviceName: transport.displayName,
        detail: '正在中止上一個連線，請稍候…',
      );
      // Reaches the transport. `_teardown` disposes the client, and
      // `Elm327Client.dispose()` disconnects its transport — which is where a
      // Bluetooth Classic cascade learns to stop at the end of the tier it is
      // in rather than walking the remaining two.
      // One budget for the whole handover, not one per await.
      //
      // The bound used to start *after* the teardown, and a teardown has no
      // deadline of its own: it awaits stream cancellations, `engine.dispose`,
      // and a transport disconnect that on Bluetooth Classic reaches the
      // platform. So the twenty seconds this promises could be preceded by an
      // unbounded wait, and the number in the refusal was not the number the
      // user experienced.
      final clock = Stopwatch()..start();
      Duration remaining() {
        final left = abandonTimeout - clock.elapsed;
        return left.isNegative ? Duration.zero : left;
      }

      try {
        await _teardown().timeout(remaining());
      } on Object {
        // Not waiting for it any longer is the whole point; whether it
        // finished is answered by `_connecting` below.
      }
      // Waited for in a loop, and the loop is the point.
      //
      // Three taps in quick succession — A wrong, B wrong, C the adapter —
      // used to connect **B**. A single wait meant B and C both queued behind
      // A; A finished, B woke first and took the link, and C woke to find
      // somebody connecting and was refused. The user's last tap lost to the
      // one they had already changed their mind about, and the app ended up
      // talking to a device they had rejected.
      //
      // So each caller records its claim, and a caller that finds a newer
      // claim stands down: whoever tapped last is the one being waited for.
      // Standing down publishes nothing, which is right here and only here —
      // the newer tap is already showing its own progress on the same screen.
      while (true) {
        if (_generation != mine) return false;
        if (!_connecting) break;
        final inFlight = _inFlight;
        if (inFlight == null) break;
        try {
          await inFlight.timeout(remaining());
        } on Object {
          // Whether it unwound cleanly is not this attempt's business; the
          // only question is whether the link is free, and that is what the
          // checks below answer.
          break;
        }
      }
      if (_generation != mine) return false;
      // Bounded waits end whether or not the thing they waited for did. A
      // silent `false` here would be the same defect one level down, so
      // the refusal says what happened and what to do about it.
      if (_connecting) {
        state = state.copyWith(
          phase: ConnectionPhase.failed,
          error: '上一個連線仍在中止中，轉接器還沒有釋放。請等幾秒再試一次。',
        );
        return false;
      }
    }
    if (_connecting) return false;
    _connecting = true;
    _inFlightTransport = transport;
    _connectEpoch++;
    final attempt = _connectInner(transport, kind, ++_generation);
    _inFlight = attempt;
    try {
      return await attempt;
    } finally {
      _connecting = false;
      // Only if nothing has replaced it, so a successor's handle is not
      // cleared by its predecessor finishing late.
      if (identical(_inFlight, attempt)) _inFlight = null;
      if (identical(_inFlightTransport, transport)) _inFlightTransport = null;
    }
  }

  /// True when this attempt has been superseded and must publish nothing.
  bool _superseded(int generation) => generation != _generation;

  /// Ends a failed attempt, publishing only if it is still the current one.
  ///
  /// The three failure paths all wrote `failed` unconditionally, and the state
  /// they overwrote was whatever had replaced them. Concretely: the user taps
  /// 取消 on a Wi-Fi attempt, the screen returns to idle, and eight seconds
  /// later the abandoned socket's own timeout repaints it as
  /// 連線失敗 — an error about a connection the user had already walked away
  /// from, on a screen they had moved on from. Nothing distinguishes it from a
  /// failure of whatever they did next.
  ///
  /// The record is written either way. A cancelled attempt is exactly the kind
  /// somebody wants to look at afterwards, and the transcript belongs to the
  /// attempt rather than to the screen.
  Future<bool> _failAttempt(
    int generation,
    Elm327Client client,
    String why, {
    String prefix = '連線失敗',
    String? detail,
  }) async {
    _completeEvidence(client, outcome: 'failed');
    // Before the teardown reads it. The sentence on screen is what the user
    // gets; this is what somebody can act on afterwards.
    _attemptTranscript?.recordNote('$prefix：${detail ?? why}');
    if (_superseded(generation)) {
      // This attempt's own client, not the shared teardown: whoever superseded
      // it has already torn down and published, and `_teardown()` here would
      // reach into a session that is no longer this one's to end.
      await client.dispose();
      return false;
    }
    state = state.copyWith(phase: ConnectionPhase.failed, error: why);
    await _teardown();
    return false;
  }

  Future<bool> _connectInner(
    ObdTransport transport,
    TransportKind kind,
    int generation,
  ) async {
    await _teardown();
    if (_superseded(generation)) {
      await transport.disconnect();
      return false;
    }

    _sessionKind = kind.label;
    _sessionTransport = kind;
    _sessionDevice = transport.displayName;
    _sessionProtocol = '';
    final startedAt = DateTime.now().toUtc();
    _sessionEvidence = SessionEvidenceMetadata(
      sessionId: _nextEvidenceSessionId(startedAt),
      startedAt: startedAt,
      platform: platformMetadata,
      vehicleProfile: ref.read(vehicleProfileProvider),
      transportKind: kind.label,
      deviceName: transport.displayName,
      // Demo never crosses a physical adapter or ECU. Freeze that provenance
      // into the evidence itself so its export cannot carry a field header,
      // even when it runs inside the exact production Android package.
      testRig: testRigBuild || kind == TransportKind.demo,
      initialTransportMetadata: transport.diagnosticMetadata,
    );
    _attemptTranscript = ObdTranscript()
      ..recordNote('開始連線：${transport.displayName}（${kind.label}）');
    state = ObdConnectionState(
      phase: ConnectionPhase.connecting,
      kind: kind,
      deviceName: transport.displayName,
    );

    // The transcript is the *attempt's*, not the client's.
    //
    // A Wi-Fi socket that is refused and a Bluetooth cascade that times out
    // both fail before a single OBD byte exists, and the export was therefore
    // empty for exactly the failures a person most needs explained. Starting
    // the record at the tap means even those attempts come back with
    // something: which transport, which address, which tier, and how long each
    // one waited.
    final client = Elm327Client(transport, transcript: _attemptTranscript!);
    _client = client;

    final steps = <InitProgress>[];
    _initSub = client.initProgress.listen((progress) {
      // Replace the in-flight entry for a step rather than appending, so the
      // wizard shows one row per command that mutates from running → ok.
      final existing = steps.indexWhere((s) => s.index == progress.index);
      if (existing >= 0) {
        steps[existing] = progress;
      } else {
        steps.add(progress);
      }
      // Only advance the phase while the handshake is genuinely in flight.
      // These events are delivered asynchronously off a broadcast stream, so
      // the last few land *after* `connect()` has returned and the phase has
      // moved to connected — writing `handshaking` unconditionally would clobber
      // it, leaving the session live but permanently reporting itself offline.
      final stillHandshaking =
          state.phase == ConnectionPhase.connecting ||
          state.phase == ConnectionPhase.handshaking;
      state = state.copyWith(
        phase: stillHandshaking ? ConnectionPhase.handshaking : null,
        initSteps: List.unmodifiable(steps),
      );
    });

    // Bound to the generation that built this client, so a transport dying
    // after the user has moved on cannot speak for whatever session is current
    // by then.
    client.onConnectionLost = () => _handleConnectionLost(generation);

    try {
      final ok = await client.connect();
      if (_superseded(generation)) {
        // Disconnected or dropped while the handshake ran. Tear down what this
        // attempt built and publish nothing — the state now on screen belongs
        // to whatever superseded it.
        await client.dispose();
        return false;
      }
      if (!ok) {
        return await _failAttempt(
          generation,
          client,
          _describeHandshakeFailure(steps),
          prefix: '握手失敗',
        );
      }
    } on TransportException catch (e) {
      return _failAttempt(generation, client, e.message);
    } on Object catch (e) {
      // The sentence and the evidence go to different readers: the driver gets
      // something to act on, the transcript keeps the exception verbatim.
      return _failAttempt(
        generation,
        client,
        describeConnectException(e),
        detail: '$e',
      );
    }

    if (_superseded(generation)) {
      await client.dispose();
      return false;
    }

    _completeEvidence(client, outcome: 'connected');

    final engine = PollingEngine(client);
    engine.shouldContinue = () => _foreground && !_superseded(generation);
    // The same question, asked where the bytes actually leave. `shouldContinue`
    // guards the loop's decisions; this guards the wire, which is the only
    // place that sees a queued Mode 04 arriving after the screen has gone.
    // `owner` is an operation's lease; see `Elm327Client.mayTransmit`. The
    // foreground flag alone answers "right now", and a resume makes it true
    // again for work the user abandoned before backgrounding — including a
    // Mode 04 clear, which erases fault memory and cannot be taken back. The
    // pause epoch only ever advances, so a lease taken before the pause can
    // never match after it.
    client.mayTransmit = (owner) =>
        _foreground &&
        !_superseded(generation) &&
        (owner == null || owner == _pauseEpoch);
    // And what the *operation* owns, which is a different question. The gate
    // above is a sample of now; this lets a long operation notice that the
    // interruption it slept through happened at all.
    engine.lifecycleEpoch = () => _pauseEpoch;
    _engine = engine;
    _snapshotSub = engine.snapshots.listen((snapshot) {
      if (!_telemetry.isClosed) _telemetry.add(snapshot);
    });

    engine.setActivePids(ref.read(activePidsProvider));
    // A protocol search can take 25 seconds, and the user may well have put
    // the phone down during it. Starting to poll from the background is both
    // rude and unsafe — an OS freeze mid-command splits a request from its
    // reply — so the session is left parked for the next resume to recover.
    if (_foreground) {
      engine.start();
    } else {
      _pausedByLifecycle = true;
      if (!_telemetry.isClosed) _telemetry.add(const TelemetrySnapshot());
    }

    // Support discovery runs in the background: it is useful for greying out
    // PIDs the car does not have, but nothing should wait on it.
    unawaited(engine.discoverSupportedPids());
    // Who is on this bus, asked once against the vehicle actually attached.
    // A fault-code scan establishes who answered and never who should have,
    // so a controller that stays silent appears in no count and the engine's
    // clean reply stands for the whole car.
    // Bounded, because nothing else bounds it. Fired unawaited, this had no
    // deadline at all — and a scan starting a moment later joined it, so the
    // census the scan was blocked on could outlive the scan's own budget.
    unawaited(
      engine.discoverResponders(deadline: DateTime.now().add(censusBudget)),
    );

    _sessionProtocol = client.protocolDescription.isEmpty
        ? client.protocolNumber
        : client.protocolDescription;
    state = state.copyWith(
      phase: ConnectionPhase.connected,
      deviceName: transport.displayName,
      protocol: _sessionProtocol,
      batteryVoltage: client.batteryVoltage,
      clearError: true,
    );
    _startPeriodicSnapshots();
    return true;
  }

  String _nextEvidenceSessionId(DateTime startedAt) {
    _evidenceSequence++;
    final utc = startedAt.toUtc().toIso8601String().replaceAll(
      RegExp(r'[-:.]'),
      '',
    );
    return '$utc-${_evidenceSequence.toRadixString(36)}';
  }

  void _completeEvidence(Elm327Client client, {required String outcome}) {
    final evidence = _sessionEvidence;
    if (evidence == null || evidence.transportMetadataCompleted) return;
    _sessionEvidence = evidence.completeTransportMetadata({
      ...client.transport.diagnosticMetadata,
      'connectionOutcome': outcome,
    });
  }

  /// Turns a failed handshake into something the driver can act on.
  ///
  /// "Initialisation failed" tells nobody anything. Which command died, and
  /// whether it died on the very first one, separates "this is not an ELM327"
  /// from "the adapter is fine but the ignition is off".
  static String _describeHandshakeFailure(List<InitProgress> steps) {
    final failed = steps.where((s) => s.status == InitStatus.failed).toList();
    if (failed.isEmpty) {
      return '初始化未通過，轉接器可能不相容。';
    }

    final first = failed.first;
    if (first.index == 0) {
      return '轉接器沒有回應重置指令（${first.step.command}）。'
          '這個裝置可能不是 ELM327 轉接器，或是連到了錯誤的裝置。';
    }
    return '初始化在 ${first.step.command} 失敗（${first.detail ?? '無回應'}）。'
        '請確認轉接器已插好、車輛電門已開啟。';
  }

  /// Reports the link lost — unless the session it was about is already gone.
  ///
  /// [generation] is the session this conclusion belongs to. The success paths
  /// all check `_superseded` and this one did not, which cost two things. A
  /// user who tapped 中斷連線 during the resume probe watched the probe fail
  /// against its own disposed client and got 轉接器停止回應，連線已中斷 over a
  /// disconnect they had asked for. Worse, the bare `_generation++` invalidated
  /// whatever session was current *by then*: disconnect, immediately connect to
  /// another adapter, and the previous session's dying probe bumped the counter
  /// so the new attempt's next ownership check aborted it and disposed a client
  /// it had just built. The reconnect failed silently because a corpse lost a
  /// race.
  void _handleConnectionLost(int generation) {
    if (_superseded(generation)) return;
    _client?.transcript.recordNote('連線事件：轉接器連線中斷');
    _generation++;
    state = state.copyWith(
      phase: ConnectionPhase.failed,
      error: '轉接器停止回應，連線已中斷。',
    );
    unawaited(_teardown());
  }

  /// Pushes a changed PID selection into the running loop.
  void syncActivePids(List<Pid> pids) => _engine?.setActivePids(pids);

  /// Throws when the link is gone rather than answering with an empty list.
  ///
  /// Returning `[]` for "not executed" is how a mid-scan disconnect became a
  /// green no-faults result: the screen cannot tell an unanswered question
  /// from a clean answer once both are the same value.
  /// Makes sure the responder census has been attempted before a scan.
  ///
  /// Fired unawaited at connect for speed; this is how a caller that actually
  /// depends on it waits.
  Future<void> ensureResponderCensus({DateTime? deadline}) async {
    final engine = _engine;
    if (engine == null || engine.responders != null) return;
    await engine.discoverResponders(deadline: deadline);
  }

  Future<List<Dtc>> readDtcs(DtcKind kind, {DateTime? deadline}) async {
    final engine = _engine;
    if (engine == null) {
      throw const DtcReadException('連線已中斷', kind: DtcReadFailure.disconnected);
    }
    return engine.readDtcs(kind, deadline: deadline);
  }

  Future<ClearOutcome> clearDtcs() async {
    final engine = _engine;
    if (engine == null) {
      throw const DtcReadException('連線已中斷', kind: DtcReadFailure.disconnected);
    }
    // One clear at a time, decided here rather than by whoever is on screen.
    //
    // The screen's own guard lived in widget state, so switching tabs while a
    // clear was in flight rebuilt it cleared: tap 清除, glance at the
    // dashboard, come back, tap again, and a second functional `04` queued
    // behind the first. The second one reaches the controller the first just
    // finished and resets its readiness monitors again.
    //
    // A UI guard is still worth having — it is what greys the button — but it
    // cannot be the only one, because it is the one that does not survive the
    // screen.
    if (_clearInFlight) {
      throw const DtcReadException(
        '已經有一個清除指令正在執行，請等它完成。',
        kind: DtcReadFailure.error,
      );
    }
    _clearInFlight = true;
    try {
      return await engine.clearDtcs();
    } finally {
      _clearInFlight = false;
    }
  }

  /// Whether a Mode 04 is on the wire right now. See [clearDtcs].
  bool _clearInFlight = false;

  Future<String?> readVin({DateTime? deadline}) async {
    final engine = _engine;
    if (engine == null) {
      throw const DtcReadException('連線已中斷', kind: DtcReadFailure.disconnected);
    }
    return engine.readVin(deadline: deadline);
  }

  /// The vehicle's own fault-lamp summary, or null if it could not be read.
  Future<MilStatus?> readMilStatus({DateTime? deadline}) async =>
      _engine?.readMilStatus(deadline: deadline);

  /// Throws when there is no session to ask with, for the reason [readDtcs]
  /// gives: an empty list for "not executed" is how a mid-scan disconnect
  /// becomes an affirmative statement about the vehicle.
  Future<FreezeFrameRead> readFreezeFrames({DateTime? deadline}) async {
    final engine = _engine;
    if (engine == null) {
      throw const DtcReadException(
        '連線在讀取凍結幀前中斷，這次沒有讀到。',
        kind: DtcReadFailure.disconnected,
      );
    }
    return engine.readFreezeFrames(deadline: deadline);
  }

  Future<void> disconnect() async {
    // Invalidates any handshake still in flight, so a connect the user has
    // just abandoned cannot finish and publish itself as live.
    _client?.transcript.recordNote('連線事件：使用者中斷連線');
    _generation++;
    await _teardown();
    state = const ObdConnectionState();
  }

  /// Tears the current session down.
  ///
  /// Every handle is detached into a local **before** the first await. The
  /// previous shape re-read the shared fields after awaiting, so a teardown
  /// started by a dropped link could still be running when the user reconnected
  /// and would then dispose the *new* client it found there.
  /// A teardown that is still unwinding, if any.
  ///
  /// `_handleConnectionLost` starts one without awaiting it, so a user who
  /// taps reconnect the moment the watchdog gives up begins a new connection
  /// while the old chain is still draining. That chain ends at a BLE
  /// disconnect, and the BLE layer keys devices by their platform id — the
  /// same physical adapter — so it is the *new* connection that gets dropped,
  /// seconds after appearing to succeed.
  ///
  /// A second `_teardown()` could not prevent it. The first detaches the
  /// handles synchronously, so the second found nothing left to wait for and
  /// returned immediately. Teardowns therefore chain: the one a connection
  /// awaits does not complete until every earlier one has.
  Future<void>? _teardownDraining;

  Future<void> _teardown() {
    // Every way a session ends passes through here — a failed connect, a
    // deliberate disconnect, a link that dropped, the provider being disposed.
    // The recording is worth keeping in all of them, and this is the one place
    // that does not have to enumerate them.
    _stopPeriodicSnapshots();
    unawaited(_saveTranscriptSnapshot());
    final chained = _drainTeardown(_teardownDraining);
    _teardownDraining = chained;
    return chained;
  }

  /// Writes the current recording where it can outlive this process.
  ///
  /// Reads through `exportableRecord`, so the file gets exactly what the
  /// export button would have produced — the same bytes under the same
  /// heading, rather than a second rendering that could disagree with it.
  /// Queues a snapshot the way the pause and teardown handlers do.
  @visibleForTesting
  Future<void> saveTranscriptSnapshotForTest() async {
    await _saveTranscriptSnapshot();
  }

  @visibleForTesting
  Future<bool> savePeriodicSnapshotForTest() => _savePeriodicSnapshotIfNeeded();

  @visibleForTesting
  Future<void> drainTranscriptSnapshotsForTest() => _savingSnapshot;

  Future<bool> _saveTranscriptSnapshot() {
    final record = exportableRecord;
    if (record == null) return Future<bool>.value(false);
    // Both reads happen now, before anything is awaited, so a save queued
    // behind another one still writes the session it was asked about rather
    // than whatever has since connected.
    final liveTranscript = record.transcript;
    final transcript = liveTranscript.frozenCopy();
    final header = record.header;
    // The simulator is a session with no vehicle in it. It may be saved — it
    // is still the last thing that happened — but it may not replace a
    // recording that came off an adapter.
    final fromRealHardware =
        _sessionTransport != TransportKind.demo && !_currentSessionIsTestRig;
    final recordedAtTrigger = liveTranscript.recorded;

    // Serialised, the same way teardown already is.
    //
    // Two saves can genuinely overlap: the watchdog declaring the link dead at
    // the moment the app is backgrounded runs the pause handler and the
    // teardown handler together. They opened the same staging file and wrote a
    // few hundred kilobytes each across many syscalls, so the two could
    // interleave into a file that is neither — and the rename then installed
    // the wreckage. Worse than losing one save: `load()` returns null on a
    // corrupt file, and the guard that stops a simulator overwriting hardware
    // asks `load()` first, so a corrupted recording silently withdrew its own
    // protection.
    final operation = _savingSnapshot.then((_) async {
      final saved = await transcriptStore.save(
        transcript,
        header,
        fromRealHardware: fromRealHardware,
      );
      if (saved) {
        _lastSavedTranscript = liveTranscript;
        _lastSavedMark = recordedAtTrigger;
      }
      return saved;
    });
    _savingSnapshot = operation.then<void>((_) {});
    return operation;
  }

  /// The tail of the snapshot queue. `TranscriptStore.save` never throws, so
  /// this cannot be poisoned by a failed write.
  Future<void> _savingSnapshot = Future<void>.value();

  /// How often a live session writes its recording to disk.
  ///
  /// Thirty seconds is the answer to a measurement rather than a guess. On a
  /// Pixel 9, 2026-08-20: backgrounding the app and then force-stopping it left
  /// the recording intact, because `onPause` ran — but `am crash` from the
  /// foreground left **nothing**, because no handler runs at all. The app
  /// crashing in a car is precisely the session somebody needs to send back,
  /// and it was the one with no record. So the snapshot is no longer only a
  /// farewell: during normal foreground operation, each successful write
  /// bounds the unsaved tail to roughly one interval.
  ///
  /// Not shorter, because the file is a few hundred kilobytes and this runs
  /// while the same phone is driving gauges off a 20 Hz stream. Not longer,
  /// because thirty seconds of a fault-code scan is most of the scan.
  Duration snapshotInterval = const Duration(seconds: 30);

  Timer? _snapshotTimer;

  /// Transcript identity and [ObdTranscript.recorded] as of the last write, so
  /// a tick with nothing new to say writes nothing. Both are required: a slow
  /// save from the previous session may complete after the next one begins,
  /// and equal entry counts do not make those two transcripts the same state.
  /// Updated by every path that saves, not just the timer's — otherwise the
  /// first tick after a pause rewrites what the pause handler already put there.
  ObdTranscript? _lastSavedTranscript;
  int _lastSavedMark = -1;

  void _startPeriodicSnapshots() {
    _snapshotTimer?.cancel();
    // A new session has a new transcript counting from zero, and the mark left
    // by the previous session's final save is a number from a different count.
    // They are very unlikely to collide, and "very unlikely" is a worse reason
    // to skip a write than "impossible" is.
    _lastSavedTranscript = null;
    _lastSavedMark = -1;
    _snapshotTimer = Timer.periodic(
      snapshotInterval,
      (_) => unawaited(_savePeriodicSnapshotIfNeeded()),
    );
  }

  Future<bool> _savePeriodicSnapshotIfNeeded() {
    // The background is the pause handler's job, and it has already written
    // once. A backgrounded session is also not adding anything.
    if (!_foreground) return Future<bool>.value(false);
    final record = exportableRecord;
    if (record == null) return Future<bool>.value(false);
    if (identical(record.transcript, _lastSavedTranscript) &&
        record.transcript.recorded == _lastSavedMark) {
      return Future<bool>.value(false);
    }
    return _saveTranscriptSnapshot();
  }

  void _stopPeriodicSnapshots() {
    _snapshotTimer?.cancel();
    _snapshotTimer = null;
  }

  /// Where a recording goes so it survives the app being killed.
  @visibleForTesting
  TranscriptStore transcriptStore = TranscriptStore();

  Future<void> _drainTeardown(Future<void>? previous) async {
    final snapshotSub = _snapshotSub;
    final initSub = _initSub;
    final engine = _engine;
    final client = _client;

    // Detached first and synchronously, so nothing started after this point
    // can find them.
    // The transcript outlives the client that made it.
    //
    // This is the whole point of recording. Every connect failure ends in a
    // teardown, the teardown nulled the client, and the export read the
    // transcript *off* the client — so the one session whose bytes somebody
    // actually needs was the one session whose bytes were deleted, by the
    // code written to keep them. The header is rendered now rather than
    // lazily, because it reads live client state that is about to be gone.
    final record = client?.transcript ?? _attemptTranscript;
    if (record != null && !record.isEmpty) {
      _lastTranscript = record;
      _lastTranscriptHeader = transcriptHeader;
    }

    _snapshotSub = null;
    _initSub = null;
    _engine = null;
    _client = null;

    // A session ending must clear the display. Otherwise the last car's
    // readings sit on the gauges while the next connection is being made, and
    // for a few seconds the app shows one vehicle's data labelled as another's.
    if (!_telemetry.isClosed) _telemetry.add(const TelemetrySnapshot());

    if (previous != null) {
      // Bounded, because a wedged native disconnect must not make reconnecting
      // impossible — only ordered.
      try {
        await previous.timeout(const Duration(seconds: 5));
      } on Object {
        // An earlier teardown's failure is not this one's to report.
      }
    }

    await snapshotSub?.cancel();
    await initSub?.cancel();
    await engine?.dispose();
    await client?.dispose();
  }
}

final obdSessionProvider = NotifierProvider<ObdSession, ObdConnectionState>(
  ObdSession.new,
);

/// Live telemetry. Replays the engine's current snapshot before subscribing, so
/// a screen opened mid-drive paints real values on its first frame rather than
/// a row of dashes.
/// How often the UI re-asks the engine what it currently knows.
///
/// Staleness is a statement about *now*, and the screens only re-evaluated it
/// when a new snapshot arrived — which stops happening in exactly the
/// situations staleness exists for: the polling loop's exception path returns
/// without publishing, a protocol re-search runs silent for 25 seconds, a
/// wedged adapter answers nothing at all. Verified on a device: the gauges held
/// pre-freeze values at full brightness for three minutes, and the only thing
/// that dimmed them was switching tabs, because that forced a rebuild.
///
/// Anchoring the model to a wall clock, as the previous round did, fixed the
/// answer and not the question. Something has to ask again.
const Duration kTelemetryHeartbeat = Duration(seconds: 1);

final telemetryProvider = StreamProvider<TelemetrySnapshot>((ref) {
  final session = ref.watch(obdSessionProvider.notifier);
  final controller = StreamController<TelemetrySnapshot>();

  final current = session.engine?.current;
  if (current != null) controller.add(current);

  final sub = session.telemetryStream.listen(
    controller.add,
    onError: controller.addError,
  );

  // Re-reads `engine.current` rather than replaying the last snapshot, so the
  // figures that age on the client — adapter voltage, throughput — are
  // recomputed too rather than being frozen scalars copied at publish time.
  final heartbeat = Timer.periodic(kTelemetryHeartbeat, (_) {
    if (controller.isClosed) return;
    // Only a foreground session with a running loop may be re-read.
    //
    // Without those two conditions the heartbeat undid the pause it was
    // supposed to complement, within one second. `_pauseNow` publishes an
    // empty snapshot when the app is backgrounded; `stop()` deliberately
    // retains the last readings so a resume has something to show while it
    // re-establishes. A heartbeat that reads `engine.current` regardless
    // therefore republished a stopped engine's retained 6000 rpm one second
    // after the screen had been cleared — and if the user came back while the
    // three-second voltage probe was still pending, that old number was on
    // screen looking entirely live before the link had been re-established.
    //
    // The state this exists for is different and is still covered: a *running*
    // loop whose link has gone silent, where nothing publishes because nothing
    // answers. There the values age on screen because something keeps asking.
    final engine = session.engine;
    if (engine == null || !engine.isRunning || !session.isForeground) return;
    controller.add(engine.current);
  });

  ref.onDispose(() {
    heartbeat.cancel();
    unawaited(sub.cancel());
    unawaited(controller.close());
  });

  return controller.stream;
});
