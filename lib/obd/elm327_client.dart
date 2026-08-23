/// ELM327 protocol client.
///
/// Owns everything above the raw byte link: the AT handshake, prompt framing,
/// the error matrix, multi-frame reassembly and the stall watchdog. Any
/// [ObdTransport] can be driven by it.
///
/// The ELM327 is strictly half-duplex — one command, one reply, terminated by
/// the `>` prompt — so commands are serialised through [_pending]. Overlapping
/// sends would interleave replies with no way to tell which is which.
library;

import 'dart:async';
import 'dart:convert';

import 'adapter_identity.dart';
import 'addressing.dart';
import 'transport/obd_transport.dart';
import 'programmable_parameters.dart';
import 'transcript.dart';

/// Status the adapter can report in place of data.
///
/// The full set from the ELM327 datasheet's "Error and Alert Messages", not the
/// subset the reverse-engineering spec lists. Anything unclassified would be
/// stripped to hex and read as a sensor value, so completeness here is what
/// stops the app inventing numbers.
enum Elm327ErrorCode {
  none,
  noData,
  busInitError,
  canError,
  unableToConnect,
  stopped,
  bufferFull,
  busBusy,
  busError,
  dataError,
  feedbackError,
  lowVoltageReset,
  activityAlert,
  lowPowerAlert,
  internalError,
  unknownCommand;

  /// Whether this failure is *about the PID* rather than about the link.
  ///
  /// It was called `isPermanentForPid` and documented as "the PID will never
  /// work on this vehicle", which stopped being true when the poller learned
  /// to give `NO DATA` three strikes and a sixty-second backoff. The
  /// description string was corrected and the flag's name and doc were not, so
  /// the two halves of the same idea disagreed in the same file.
  ///
  /// `NO DATA` is the adapter reporting that nothing arrived before its own
  /// timeout — a busy ECU, a receive filter or one aggressive timing window
  /// produces it exactly as an absent sensor does. What it identifies is which
  /// *counter* the failure belongs to, not a verdict about the vehicle.
  bool get countsAgainstThisPid => this == Elm327ErrorCode.noData;

  /// Whether the link itself needs rebuilding.
  bool get requiresReconnect =>
      this == Elm327ErrorCode.unableToConnect ||
      this == Elm327ErrorCode.busInitError ||
      this == Elm327ErrorCode.lowVoltageReset;

  /// Message for the connection status strip. Written for a driver.
  String get description => switch (this) {
    Elm327ErrorCode.none => '',
    // Not "the vehicle does not support this".
    //
    // `NO DATA` is the *adapter* saying nothing arrived before its own
    // timeout — a busy ECU, a receive filter, or one aggressive timing
    // window produces it exactly as an absent sensor does. Reading it as a
    // capability claim is the mistake this whole codebase is organised
    // against, and it was still being told to the user in those words.
    //
    // It is also used for whole *services*: a Mode 03 fault-code read that
    // goes unanswered surfaced as "this vehicle does not support that
    // PID", in the same tree that says elsewhere, correctly, that silence
    // is not a clean answer.
    Elm327ErrorCode.noData => '沒有收到回應（可能是暫時無回應，或車輛不支援）',
    Elm327ErrorCode.busInitError => '匯流排初始化失敗',
    Elm327ErrorCode.canError => 'CAN 匯流排錯誤',
    Elm327ErrorCode.unableToConnect => '無法與 ECU 通訊，請確認電門已開啟',
    Elm327ErrorCode.stopped => '傳輸被中斷',
    Elm327ErrorCode.bufferFull => '轉接器緩衝區溢位',
    Elm327ErrorCode.busBusy => '匯流排忙碌',
    Elm327ErrorCode.busError => '匯流排錯誤，可能是接線問題',
    Elm327ErrorCode.dataError => '收到的資料不正確',
    Elm327ErrorCode.feedbackError => '訊號回授錯誤',
    Elm327ErrorCode.lowVoltageReset => '電壓過低導致轉接器重置',
    Elm327ErrorCode.activityAlert => '匯流排活動警示',
    Elm327ErrorCode.lowPowerAlert => '轉接器即將進入低功耗模式',
    Elm327ErrorCode.internalError => '轉接器內部錯誤',
    Elm327ErrorCode.unknownCommand => '轉接器不支援此指令',
  };
}

/// One parsed reply.
/// One complete message from one controller.
///
/// [sourceId] is the address the ECU answered from — `7E8` on CAN, or on a
/// legacy bus the *source byte* of the three-byte header, which is the third
/// one. It is null when headers are off, because with `ATH0`
/// two controllers' replies are genuinely indistinguishable. The datasheet says
/// so itself: "the only way to know is to turn on the headers".
/// How much a line of a reply establishes about who sent it.
///
/// Four rounds of review were spent collapsing these into one boolean and
/// finding, each time, the case that collapse breaks. They are different
/// facts and the coverage rules want different things from each.
enum ObservedEvidence {
  /// A complete headered frame whose service could be read from its framing.
  answered,

  /// A definite source whose service could not be read — a truncated payload,
  /// an orphan continuation frame, or a bare header this connection has
  /// already seen speak properly.
  ///
  /// It says a controller is there. It says nothing about what it answered,
  /// so it cannot become a debt for this service — but it does mean the
  /// vehicle is not fully accounted for.
  present,

  /// A token that might be an address and might be payload.
  ///
  /// `430` is a legal 11-bit identifier and the start of a headerless
  /// `43 00`, and nothing in the token says which. Naming it invents a
  /// controller; discarding it silently loses a real one. It is carried as
  /// what it is: an open question.
  candidate,
}

class ObdFrame {
  const ObdFrame(
    this.bytes, {
    this.sourceId,
    this.service,
    this.payload,
    this.operand,
    this.evidence = ObservedEvidence.answered,
  });

  /// What this line establishes about its source. Only meaningful on observed
  /// frames; a reassembled frame is always [ObservedEvidence.answered].
  final ObservedEvidence evidence;

  final List<int> bytes;
  final String? sourceId;

  /// The service this frame is about, when it can be told.
  ///
  /// Set on every frame that names one — reassembled and observed alike —
  /// because callers ask this question of both and there must be one answer.
  /// Null only for a bare identity, or a fragment that never reached its
  /// service byte.
  ///
  /// It was originally set on *observed* frames only, on the reasoning that a
  /// reassembled frame's [bytes] already start at the service byte so its
  /// reader could just look. Two readers did look, and wrote two different
  /// rules. The clear's coverage check asked "is this `44`, or a three-byte
  /// `7F 04`?" — a question about content — and so forgot the controller in:
  ///
  ///     04 -> 7E8 01 44
  ///           7E9 02 44 DE      complete, well-framed, malformed after 44
  ///
  /// and equally in `7E9 02 7F 04`, a clone reprinting a short NRC. Both name
  /// Mode 04 at the offset the framing puts it; neither is `44` alone or a
  /// three-byte negative. The rescan then accepted `7E8`'s empty Mode 03 as
  /// the whole vehicle — the same false all-clear the damaged path had already
  /// been fixed for, wearing the one hat left.
  ///
  /// Computed by the parser because the ISO-TP frame type decides where the
  /// service byte sits, and re-deriving that elsewhere produced a second,
  /// wrong rule: a First Frame's service is at offset 2, and reading offset 1
  /// made a Mode 03 reply look like no service at all and a Mode 01 reply look
  /// like Mode 03.
  final int? service;

  /// This frame's application bytes, bounded by what its PCI declares.
  ///
  /// Set on *observed* frames for the same reason [service] is, and computed
  /// in the same place: [bytes] on an observed frame is the raw ISO-TP body,
  /// so `7E8 01 44` arrives as `01 44` and the padding of a short frame is
  /// still attached. A caller that wants to know what a controller actually
  /// said has to strip the PCI and honour the declared length, and re-deriving
  /// that outside the parser is exactly the second, wrong rule the note on
  /// [service] warns about.
  ///
  /// Null when this frame does not carry a complete message on its own — a
  /// First Frame, a continuation frame, a bare header, or a Single Frame whose
  /// declared bytes did not all arrive. None of those may be read as what a
  /// controller said.
  final List<int>? payload;

  /// The byte after the service byte, when this frame carried one.
  ///
  /// For Mode 01 and 02 that is the PID. Computed by the parser for the same
  /// reason [service] is — the ISO-TP frame type decides where it sits — and
  /// deliberately **not** bounded by the whole message having arrived, which
  /// is the difference between this and [payload].
  ///
  /// That difference is the point. Identity and content are separate facts,
  /// and this app has learned three times that conflating them produces a
  /// false all-clear. A reply cut short:
  ///
  ///     7E9 06 41 01 82 07 65      PCI declares six, five arrived
  ///
  /// is not data — nothing here becomes a reading — but `7E9` visibly answered
  /// PID 01, and forgetting that let Mode 03 complete on `7E8` alone and the
  /// panel go green with the fault lamp lit on the dashboard in front of the
  /// user.
  ///
  /// Still bounded by the PCI's *declared* length, so CAN padding cannot
  /// supply it: a frame declaring one byte says nothing about a second.
  final int? operand;

  @override
  String toString() =>
      'ObdFrame(${sourceId ?? '?'}: ${bytes.map((b) => b.toRadixString(16)).join(' ')})';
}

class ObdResponse {
  final List<String> rawLines;
  final String hexPayload;
  final List<int> bytes;

  /// The payload of each accepted line, kept apart.
  ///
  /// [bytes] is the concatenation, which is the right reading for a CAN reply:
  /// ISO-TP segments are pieces of one logical message and belong glued
  /// together. It is the wrong reading for every legacy bus, where the adapter
  /// prints one *complete message* per line and each repeats its own service
  /// byte. Concatenating those and stripping only the leading service byte
  /// shifts the pairing of everything after the first message, which is how a
  /// four-fault ISO 9141 car reported two codes it had never set.
  ///
  /// Callers that care about message boundaries — anything decoding Mode 03/07/
  /// 0A or a legacy Mode 09 — must use this and not [bytes].
  final List<ObdFrame> frames;

  final Elm327ErrorCode errorCode;

  /// Controllers that were identifiable in this reply, even when its payload
  /// was not.
  ///
  /// Payload validity and responder identity are independent facts. A legacy
  /// exchange with one valid TCM frame and one damaged ECM line is rejected as
  /// a whole — correctly — and the TCM's identity used to be discarded with
  /// it, so a later clear was measured against a set that had forgotten a
  /// controller this very scan had heard from.
  final Set<String> attributedSources;

  /// What could be identified in this reply, with whatever payload came with
  /// it — including on a reply the parser refused.
  ///
  /// Never a source of *values*: an errored exchange is not data. It is
  /// evidence about who was on the bus and what they were talking about, and
  /// collapsing that to a bare source set is what let a stale Mode 01 reply
  /// become a permanent fault-code obligation and a real Mode 03 answer be
  /// reported as silence.
  final List<ObdFrame> observedFrames;
  final double? batteryVoltage;

  /// Whether the adapter acknowledged `ATH1` for the exchange that produced
  /// this response.
  ///
  /// The difference between "every controller answered anonymously" and "the
  /// adapter would not print headers at all" is invisible in [frames], and the
  /// two demand opposite responses: the first is an adapter contradicting
  /// itself and must be refused, the second is a limitation to be reported.
  /// Only [Elm327Client.sendGlobal] sets this, because it is the only caller
  /// that turns headers on.
  final bool headersEnabled;

  const ObdResponse({
    this.rawLines = const [],
    this.hexPayload = '',
    this.bytes = const [],
    this.frames = const [],
    this.errorCode = Elm327ErrorCode.none,
    this.attributedSources = const {},
    this.observedFrames = const [],
    this.batteryVoltage,
    this.headersEnabled = false,
  });

  ObdResponse withHeadersEnabled(bool value) => ObdResponse(
    rawLines: rawLines,
    hexPayload: hexPayload,
    bytes: bytes,
    frames: frames,
    errorCode: errorCode,
    batteryVoltage: batteryVoltage,
    headersEnabled: value,
    attributedSources: attributedSources,
    observedFrames: observedFrames,
  );

  bool get isSuccess => errorCode == Elm327ErrorCode.none;

  /// First non-empty line, used to read back version and protocol strings.
  String get firstLine => rawLines.isEmpty ? '' : rawLines.first;

  @override
  String toString() =>
      'ObdResponse(${isSuccess ? hexPayload : errorCode.name}${batteryVoltage != null ? ', ${batteryVoltage}V' : ''})';
}

/// Progress of the AT handshake, surfaced live in the connection wizard.
class InitStep {
  final String command;
  final String purpose;
  final bool isCritical;

  /// Proof beyond "the adapter did not print an error string".
  ///
  /// [ObdResponse.isSuccess] answers a much weaker question than the handshake
  /// needs: it is true for `OK`, for arbitrary text, and for a bare prompt.
  /// A device that acknowledges everything it does not understand — a wrong
  /// paired peer, a clone with half-implemented firmware — therefore walks the
  /// whole sequence and the app declares a live vehicle with no ECU behind it.
  ///
  /// Returns null when the reply is acceptable, or the reason it is not.
  final String? Function(ObdResponse response)? validate;

  const InitStep(
    this.command,
    this.purpose, {
    this.isCritical = false,
    this.validate,
  });
}

/// Requires the literal `OK` acknowledgement a state-changing AT command owes.
String? _requireOk(ObdResponse response) {
  final said = response.rawLines.any((l) => l.trim().toUpperCase() == 'OK');
  return said ? null : '轉接器未確認此指令';
}

/// Requires a well-formed positive answer to the Mode 01 support probe.
///
/// This is the only step that proves a *vehicle* is on the bus: every AT
/// command answers happily with the ignition off, and `0100` does not. Reading
/// it loosely gives that proof away.
String? _requireSupportMask(ObdResponse response) {
  final bytes = response.bytes;
  if (bytes.isEmpty) return 'ECU 沒有回應';
  if (bytes.first == 0x7F) return 'ECU 拒絕了支援度查詢（negative response）';
  // Positive response to service 01 is 0x41, echoing the requested PID 0x00,
  // followed by the four mask bytes. Anything shorter is not a usable answer,
  // and treating it as one builds the supported-PID set out of bytes the ECU
  // never sent.
  if (bytes.length < 6) return '支援度回應過短（需要 41 00 加四個位元組）';
  if (bytes[0] != 0x41) return '回應不是 Mode 01 的正向回覆';
  if (bytes[1] != 0x00) return '回應的 PID 與查詢不符';
  return null;
}

enum InitStatus { pending, running, ok, failed, skipped }

class InitProgress {
  final InitStep step;
  final int index;
  final int total;
  final InitStatus status;
  final String? detail;

  const InitProgress({
    required this.step,
    required this.index,
    required this.total,
    required this.status,
    this.detail,
  });
}

class Elm327Client {
  Elm327Client(
    this.transport, {
    this.watchdogTimeout = const Duration(seconds: 5),
    this.responsePendingTimeout = const Duration(seconds: 7),
    this.commandTimeout = const Duration(seconds: 5),
    this.writeTimeout = const Duration(seconds: 2),
    ObdTranscript? transcript,
  }) : transcript = transcript ?? ObdTranscript();

  final ObdTransport transport;
  final Duration watchdogTimeout;
  final Duration commandTimeout;

  /// How long handing bytes to the transport may take before the link is
  /// considered gone. See the write in [_sendNow].
  final Duration writeTimeout;

  /// Deadline granted once the adapter reports `SEARCHING...`. Generous on
  /// purpose: a cold CAN bus on an older vehicle can take well over ten
  /// seconds to answer the first query.
  static const Duration protocolSearchTimeout = Duration(seconds: 25);

  /// The handshake.
  ///
  /// Two deliberate departures from the spec's table — both documented in
  /// `docs/protocol-deviations.zh-TW.md`:
  ///
  ///  * `ATCRA 7B0` is **omitted**. With the transmit header set to `7E0`, the
  ///    ECU answers on `7E8`; filtering receives to `7B0` would discard every
  ///    reply and leave the app connected but permanently reading `NO DATA`.
  ///    No receive filter is set at all, which is what the ELM327 defaults to.
  ///  * `ATCFC0` is **omitted**. ISO 15765-4 requires a Flow Control frame in
  ///    answer to every First Frame, and the ELM327 sends those automatically
  ///    — `CFC1`, the default. Turning it off is for experimenting with
  ///    non-OBD CAN systems; on a car it means every reply longer than seven
  ///    data bytes (VIN, DTC lists, batched reads) delivers its first frame
  ///    and then stalls.
  ///  * `ATDPN` is **kept** — the numeric protocol ID is worth showing the user
  ///    alongside the text description.
  static const List<InitStep> initSequence = [
    InitStep('ATZ', '軟體重置轉接器', isCritical: true),
    InitStep('ATE0', '關閉指令回音', isCritical: true, validate: _requireOk),
    // Not critical, and not `OK`-gated.
    //
    // Linefeeds are a *rendering* preference: the parser trims whitespace and
    // frames on the prompt, so an adapter that keeps them on is read correctly
    // either way. Making it critical meant a clone that will not acknowledge
    // one cosmetic command could not connect at all — the handshake is the
    // most clone-sensitive surface in this app and every literal-OK gate on it
    // is another way for a working adapter to be refused.
    //
    // `ATE0` and `ATSP0` stay critical for reasons that are not cosmetic: a
    // command echo is valid hex that prepends bytes to a reading, and nothing
    // downstream works without a protocol.
    InitStep('ATL0', '關閉換行字元'),
    InitStep('ATM0', '關閉記憶體寫入'),
    InitStep('ATS0', '關閉空白字元，減少 33% 傳輸量'),
    // `ATAT1` rather than the spec's `ATAT2`.
    //
    // Both enable adaptive timing; AT2 is the more aggressive variant, which
    // shortens the window an ECU has to answer. The datasheet names AT1 as both
    // the default and the recommended setting. Combined with treating a single
    // `NO DATA` as proof that a PID is unsupported, AT2 meant one missed window
    // could retire a working gauge for the rest of the session.
    InitStep('ATAT1', '啟用自適應計時（datasheet 建議值）'),
    InitStep('ATST66', '設定回應逾時 ~408ms'),
    InitStep('ATSP0', '自動偵測匯流排協定', isCritical: true, validate: _requireOk),
    InitStep('ATI', '讀取轉接器版本'),
    InitStep('AT@1', '讀取裝置識別字串'),
    InitStep('ATRV', '讀取電瓶電壓'),
    // The probe, and the reason the protocol reads sit after it.
    //
    // `ATSP0` only *arms* automatic search; the adapter does not actually try
    // any bus protocol until the first OBD request. Reading ATDP/ATDPN before
    // that returns `AUTO` / `A0` — "undecided" — and everything downstream
    // then works off a protocol that was never determined. Worse, `A0` parses
    // as 0, which the DTC decoder reads as a legacy bus, so a CAN car's fault
    // codes get decoded with the wrong frame layout and report codes it does
    // not have.
    //
    // It is also the only step that proves a *vehicle* is there. Every AT
    // command answers happily with the ignition off; `0100` does not.
    InitStep(
      '0100',
      '查詢 ECU 支援的 PID（確認車輛已回應）',
      isCritical: true,
      validate: _requireSupportMask,
    ),
    InitStep('ATDP', '讀取協定描述'),
    InitStep('ATDPN', '讀取協定編號'),
    // `ATSH 7E0` used to be sent here, unconditionally, and it is the reason a
    // legacy or 29-bit vehicle could pair and then answer nothing.
    //
    // Three hex digits is the 11-bit CAN form. J1850, ISO 9141-2 and
    // ISO 14230-4 take three bytes; 29-bit CAN takes four. On those buses the
    // command either fails or installs nonsense, and either way it discards the
    // addressing `ATSP0` had just worked out. The datasheet's own advice,
    // under `AT SH xx yy zz`, is that these bytes "are normally assigned
    // values for you (and are not required to be adjusted)".
    //
    // Headers are now selected per request, and only when the header actually
    // means something on the detected bus — see [BusAddressing].
  ];

  static const int _promptByte = 0x3E; // '>'
  static const int _crByte = 0x0D;

  final _buffer = <int>[];
  final _initProgress = StreamController<InitProgress>.broadcast();

  Completer<ObdResponse>? _pending;
  Timer? _pendingTimeout;
  bool _searchExtended = false;

  /// Set when a command times out, cleared once [_resync] has drained the
  /// adapter. Guards against replies being attributed to the wrong request.
  bool _outOfSync = false;

  /// Whether the link is believed to be out of step with the adapter.
  ///
  /// Exposed because "did that failure leave anything owed" is not observable
  /// from the outside otherwise, and it is the difference between a write that
  /// failed and one that timed out.
  bool get isOutOfSync => _outOfSync;

  /// Non-null while [_resync] is waiting for the outstanding reply's prompt.
  /// Completes with whether a real `>` prompt was actually observed.
  ///
  /// The distinction is the whole point: a drain that ends because the deadline
  /// expired has *not* resynchronised anything.
  Completer<bool>? _draining;
  StreamSubscription<List<int>>? _rxSub;
  StreamSubscription<bool>? _connectionSub;
  bool _transportLost = false;
  Timer? _watchdog;

  /// When the last command was written, regardless of whether it is still
  /// outstanding. See the watchdog for why this is not `_pending`.
  DateTime? _lastCommandSentAt;
  Future<void> _commandChain = Future<void>.value();

  bool isInitialized = false;
  DateTime lastRxAt = DateTime.now();

  /// Whether the app has told this client it is no longer running.
  ///
  /// The watchdog is a periodic timer and timers do not run while the OS has
  /// the process frozen — they fire *afterwards*, in expiry order, against a
  /// wall clock that moved on without them. So on resume the watchdog tick
  /// came due before the session's own revalidation could call [markAlive],
  /// saw a command outstanding since before the freeze, and tore down a link
  /// that had never gone anywhere. Locking the phone straight after
  /// backgrounding the app is enough to produce it.
  ///
  /// [markAlive] is the only thing that clears this, which is the right shape:
  /// the link is presumed unobserved until somebody re-establishes when it was
  /// last actually heard from.
  bool _suspended = false;

  /// Tells the client that nothing is running to receive bytes.
  ///
  /// Called synchronously when the app is backgrounded, before any of the
  /// asynchronous unwinding, because the freeze can begin at any point after
  /// that and the flag has to already be set when it does.
  void suspendLiveness() => _suspended = true;

  /// Restarts the liveness clock after time passed with the app suspended.
  ///
  /// Dart's timers stop when the OS freezes the process, so on resume the
  /// watchdog wakes up, compares `lastRxAt` against a wall clock that has moved
  /// on by however long the user was in another app, and tears down a link that
  /// never went anywhere. The guard for an idle link — `_pending == null` —
  /// does not help, because the polling loop almost always has a command
  /// outstanding.
  ///
  /// Elapsed wall-clock is not evidence of adapter silence. Only bytes are, and
  /// none could have arrived while nothing was running to receive them.
  void markAlive() {
    _suspended = false;
    lastRxAt = DateTime.now();
    // The in-flight command's deadline expired while suspended too; restarting
    // it gives the adapter the same window it would have had.
    //
    // Within the caller's budget, like every other rearm. This one was missed
    // when the others were clamped, which made it the way round them: suspend
    // and resume with 70 ms of a scan's budget left and the command got five
    // seconds back. The suspension does not extend what the caller asked for.
    if (_pending != null) {
      _pendingTimeout?.cancel();
      _pendingTimeout = Timer(
        _withinDeadline(commandTimeout),
        _onCommandTimeout,
      );
    }
  }

  String deviceVersion = '';
  String deviceIdentity = '';
  String protocolDescription = '';

  /// Everything that crossed the wire this connection.
  ///
  /// Always recording, not a developer switch. The one thing a person cannot
  /// do is drive back to the car, so a session that failed has to be worth
  /// something after it is over — and the sentence on screen is not.
  final ObdTranscript transcript;

  String protocolNumber = '';

  /// What `ATDPN` prints: one protocol character, optionally prefixed by `A`.
  ///
  /// "The ELM327 will print a leading 'A' if the protocol was found
  /// automatically" (ELM327DSJ, *DPN*). Protocols run `0` to `C`, so the
  /// character is a hex digit — and one hex digit on its own is not a byte
  /// pair, which is why this needs a rule of its own rather than the general
  /// reply parser's.
  static final RegExp _protocolNumberLine = RegExp(
    r'^A?[0-9A-Ca-c]$',
    caseSensitive: false,
  );
  double? _batteryVoltage;
  DateTime? _batteryVoltageAt;

  /// How long an `ATRV` reading stays presentable as live.
  ///
  /// Generous next to the 15-second refresh, so one dropped reply does not
  /// blank the status pill — but bounded, because a figure frozen at the
  /// handshake value is exactly what hides an alternator sagging under load.
  static const Duration voltageMaxAge = Duration(seconds: 60);

  /// Adapter supply voltage from `ATRV`, or null when it has not been read,
  /// the adapter reported something that is not a battery, or the reading is
  /// too old to present as current.
  ///
  /// Nullable on purpose: a non-nullable double defaulting to zero cannot tell
  /// "not measured" apart from "flat battery", and the dashboard renders the
  /// difference as a confident number either way. The age matters for the same
  /// reason — every later `ATRV` answering `?` used to leave the handshake
  /// figure on screen indefinitely.
  double? get batteryVoltage {
    final at = _batteryVoltageAt;
    if (at == null) return null;
    if (DateTime.now().difference(at) > voltageMaxAge) return null;
    return _batteryVoltage;
  }

  /// Records a voltage measurement, or the absence of one.
  ///
  /// A refused or unparseable `ATRV` is not evidence that the previous reading
  /// still holds; it is evidence that we no longer know.
  void _recordVoltage(double? volts) {
    _batteryVoltage = volts;
    _batteryVoltageAt = volts == null ? null : DateTime.now();
  }

  /// Fires when the watchdog gives up, so the app can drop to a disconnected
  /// state rather than showing frozen gauges.
  void Function()? onConnectionLost;

  Stream<InitProgress> get initProgress => _initProgress.stream;

  /// Connects the transport and runs the handshake. Returns false if a step
  /// marked critical failed.
  Future<bool> connect() async {
    _transportLost = false;
    await transport.connect();
    transcript.recordNote(
      '連線建立：${transport.displayName}（${transport.kind.label}）',
    );
    _rxSub = transport.incoming.listen(_onBytes);

    // React to the link dropping the moment the transport notices, rather than
    // waiting out the 5 s stall timer. A Bluetooth adapter yanked out of the
    // OBD port reports disconnection immediately; the watchdog is the backstop
    // for links that go quiet without saying so.
    _connectionSub = transport.connectionChanges.listen((connected) {
      if (connected) return;
      _transportLost = true;
      final wasInitialized = isInitialized;
      isInitialized = false;
      _watchdog?.cancel();
      _watchdog = null;
      _failPending(const TransportException('連線已中斷。'));
      // During the handshake, failing the pending command lets connect() and
      // its caller publish the precise failed-attempt state. Only a session
      // that had already completed initialization needs the asynchronous
      // connection-lost callback and generation teardown.
      if (wasInitialized) onConnectionLost?.call();
    });

    lastRxAt = DateTime.now();
    final ok = await _runInitSequence();
    if (ok) {
      await _readProgrammableParameters();
      await _disambiguateDualWidthRendering();
      if (isInitialized && !_transportLost && transport.isConnected) {
        _startWatchdog();
      }
    }
    return ok && isInitialized && !_transportLost && transport.isConnected;
  }

  /// Asks the adapter how it is configured, once, and tolerates a refusal.
  ///
  /// Deliberately *not* a sixteenth initialisation step. The handshake is the
  /// most clone-sensitive surface in this app and every command added to it is
  /// another way for a working adapter to fail to connect; this runs after the
  /// sequence has already succeeded, and a `?`, a timeout or a garbled reply
  /// leaves the parameters unread and every consumer conservative.
  ///
  /// Worth asking at all because two decisions have no other source. `ATDPN B`
  /// does not say whether protocol B is even framed, and the version banner
  /// does not say whether Response Pending handling is switched on. Both were
  /// being guessed, and both guesses fail toward a plausible wrong answer.
  Future<void> _readProgrammableParameters() async {
    try {
      final reply = await send('ATPPS');
      // How it ended, kept apart from what it produced.
      //
      // `ProgrammableParameters.wasRead` is false for an explicit `?`, a
      // timeout, an unreadable reply and a thrown exception alike, because
      // everything below is swallowed. That is right for the parameters
      // themselves — every consumer of them already treats "unknown" as
      // "assume nothing". It is wrong for `AdapterIdentity`, which asks
      // whether the *device* refused a command it should implement, and would
      // otherwise convict an honest adapter of being a clone on the strength
      // of a dropped Bluetooth packet.
      ppsProbe = reply.errorCode == Elm327ErrorCode.unknownCommand
          ? PpsProbe.refused
          : PpsProbe.read;
      programmableParameters = ProgrammableParameters.parse(
        reply.rawLines.join('\n'),
      );
    } on Object {
      // Unread, which is the state every consumer already handles.
      ppsProbe = PpsProbe.unavailable;
    }
  }

  /// How the `ATPPS` probe ended, for [adapterIdentity].
  PpsProbe ppsProbe = PpsProbe.unavailable;

  /// What this adapter says about itself, and where that fails to add up.
  ///
  /// Built from replies the handshake already collected — no extra command is
  /// sent, and nothing is ever written to the adapter's programmable
  /// parameters. (A popular identification app is reported to have bricked an
  /// STN1170 by writing them, which is a strong argument for reading only.)
  AdapterIdentity get adapterIdentity => AdapterIdentity(
    version: deviceVersion,
    identity: deviceIdentity,
    pps: ppsProbe,
  );

  /// Turns the byte spaces back on when the identifier width is ambiguous.
  ///
  /// `ATS0` is in the handshake because it saves a third of the traffic, and on
  /// every ordinary bus it costs nothing: a reply is either three header digits
  /// or eight, and the parser knows which.
  ///
  /// On a user CAN slot configured to accept *both* widths it costs
  /// correctness. `18D03410 4 03 41 04 5A` unspaced is `18D0341040341045A`,
  /// and that string is two different legal frames from two different
  /// controllers — 35.3% engine load from `18D03410`, or 1.2% from `18D`.
  /// Nothing in the characters says which. Two rounds were spent trying to
  /// choose between them by shape, and each rule that made one case right made
  /// another case wrong: preferring the transmit width published the wrong
  /// number, and excluding a lone First Frame published a different wrong
  /// number.
  ///
  /// The ambiguity is not in the app's reasoning, it is in the rendering. With
  /// spaces on, the header is a separate token and there is nothing to guess.
  /// So on the one configuration where it matters, ask for the spaces back.
  ///
  /// A refusal is tolerated: the parser still refuses to choose between two
  /// readings, which is the fail-closed behaviour this replaces rather than
  /// removes.
  Future<void> _disambiguateDualWidthRendering() async {
    if (addressing.acceptedReceiveWidths.length < 2) return;
    try {
      final reply = await send('ATS1');
      if (_saidOk(reply)) {
        transcript.recordNote('此匯流排同時接受 11/29 位識別碼，已開啟位元組空白以避免歧義');
      }
    } on Object {
      // An adapter that will not do it leaves the parser's refusal in place.
    }
  }

  Future<void> disconnect() async {
    _watchdog?.cancel();
    _watchdog = null;
    _pendingTimeout?.cancel();
    _failPending(const TransportException('連線已中斷。'));
    await _rxSub?.cancel();
    _rxSub = null;
    await _connectionSub?.cancel();
    _connectionSub = null;
    await transport.disconnect();
    isInitialized = false;
    _buffer.clear();
  }

  Future<void> dispose() async {
    await disconnect();
    await _initProgress.close();
  }

  // ------------------------------------------------------------- framing ----

  void _onBytes(List<int> chunk) {
    lastRxAt = DateTime.now();
    // Before the NULL filter and before framing. The stray `0x00` the
    // datasheet warns about, a chunk boundary that split a prompt, a reply
    // that arrived with no command outstanding — every one of those is
    // invisible downstream and every one of them is what somebody would be
    // looking for. `_onBytes(const [])` is also how this class re-enters
    // itself to drain a buffered second reply; an empty chunk records nothing.
    transcript.recordRead(chunk);
    // The datasheet notes an ELM327 may occasionally insert a NULL byte into
    // the stream and instructs host software to discard them. With a
    // whitelist parser a stray 0x00 inside `41 0C 1A F8` invalidates the whole
    // line, so the poll silently records neither a value nor a fault and the
    // previous number stays on the gauge.
    _buffer.addAll(chunk.where((b) => b != 0x00));

    // A reply is complete at the prompt. Anything after it belongs to the next
    // reply — rare, but it happens when an adapter echoes late.
    final promptIndex = _buffer.indexOf(_promptByte);
    if (promptIndex == -1) {
      _extendTimeoutIfSearching();
      _extendTimeoutIfPending();
      return;
    }

    final frame = _buffer.sublist(0, promptIndex);
    _buffer.removeRange(0, promptIndex + 1);

    // A drain is in progress: this prompt is the outstanding reply we were
    // waiting to see go past. Consume it and release the resync.
    final draining = _draining;
    if (draining != null) {
      // A genuine prompt — this is what the drain was waiting for.
      if (!draining.isCompleted) draining.complete(true);
      return;
    }

    // Nothing is waiting: this is a late reply to a command that already timed
    // out. Handing it to the next completer is exactly the desync [_resync]
    // exists to prevent, so it is discarded.
    if (_pending == null) {
      // Discarding it *is* the resynchronisation: the outstanding reply has
      // now gone past. Leaving the flag set made the next command open with a
      // three-second drain waiting for a prompt that had already arrived, and
      // on a flaky Bluetooth link that turned every timeout into five seconds
      // plus three of doing nothing.
      _outOfSync = false;
      return;
    }

    final response = _parse(frame);
    _completePending(response);

    // More than one prompt can arrive in a single chunk when the adapter is
    // catching up; keep draining so the surplus never lands on a later command.
    if (_buffer.contains(_promptByte)) _onBytes(const []);
  }

  /// Extends the deadline when a controller says it is still working.
  ///
  /// `7F xx 78` makes the adapter wait up to five seconds — and the host's own
  /// command timeout is five seconds, so the two expire together and the host
  /// can give up on the very exchange the adapter is still holding open. It
  /// then marks the link out of sync and the terminal answer, when it arrives,
  /// belongs to nobody.
  ///
  /// Positive evidence the vehicle is alive and working, exactly like
  /// `SEARCHING...`, and treated the same way.
  void _extendTimeoutIfPending() {
    if (_pending == null) return;
    if (_buffer.length > 512) return;
    final text = ascii
        .decode(_buffer, allowInvalid: true)
        .toUpperCase()
        .replaceAll(' ', '');
    // `7F <mode> 78`, whatever the mode and whatever the header before it.
    if (!RegExp(r'7F[0-9A-F]{2}78').hasMatch(text)) return;

    // Re-armed on every further pending reply, which is what the standard
    // says and what the comment above claimed while the guard did otherwise:
    // "if another Response Pending arrives, the 5 second timer should be
    // reset so that the timing starts over". A controller that keeps saying
    // it is working keeps buying time; one flag set once bought it a single
    // window no matter how many times it asked.
    //
    // `_pendingSeen` is what stops this re-arming on the same bytes forever —
    // the buffer still holds them on the next chunk — so the count of pending
    // replies is what matters, not the presence of one.
    final seen = RegExp(r'7F[0-9A-F]{2}78').allMatches(text).length;
    if (seen <= _pendingSeen) return;
    _pendingSeen = seen;
    _pendingTimeout?.cancel();
    _pendingTimeout = Timer(
      _withinDeadline(responsePendingTimeout),
      _onCommandTimeout,
    );
  }

  /// How many `7F xx 78` replies this exchange has already been extended for.
  int _pendingSeen = 0;

  /// The deadline the outstanding command was given, if any.
  Duration? _pendingDeadline;

  /// The caller's absolute budget for the command in flight, if any.
  ///
  /// Clamping once at admission was not enough, and the ways round it were all
  /// *rearms*: a `7F xx 78` cancelled the clamped timer and installed a fresh
  /// full pending window, `SEARCHING...` installed a fresh twenty-five second
  /// one, and the transport write always got its own full allowance. Each of
  /// those is the exchange asking for more time after the caller stopped
  /// waiting, which is the whole of what the deadline exists to prevent.
  DateTime? _deadlineAt;

  /// [proposed], or whatever is left of the caller's budget if that is less.
  ///
  /// Never zero or negative: a timer armed for the past fires immediately,
  /// which is the correct outcome and needs no special case.
  Duration _withinDeadline(Duration proposed) {
    final deadline = _deadlineAt;
    if (deadline == null) return proposed;
    final left = deadline.difference(DateTime.now());
    if (left <= Duration.zero) return Duration.zero;
    return left < proposed ? left : proposed;
  }

  /// The deadline a *global* diagnostic exchange gets.
  ///
  /// `commandTimeout` is five seconds and so is the window the adapter opens
  /// for itself when it sees `7F xx 78`, so the two expire together and the
  /// host can abandon the very exchange the adapter is still holding. The
  /// terminal reply then arrives belonging to nobody, and a Mode 04 clear that
  /// actually succeeded is reported as a timeout.
  ///
  /// `_extendTimeoutIfPending` is not enough on its own, and the reason this
  /// comment used to give was invented. It said that from v2.1 the adapter
  /// *swallows* those bytes rather than forwarding them, so nothing pending
  /// ever reaches the buffer. The datasheet says no such thing — it says the
  /// adapter "checks each reply to see if it is a special 'Response Pending'
  /// message" and changes *its own* timeout to five seconds when it sees one.
  /// Nothing about suppression, and this app's own model disagrees too: the
  /// v2.x fixture forwards `7F 03 78` and the read reports it as pending.
  /// Fourth fabricated datasheet citation found in this project.
  ///
  /// The real reason is timing, and it does not depend on forwarding at all.
  /// The extension can only fire once bytes arrive; if the host's own window
  /// closes first, there is nothing left to extend. The two windows have to be
  /// ordered, and this is where that is done.
  ///
  /// Only global reads get this. An ordinary PID poll must stay responsive —
  /// a gauge that waits seven seconds to admit it has no answer is its own
  /// defect.
  Duration get globalTimeout => commandTimeout < responsePendingTimeout
      ? responsePendingTimeout
      : commandTimeout;

  /// How long to wait once a controller has answered `7F xx 78`.
  ///
  /// The standard gives the server five seconds and resets that window on each
  /// further pending reply. This is that window plus the room the adapter
  /// needs to hand it over.
  final Duration responsePendingTimeout;

  /// Restarts the pending command's deadline when the adapter says it is
  /// hunting for the bus protocol.
  ///
  /// After `ATSP0` the first real query makes the ELM327 try each protocol in
  /// turn. It emits `SEARCHING...` and only then the answer, and on a slow
  /// vehicle that whole dance runs well past a normal command timeout. Timing
  /// out there would abort a connection that was actually about to succeed —
  /// but `SEARCHING` is positive evidence the adapter is alive and working, so
  /// the deadline is pushed out rather than the command being abandoned.
  ///
  /// (This doc was orphaned for a while: a new method and its comment were
  /// spliced between it and the body it describes, leaving this one
  /// undocumented and its text attached to the wrong thing. In a tree where
  /// comments are audited as evidence, a detached doc is how the next
  /// fabricated citation starts.)
  void _extendTimeoutIfSearching() {
    if (_pending == null || _searchExtended) return;
    if (_buffer.length > 256) return;
    final text = ascii.decode(_buffer, allowInvalid: true).toUpperCase();
    if (!text.contains('SEARCHING')) return;

    _searchExtended = true;
    _pendingTimeout?.cancel();
    _pendingTimeout = Timer(_withinDeadline(protocolSearchTimeout), () {
      _outOfSync = true;
      _failPending(TimeoutException('協定搜尋逾時，車輛可能未開啟電門', protocolSearchTimeout));
    });
  }

  void _completePending(ObdResponse response) {
    // Any reply carrying a voltage refreshes the cached figure, so a periodic
    // ATRV keeps the status pill live rather than pinned to the handshake.
    final volts = response.batteryVoltage;
    final wasVoltageQuery =
        _pendingCommand?.toUpperCase().replaceAll(' ', '') == 'ATRV';
    if (wasVoltageQuery) {
      // This command exists to answer the voltage question, so its failure to
      // answer is itself the answer. Retaining the previous figure is how a
      // clone that stopped reporting left the handshake's 13.9 V on the status
      // pill while the real supply sagged.
      _recordVoltage(volts);
    } else if (volts != null) {
      _recordVoltage(volts);
    }

    // Some failures are not about this command at all — the adapter has reset
    // itself and lost echo, header and protocol settings. Carrying on polling
    // against those stale assumptions produces replies that parse but mean
    // something else, so the session is torn down and rebuilt instead.
    if (response.errorCode.requiresReconnect ||
        response.errorCode == Elm327ErrorCode.internalError) {
      isInitialized = false;
      _watchdog?.cancel();
      _watchdog = null;
      scheduleMicrotask(() => onConnectionLost?.call());
    }

    _pendingTimeout?.cancel();
    _pendingTimeout = null;
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) pending.complete(response);
  }

  void _failPending(Object error) {
    _pendingTimeout?.cancel();
    _pendingTimeout = null;
    final pending = _pending;
    _pending = null;
    if (pending == null || pending.isCompleted) return;
    // Marked handled before it is failed.
    //
    // `disconnect` fails whatever was in flight, and the thing in flight is not
    // always something a caller is still waiting on — the header restore that
    // trails a `sendGlobal` runs after that call's own future has completed, so
    // tearing down straight after a scan errors a future with no listener and
    // Dart reports it as an unhandled asynchronous exception. On a phone that
    // is a red screen in debug and a logged crash in release, produced by the
    // ordinary act of tapping 中斷連線 while the last command is still on the
    // wire.
    //
    // `ignore()` registers a handler; it does not consume the error. A caller
    // that *is* awaiting still receives it, which is the whole point — the
    // failure has to keep reaching anyone who asked for it.
    pending.future.ignore();
    pending.completeError(error);
  }

  // ------------------------------------------------------------ commands ----

  /// Sends [command] and waits for its reply.
  ///
  /// Calls are chained rather than run concurrently: the adapter has exactly
  /// one reply slot, so a second send before the first `>` arrives would make
  /// the two replies indistinguishable.
  Future<ObdResponse> send(String command, {Duration? timeout}) {
    final completer = Completer<ObdResponse>();
    _commandChain = _commandChain.then((_) async {
      try {
        if (_outOfSync) await _resync();
        completer.complete(await _sendNow(command, timeout ?? commandTimeout));
      } on Object catch (e, st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// Consulted immediately before every write, inside the serialized chain.
  ///
  /// Lifecycle was checked by callers, which is a different place from where
  /// the bytes go out. A pause increments the polling epoch, but a loop parked
  /// on `ATRV` refills its queue and transmits one more command before
  /// anything notices; a pending-response retry sleeps two seconds and sends
  /// again with no lifecycle token at all; a queued Mode 04 clear reaches the
  /// head of the chain after the screen that asked for it has gone. Each of
  /// those is traffic on a stranger's vehicle bus after the app stopped being
  /// in front of anyone, and a clear is state-changing.
  ///
  /// The chain is the only place that sees every write, so the question is
  /// asked here rather than at each of the callers that used to try.
  ///
  /// `owner` is the operation's lease, and it exists because "is this session
  /// in the foreground *right now*" answers a different question from "is this
  /// still the operation the user asked for". Backgrounding refuses the queued
  /// Mode 04 correctly; resuming sets foreground back to true and the same
  /// stale clear — queued minutes ago, for a screen that has since gone —
  /// passes and erases the vehicle's fault memory. A lease captured when the
  /// operation started and compared against the current one survives the round
  /// trip through background, because pausing advances the epoch and resuming
  /// does not put it back. `null` means "no lease", which is the right default
  /// for the polling loop: its writes are idempotent reads.
  bool Function(Object? owner)? mayTransmit;

  Future<ObdResponse> _sendNow(
    String command,
    Duration timeout, {
    Object? owner,
    DateTime? deadline,
    bool completesCommittedTransaction = false,
  }) async {
    // The two refusals that are *provably* before the wire. Nothing has been
    // handed to the transport at this point, so the adapter owes nothing and
    // the send timestamp must not move — leaving one behind would have the
    // watchdog count silence against a request that was never made, and tear
    // the link down for it five seconds later.
    if (!transport.isConnected) {
      throw const TransportException('連線尚未建立。');
    }
    // Refused before a transaction starts, never in the middle of one.
    //
    // `sendOnHeader` is two writes: `ATSH`, then the query. Once the adapter
    // has acknowledged the header the client has committed to it, and letting
    // the lifecycle gate refuse the second write leaves both of them pointed
    // at a custom address nobody is going to move. On J1850 there is no
    // modelled restore header, so every built-in PID afterwards throws
    // `UnaddressableRequestException` — a session that still looks connected
    // with every gauge permanently blank until reconnect.
    //
    // A read that finishes work already begun is not the thing the gate is
    // for. What it is for — a state-changing Mode 04 reaching the wire for a
    // screen that has gone — is refused at the *first* write of its exchange,
    // which is where the decision belongs.
    if (!completesCommittedTransaction && !(mayTransmit?.call(owner) ?? true)) {
      throw const OperationRetiredException('這個工作階段已經結束或退到背景，指令沒有送出。');
    }
    // The caller's budget, applied to each write rather than to the operation
    // as a whole.
    //
    // A global exchange is `ATH1`, `ATSH`, the service and `ATH0`, and the
    // preflight sized it against one response window. With eight seconds left
    // and each control command answering in four and a half — both inside
    // their own contracts — the caller's `Future.timeout` fired while the
    // chain went on to transmit the service and the restore. The screen said
    // the category was finished and the adapter was still executing it; an
    // immediate rescan then queued behind work nobody owned.
    //
    // `Future.timeout` cannot cancel the chain, so the chain has to hold the
    // deadline itself.
    _deadlineAt = deadline;
    if (deadline != null) {
      final left = deadline.difference(DateTime.now());
      if (left <= Duration.zero) {
        throw TimeoutException('已超過這次操作的時間上限，$command 沒有送出。');
      }
      if (left < timeout) timeout = left;
    }
    _buffer.clear();
    _searchExtended = false;
    _pendingSeen = 0;
    // Cancel before overwriting: if the previous write threw, its timer is
    // still armed and would later fail whichever command is then in flight.
    _pendingTimeout?.cancel();

    final pending = Completer<ObdResponse>();
    _pending = pending;
    _pendingCommand = command.trim();
    // Outlives the completer on purpose: the watchdog needs to know that a
    // command went out after the adapter last spoke, which stays true after
    // `_onCommandTimeout` has cleared `_pending`.
    _lastCommandSentAt = DateTime.now();

    final normalised = command.trim().toUpperCase().replaceAll(' ', '');
    // Kept for the watchdog, which must not give up before the command does.
    _pendingDeadline = timeout;
    _pendingTimeout = Timer(timeout, _onCommandTimeout);

    try {
      // Its own deadline, because a write can block forever with nothing
      // watching. `WifiTransport.write` is `socket.add` plus `await flush()`,
      // and on a half-dead TCP link — the phone carried out of range of the
      // adapter's hotspot, no RST, the OS retransmitting for fifteen minutes —
      // that flush never returns. The command chain then parks on the write,
      // `_pending` is cleared by its own timer, and the watchdog has nothing
      // to observe: a frozen screen that still says connected.
      //
      // Shorter than `commandTimeout`, because handing bytes to a healthy link
      // is not something that takes seconds.
      final wire = ascii.encode('${command.trim()}\r');
      // Which command's bytes were last handed to the transport.
      //
      // The note below says the only provably-unsent writes are the ones
      // rejected before this call, and that was true and unavailable: every
      // caller saw an exception whose Dart type says nothing about the wire.
      // A clear needs the answer more than anything else in the app — a Mode
      // 04 that may have reached the adapter must not be offered as a free
      // retry, and one that provably did not must not be locked away — so the
      // fact is recorded where it is known instead of guessed where it is not.
      _writesSinceAudit.add(normalised);
      // Recorded before the write, not after it. A write that never returns is
      // the case worth having on record, and recording on success would be the
      // one time the transcript stays silent.
      transcript.recordWrite(wire);
      await transport.write(wire).timeout(_withinDeadline(writeTimeout));
    } on Object catch (e) {
      // …and taken back only when the transport says it never started.
      //
      // Recording before the write is the conservative default and stays that
      // way: an unknown failure has to read as possibly-sent. But every
      // transport opens `write` with a precondition check — no socket, no
      // characteristic, no connection — and that is the one place in the stack
      // where "no byte left the app" is a fact rather than an inference.
      //
      // Without this, a `04` rejected at that guard was reported as sent, so
      // the clear locked its button over a Mode 04 that provably never
      // happened and asked for a rescan that could settle nothing.
      if (e is WriteRefusedException) _writesSinceAudit.remove(normalised);
      _pendingTimeout?.cancel();
      _pendingTimeout = null;
      _pending = null;
      _pendingCommand = null;

      // Anything that comes out of `transport.write` leaves the outcome
      // **unknown**, whatever type it is.
      //
      // A previous version split on `e is TimeoutException` and confidently
      // classified everything else as "not sent". That distinction does not
      // exist. `WifiTransport.write` is `socket.add(data)` followed by `await
      // flush()`; `add` hands the bytes to the kernel immediately, so a
      // `SocketException` from `flush` — connection reset, broken pipe —
      // happens *after* the adapter may already have received the command.
      // The exception's Dart class says nothing about whether the bytes
      // reached the wire.
      //
      // Getting this wrong is not a lost command but a mislabelled one: the
      // buffered request arrives late, its perfectly valid reply completes the
      // *next* command, and the app publishes an old sample under a new
      // timestamp. Every gauge one request stale with nothing saying so.
      //
      // So the timestamp stays — it is what the watchdog counts silence
      // against — and the link is marked out of sync so the next command
      // drains before it writes. The only writes that are *provably* unsent
      // are the ones rejected before `transport.write` was ever called, and
      // those are handled above, where the proof is.
      _outOfSync = true;
      rethrow;
    }

    final response = await pending.future;
    _applyRenderingState(normalised, response);
    return response;
  }

  /// Updates the model of the adapter's rendering, once the adapter agrees.
  ///
  /// This used to run when the command went *out*. A clone answering `?` to
  /// `ATH1` therefore left the parser expecting attributed lines that were
  /// never coming: with spaces off, an unheadered `4100BE1FA813` matches the
  /// eight-hex-digit shape of a 29-bit CAN identifier and was decoded as an
  /// address rather than as data. The reverse case is worse — a timed-out
  /// `ATH0` left the client believing headers were off while every polling
  /// reply arrived with one, and the whitelist discarded all of them.
  void _applyRenderingState(String normalised, ObdResponse response) {
    if (normalised == 'ATZ' || normalised == 'ATD') {
      // A reset restores the documented defaults regardless of what it prints
      // — `ATZ` answers with the version string, not `OK`.
      _headersOn = false;
      // And the header selection goes with it. Only `_headersOn` was cleared,
      // so a reset mid-session left the client naming a header the adapter had
      // just discarded — and the next query for that header would skip `ATSH`
      // and go out on whatever the reset restored. Unreachable today, because
      // nothing sends `ATD`/`ATWS` after the handshake and each connection
      // builds a fresh client; it is the same defect class as the lost `ATSH`
      // reply, and half a reset is how that one survived.
      _currentHeader = null;
      return;
    }
    if (!_saidOk(response)) return;
    if (normalised == 'ATH1') {
      _headersOn = true;
    } else if (normalised == 'ATH0') {
      _headersOn = false;
    }
  }

  /// A timed-out command leaves the adapter still owing us a reply.
  ///
  /// If that late reply arrives while the *next* command is in flight, its `>`
  /// completes the wrong completer and every reply from then on is attributed
  /// to the previous request — the dashboard would show last cycle's values as
  /// this cycle's, forever, with nothing to make it self-heal. So the link is
  /// marked out of sync and resynchronised before anything else is sent.
  void _onCommandTimeout() {
    _outOfSync = true;
    _failPending(TimeoutException('等待回應逾時', commandTimeout));
  }

  /// Waits out whatever the adapter still owes us, then clears the desync.
  ///
  /// Deliberately sends **nothing**. A bare `\r` is not a passive re-prompt on
  /// an ELM327 — the datasheet defines it as "repeat the previous command", so
  /// using it to resynchronise would re-issue whatever just timed out and make
  /// the pile-up worse.
  ///
  /// Instead this waits for a real `>` from the outstanding reply. Only when
  /// the prompt has actually been seen is the link back in step; if none
  /// arrives inside the deadline the adapter is not answering at all and the
  /// caller is told, rather than the desync being cleared on a guess.
  Future<void> _resync({DateTime? deadline}) async {
    // Worth a line of its own. A resync is the app saying the stream is out of
    // step, and the bytes around it read very differently once you know that
    // is what was happening.
    transcript.recordNote('連線不同步，開始重新對齊');
    _buffer.clear();
    final drain = Completer<bool>();
    _draining = drain;

    // `false` — the deadline expiring is not a resynchronisation.
    // Within the caller's budget when it has one. Three fixed seconds meant a
    // command with a millisecond left still spent them here, and a link that
    // stays quiet then ends the session — long after whoever asked had gone.
    final started = DateTime.now();
    final window = deadline == null
        ? resyncTimeout
        : (() {
            final left = deadline.difference(DateTime.now());
            if (left <= Duration.zero) return Duration.zero;
            return left < resyncTimeout ? left : resyncTimeout;
          })();
    final timer = Timer(window, () {
      if (!drain.isCompleted) drain.complete(false);
    });

    final bool sawPrompt;
    try {
      sawPrompt = await drain.future;
    } finally {
      timer.cancel();
      _draining = null;
      _buffer.clear();
    }

    // A caller running out of time is not the adapter failing.
    //
    // The drain window is clamped to whoever asked, so 50 ms of remaining
    // budget produces a 50 ms window — and treating *that* expiry as proof the
    // link is dead tore down a session whose valid prompt was 100 ms away,
    // comfortably inside the three seconds this recovery actually allows. The
    // caller is refused; the link keeps the benefit of the doubt it was given.
    if (!sawPrompt && window < resyncTimeout) {
      // The rest of the window this client allows, minus what was spent.
      _resyncGraceUntil = started.add(resyncTimeout);
      throw TimeoutException('這次操作的時間上限到了，連線同步尚未完成。請重新操作。');
    }
    if (!sawPrompt) {
      // Clearing the flag here — which is what this method used to do
      // unconditionally, in `finally` — declares the stream synchronised on no
      // evidence at all. The outstanding reply is still in flight, so the next
      // command's `>` may well be the *previous* command's, and from then on
      // every reading is last cycle's data wearing this cycle's timestamp.
      //
      // Steady-state polling repeats the same PIDs, so those replies pass every
      // self-identification check the parser makes, the watchdog stays quiet
      // and staleness never fires. It does not self-heal. The link has to go.
      _outOfSync = true;
      isInitialized = false;
      // "The link has to go" was the intent, and nothing carried it out. The
      // throw reaches whichever command triggered the resync, the polling
      // loop swallows it, and the session is never told — so the dashboard
      // keeps its green dot, its "10 PIDs/s" pill and its last values while
      // the loop retries a resync that can no longer succeed. Reproduced on a
      // device: four minutes of a frozen but confidently connected screen.
      //
      // Clearing `isInitialized` also permanently disables the watchdog, which
      // returns early on it, so nothing else was going to notice either.
      _watchdog?.cancel();
      _watchdog = null;
      scheduleMicrotask(() => onConnectionLost?.call());
      throw const TransportException('轉接器沒有回應同步請求，連線已中斷。請重新連線。');
    }
    _outOfSync = false;
  }

  /// How long to wait for the outstanding reply's prompt before giving up on
  /// resynchronising and simply carrying on.
  static const Duration resyncTimeout = Duration(seconds: 3);

  /// Until when a late prompt is still an ordinary recovery.
  ///
  /// Set when a drain is cut short by its caller's budget rather than by the
  /// adapter failing to answer. Null the rest of the time.
  DateTime? _resyncGraceUntil;

  /// Queries a PID. Distinct from [send] only in that it refuses to run before
  /// the handshake has completed.
  Future<ObdResponse> queryPid(String modeAndPid) {
    if (!isInitialized) {
      throw StateError('ELM327 尚未完成初始化');
    }
    return send(modeAndPid);
  }

  /// Sends [command] with the transmit header set to [header], as one
  /// indivisible slot in the command chain.
  ///
  /// Setting the header and issuing the query as two separate `send()` calls
  /// leaves a gap: DTC reads, VIN reads and support discovery all share this
  /// chain, and any of them can slip in between and run against the header
  /// that was just selected for something else. On a multi-ECU car that means
  /// a transmission query answered by the engine, or the reverse — wrong
  /// numbers, from the right adapter, with nothing to indicate it.
  Future<ObdResponse> sendOnHeader(
    String header,
    String command, {
    Duration? timeout,
  }) {
    final completer = Completer<ObdResponse>();
    _commandChain = _commandChain.then((_) async {
      // Whether this slot moved the adapter's header. If it did, the query
      // that follows finishes a transaction the adapter is already committed
      // to and may not be abandoned half-done — see `_sendNow`.
      var committed = false;
      try {
        if (_outOfSync) await _resync();
        if (header != _currentHeader) {
          // Unknown from the moment the write leaves, not from the moment the
          // reply fails to arrive.
          //
          // This file's own doctrine is that a write whose reply is lost has
          // an *unknown* outcome — and this was the one place that treated it
          // as undone. The adapter may well have applied the header; if it
          // did, `_currentHeader` went on naming the old one, the next query
          // for that old header skipped `ATSH` as redundant, and the request
          // was physically transmitted to a different controller. A
          // transmission answering an engine query decodes into a plausible
          // gauge reading with nothing to indicate it.
          _currentHeader = null;
          final ack = await _sendNow('ATSH $header', commandTimeout);
          // `?` is how an ELM327 refuses a header the current bus cannot take.
          // Proceeding past that sends the query on whatever header the adapter
          // really holds, and the answer comes back from the wrong ECU looking
          // exactly like the right one.
          final acknowledged =
              ack.isSuccess &&
              ack.rawLines.any((l) => l.trim().toUpperCase() == 'OK');
          if (!acknowledged) {
            throw TransportException('轉接器拒絕切換標頭 $header');
          }
          _currentHeader = header;
          committed = true;
        }
        completer.complete(
          await _sendNow(
            command,
            timeout ?? commandTimeout,
            completesCommittedTransaction: committed,
          ),
        );
      } on Object catch (e, st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  static bool _saidOk(ObdResponse r) =>
      r.isSuccess && r.rawLines.any((l) => l.trim().toUpperCase() == 'OK');

  /// Sends [command] to [header], selecting it only when it means something on
  /// the detected bus.
  ///
  /// The app's stored default is `7E0`, which addresses the engine on 11-bit
  /// CAN and is not a header at all elsewhere. Transmitting it on a legacy bus
  /// would replace the addressing `ATSP0` established, so there the default is
  /// read as "no preference" and the adapter is left alone.
  Future<ObdResponse> sendAddressed(
    String header,
    String command, {
    Duration? timeout,
  }) {
    if (addressing.shouldTransmit(header)) {
      return sendOnHeader(header, command, timeout: timeout);
    }

    // "Do not transmit the stored default" only means "address the engine"
    // while nothing else has changed the adapter. A custom PID's own `ATSH`
    // persists, and a global scan leaves `18DB33F1` installed on 29-bit CAN —
    // after which leaving the adapter alone sends this query to whichever
    // controller that names. If it answers, the reading is indistinguishable
    // from the right one.
    //
    // Nothing is transmitted unless something was actually displaced. On the
    // overwhelmingly common vehicle — no custom PID, adapter untouched since
    // the handshake — this path sends no `ATSH` at all, which is both correct
    // and the only behaviour with any hardware history behind it.
    if (_currentHeader == null) {
      // Nothing was displaced — but "leave the adapter alone" is only safe
      // when the adapter's own default addresses one controller.
      //
      // On 29-bit CAN it does not. The default there is the functional ID
      // `18DB33F1`, which every emissions controller answers, so a built-in
      // query for rpm and speed goes out to all of them and comes back as two
      // controllers' lines concatenated into one payload. The splitter then
      // reads a boundary that belongs to neither. On 11-bit this cannot
      // happen, because `7E0` *is* transmittable there and is installed
      // explicitly.
      //
      // So: if this bus has a functional default and a known physical engine
      // address, install the physical one. Legacy buses have the same
      // functional default and no known physical address — that is round 7's
      // F-2, and inventing one is what it was about — so they are left alone
      // and their replies are separated by frame instead.
      final engine = addressing.engineHeader;
      if (engine != null && addressing.functionalHeader != null) {
        return sendOnHeader(engine, command, timeout: timeout);
      }
      return send(command, timeout: timeout);
    }

    final restore = addressing.restoreHeader;
    if (restore == null) {
      // J1850: no physical engine address is defined and the family's two
      // protocols disagree about the functional one, so there is no known
      // addressing state to return to. The query is refused rather than sent
      // to whichever controller the custom PID selected — a plausible number
      // on the wrong gauge is the failure this app exists to avoid, and unlike
      // a refusal it says nothing about itself.
      throw UnaddressableRequestException(
        '這輛車使用的舊式匯流排沒有標準的控制器位址，而轉接器目前指定在 '
        '$_currentHeader。無法確定內建感測器的查詢會由哪一個控制器回答，'
        '因此已停止查詢。請移除自訂 PID 的標頭設定後重新連線。',
      );
    }
    if (_currentHeader != restore.toUpperCase()) {
      return sendOnHeader(restore, command, timeout: timeout);
    }
    return send(command, timeout: timeout);
  }

  /// Sends a request that is about the *vehicle* rather than one controller.
  ///
  /// Mode 03/07/0A, Mode 04 and Mode 09 are questions the whole emissions
  /// system answers. Sending them to a physical address asks the engine
  /// controller alone, so a transmission fault is invisible and the screen
  /// reports a clean scan; sending them on whatever header the last custom PID
  /// selected is worse still, because then the answer comes from a controller
  /// nobody chose.
  ///
  /// Headers are turned on for the exchange. With `ATH0` two controllers'
  /// replies are genuinely indistinguishable — datasheet p.43 concludes "the
  /// only way to know is to turn on the headers" — and being unable to
  /// attribute a fault code is the same problem in a different coat.
  /// `owner` leases the whole exchange, checked again at each write rather than
  /// once at the top. The gap between them is where a queued Mode 04 used to
  /// live: the caller's own before/after checks bracket the `await`, so an
  /// expiry during the wait was noticed only once the bytes were already on the
  /// wire — reporting failure for a clear that had happened. The `ATH0` restore
  /// in `finally` deliberately carries no lease, because leaving the adapter
  /// with headers on is a state the next command inherits.
  Future<ObdResponse> sendGlobal(
    String command, {
    Duration? timeout,
    Object? owner,
    DateTime? deadline,
    String? header,
  }) {
    final completer = Completer<ObdResponse>();
    _commandChain = _commandChain.then((_) async {
      try {
        // Before the recovery, not after it. `_resync` is a fixed three-second
        // drain that can end by tearing the link down, and a caller whose
        // budget or lease had already expired was made to sit through it —
        // blocking newer commands and, on a link that stays quiet,
        // disconnecting the session on behalf of work nobody was waiting for.
        if (!(mayTransmit?.call(owner) ?? true)) {
          throw const OperationRetiredException('這個工作階段已經結束或退到背景，指令沒有送出。');
        }
        if (deadline != null && !deadline.isAfter(DateTime.now())) {
          throw TimeoutException('已超過這次操作的時間上限，$command 沒有送出。');
        }
        if (_outOfSync) await _resync(deadline: deadline);

        // Normally the functional broadcast. [header] overrides it so a
        // caller can put one *named* controller through this same machinery —
        // headers on, the query, headers restored — rather than reimplementing
        // it. The point of routing a physical request through here is the
        // attribution: the reply has to prove which module sent it, and that
        // is the whole reason this method turns headers on at all.
        final functional = header ?? addressing.functionalHeader;
        if (functional == null) {
          // Legacy buses have no single documented functional address for OBD
          // — it is per-message and per-standard — so the adapter's own
          // default is used rather than a guess.
          //
          // "The adapter's default" only holds while nothing has installed a
          // physical header since. A custom PID's own `ATSH` persists, and
          // Mode 03 would then go out physically addressed to one controller
          // while the UI presents the result as a whole-vehicle scan: a clean
          // ECM answer returned, a transmission fault never even requested.
          final installed = _currentHeader;
          if (installed != null && !BusAddressing.isAppDefault(installed)) {
            throw TransportException(
              '這輛車使用的舊式匯流排沒有標準的廣播位址，而轉接器目前指定在控制器 '
              '$installed。掃描只會涵蓋該控制器，不能當作全車結果，因此已中止。'
              '請重新連線後再掃描一次。',
            );
          }
          // Headers on here too, for the same reason they go on for CAN: a
          // reply nobody can attribute cannot support a whole-vehicle claim.
          // Without this the legacy header parser was unreachable and legacy
          // vehicles were exempt from the attribution requirement entirely —
          // so one anonymous `43 00` could still close a scan as clean on
          // exactly the buses whose attribution nobody had implemented.
          //
          // A refusal is not fatal here, unlike on CAN. Legacy adapters vary
          // more, `ATH1` is likelier to be unsupported, and the request still
          // reaches the bus; the caller decides what an unattributed reply
          // entitles it to claim.
          final legacyHeadersWereOn = _headersOn;
          final legacyHeadersOn = _saidOk(
            await _sendNow(
              'ATH1',
              commandTimeout,
              owner: owner,
              deadline: deadline,
            ),
          );
          try {
            completer.complete(
              (await _sendNow(
                command,
                timeout ?? globalTimeout,
                owner: owner,
                deadline: deadline,
              )).withHeadersEnabled(legacyHeadersOn || legacyHeadersWereOn),
            );
          } finally {
            if (legacyHeadersOn && !legacyHeadersWereOn) {
              // Never `return` from a `finally`: it discards the exception in
              // flight and hangs the caller. Learned the hard way on the CAN
              // path above.
              var canRestore = true;
              if (_outOfSync) {
                try {
                  await _resync();
                } on Object {
                  canRestore = false;
                }
              }
              if (canRestore) {
                // A refusal is not a desynchronisation.
                //
                // `_sendNow` returning at all means the prompt arrived, so the
                // stream is in step — the adapter simply declined to turn
                // headers off. Marking the link out of sync sent the *next*
                // command into `_resync`, which drains waiting for a prompt from
                // a command nobody issued, times out after three seconds, and
                // tears the session down. A fault-code scan would succeed and
                // every gauge would then disconnect three seconds later.
                //
                // Nothing needs recovering. `_applyRenderingState` only commits
                // `_headersOn` on a literal `OK`, so the model still says headers
                // are on, which is exactly what is true — and the parser handles
                // headered replies. A timeout is different and still throws,
                // which is where a real desync would be caught.
                // Explicitly exempt, because omitting `owner` never was.
                // `mayTransmit(null)` is still consulted and the production gate
                // refuses *every* owner while the app is backgrounded — so a scan
                // interrupted after `ATH1` left the adapter printing headers for
                // the rest of the session, and the poll loop pays those bytes on
                // every reply. Restoring state this exchange changed is the one
                // write that must outlive the exchange.
                await _sendNow(
                  'ATH0',
                  commandTimeout,
                  completesCommittedTransaction: true,
                );
              }
            }
          }
          return;
        }

        // Attribution is what makes this operation global rather than a
        // request that happened to be answered by someone. Proceeding without
        // it let one anonymous `43 00` stand for every controller on the bus.
        //
        // A refusal is reported, not thrown. This used to be fatal here, and
        // deciding it in the transport layer was the mistake: "cannot attribute"
        // is worth different things to different callers — fatal to a
        // fault-code scan's all-clear, irrelevant to a VIN — and only the
        // caller knows which it is. Throwing also meant that giving the legacy
        // buses functional headers of their own, two files away, silently
        // routed them into this branch and turned every scan on an
        // `ATH1`-refusing adapter from working into a hard error.
        final headersWereOn = _headersOn;
        final headersOn =
            _saidOk(
              await _sendNow(
                'ATH1',
                commandTimeout,
                owner: owner,
                deadline: deadline,
              ),
            ) ||
            headersWereOn;

        try {
          // Unknown from the moment the write leaves. Same rule as
          // `sendOnHeader`, and for the same reason: a lost acknowledgement
          // does not mean the adapter kept the old header, so the model must
          // stop claiming to know which one it holds.
          _currentHeader = null;
          final ack = await _sendNow(
            'ATSH $functional',
            commandTimeout,
            owner: owner,
            deadline: deadline,
          );
          if (!_saidOk(ack)) {
            throw TransportException('轉接器拒絕切換為功能定址 $functional');
          }
          _currentHeader = functional;

          completer.complete(
            (await _sendNow(
              command,
              timeout ?? globalTimeout,
              owner: owner,
              deadline: deadline,
            )).withHeadersEnabled(headersOn),
          );
        } finally {
          // Restore the quieter rendering for the polling loop, which does not
          // need attribution and pays the extra bytes on every reply. In
          // `finally` because a failed scan leaves the adapter just as changed
          // as a successful one.
          if (headersOn && !headersWereOn) {
            // Every ordinary `send` drains before writing when the link is out
            // of sync. Calling `_sendNow` from here skipped that invariant on
            // exactly the path that needs it: if the scan timed out, the
            // adapter still owes a reply, and writing `ATH0` immediately lets
            // that late `43 00` complete *this* command's completer — judged
            // "not OK" — while the real `OK` arrives with nothing pending and
            // is discarded as noise, silently clearing the desync flag. The
            // adapter ends up with headers off and the client believing they
            // are on, with no drain having happened.
            // Never `return` from here. A `return` inside `finally` discards
            // the exception in flight — so the outer catch never ran, the
            // completer was never completed either way, and the caller's
            // future simply hung. A fault-code scan whose exchange failed and
            // whose drain then failed would wait forever, which is worse than
            // the failure it was recovering from.
            var canRestore = true;
            if (_outOfSync) {
              try {
                await _resync();
              } on Object {
                // `_resync` has already ended the session. Nothing is left to
                // restore, and whatever brought us into `finally` is still the
                // outcome the caller should see.
                canRestore = false;
              }
            }
            if (canRestore) {
              // A refusal is not a desynchronisation.
              //
              // `_sendNow` returning at all means the prompt arrived, so the
              // stream is in step — the adapter simply declined to turn
              // headers off. Marking the link out of sync sent the *next*
              // command into `_resync`, which drains waiting for a prompt from
              // a command nobody issued, times out after three seconds, and
              // tears the session down. A fault-code scan would succeed and
              // every gauge would then disconnect three seconds later.
              //
              // Nothing needs recovering. `_applyRenderingState` only commits
              // `_headersOn` on a literal `OK`, so the model still says headers
              // are on, which is exactly what is true — and the parser handles
              // headered replies. A timeout is different and still throws,
              // which is where a real desync would be caught.
              // Explicitly exempt, because omitting `owner` never was.
              // `mayTransmit(null)` is still consulted and the production gate
              // refuses *every* owner while the app is backgrounded — so a scan
              // interrupted after `ATH1` left the adapter printing headers for
              // the rest of the session, and the poll loop pays those bytes on
              // every reply. Restoring state this exchange changed is the one
              // write that must outlive the exchange.
              await _sendNow(
                'ATH0',
                commandTimeout,
                completesCommittedTransaction: true,
              );
            }
          }
        }
      } on Object catch (e, st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// The header the adapter has *confirmed*, or null while that is unknown.
  ///
  /// Starting this at `7E0` was a claim the app had no evidence for: nothing
  /// had been sent yet, and on any bus that is not 11-bit CAN the adapter would
  /// refuse that header outright. `sendOnHeader` skips the switch when it
  /// believes the header already matches, so the untrue starting value meant
  /// the very first addressed query could go out on whatever the adapter
  /// actually had. Unknown until acknowledged is the honest state.
  String? _currentHeader;
  static const String kDefaultHeaderValue = '7E0';

  /// Commands whose bytes have been handed to [transport] since
  /// [beginWriteAudit].
  ///
  /// See the note in `_sendNow`: a failure *after* a write leaves the outcome
  /// unknown, and a failure before it is proof the command never went out.
  /// That distinction is the only honest basis for deciding whether a
  /// state-changing request may be repeated, and until now no caller could
  /// reach it.
  ///
  /// A window rather than a "last write", because the answer must survive
  /// whatever the exchange does next: a global send is `ATH1`, `ATSH`, the
  /// service and `ATH0`, and the header restore runs even when the service
  /// write failed — so the last thing written is never the thing being asked
  /// about.
  final Set<String> _writesSinceAudit = {};

  /// Starts a new window for [wroteSinceAudit].
  void beginWriteAudit() => _writesSinceAudit.clear();

  /// Whether [command]'s bytes reached the transport during this window.
  bool wroteSinceAudit(String command) =>
      _writesSinceAudit.contains(command.trim().toUpperCase());

  /// The adapter's persistent configuration, read once per connection.
  ///
  /// [ProgrammableParameters.unread] until `AT PPS` has answered, and it stays
  /// that way on any adapter that will not. Every consumer treats unread as
  /// unknown rather than as defaults, because a clone that does not implement
  /// the command has also told us nothing about how it is configured.
  ProgrammableParameters programmableParameters =
      const ProgrammableParameters.unread();

  /// Addressing implied by the protocol the adapter actually settled on.
  BusAddressing get addressing {
    final byNumber = BusAddressing.forProtocolNumber(
      protocolNumber,
      userCanOptions: programmableParameters.userCanOptions(
        BusAddressing.normaliseProtocolNumber(protocolNumber),
      ),
    );
    if (byNumber.isKnown) return byNumber;
    // Only when the *number* is missing, never when it is known and
    // deliberately not enough.
    //
    // `ATDPN` is not a critical step, so an adapter that answers it with `?`
    // connects and is then useless: undetermined refuses every gauge, every
    // fault-code read and the VIN, and reconnecting produces the same answer
    // because the adapter is consistent. `ATDP` is the second witness and the
    // app already asked for it.
    //
    // But `B` and `C` are *not* that case. Their number arrives perfectly
    // well; what is unknown is the framing, which lives in PP 2C / PP 2E, and
    // an adapter that will not print `AT PPS` leaves it unknowable. Reading
    // the description there would answer a question nobody asked and run the
    // J1979 decoder over possibly unframed CAN — which is the exact defect
    // the B/C handling exists to prevent. So the fallback is gated on the
    // number being absent, not on the addressing being unknown.
    final number = BusAddressing.normaliseProtocolNumber(protocolNumber);
    if (number.isNotEmpty && number != '0') return byNumber;
    return BusAddressing.forProtocolDescription(protocolDescription);
  }

  // ---------------------------------------------------------------- init ----

  Future<bool> _runInitSequence() async {
    var allCriticalPassed = true;

    for (var i = 0; i < initSequence.length; i++) {
      final step = initSequence[i];

      // Stop at the first critical failure instead of grinding through the
      // rest. Connecting to something that is not an ELM327 — a BLE speaker,
      // the wrong paired device — makes every command time out, and running
      // all fifteen means a minute of dead waiting before the app admits it.
      // Once a critical step has failed the outcome is already decided.
      if (!allCriticalPassed) {
        _emitProgress(step, i, InitStatus.skipped, '已中止');
        continue;
      }

      _emitProgress(step, i, InitStatus.running);

      try {
        final response = await send(
          step.command,
          timeout: const Duration(seconds: 4),
        );
        _captureIdentity(step.command, response);

        // `?` from an optional probe such as AT@1 means "this adapter does not
        // implement that command" — not a failure worth aborting for.
        final softFail = response.errorCode == Elm327ErrorCode.unknownCommand;
        if (softFail && !step.isCritical) {
          _emitProgress(step, i, InitStatus.skipped, '轉接器不支援此指令');
          continue;
        }
        if (!response.isSuccess && step.isCritical) {
          allCriticalPassed = false;
          // The sentence, not the identifier.
          //
          // This rendered as 初始化在 0100 失敗（unableToConnect） — a Dart enum
          // name in English inside a Chinese sentence, at the exact moment
          // somebody is standing at a car deciding whether the app is broken.
          // Every code already carries a driver-facing description a few
          // hundred lines up; they were written and never used here.
          _emitProgress(
            step,
            i,
            InitStatus.failed,
            response.errorCode.description,
          );
          continue;
        }

        // "Printed no error" is a much weaker claim than "answered correctly",
        // and the difference is the whole gap a device that says `OK` to
        // everything walks through.
        final failure = step.validate?.call(response);
        if (failure != null) {
          if (step.isCritical) allCriticalPassed = false;
          _emitProgress(
            step,
            i,
            step.isCritical ? InitStatus.failed : InitStatus.skipped,
            failure,
          );
          continue;
        }

        _emitProgress(step, i, InitStatus.ok, _detailFor(step.command));
      } on Object catch (e) {
        if (step.isCritical) allCriticalPassed = false;
        _emitProgress(
          step,
          i,
          step.isCritical ? InitStatus.failed : InitStatus.skipped,
          e is TimeoutException ? '逾時' : '$e',
        );
      }
    }

    isInitialized =
        allCriticalPassed && !_transportLost && transport.isConnected;
    return isInitialized;
  }

  /// Picks the first line that is not the adapter echoing our own command.
  ///
  /// Echo is only switched off by `ATE0`, which is the *second* step — so the
  /// reply to `ATZ` legitimately begins with `ATZ`, and reading `firstLine`
  /// blindly would report the adapter's version as "ATZ".
  String _identityLine(String command, ObdResponse response) {
    final normalised = command.replaceAll(' ', '').toUpperCase();
    for (final line in response.rawLines) {
      if (line.replaceAll(' ', '').toUpperCase() == normalised) continue;
      if (line.trim().isEmpty) continue;
      return line;
    }
    return '';
  }

  /// Whether this adapter handles `7F xx 78` itself.
  ///
  /// The datasheet is explicit that this is a firmware property, not a bus
  /// property: "Beginning with v2.1, that is changing… If bit 2 of PP 2A is
  /// set (it is by default), the ELM327 will support this part of J1979,
  /// changing the timeout to 5 seconds for you". A v1.x adapter does none of
  /// it, and a clone reporting a version it does not implement does less.
  ///
  /// Keying the retry decision on CAN-versus-legacy read the *standard* and
  /// forgot the *device*: on a genuine v1.3a talking to a CAN vehicle the app
  /// stopped asking, so a P0301 the adapter would have returned on a second
  /// request came back as an incomplete scan instead.
  ///
  /// Unknown counts as "does not", which is the safe direction here — an extra
  /// request costs a round trip, and not asking costs the fault.
  bool get adapterHandlesResponsePending {
    // Two conditions, and only one of them was being checked.
    //
    // The datasheet makes the five-second extension conditional on PP 2A bit
    // 2 — "If bit 2 of PP 2A is set (it is by default), the ELM327 will
    // support this part of J1979". Inferring it from the version banner alone
    // gets the default case right and the configured case exactly backwards:
    // an adapter with bit 2 cleared does *not* wait, this app then declines to
    // re-ask a controller that answered `7F xx 78`, and a stored fault the
    // vehicle was about to report is never read. It also takes a clone's word
    // for a version it may not implement.
    //
    // Unknown counts as "not handled", which costs one redundant request and
    // cannot cost a fault code.
    if (programmableParameters.responsePendingHandled != true) return false;
    final match = RegExp(
      r'ELM327\s+v?(\d+)\.(\d+)',
      caseSensitive: false,
    ).firstMatch(deviceVersion);
    if (match == null) return false;
    final major = int.tryParse(match.group(1)!) ?? 0;
    final minor = int.tryParse(match.group(2)!) ?? 0;
    return major > 2 || (major == 2 && minor >= 1);
  }

  /// How many controllers answered the handshake's `0100` probe.
  ///
  /// `0100` is a functional request, so every emissions controller replies —
  /// and on a legacy bus each reply is one complete line, so the *number of
  /// lines* counts responders whether or not headers are on. That is a census
  /// available on adapters that will not print headers, where the attributed
  /// one is not.
  ///
  /// Null before the probe has run. Zero never: reaching this point means
  /// something answered.
  int? responderCount;

  void _captureIdentity(String command, ObdResponse response) {
    switch (command) {
      case '0100':
        if (response.isSuccess && response.frames.isNotEmpty) {
          responderCount = response.frames.length;
        }
      case 'ATZ':
      case 'ATI':
        final line = _identityLine(command, response);
        if (line.isNotEmpty) deviceVersion = line;
      case 'AT@1':
        if (response.isSuccess) deviceIdentity = response.firstLine;
      case 'ATRV':
        // Including the null case: this command exists to answer the question,
        // so its failure to answer is the answer.
        _recordVoltage(response.batteryVoltage);
      case 'ATDP':
        if (response.isSuccess) protocolDescription = response.firstLine;
      case 'ATDPN':
        // Read from the raw lines, not from a successful parse.
        //
        // The datasheet prints one character here — "a leading 'A' if the
        // protocol was found automatically" — so a compliant chip after
        // `ATSP0` answers `A6` and a clone that omits the prefix, or an
        // adapter on a forced protocol, answers a bare `6`. One hex digit is
        // hex-shaped but not a byte pair, so the general parser correctly
        // called it `DATA ERROR` and the protocol number was never stored.
        //
        // Which then refused everything downstream: `_busRefusal` has no
        // protocol to reason about, so every fault-code and VIN read on that
        // adapter answered 尚未確定車輛使用的匯流排協定, and reconnecting
        // produced the same reply again. Fail-closed is right and this is a
        // working adapter it was closing on.
        final printed = response.rawLines
            .map((l) => l.trim())
            .firstWhere(_protocolNumberLine.hasMatch, orElse: () => '');
        if (printed.isNotEmpty) {
          protocolNumber = printed;
        } else if (response.isSuccess) {
          protocolNumber = response.firstLine;
        }
      default:
        break;
    }
  }

  String? _detailFor(String command) => switch (command) {
    'ATZ' || 'ATI' => deviceVersion,
    'AT@1' => deviceIdentity,
    'ATRV' =>
      batteryVoltage != null ? '${batteryVoltage!.toStringAsFixed(1)} V' : null,
    'ATDP' => protocolDescription,
    'ATDPN' => protocolNumber,
    _ => null,
  };

  void _emitProgress(
    InitStep step,
    int index,
    InitStatus status, [
    String? detail,
  ]) {
    if (_initProgress.isClosed) return;
    _initProgress.add(
      InitProgress(
        step: step,
        index: index,
        total: initSequence.length,
        status: status,
        detail: detail,
      ),
    );
  }

  // ------------------------------------------------------------ watchdog ----

  /// Spec §2.4: if no byte arrives for [watchdogTimeout] the link is wedged.
  /// Rather than trying to nurse the socket back, the client reports the loss
  /// and lets the app decide — an automatic reconnect that fights a genuinely
  /// unplugged adapter just burns battery.
  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!isInitialized) return;
      // Nothing was running to receive bytes, so their absence proves nothing.
      // See [_suspended]: this tick is very likely one that came due *during*
      // the freeze and is only now being delivered.
      if (_suspended) return;
      // A protocol search is legitimate silence. The adapter says `SEARCHING...`
      // once and then says nothing for as long as it takes to try each bus
      // protocol; tripping the 5 s stall timer through that would tear down a
      // connection that was about to succeed.
      if (_searchExtended && _pending != null) return;
      // Silence only means something when the adapter owes us a reply. An idle
      // link — every active PID unsupported, or the app just resumed from the
      // background with a stale wall-clock timestamp — is not a dead one, and
      // tearing it down on that basis disconnects a perfectly healthy adapter.
      //
      // But requiring `_pending` to be non-null *right now* made this a race
      // the watchdog almost always loses. Both timers are five seconds, and
      // `_onCommandTimeout` clears `_pending`; the next command follows after
      // `interCommandDelay`, which is 10ms. So the window in which this tick
      // could observe an outstanding command was about 10ms wide, sampled once
      // a second — roughly a 1% chance per stall. The command timer fired
      // first the other 99% of the time, and its recovery path is exactly the
      // one that leaves a zombie session.
      //
      // What matters is whether the adapter owes us a reply *since it last
      // said anything*, which outlives the completer.
      final sentAt = _lastCommandSentAt;
      final owesReply =
          _pending != null || (sentAt != null && sentAt.isAfter(lastRxAt));
      if (!owesReply) return;
      // Against the deadline the *outstanding command* was given, not a fixed
      // one.
      //
      // There are three clocks here and they were not ordered: the adapter
      // opens a five-second window when it sees `7F xx 78`, a global read now
      // waits seven so it is not the first to give up, and this fired at five
      // — tearing the link down in the middle of an exchange the app itself
      // had decided to wait for. A controller doing a flash erase is slow on
      // purpose, and "connection stopped responding" is the wrong thing to
      // tell someone whose clear was about to succeed.
      //
      // The watchdog's job is a *wedged* link, so it has to outlast whatever
      // the app is legitimately still waiting on.
      final owed = _pendingDeadline;
      var limit = owed != null && owed > watchdogTimeout
          ? owed + const Duration(seconds: 1)
          : watchdogTimeout;
      // A resync the *caller* abandoned early is still a resync.
      //
      // Cutting the drain short when a caller runs out of budget was right —
      // that caller cannot wait — but the link was still inside the three
      // seconds this client allows a late prompt, and the watchdog was not
      // told. It killed the session a second later, and the valid prompt
      // arrived one and a half seconds after that, to a connection that no
      // longer existed. Whoever asked is refused; the link keeps the whole
      // window it was promised.
      final grace = _resyncGraceUntil;
      if (grace != null) {
        if (DateTime.now().isBefore(grace)) return;
        _resyncGraceUntil = null;
      }
      if (DateTime.now().difference(lastRxAt) <= limit) return;
      isInitialized = false;
      _watchdog?.cancel();
      _watchdog = null;
      _failPending(const TransportException('連線停止回應。'));
      onConnectionLost?.call();
    });
  }

  // ------------------------------------------------------------- parsing ----

  static final RegExp _seqPrefix = RegExp(r'^[0-9A-Fa-f]{1,2}:\s*');

  /// `ATRV` answers `12.6V`. The `V` must follow the digits immediately and the
  /// value must be a plausible battery voltage — a looser pattern reads the
  /// version banner `ELM327 v2.1` as 327 volts, because `327` is followed by a
  /// space and then a `V`.
  static final RegExp _voltage = RegExp(r'\b(\d{1,2}(?:\.\d+)?)V(?![0-9A-Z])');

  /// The band a real vehicle's supply sits in.
  ///
  /// A 12 V system runs from roughly 9 V while cranking to 15 V on charge; a
  /// 24 V commercial vehicle reaches about 30 V. The ELM327 datasheet also
  /// describes `ATRV` as the adapter's own input voltage with roughly 2%
  /// accuracy, so this is a plausibility gate, not a diagnostic instrument.
  static bool _isPlausibleVoltage(double v) => v >= 6.0 && v <= 32.0;

  /// A line captured with `ATH1`: the responding address, then payload bytes.
  ///
  /// Three hex digits for 11-bit CAN, eight for 29-bit. Note this deliberately
  /// does not match a plain byte-pair line — the whole point is telling the two
  /// renderings apart, because with headers off the address is absent and with
  /// them on it must not be read as data.
  static final RegExp _headeredCanLine = RegExp(
    r'^([0-9A-Fa-f]{3}|[0-9A-Fa-f]{8})((?: ?[0-9A-Fa-f]{2})+)$',
  );

  /// The two CAN widths, separately, for callers that know which bus they are
  /// on. [_headeredCanLine] accepts either and must not be used where the
  /// width is known, because the wrong alternative will happily consume
  /// payload as an address.
  static final RegExp _headeredCan11Line = RegExp(
    r'^([0-9A-Fa-f]{3})((?: ?[0-9A-Fa-f]{2})+)$',
  );
  static final RegExp _headeredCan29Line = RegExp(
    r'^([0-9A-Fa-f]{8})((?: ?[0-9A-Fa-f]{2})+)$',
  );

  /// Whether [check] is the right check byte for [message] on this bus.
  ///
  /// J1850 uses CRC-8 with polynomial `0x1D`; ISO 9141-2 and ISO 14230-4 use a
  /// running total, which the datasheet describes as "a sum calculation (ie a
  /// 'running total' of byte values) that is sent at the end of a message".
  ///
  /// Unknown protocols cannot be checked and are not refused for it: this is
  /// only ever reached on a bus already resolved to six-digit headers.
  bool _legacyChecksumHolds(List<int> message, int check) {
    switch (addressing.family) {
      case ObdBusFamily.j1850Pwm:
      case ObdBusFamily.j1850Vpw:
        var crc = 0xFF;
        for (final byte in message) {
          crc ^= byte;
          for (var bit = 0; bit < 8; bit++) {
            crc = (crc & 0x80) != 0
                ? ((crc << 1) ^ 0x1D) & 0xFF
                : (crc << 1) & 0xFF;
          }
        }
        return ((~crc) & 0xFF) == check;
      case ObdBusFamily.iso9141:
      case ObdBusFamily.kwp2000:
        return message.fold<int>(0, (a, b) => (a + b) & 0xFF) == check;
      default:
        return true;
    }
  }

  /// Which controller a three-byte legacy header came from.
  ///
  /// The third byte, and only the third byte. The datasheet says so twice: the
  /// three bytes give "the priority, the receiver, and the transmitter", and
  /// "the sender of information is usually shown in the third byte of the
  /// header".
  ///
  /// Using all six digits made one ECU look like several. For ISO 14230-4 the
  /// first byte "must always include the length of the data field, which
  /// varies from message to message" — so the same controller answering a
  /// six-byte census and a seven-byte fault-code request appeared as `86F110`
  /// and `87F110`, and the second reply was then refused for the silence of a
  /// controller that had just spoken.
  static String _legacyResponder(String header) =>
      header.length >= 2 ? header.substring(header.length - 2) : header;

  /// A headered line on a legacy bus: a three-byte address, then the message.
  ///
  /// The CAN pattern accepts only three- and eight-digit identifiers, so a
  /// six-digit J1850 / ISO 9141 / KWP header matched nothing and the reply fell
  /// through to the unattributed parser. Attribution was therefore impossible
  /// on every non-CAN bus even with `ATH1` — which, once global operations
  /// began *requiring* attribution, would have refused every legacy fault-code
  /// scan outright.
  static final RegExp _headeredLegacyLine = RegExp(
    r'^([0-9A-Fa-f]{6})((?: ?[0-9A-Fa-f]{2})+)$',
  );

  /// Every controller address visible in [lines], whatever else is wrong.
  ///
  /// Deliberately looser than the parsers: a *bare* header whose payload was
  /// lost still names a controller, and so does a frame printed just before an
  /// adapter error marker. Identity is a separate fact from readability, and
  /// this is the only place that reads it without judging anything else.
  /// Only what is definite. A [ObservedEvidence.candidate] is an open question
  /// and this set is read as an answer — `attributedSources` feeds "somebody
  /// replied", and a fragment of headerless payload has not replied.
  Set<String> _sourcesIn(List<String> lines) => Set.unmodifiable(
    _observedFramesIn(lines)
        .where((f) => f.evidence != ObservedEvidence.candidate)
        .map((f) => f.sourceId!)
        .where((id) => id.isNotEmpty),
  );

  /// What could be *identified* in [lines], with payloads kept.
  ///
  /// A bare header yields a frame with no bytes, which is the distinction the
  /// caller needs: an identity with nothing attached is damage worth
  /// remembering, and a complete frame about another service is not a claim
  /// about this one. Collapsing both to a bare source — which is what happened
  /// whenever the adapter appended an error marker, because the parsers return
  /// before building frames — made a stale Mode 01 reply a permanent
  /// fault-code obligation again.
  ///
  /// Never used to decode a value. An errored exchange is not data; it is
  /// evidence about who was on the bus.
  List<ObdFrame> _observedFramesIn(List<String> lines) {
    // Which pattern applies is decided by the bus, exactly as it is for the
    // parsers themselves — not by trying both and taking whichever matches.
    //
    // The two overlap in a way that produces confident nonsense: with `ATS0` a
    // six-digit legacy address and its first byte print as eight unspaced
    // characters, which is also the shape of a 29-bit identifier. Guessing
    // CAN-first invented a controller called `486B1043` and refused a working
    // legacy scan for its silence; guessing legacy-first would read a real
    // 29-bit reply as a controller called `18DAF1`.
    // Nothing is identity unless headers are actually on.
    //
    // The ordinary parsers gate on this and the error path did not, so an
    // adapter that answered `ATH1` with `?` still had its headerless bytes
    // mined for addresses. Preserving visible identity through damage was
    // right; inventing it out of payload is the over-strict sibling of the
    // same fix, and it makes later categories owe an answer to a controller
    // that never existed.
    if (!_headersOn) return const [];

    final width = addressing.headerHexDigits;
    // Exact width per family. The shared CAN pattern accepts three *or* eight
    // digits, so on an 11-bit bus a headerless `430207150300` was split as an
    // eight-digit "source" `43020715` followed by payload — a phantom
    // controller, named in a completeness refusal.
    //
    // Unless the adapter was configured to accept both, in which case both are
    // real. Same rule as `_canLineForBus`, and it has to be the same rule.
    final isLegacy = width == 6;
    if (!isLegacy && addressing.acceptedReceiveWidths.isEmpty) return const [];

    // An ambiguous token is carried as ambiguous, not resolved by a neighbour.
    //
    // A lone hex token of legal width is ambiguous by construction: `008` is
    // a multi-frame envelope's total length, `430` is the start of a
    // headerless `43 00`, and `486B18` is a real controller whose payload was
    // lost. Four rounds were spent picking one reading and finding the case it
    // breaks — dropping the token loses a real module, keeping it invents one,
    // and the rule that replaced both (*some other line in this reply had a
    // header, so this token is an address*) promotes `430` on the strength of
    // an unrelated `7E8` sitting beside it.
    //
    // What corroborates an identifier is that *identifier* having spoken, not
    // its neighbours. So there are three outcomes here and not two, and the
    // third — [ObservedEvidence.candidate] — is the honest one: an open
    // question, which the coverage rules answer by refusing to call the read
    // complete rather than by naming a module that may not exist.
    //
    // A `length + N:` envelope's first line is a byte count and not an
    // address — and it is not special-cased here, deliberately.
    //
    // The adapter numbers lines that way only with `ATH0`, and this routine
    // has already returned above when headers are off. Written as a guard
    // anyway ("first line is bare hex and a later one is numbered"), it fired
    // on `7E9` followed by damaged `0:`/`1:` lines and threw away a real
    // controller's address — the shape it was meant to protect cannot occur
    // where it was placed, and the shape it actually matched was a module.
    //
    // If a lying adapter does print an envelope while claiming `ATH1`, the
    // length line becomes an open question rather than a named controller,
    // which is the direction that refuses rather than invents.
    final frames = <ObdFrame>[];
    for (var index = 0; index < lines.length; index++) {
      final stripped = lines[index].trim();
      if (stripped.isEmpty) continue;

      final legacy = isLegacy ? _headeredLegacyLine.firstMatch(stripped) : null;
      final headered = isLegacy
          ? (legacy == null
                ? null
                : (id: legacy.group(1)!, payload: legacy.group(2)!))
          : _canLine(stripped);
      if (headered != null) {
        final id = headered.id.toUpperCase();
        final body = _hexToBytes(headered.payload.replaceAll(' ', ''));
        // Legacy prints one complete message per line, so its service byte is
        // first. CAN wraps it in ISO-TP, where the offset depends on the frame
        // type — which is why this is computed here and not by a second rule
        // somewhere else.
        //
        // A continuation frame carries no service byte at all, and a Single
        // Frame declaring zero payload carries nothing but padding. Both are
        // definite sources about which nothing was said, and calling that
        // "answered Mode 03" manufactured a fault-code debt out of filler.
        final service = isLegacy ? _serviceOfPayload(body) : _serviceOf(body);
        // Legacy prints one complete message per line — and the line ends in a
        // checksum, which is not payload.
        //
        // Handing the whole body over was wrong in both directions and the
        // damage was concrete: on ISO 9141 a controller that finished a clear
        // prints `48 6B 10 44 07`, and reading `[0x44, 0x07]` as the message
        // made J1979's one-byte completion look malformed. A damaged clear
        // that one ECU *had* completed was reported as 清除失敗，沒有控制器接
        // 受指令 — with nothing warning against a repeat, because as far as the
        // engine knew nothing had happened. The repeat resets that
        // controller's readiness monitors a second time.
        //
        // Verified, not just trimmed, because this is a content claim and the
        // ordinary parser checks it before believing one.
        final payload = isLegacy
            ? _legacyPayload(_hexToBytes(headered.id), body)
            : _singleFramePayload(body);
        // On a legacy bus, a failed checksum takes the identity with it.
        //
        // This is where legacy and CAN genuinely differ, and the difference is
        // not a matter of strictness. A CAN header is structurally separate
        // from its payload — the adapter prints an identifier and then a
        // frame — so damage to the data cannot invent a controller. A legacy
        // line is one run of hex whose first three bytes are *called* the
        // header, and the checksum is the only thing that says the split is
        // real. `4300BE43000000` reads perfectly well as header `43 00 BE`
        // plus a body, and it is nothing of the sort.
        //
        // So a line that does not check out is not a headered frame at all.
        // It falls through to the ambiguous branch below and is carried as an
        // open question — which refuses, loudly, for this exchange, instead of
        // adding a controller that never existed to a coverage set that only
        // ever grows and then refusing every scan for the rest of the
        // connection.
        if (isLegacy && payload == null) {
          // Dropped, not carried as an open question.
          //
          // A doubt has to *outlive* the exchange that raised it — a bare
          // `7E9` seen during a damaged clear makes the next clear refuse, so
          // a retry answered by `7E8` alone cannot be reported as the whole
          // vehicle cleared. That is right, and it is what makes this line
          // different: an unresolved identity is a permanent claim that
          // something might be on this bus, and a legacy line whose checksum
          // failed gives no evidence that any part of it is an address at all.
          // One noise burst would otherwise veto every clear for the rest of
          // the connection.
          //
          // Nothing is lost by dropping it. The ordinary parser refuses the
          // whole reply for the same failed checksum, so the exchange is
          // already damaged: the clear reports `sentUnconfirmed`, locks the
          // repeat, and asks for a rescan. Loud, safe, and recoverable —
          // which a permanent veto is not.
          continue;
        } else {
          final operand = isLegacy ? _legacyOperand(body) : _canOperand(body);
          frames.add(
            ObdFrame(
              body,
              sourceId: isLegacy ? _legacyResponder(id) : id,
              service: service,
              payload: payload,
              operand: operand,
              evidence: service == null
                  ? ObservedEvidence.present
                  : ObservedEvidence.answered,
            ),
          );
          continue;
        }
      }

      // Everything else that is made of hex: a bare header whose payload was
      // lost, a line truncated mid-byte, or payload that lost its header.
      //
      // These are one case, not three, because `ATS0` is in the initialisation
      // sequence and removes the only thing that told them apart. `7E9037F031`
      // and a headerless `037F031` are both just hex digits; the first three
      // of the second are `037`, a perfectly legal 11-bit identifier.
      //
      // So the shape never establishes a source. Only [knownResponders] does —
      // and where it does, the identifier is one this connection has already
      // heard speak, which is what makes it definite rather than plausible.
      if (!_hexOrSpaceLine.hasMatch(stripped)) continue;
      final compact = stripped.replaceAll(' ', '').toUpperCase();
      final id = _speculativeSourceIn(compact, isLegacy: isLegacy);
      if (id == null) continue;
      frames.add(
        ObdFrame(
          const [],
          sourceId: id,
          evidence: knownResponders.contains(id)
              ? ObservedEvidence.present
              : ObservedEvidence.candidate,
        ),
      );
    }
    return List.unmodifiable(frames);
  }

  /// Identifiers this connection has already heard speak properly.
  ///
  /// Assigned by the poller before each exchange. It is the only thing that
  /// turns an ambiguous token into a definite source, so it must contain
  /// identifiers established by *evidence* — a census reply, an attributed
  /// frame — and never ones this routine itself guessed at.
  Set<String> knownResponders = const {};

  /// Which identifier [compact] would name, if it named one.
  ///
  /// Prefers a width that [knownResponders] recognises: on a bus accepting
  /// both CAN widths the same digits can be read two ways, and the reading
  /// that matches a controller already heard from is the one worth promoting.
  /// Failing that it falls back to this bus's own header width, which is only
  /// ever used to phrase an open question.
  String? _speculativeSourceIn(String compact, {required bool isLegacy}) {
    final widths = isLegacy ? const {6} : addressing.acceptedReceiveWidths;
    String? exact;
    String? known;
    String? preferred;
    String? any;
    for (final width in widths) {
      if (compact.length < width) continue;
      final head = compact.substring(0, width);
      if (!isLegacy && !BusAddressing.isLegalCanId(head)) continue;
      final id = isLegacy ? _legacyResponder(head) : head;
      // A line that is *exactly* one accepted width is a bare header and
      // nothing else, and that outranks everything — including a shorter
      // prefix this connection happens to recognise.
      //
      // Recognition used to win, and it took the wrong module. On a slot
      // accepting both widths, `18DAF118` is a legal 29-bit identifier whose
      // first three digits are `18D` — a controller already heard from. The
      // whole token was discarded, `18D` was marked present, and a clear that
      // `18DAF118` never acknowledged then reported success.
      if (compact.length == width) exact ??= id;
      if (knownResponders.contains(id)) known ??= id;
      if (width == addressing.headerHexDigits) preferred ??= id;
      any ??= id;
    }
    return exact ?? known ?? preferred ?? any;
  }

  /// A line of hex digits, with or without the spaces `ATS0` removes.
  static final RegExp _hexOrSpaceLine = RegExp(r'^[0-9A-Fa-f][0-9A-Fa-f ]*$');

  /// A payload line: hex byte pairs, optionally space-separated, nothing else.
  static final RegExp _hexLine = RegExp(r'^[0-9A-Fa-f]{2}( ?[0-9A-Fa-f]{2})*$');

  /// A line made only of hex digits and spaces.
  ///
  /// Used to tell corrupted *data* from adapter *status*. `SEARCHING...` and
  /// `BUS INIT: OK` are prose and may be skipped; `7E9 03 7F 03 1` and
  /// `43 01 3` are a controller's answer that arrived damaged, and skipping
  /// those let one well-formed responder outvote another's corruption and
  /// close a vehicle-wide category as clean.
  static final RegExp _hexishLine = RegExp(r'^[0-9A-Fa-f ]+$');

  /// The total-length header the ELM327 prints above a multi-frame reply
  /// (`014` before `0: 49 02 ...`). Three or four hex digits on their own line.
  static final RegExp _lengthHeader = RegExp(r'^[0-9A-Fa-f]{3,4}$');

  /// The command currently awaiting a reply, used to recognise its echo.
  String? _pendingCommand;

  /// Whether `ATH1` is in effect, so replies carry the responding address.
  ///
  /// Tracked rather than inferred. `sendGlobal` turns headers on for the
  /// exchange and off again afterwards, and the parser has to agree with it —
  /// guessing from the line shape is ambiguous once `ATS0` removes the spaces.
  bool _headersOn = false;

  ObdResponse _parse(List<int> frame) {
    // Stripped here as well as on arrival: an ELM327 can insert a NULL anywhere
    // in the stream, and one landing mid-line would otherwise fail the hex
    // whitelist and discard a perfectly good reply.
    final text = ascii.decode(
      frame.where((b) => b != 0x00).toList(),
      allowInvalid: true,
    );
    final lines = text
        .split(String.fromCharCode(_crByte))
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();

    if (lines.isEmpty) return const ObdResponse();

    // Some clones acknowledge `ATE0` and then go on echoing numeric commands
    // anyway. `ATZ`'s echo is harmless because `ATZ` is not hex, but the echo
    // of `010C` *is* valid hex, so it passes the payload whitelist and prepends
    // two bytes to the reading. Drop it only on an exact match with the command
    // that is actually outstanding — a blanket "looks like a command" rule
    // would eat real data.
    final pendingEcho = _pendingCommand?.toUpperCase().replaceAll(' ', '');
    if (pendingEcho != null &&
        lines.length > 1 &&
        lines.first.toUpperCase().replaceAll(' ', '') == pendingEcho) {
      lines.removeAt(0);
    }

    final upper = lines.join(' ').toUpperCase();

    final error = _classifyError(upper, lines);
    if (error != Elm327ErrorCode.none) {
      // The adapter's own error markers do not erase what it printed first.
      //
      // Datasheet, on `<DATA ERROR`: the reply still shows what was received;
      // on an RX error, the whole received message is printed before
      // `<RX ERROR`. So a TCM frame followed by `<RX ERROR` is an unreadable
      // exchange in which a controller demonstrably answered — and returning
      // here without its address threw that away, letting a later clear be
      // measured against a set that had never heard of it.
      final observed = _observedFramesIn(lines);
      return ObdResponse(
        rawLines: lines,
        errorCode: error,
        attributedSources: Set.unmodifiable(
          observed.map((f) => f.sourceId!).where((id) => id.isNotEmpty),
        ),
        observedFrames: observed,
      );
    }

    double? volts;
    final voltMatch = _voltage.firstMatch(upper);
    if (voltMatch != null) {
      final parsed = double.tryParse(voltMatch.group(1)!);
      // Syntactic validity is not a measurement. A corrupt or clone reply of
      // `99.9V` matches the pattern perfectly and then renders as a healthy
      // green reading, because the dashboard treats anything at or above 11.8
      // as good. A number outside any real vehicle's range is corruption, and
      // showing nothing is honest where showing 99.9 V is not.
      if (parsed != null && _isPlausibleVoltage(parsed)) volts = parsed;
    }

    // Payload extraction is a WHITELIST, not a blacklist.
    //
    // Stripping non-hex characters from every line and concatenating whatever
    // survives is how status text becomes data: `DATA ERROR` reduces to `DAAE`
    // and is then read as two perfectly plausible bytes. Only lines that are
    // entirely hex byte pairs are payload; everything else is status, however
    // it is spelled and whatever future firmware adds.
    //
    // Dropped by the same rule: the `014` total-length header above a
    // multi-frame reply, which otherwise contributes three nibbles and shifts
    // the whole payload by half a byte — enough to turn a VIN into noise and a
    // DTC list into codes the car does not have.
    // A reply is multi-frame when any line carries an ISO-TP sequence index.
    // Only then can the first line be a total-length header, so the header is
    // only ever dropped in the shape where one actually occurs — a bare
    // four-hex-digit line in a single-frame reply stays data.
    // Headers on: every line is prefixed by the responding ECU's address, and
    // ISO-TP sequencing lives in the raw PCI byte rather than an `N:` prefix.
    //
    // Gated on the client's own `ATH1` state rather than on the shape of the
    // line, because with `ATS0` — which this app's own handshake enables —
    // spaces are stripped and the two renderings become ambiguous. A plain
    // `4100BE3FA813` splits perfectly well into a 29-bit ID `4100BE3F` and a
    // two-byte payload, and reading it that way turned an ordinary support
    // mask into a rejected frame. The adapter's header state is not a guess:
    // this client is the one that sets it.
    // …and only for a *data* reply. An AT command's acknowledgement carries no
    // header whatever `ATH` is set to, so routing `OK` through the headered
    // parser found no addressed lines and rejected the whole thing — which is
    // how `sendGlobal` came to report that the adapter had refused the very
    // header switch it had just acknowledged.
    final awaitingAt = _pendingCommand?.toUpperCase().startsWith('AT') ?? false;
    if (_headersOn && !awaitingAt) {
      // Legacy buses have no ISO-TP: the adapter prints one complete message
      // per line, each with its own address, so they are grouped rather than
      // reassembled.
      if (addressing.headerHexDigits == 6) {
        final legacy = _parseHeaderedLegacy(lines, volts);
        if (legacy != null) return legacy;
      }
      final headered = _parseHeaderedCan(lines, volts);
      // A data reply with headers on always carries them. If none are present
      // the adapter is telling us something else, so fall through rather than
      // reject: refusing a reply we simply failed to recognise is the same
      // mistake in the other direction.
      final looksHeadered = lines.any((l) {
        final trimmed = l.trim();
        return _headeredCanLine.hasMatch(trimmed) || _canLine(trimmed) != null;
      });
      if (headered.isSuccess || looksHeadered) return headered;
    }

    final isMultiFrame = lines.any((l) => _seqPrefix.hasMatch(l));
    if (isMultiFrame) return _parseMultiFrame(lines, volts);

    final hex = StringBuffer();
    final frames = <ObdFrame>[];
    for (final line in lines) {
      final stripped = line.trim();
      if (stripped.isEmpty) continue;
      if (!_hexLine.hasMatch(stripped)) {
        // A line that is nothing but hex digits and spaces, yet does not parse
        // as byte pairs, is a damaged reply rather than adapter prose — an odd
        // nibble, a truncated line. Dropping it silently let a second
        // controller's corruption disappear while the first controller's clean
        // answer closed the category.
        //
        // No exception by shape. A bare three- or four-hex-digit line is
        // indistinguishable from a truncated message — `43 00` followed by
        // `430` is a damaged second reply, not formatting — and a legitimate
        // total-length line only ever appears inside an `N:` envelope, which
        // is parsed before this loop is reached.
        if (_hexishLine.hasMatch(stripped)) {
          return ObdResponse(
            rawLines: lines,
            errorCode: Elm327ErrorCode.dataError,
            batteryVoltage: volts,
          );
        }
        continue;
      }
      final clean = stripped.replaceAll(' ', '');
      hex.write(clean);
      final body = _hexToBytes(clean);
      // Set here for uniformity, not because anything reads it yet.
      //
      // agy round 32 demonstrated that deleting `service:` from this site and
      // the headerless-CAN one below leaves the suite green, and that is
      // honest: every consumer of `service` on a *reassembled* frame also
      // requires a `sourceId`, which a headerless reply does not have. The
      // field is populated anyway because a frame that answers a question
      // should say which question, and a future reader finding null here would
      // have no way to tell "no service" from "headers were off".
      frames.add(ObdFrame(body, service: _serviceOfPayload(body)));
    }

    final hexPayload = hex.toString();
    return ObdResponse(
      rawLines: lines,
      hexPayload: hexPayload,
      bytes: _hexToBytes(hexPayload),
      frames: frames,
      batteryVoltage: volts,
    );
  }

  /// Reassembles an ISO-TP reply, rejecting anything that is not intact.
  ///
  /// The old code stripped the length header and the `0:`/`1:` prefixes and
  /// flattened whatever was left. Nothing checked that the segments were
  /// contiguous, unique, or that as many bytes arrived as the header promised.
  /// A BLE notification carrying line `1:` can simply be lost while `0:`, `2:`
  /// and the prompt all arrive — and the result was a shorter payload accepted
  /// as complete. On a VIN that fabricates an identity; on a DTC list it
  /// fabricates fault codes. Transport loss has to become a rejected frame,
  /// not data.
  ObdResponse _parseMultiFrame(List<String> lines, double? volts) {
    ObdResponse reject() => ObdResponse(
      rawLines: lines,
      errorCode: Elm327ErrorCode.dataError,
      batteryVoltage: volts,
    );

    int? declared;
    final segments = <List<int>>[];
    var expectedSeq = 0;

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final match = _seqPrefix.firstMatch(line);

      if (match == null) {
        // The one non-sequenced line an ISO-TP reply carries is the total
        // length, printed above the first segment.
        if (i == 0 && _lengthHeader.hasMatch(line.trim())) {
          declared = int.tryParse(line.trim(), radix: 16);
          if (declared == null) return reject();
          continue;
        }
        // Anything else that is hex-shaped is damage, and dropping it here
        // was the last place this defect had left to hide. Once one `N:`
        // segment exists this parser owns the whole reply, so a truncated peer
        // line vanished behind a declaration the real segments happened to
        // satisfy:
        //
        //   004
        //   0: 41 0C 1A F8
        //   430
        //
        // The segment matches the four bytes promised, `430` is skipped, and
        // 1726 rpm is published beside evidence that something arrived
        // damaged. Prose is still skipped — `SEARCHING...` inside an envelope
        // is the adapter talking about itself.
        final stripped = line.trim();
        if (stripped.isNotEmpty && _hexishLine.hasMatch(stripped)) {
          return reject();
        }
        continue;
      }

      final seq = int.tryParse(
        match.group(0)!.replaceAll(':', '').trim(),
        radix: 16,
      );
      // Sequence numbers run 0..F and wrap. Validating against the printed
      // order rather than a sorted set catches a gap, a duplicate and a
      // reordering with the same check, and survives the wrap.
      if (seq == null || seq != expectedSeq) return reject();
      expectedSeq = (expectedSeq + 1) & 0xF;

      final body = line.replaceFirst(_seqPrefix, '').trim();
      if (!_hexLine.hasMatch(body)) return reject();
      segments.add(_hexToBytes(body.replaceAll(' ', '')));
    }

    if (segments.isEmpty || declared == null) return reject();

    final assembled = [for (final s in segments) ...s];
    // Short of what the header promised: frames went missing.
    if (assembled.length < declared) return reject();

    // Longer is normal — the final CAN frame is zero-padded to eight bytes —
    // but only the declared length is payload.
    final payload = assembled.sublist(0, declared);
    final hexPayload = payload
        .map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0'))
        .join();

    return ObdResponse(
      rawLines: lines,
      hexPayload: hexPayload,
      bytes: payload,
      frames: [ObdFrame(payload, service: _serviceOfPayload(payload))],
      batteryVoltage: volts,
    );
  }

  /// Parses a reply captured with `ATH1`, grouping by responding controller.
  ///
  /// Datasheet p.44 shows two ECUs answering one request with their frames
  /// **interleaved**:
  ///
  ///     7E8 10 13 49 04 01 35 36 30
  ///     7E8 21 32 38 39 34 39 41 43
  ///     7E9 10 13 49 04 01 35 36 30
  ///     7E8 22 00 00 00 00 00 00 31
  ///     7E9 21 32 38 39 35 34 41 43
  ///     7E9 22 00 00 00 00 00 00 00
  ///
  /// Flattening that yields one payload assembled out of two vehicles' worth of
  /// data. Each address is reassembled on its own.
  /// One frame per line, attributed, with no reassembly.
  ///
  /// Returns null when no line carries a legacy header, so the caller can fall
  /// through to the other parsers rather than rejecting a reply that simply
  /// was not in this shape.
  ObdResponse? _parseHeaderedLegacy(List<String> lines, double? volts) {
    final frames = <ObdFrame>[];
    // Hex-shaped lines this parser could not make a frame of.
    //
    // Skipping them silently is the same defect the unattributed parser was
    // fixed for, and it became reachable here the moment `ATH1` was enabled on
    // legacy buses. The trigger is two lines:
    //
    //   486B10 43 00 00 00 00 00 00
    //   486B18
    //
    // The first controller says it has nothing wrong. The second is a bare
    // header whose payload was lost — visible transport damage, all hex, and
    // dropped. The clean answer then closed the whole category and the damaged
    // controller disappeared before completeness was ever evaluated.
    //
    // Prose is still skipped: `SEARCHING...` and `BUS INIT: OK` are the
    // adapter talking about itself, and refusing a reply for containing them
    // would be the opposite error.
    var damaged = false;
    for (final line in lines) {
      final stripped = line.trim();
      if (stripped.isEmpty) continue;
      final match = _headeredLegacyLine.firstMatch(stripped);
      if (match == null) {
        if (_hexishLine.hasMatch(stripped)) damaged = true;
        continue;
      }
      final body = _hexToBytes(match.group(2)!.replaceAll(' ', ''));
      // The last byte is the checksum, not data.
      //
      // With `ATH1` the adapter prints the complete legacy message: three
      // header bytes, the data, and the trailing checksum. Keeping it fed the
      // checksum to the decoder, which strips the service byte and pairs what
      // is left — so a padded reply came out odd and was refused.
      //
      // An earlier version of this comment said that made "every real
      // fault-code reply unparseable", which was too kind to it. A
      // transport-valid short line `48 6B 10 43 00 26` pairs *evenly* and
      // decodes `00 26` as P0026 — a fault the car never set, drawn in the
      // same red as a real one. The fixtures omitted the byte too, so the
      // suite modelled the same wrong wire and neither shape could be seen.
      //
      // Two bytes minimum: something to carry and something to check it.
      if (body.length < 2) {
        damaged = true;
        continue;
      }
      // And it has to *be* the checksum.
      //
      // Dropping the last byte unchecked let a fabricated split authenticate
      // itself: an adapter that answers `OK` to `ATH1` and then prints
      // headerless bytes gives `4300BE43000000`, which this pattern reads as
      // header `43 00 BE` plus a body whose final `00` is discarded as though
      // it had proved the split. The real payload holds P00BE and C0300, and
      // the screen said the car was clean.
      //
      // Computed over exactly what the adapter would have: the header bytes
      // and the data.
      //
      // This catches corruption and a great deal of mis-splitting, and it is
      // not proof that headers were present — an eight-bit check collides with
      // an invented split's own sum about once in 256. An earlier version of
      // this comment claimed it authenticated the header boundary, which is
      // more than eight bits can carry. What rules that case out is the
      // census requiring a real `41 00` response before it will believe in a
      // controller.
      final header = _hexToBytes(match.group(1)!);
      final payload = body.sublist(0, body.length - 1);
      if (!_legacyChecksumHolds([...header, ...payload], body.last)) {
        damaged = true;
        continue;
      }
      frames.add(
        ObdFrame(
          payload,
          sourceId: _legacyResponder(match.group(1)!.toUpperCase()),
          service: _serviceOfPayload(payload),
        ),
      );
    }
    // No legacy frame at all means this was not a legacy reply; fall through
    // rather than judging it. Damage only counts once attribution is
    // established, because until then there is nothing to say the line was
    // meant to be one of these.
    if (frames.isEmpty) return null;
    // Identity survives the rejection. One valid TCM frame beside one damaged
    // ECM line is not a readable exchange — and the TCM did answer. Discarding
    // that along with the payload let a later clear be measured against a set
    // that had forgotten a controller this very scan heard from: a successful
    // clear message, then a green rescan, for a car still holding P0715.
    // From the lines, not from the frames that survived parsing. A bare
    // `486B18` is exactly the damage this parser was taught to notice, and
    // noticing it while forgetting who sent it is the same loss in a smaller
    // place.
    final legacySources = _sourcesIn(lines);
    if (damaged) {
      return ObdResponse(
        rawLines: lines,
        errorCode: Elm327ErrorCode.dataError,
        attributedSources: legacySources,
        observedFrames: _observedFramesIn(lines),
        batteryVoltage: volts,
      );
    }

    final primary = frames.first.bytes;
    return ObdResponse(
      rawLines: lines,
      hexPayload: primary
          .map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0'))
          .join(),
      bytes: primary,
      frames: frames,
      attributedSources: legacySources,
      batteryVoltage: volts,
    );
  }

  /// A `7F xx 78` carried in its own ISO-TP single frame.
  ///
  /// Exactly that shape and nothing looser: a three-byte single frame whose
  /// payload is a negative response with code `78`. A refusal with any other
  /// code is terminal and must not be discarded.
  static bool _isPendingSingleFrame(List<int> body) =>
      body.length >= 4 && body[0] == 0x03 && body[1] == 0x7F && body[3] == 0x78;

  /// The service a *payload* is about, once the framing is off it.
  static int? _serviceOfPayload(List<int> payload) {
    if (payload.isEmpty) return null;
    final first = payload[0];
    if (first == 0x7F) return payload.length >= 2 ? payload[1] : null;
    if (first >= 0x41 && first <= 0x7E) return first - 0x40;
    return null;
  }

  /// The service a frame is about, read through its ISO-TP header.
  ///
  /// The first version of this read `body[1]` unconditionally, which is the
  /// service byte only on a *single* frame. On a First Frame that byte is the
  /// low half of the message length, so a multi-frame answer looked like no
  /// answer at all and the pending frame it superseded was kept — handing the
  /// reassembler two logical messages as one and turning a reply carrying four
  /// real fault codes into `DATA ERROR`.
  ///
  /// It also capped positive responses at `0x4F`, which excludes Mode 22's
  /// `0x62`. A response service is the request service plus `0x40` across the
  /// whole range, so a custom PID's answer was invisible here too.
  ///
  /// Null for a Consecutive Frame: it carries no header of its own and belongs
  /// to whichever First Frame precedes it.
  /// The parameter a **positive** CAN Single Frame response names, or null.
  ///
  /// Same offsets [_serviceOf] uses, one byte further along, and bounded by
  /// the declared length rather than by what arrived — a frame declaring fewer
  /// than two bytes has not named a PID, and reading the next byte anyway is
  /// how padding became data.
  ///
  /// Two exclusions, both of which were missing and both of which invented
  /// controllers out of replies that made no such claim:
  ///
  ///  * A **negative** response is `7F <service> <nrc>`. Its second byte is
  ///    the service being refused, not a parameter — so `7E9 03 7F 01 11`,
  ///    a controller saying it does not support Mode 01, was harvested as a
  ///    controller that had *answered* PID 01, and every later fault-code
  ///    category then failed for its silence.
  ///  * A **First Frame** declares a message longer than seven bytes. A Mode
  ///    01 PID 01 reply is six (`41 01 A B C D`), so a First Frame cannot be
  ///    one. The rule this accessor replaced excluded them and this one did
  ///    not, which is the kind of invariant that disappears in a repair.
  static int? _canOperand(List<int> body) {
    if (body.isEmpty || body[0] >> 4 != 0x0) return null;
    final declared = body[0] & 0x0F;
    if (declared < 2) return null;
    if (body.length < 3) return null;
    if (!_isPositiveResponse(body[1])) return null;
    return body[2];
  }

  /// The parameter a **positive** legacy response names, or null.
  ///
  /// Three bytes minimum: the service, the byte in question, and the checksum
  /// that must follow it. Two would mean the byte being read *is* the
  /// checksum. Negative responses are excluded for the same reason as on CAN.
  static int? _legacyOperand(List<int> body) =>
      body.length >= 3 && _isPositiveResponse(body[0]) ? body[1] : null;

  /// Every positive response is its request plus `0x40`.
  static bool _isPositiveResponse(int first) => first >= 0x41 && first <= 0x7E;

  /// The application bytes of a legacy message, or null if the line does not
  /// carry one that checks out.
  ///
  /// The same rule the ordinary parser applies, and it has to be the same
  /// rule: the adapter prints three header bytes, the data and a trailing
  /// checksum, so the last byte is never payload — and a sum that does not
  /// hold means the split itself is in doubt.
  List<int>? _legacyPayload(List<int> header, List<int> body) {
    // Something to carry and something to check it.
    if (body.length < 2) return null;
    final payload = body.sublist(0, body.length - 1);
    if (!_legacyChecksumHolds([...header, ...payload], body.last)) return null;
    return List.unmodifiable(payload);
  }

  /// The application bytes of a CAN Single Frame, or null if [body] is not
  /// one that carries a complete message.
  ///
  /// Bounded by the declared length on both sides: padding after it is not
  /// payload, and a frame that declares more than it delivers has not
  /// delivered a message at all. Both matter here — the first is how `00`
  /// padding was once read as data, and the second is how a truncated reply
  /// would otherwise pass for a short one.
  static List<int>? _singleFramePayload(List<int> body) {
    if (body.isEmpty || body[0] >> 4 != 0x0) return null;
    final declared = body[0] & 0x0F;
    if (declared == 0 || body.length < 1 + declared) return null;
    return List.unmodifiable(body.sublist(1, 1 + declared));
  }

  static int? _serviceOf(List<int> body) {
    if (body.isEmpty) return null;
    final int payloadStart;
    final int declared;
    switch (body[0] >> 4) {
      case 0x0:
        payloadStart = 1;
        declared = body[0] & 0x0F;
      case 0x1:
        payloadStart = 2;
        declared = ((body[0] & 0x0F) << 8) | (body.length > 1 ? body[1] : 0);
      default:
        return null;
    }
    // Bounded by what the PCI declares, not by what the eight-byte frame
    // happens to contain. `7E9 00 43 …` declares *zero* payload bytes, and
    // reading the padding after it reported that the controller had spoken
    // Mode 03 — inventing a fault-code debt out of filler.
    if (declared == 0) return null;
    if (body.length <= payloadStart) return null;
    final first = body[payloadStart];
    // `7F <service> 78` — the negative response names its own service, and
    // that byte has to be inside the declared payload too.
    if (first == 0x7F) {
      if (declared < 2) return null;
      return body.length > payloadStart + 1 ? body[payloadStart + 1] : null;
    }
    // Every positive response is its request plus 0x40.
    if (first >= 0x41 && first <= 0x7E) return first - 0x40;
    return null;
  }

  /// The header pattern for the CAN bus actually in use.
  ///
  /// `_headeredCanLine` accepts three *or* eight digits, and using it where the
  /// width is known lets an impossible line create a frame: an `18DAF110`
  /// reply on a connection resolved as 11-bit produced a responder that cannot
  /// exist, which then either matched a matching empty result into a false
  /// all-clear or sat in the monotonic set refusing every later category for
  /// its own silence. `_sourcesIn` already chose by width; its sibling did
  /// not.
  /// Matches [line] as a headered CAN reply on the bus in use, or null.
  ///
  /// One rule, asked in one place, for the frame parser and both source
  /// extractors. It used to be three rules: a shared three-or-eight regex
  /// here, an exact width there, and the transmit width for bare headers — and
  /// every disagreement between them either invented a controller or forgot
  /// one.
  ///
  /// Width alone is not enough either. `43020715` has eight digits and is
  /// above the 29-bit maximum, so on a slot that accepts both widths a
  /// headerless Mode 03 payload parsed as a source with a body that
  /// reassembled cleanly — an attributed empty answer for a car that had just
  /// reported two codes.
  /// A headered CAN line in either rendering the adapter may produce.
  ///
  /// The same characters can parse more than one way. On a slot that accepts
  /// both identifier widths, `18DAF110 8 04 43 01 03 01 00 00 00` with `ATS0`
  /// is a legal 29-bit line with its data length displayed — and its first
  /// three digits are also a legal 11-bit identifier, so the shorter strict
  /// grammar consumed `AF 11 …` as a payload and the real frame was never
  /// seen. The mirror image is just as real: an 11-bit `18D` reply, unspaced,
  /// offers a legal 29-bit reading of its own.
  ///
  /// So every reading is enumerated and one is chosen only when the choice is
  /// forced. Being ISO-TP shaped is what usually forces it — a reading whose
  /// first byte is no frame type at all is not a reading. Where that still
  /// leaves two, **nothing here picks between them**.
  ///
  /// The tie used to go to the bus's own transmit width, and that is not
  /// evidence about which identifier *received* a reply. PP 2C's `b5` says the
  /// adapter accepts both widths precisely because the transmit width does not
  /// determine the receive width, so using it as a tie-break asserted the one
  /// thing the configuration denies. `0104` answered by
  /// `18D03410 4 03 41 04 5A` reads two ways — as `18D03410` saying the engine
  /// load is 35.3%, and as `18D` saying it is 1.2% — and both are Single
  /// Frames. The transmit width chose the second: a plausible wrong number
  /// under a plausible wrong controller, which is this app's one prohibited
  /// outcome, produced from entirely legal traffic.
  ///
  /// Refusing costs a reply on a rare configuration. Choosing costs the
  /// driver a number that is wrong and looks right.
  ({String id, String payload})? _canLine(String line) {
    final widths = addressing.acceptedReceiveWidths;
    // Deterministic order. It no longer decides anything, but a set's
    // iteration order must not decide which damaged reading is reported
    // either.
    final ordered =
        [
          if (widths.isEmpty) ...const [3, 8] else ...widths,
        ]..sort((a, b) {
          final own = addressing.headerHexDigits;
          if (a == own) return -1;
          if (b == own) return 1;
          return b - a;
        });

    final shaped = <({String id, String payload})>[];
    ({String id, String payload})? firstSeen;
    for (final width in ordered) {
      for (final parsed in [
        _matchStrictCanLine(line, width),
        _matchDlcCanLine(line, width),
      ]) {
        if (parsed == null) continue;
        final body = _hexToBytes(parsed.payload.replaceAll(' ', ''));
        // A classic CAN frame carries at most eight data bytes, whichever
        // grammar produced it. Anything longer is not a frame this bus can
        // have carried, and handing it to the decoders is how corruption
        // becomes a fault code with a controller's name on it.
        if (body.length > 8) continue;
        firstSeen ??= parsed;
        if (_isIsoTpShaped(body)) shaped.add(parsed);
      }
    }
    // One reading is the answer. Two is a question, and the honest reply to a
    // question is not one of the answers.
    //
    // This can only happen where the adapter was configured to accept both
    // widths: at a single width the two grammars are mutually exclusive, since
    // a length digit plus whole bytes is always an odd number of hex
    // characters and the strict grammar only ever accepts an even one.
    if (shaped.length == 1) return shaped.first;
    if (shaped.length > 1) return null;
    return firstSeen;
  }

  /// Whether [body] could be a frame this reply can actually contain.
  ///
  /// Not full validation — reassembly does that, and does it properly. This
  /// separates a reading that might be a frame from one that plainly is not,
  /// which is enough to choose between two readings of the same characters.
  ///
  /// [multiLine] is what stops the check being too generous. A First Frame
  /// announces continuations, and a reply of one line has none — so on a
  /// single-line reply the First Frame reading is not a candidate at all. That
  /// distinction is the difference between two questions that look identical:
  ///
  ///   `18D03410 4 03 41 04 5A`   two complete Single Frames, genuinely
  ///                              ambiguous, and refused
  ///   `18D034104100A4104`        one complete Single Frame and one First
  ///                              Frame with nothing to continue — not
  ///                              ambiguous, and refusing it lost a legal
  ///                              engine-load reading on an ordinary
  ///                              single-width vehicle
  static bool _isIsoTpShaped(List<int> body) {
    if (body.isEmpty) return false;
    switch (body[0] >> 4) {
      case 0x0:
        final declared = body[0] & 0x0F;
        return declared >= 1 && declared <= 7 && body.length > declared;
      case 0x1:
        // A First Frame declaring seven bytes or fewer contradicts itself —
        // that is what a Single Frame is for — and one standing alone in a
        // one-line reply has nothing to continue.
        if (body.length < 2) return false;
        final total = ((body[0] & 0x0F) << 8) | body[1];
        return total > 7;
      case 0x2:
        return body.length >= 2;
      case 0x3:
        return true;
      default:
        return false;
    }
  }

  ({String id, String payload})? _matchStrictCanLine(String line, int width) {
    final match = (width == 3 ? _headeredCan11Line : _headeredCan29Line)
        .firstMatch(line);
    if (match == null) return null;
    if (!BusAddressing.isLegalCanId(match.group(1)!)) return null;
    return (id: match.group(1)!, payload: match.group(2)!);
  }

  /// The same line, rendered with the CAN data length between header and data.
  ///
  /// `AT D1` — and PP 29, which decides the power-on default — put one digit
  /// there: "the single DLC digit will appear between the ID (header) bytes
  /// and the data bytes" (ELM327DSJ, *D0 and D1*). The app never sends `ATD0`,
  /// so an adapter whose PP 29 has been programmed to `00` renders every reply
  /// this way and the strict matcher rejected all of them — a working vehicle
  /// refused for a display option.
  ///
  /// Sending `ATD0` would be the direct fix. It is not taken, and the reason
  /// is a judgement rather than a documented fact: the datasheet gives `AT D`
  /// as *set all to defaults* alongside `AT D0`/`AT D1`, and this project
  /// exists largely to survive clones whose parsers are not the datasheet's.
  /// A clone that read `ATD0` as `ATD` would wipe `ATE0`, `ATH1` and the
  /// protocol selection mid-initialisation. No source establishes that any
  /// clone does; the cost of reading the rendering instead is small enough
  /// that the hypothesis does not need proving.
  ///
  /// The digit states how many data bytes follow, and that is checked — along
  /// with the eight-byte ceiling a classic CAN frame has, without which `9`
  /// agreed with nine bytes and published a fault code out of corruption.
  /// Those two checks are the whole guarantee. They do not make the reading
  /// unambiguous on their own: the same characters can satisfy this grammar at
  /// one width and the strict grammar at another, which is why [_canLine]
  /// enumerates the readings and prefers the one that is an ISO-TP frame
  /// rather than taking whichever matched first.
  ({String id, String payload})? _matchDlcCanLine(String line, int width) {
    final match = (width == 3 ? _dlcCan11Line : _dlcCan29Line).firstMatch(line);
    if (match == null) return null;
    if (!BusAddressing.isLegalCanId(match.group(1)!)) return null;
    final payload = match.group(3)!.replaceAll(' ', '');
    final declared = int.parse(match.group(2)!, radix: 16);
    // A classic CAN frame carries at most eight data bytes, so a digit above
    // eight is not a length — it is the first nibble of something else, and
    // accepting it would hand the fault-code decoder a payload assembled from
    // corruption. `7E8 9 04 41 0C 1A F8 00 00 00 00` agreed with itself: nine
    // bytes, and the digit said nine. It published 1726 rpm from a frame that
    // cannot exist, and its Mode 03 sibling produced a P0715.
    if (declared > 8) return null;
    if (declared != payload.length ~/ 2) return null;
    return (id: match.group(1)!, payload: payload);
  }

  static final RegExp _dlcCan11Line = RegExp(
    r'^([0-9A-Fa-f]{3}) ?([0-9A-Fa-f])((?: ?[0-9A-Fa-f]{2})+)$',
  );
  static final RegExp _dlcCan29Line = RegExp(
    r'^([0-9A-Fa-f]{8}) ?([0-9A-Fa-f])((?: ?[0-9A-Fa-f]{2})+)$',
  );

  ObdResponse _parseHeaderedCan(List<String> lines, double? volts) {
    // Read from every line up front, so that rejecting on the *first* damaged
    // one cannot make what is remembered depend on the order the controllers
    // happened to answer in.
    final canSources = _sourcesIn(lines);
    ObdResponse reject() => ObdResponse(
      rawLines: lines,
      errorCode: Elm327ErrorCode.dataError,
      attributedSources: canSources,
      observedFrames: _observedFramesIn(lines),
      batteryVoltage: volts,
    );

    final groups = <String, List<List<int>>>{};
    final order = <String>[];

    for (final line in lines) {
      final stripped = line.trim();
      final match = _canLine(stripped);
      if (match == null) {
        // Same rule as the unheadered parser: hex-shaped but unparseable is a
        // peer's damaged reply, and it must not vanish before anyone can count
        // it as incomplete.
        //
        // No exception for "looks like a length header". That shape test was
        // added to tolerate a stray `014`, and it is indistinguishable from a
        // second controller's line whose payload was lost: with `ATH1` on,
        // `7E8 02 43 00` followed by a bare `7E9` is a damaged two-controller
        // exchange, and skipping the `7E9` turned it into a verified clean
        // category. A total-length line is only legal inside a validated `N:`
        // envelope, which `_parseMultiFrame` handles before this parser is
        // reached — so anything of that shape arriving here is not one.
        if (stripped.isNotEmpty && _hexishLine.hasMatch(stripped)) {
          return reject();
        }
        continue;
      }
      final id = match.id.toUpperCase();
      final body = _hexToBytes(match.payload.replaceAll(' ', ''));
      if (body.isEmpty) return reject();
      if (!groups.containsKey(id)) order.add(id);
      (groups[id] ??= []).add(body);
    }

    if (groups.isEmpty) return reject();

    // A controller that said "wait, I'm busy" and then answered sent two
    // complete messages, not one split into pieces.
    //
    // `7F xx 78` is a single frame and so is the reply that follows it, so the
    // group holds two — and ISO-TP reassembly of two single frames from one
    // identifier is not a thing, so the whole exchange was rejected as
    // `DATA ERROR`. The stored fault the controller had just taken five
    // seconds to look up was thrown away with it.
    //
    // Found by a test written for Codex's L-01, which pointed out that the
    // test claiming to cover response pending never emitted one. It did not,
    // and this is what it was hiding.
    //
    // Only frames that are *superseded* are dropped: a pending reply with
    // nothing after it is still the whole answer, and reporting it as such is
    // what tells the user to rescan rather than that the car is fine.
    for (final id in order) {
      final bodies = groups[id]!;
      if (bodies.length < 2) continue;
      // Order decides this, and the first version of this filter ignored it.
      //
      // "There is a terminal reply somewhere in the group" is not the same as
      // "this pending reply was superseded". An earlier answer and a later
      // in-progress one can overlap in the adapter's buffer:
      //
      //     7E8 02 43 00
      //     7E8 03 7F 03 78
      //     >
      //
      // Dropping the second leaves a clean `43 00` and a green panel, for a
      // controller whose last word was that it is still working. Only a
      // pending frame with a terminal one *after* it has been answered; one
      // that arrives last stays, the group then holds two messages, and the
      // exchange is refused as contradictory — which is the honest outcome.
      // Order *and* service. Order alone let a later answer to one service
      // delete an earlier pending message about a different one:
      //
      //     7E8 03 7F 07 78     ← service 07 is still working
      //     7E8 02 43 00        ← service 03 is finished
      //     >
      //
      // The first was never superseded, and erasing it turned a contradictory
      // exchange into a clean stored-codes result. A pending frame is only
      // answered by a later terminal message about the same service.
      final kept = <List<int>>[];
      for (var i = 0; i < bodies.length; i++) {
        final body = bodies[i];
        if (!_isPendingSingleFrame(body)) {
          kept.add(body);
          continue;
        }
        final service = _serviceOf(body);
        // Answered by a later terminal message about the same service…
        final answered = bodies
            .skip(i + 1)
            .any(
              (later) =>
                  !_isPendingSingleFrame(later) && _serviceOf(later) == service,
            );
        // …or superseded by a later `7F xx 78` about it, which the standard
        // says restarts the five-second window. A controller saying "still
        // working" twice is one controller still working; keeping both frames
        // handed the reassembler two single frames for one source and turned
        // continuing work into `DATA ERROR`.
        final restated = bodies
            .skip(i + 1)
            .any(
              (later) =>
                  _isPendingSingleFrame(later) && _serviceOf(later) == service,
            );
        if (!answered && !restated) kept.add(body);
      }
      if (kept.isNotEmpty && kept.length != bodies.length) groups[id] = kept;
    }

    final frames = <ObdFrame>[];
    for (final id in order) {
      final assembled = _reassembleIsoTp(groups[id]!);
      if (assembled == null) return reject();
      frames.add(
        ObdFrame(
          assembled,
          sourceId: id,
          service: _serviceOfPayload(assembled),
        ),
      );
    }

    // `bytes` is the first responder's message. Anything that must cope with
    // more than one ECU has to read [ObdResponse.frames]; collapsing them here
    // would recreate the very mixing this method exists to prevent.
    final primary = frames.first.bytes;
    return ObdResponse(
      rawLines: lines,
      hexPayload: primary
          .map((b) => b.toRadixString(16).toUpperCase().padLeft(2, '0'))
          .join(),
      bytes: primary,
      frames: frames,
      attributedSources: canSources,
      batteryVoltage: volts,
    );
  }

  /// Reassembles one controller's ISO-TP frames, or null if they are not intact.
  ///
  /// PCI high nibbles, datasheet p.44-45: `0` Single Frame with the length in
  /// the low nibble, `1` First Frame whose low nibble plus the next byte give a
  /// 12-bit total, `2` Consecutive Frame whose low nibble is the sequence
  /// number.
  static List<int>? _reassembleIsoTp(List<List<int>> raw) {
    if (raw.isEmpty) return null;
    final first = raw.first;
    if (first.isEmpty) return null;

    switch (first[0] >> 4) {
      case 0x0:
        final length = first[0] & 0x0F;
        // python-OBD rejects both a zero length and one over seven; a single
        // frame by definition is the whole message, so extra frames mean the
        // stream is not what it claims.
        if (length == 0 || length > 7) return null;
        if (raw.length != 1) return null;
        if (first.length < 1 + length) return null;
        return first.sublist(1, 1 + length);

      case 0x1:
        if (first.length < 2) return null;
        final total = ((first[0] & 0x0F) << 8) | first[1];
        // A First Frame exists because the payload does not fit in a Single
        // Frame. One declaring seven bytes or fewer is a contradiction, and it
        // was being honoured: `7E8 10 02 43 00 …` returned `43 00`, which the
        // fault-code decoder reads as a controller reporting zero stored
        // codes. With two ordinary optional-category replies beside it the
        // scan then rendered the whole vehicle clean — from a frame no ECU can
        // legally send.
        //
        // Zero was already refused. Everything up to the Single Frame capacity
        // has to go with it, for the same reason and with more consequence.
        if (total <= 7) return null;
        final out = <int>[...first.sublist(2)];
        var expected = 1;
        for (final frame in raw.skip(1)) {
          if (frame.isEmpty) return null;
          if ((frame[0] >> 4) != 0x2) return null;
          // Sequence numbers wrap 0..F, so compare on the low nibble.
          if ((frame[0] & 0x0F) != (expected & 0x0F)) return null;
          expected++;
          out.addAll(frame.sublist(1));
        }
        // Longer than declared is normal — the last frame is zero-padded to
        // eight bytes. Shorter means frames went missing.
        if (out.length < total) return null;
        return out.sublist(0, total);

      default:
        return null;
    }
  }

  /// Status and error strings the ELM327 can emit in place of data.
  ///
  /// Taken from the datasheet's "Error and Alert Messages" section rather than
  /// from the reverse-engineering spec, which lists only about half of them.
  static const Map<String, Elm327ErrorCode> _errorStrings = {
    'NO DATA': Elm327ErrorCode.noData,
    'CAN ERROR': Elm327ErrorCode.canError,
    'UNABLE TO CONNECT': Elm327ErrorCode.unableToConnect,
    'BUFFER FULL': Elm327ErrorCode.bufferFull,
    'STOPPED': Elm327ErrorCode.stopped,
    'BUS BUSY': Elm327ErrorCode.busBusy,
    'BUS ERROR': Elm327ErrorCode.busError,
    'DATA ERROR': Elm327ErrorCode.dataError,
    'FB ERROR': Elm327ErrorCode.feedbackError,
    'LV RESET': Elm327ErrorCode.lowVoltageReset,
    'RX ERROR': Elm327ErrorCode.dataError,
    'ACT ALERT': Elm327ErrorCode.activityAlert,
    'LP ALERT': Elm327ErrorCode.lowPowerAlert,
  };

  Elm327ErrorCode _classifyError(String upper, List<String> lines) {
    if (upper.contains('BUS INIT') && upper.contains('ERROR')) {
      return Elm327ErrorCode.busInitError;
    }
    for (final entry in _errorStrings.entries) {
      if (upper.contains(entry.key)) return entry.value;
    }
    // `ERR` followed by two hex digits is the ELM327's internal fault report.
    if (RegExp(r'\bERR\d{2}\b').hasMatch(upper)) {
      return Elm327ErrorCode.internalError;
    }
    // A bare `?` is the adapter rejecting the command. Only treat it as an
    // error when it is the entire reply, since `?` can legitimately appear
    // inside a version banner.
    if (lines.length == 1 && lines.first.trim() == '?') {
      return Elm327ErrorCode.unknownCommand;
    }
    return Elm327ErrorCode.none;
  }

  static List<int> _hexToBytes(String hex) {
    if (hex.length < 2) return const [];
    final usable = hex.length.isEven ? hex : hex.substring(0, hex.length - 1);
    final bytes = <int>[];
    for (var i = 0; i + 1 < usable.length; i += 2) {
      final b = int.tryParse(usable.substring(i, i + 2), radix: 16);
      if (b == null) return bytes;
      bytes.add(b);
    }
    return bytes;
  }

  /// Exposed for tests, which need to exercise the parser without a transport.
  ObdResponse parseFrameForTest(List<int> frame) => _parse(frame);
}
