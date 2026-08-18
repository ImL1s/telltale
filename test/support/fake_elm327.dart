/// A deliberately hostile ELM327 for tests.
///
/// This exists because the app has now been bitten four times by the same
/// thing: `DemoTransport` is more forgiving than real hardware, so a green
/// suite certifies code that has never been executed against anything
/// resembling a car. Round 4 found the fourth instance — legacy multi-message
/// Mode 03 responses fabricate fault codes, and no test could ever have caught
/// it because the demo only speaks 11-bit CAN.
///
/// The rules here are the inverse of the shipped simulator's:
///
///   * an unknown AT command answers `?`, never `OK`;
///   * a request addressed to a header no ECU owns answers `NO DATA`;
///   * framing follows the *selected* bus protocol, so legacy buses produce
///     one line per message and CAN produces ISO-TP;
///   * every deviation from the happy path is something a caller opts into
///     explicitly through [AdapterFaults], so a test that does not ask for
///     chunking or loss gets a clean adapter and a test that does gets a
///     reproducible one.
///
/// The shipped `DemoTransport` stays friendly and strict-but-cooperative: it is
/// a product feature, and a user picking "Demo" wants a car that works. All
/// hostility lives here, in test-only code.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:torque_obd/obd/transport/obd_transport.dart';

/// The bus protocols an ELM327 can select, with the framing that differs
/// between them.
///
/// [number] is the digit `ATDPN` reports (the `A` prefix meaning "found by
/// automatic search" is added by the adapter, not stored here).
enum BusProtocol {
  j1850pwm('1', 'SAE J1850 PWM (41.6 kbaud)'),
  j1850vpw('2', 'SAE J1850 VPW (10.4 kbaud)'),
  iso9141('3', 'ISO 9141-2 (5 baud init, 10.4 kbaud)'),
  kwp2000Slow('4', 'ISO 14230-4 KWP (5 baud init, 10.4 kbaud)'),
  kwp2000Fast('5', 'ISO 14230-4 KWP (fast init, 10.4 kbaud)'),
  can11('6', 'ISO 15765-4 (CAN 11/500)'),
  can29('7', 'ISO 15765-4 (CAN 29/500)'),
  can11Slow('8', 'ISO 15765-4 (CAN 11/250)'),
  can29Slow('9', 'ISO 15765-4 (CAN 29/250)');

  const BusProtocol(this.number, this.description);

  final String number;
  final String description;

  bool get isCan => const {can11, can29, can11Slow, can29Slow}.contains(this);

  bool get is29Bit => const {can29, can29Slow}.contains(this);

  /// How many hex digits `ATSH` takes on this bus.
  ///
  /// 11-bit CAN uses a three-digit ID; 29-bit CAN uses four bytes; the legacy
  /// buses use a three-byte (six-digit) priority/target/source header. Sending
  /// the wrong width is [C-01]: the app currently sends `ATSH 7E0` on every
  /// protocol, which is meaningless on anything but 11-bit CAN.
  int get headerDigits => switch (this) {
        can11 || can11Slow => 3,
        can29 || can29Slow => 8,
        _ => 6,
      };

  /// The functional ("ask every emissions ECU") request address, which is also
  /// what the adapter has installed before anyone sends `ATSH`.
  ///
  /// The legacy values are the datasheet's own defaults, from the Periodic
  /// (Wakeup) Messages section: `68 6A F1` for ISO 9141 and `C1 33 F1` for
  /// KWP. J1850 has no documented default and its two protocols use different
  /// priority bytes, so production declines to name one; `686AF1` here is a
  /// fixture stand-in that only ever affects this file's own routing.
  String get functionalHeader => switch (this) {
        can11 || can11Slow => '7DF',
        can29 || can29Slow => '18DB33F1',
        kwp2000Slow || kwp2000Fast => 'C133F1',
        _ => '686AF1',
      };

  /// A physical controller address a *user* might type into a custom PID.
  ///
  /// Not something the app generates any more. It used to synthesise `6810F1`
  /// for every legacy family at once, citing a datasheet example that does not
  /// exist; `6C10F1` here is the VPW physical convention and the value the
  /// repository's own spec uses in its worked example, and it is a fixture
  /// input rather than an expectation about production.
  String get engineHeader => switch (this) {
        can11 || can11Slow => '7E0',
        can29 || can29Slow => '18DA10F1',
        _ => '6C10F1',
      };
}

/// One controller on the bus.
///
/// Modelling more than one is the whole point: [C-02] is that global OBD
/// requests inherit whatever header ran last, so a TCM fault is invisible and a
/// clear can report success while ECM codes remain. A single-ECU fake cannot
/// express that bug.
class FakeEcu {
  FakeEcu({
    required this.name,
    required this.requestId,
    required this.responseId,
    this.responses = const {},
    this.literalResponses = const {},
    this.missesFunctionalFor = const {},
  });

  final String name;

  /// The physical request address, as `ATSH` would take it (`7E0`).
  final String requestId;

  /// The address this ECU answers from (`7E8`), used when headers are on.
  final String responseId;

  /// Normalised request (uppercase, no spaces, e.g. `0100`) to the full
  /// response payload *including* the positive service byte.
  ///
  /// A request absent from this map is one this ECU does not implement, and
  /// the adapter will answer `NO DATA` on its behalf rather than inventing
  /// something — which is precisely the discipline the app itself is missing.
  final Map<String, List<int>> responses;

  /// Commands this ECU does not answer when they arrive as a broadcast.
  ///
  /// A real module misses a functional request for reasons that say nothing
  /// about whether it would answer at all: another controller's long reply
  /// filled the adapter's buffer, a flow-control frame was lost, the module
  /// was still waking. It answers the same question perfectly when addressed
  /// by name.
  ///
  /// Modelled because the app now asks the silent ones directly before giving
  /// up, and a repair whose failure the simulator cannot produce is a repair
  /// nothing can test.
  final Set<String> missesFunctionalFor;

  /// Lines printed verbatim for a command, bypassing this file's framing.
  ///
  /// For fixtures taken straight from the datasheet or a capture. Generating
  /// those bytes from my own framing code would test that code against itself;
  /// pasting the published lines tests the parser against what an adapter
  /// actually prints. Mode 09 on a legacy bus is the case that needs it — its
  /// envelope is `49 02 <seq>` with an incrementing sequence number, a
  /// different shape from Mode 03's single repeated service byte.
  final Map<String, List<String>> literalResponses;
}

/// Everything that can go wrong on a real link, off by default.
///
/// Each knob corresponds to a finding. A test asks for exactly the hostility it
/// is about, so a failure names its own cause.
class AdapterFaults {
  const AdapterFaults({
    this.maxChunkBytes,
    this.dropSequenceIndex,
    this.reorderSequenceLines = false,
    this.echoNumericCommands = false,
    this.injectNulls = false,
    this.swallowPromptFor = const {},
    this.forcedReplies = const {},
    this.voltageText,
    this.unknownAtReply = '?',
    this.refusePpSummary = false,
    this.lieAboutHeaders = false,
    this.refuseHeaders = false,
    this.refuseHeadersOff = false,
  });

  /// Split every emission into chunks of at most this many bytes, the way BLE
  /// notifications do. A `>` prompt landing alone in its own chunk, or split
  /// across two, is the shape that breaks naive framing.
  final int? maxChunkBytes;

  /// Drop this ISO-TP continuation line (0-based) from the next multi-frame
  /// reply — [C-09]: transport loss must become a rejected frame, not
  /// fabricated data.
  final int? dropSequenceIndex;

  /// Emit ISO-TP continuation lines out of order.
  final bool reorderSequenceLines;

  /// Keep echoing numeric OBD commands after `ATE0` — [H-03]. Some clones
  /// acknowledge `ATE0` and go on echoing anyway, and because the echo of
  /// `010C` is *itself valid hex*, the app concatenates it into the payload.
  final bool echoNumericCommands;

  /// Sprinkle NUL bytes into the stream, as noisy links do.
  final bool injectNulls;

  /// Answer these commands with data but never a `>` prompt, wedging the link.
  final Set<String> swallowPromptFor;

  /// Force a literal reply for a command, e.g. `{'0105': 'NO DATA'}` or
  /// `{'22F190': '7F 22 78'}`.
  final Map<String, String> forcedReplies;

  /// What `ATRV` answers, verbatim. `'99.9V'` is [C-16].
  final String? voltageText;

  /// What an unrecognised AT command answers. A real ELM327 says `?`; the
  /// shipped demo says `OK`, which is why a mistyped critical AT command has
  /// never failed a test.
  final String unknownAtReply;

  /// Answers `OK` to `ATH1` and then never prints a header.
  ///
  /// The clone that *refuses* headers answers `?` and is easy to catch. This is
  /// the one that agrees and does nothing, which leaves the client believing
  /// attribution is on while every reply arrives anonymous — and the app's own
  /// demo simulator behaved exactly this way until it was taught otherwise.
  final bool lieAboutHeaders;

  /// Answers `?` to `ATH0` — an adapter that will not stop printing headers.
  ///
  /// The prompt still arrives, so nothing is out of step. The app used to
  /// treat this as a lost stream and disconnect three seconds later.
  final bool refuseHeadersOff;

  /// Answers `?` to `ATH1` — the adapter that will not print headers at all.
  ///
  /// The third of three behaviours, and the only honest one of the two
  /// failures: it says up front that it cannot attribute replies. Legacy
  /// adapters are likeliest to do this. A scan against one is not worthless —
  /// any codes it returns are real — but it cannot support "the vehicle is
  /// clean", so the app has to be able to tell this apart from
  /// [lieAboutHeaders] rather than treating every unattributed reply alike.
  final bool refuseHeaders;

  /// Answers `AT PPS` with [unknownAtReply], as an adapter that predates the
  /// command — or a clone that never implemented it — does.
  final bool refusePpSummary;
}

/// An ELM327 that behaves like the datasheet rather than like the app's hopes.
class FakeElm327 extends BaseObdTransport {
  FakeElm327({
    required this.protocol,
    required List<FakeEcu> ecus,
    this.faults = const AdapterFaults(),
    this.identity = 'ELM327 v2.1',
    this.forceProtocolNumber,
    this.responseLatency = Duration.zero,
    this.requiresProtocolSearch = true,
  }) : _ecus = List.unmodifiable(ecus) {
    _rejectAmbiguousLegacyEcus();
  }

  final BusProtocol protocol;
  final List<FakeEcu> _ecus;

  /// Two legacy controllers may not share a source address.
  ///
  /// Identity on a legacy bus is the third header byte, so `486BF1` and
  /// `4868F1` are the same controller as far as the app is concerned — and a
  /// fixture with both can let one reply cover for the other's silence, which
  /// is exactly the failure these tests exist to catch. A fixture that cannot
  /// happen must not be able to certify behaviour.
  void _rejectAmbiguousLegacyEcus() {
    if (protocol.isCan) return;
    final sources = <String>{};
    for (final ecu in _ecus) {
      final id = ecu.responseId;
      final source = id.length >= 2 ? id.substring(id.length - 2) : id;
      if (!sources.add(source.toUpperCase())) {
        throw ArgumentError(
          'two legacy ECUs share source address $source; on this bus they are '
          'one controller and the fixture cannot mean what it says',
        );
      }
    }
  }
  final AdapterFaults faults;
  /// Reports a different `ATDPN` digit than the framing this fake produces.
  ///
  /// For the bridge case: an adapter announcing J1939 while something behind
  /// it answers ordinary OBD2 questions. The app must refuse on the announced
  /// protocol rather than on whether the bytes happen to parse.
  final String? forceProtocolNumber;

  /// The version banner. Not decoration.
  ///
  /// Response-pending handling begins at firmware v2.1 per the datasheet, so
  /// this string decides whether the app has to supply the wait itself. A v1.x
  /// adapter — or a clone reporting a version it does not implement — is the
  /// case this lets a test express.
  final String identity;
  /// Mutable so a test can let the handshake run at full speed and then make
  /// the adapter slow.
  ///
  /// Sixteen AT commands at a multi-second latency exceeds the test timeout
  /// before the code under test is even reached — and the interesting delays
  /// are almost always mid-session anyway: an ECU busy with something else,
  /// a link degrading, a clone taking its time.
  Duration responseLatency;

  /// Per-command latency, for when one *controller* is slow rather than the
  /// adapter.
  ///
  /// `responseLatency` slows everything, including the `ATH1`/`ATSH` framing a
  /// global read needs — so it cannot express the case the whole
  /// response-pending machinery is about: a module doing a flash erase takes
  /// seconds to answer Mode 04 while the adapter itself is perfectly quick.
  final Map<String, Duration> slowCommands = {};

  /// Programmable parameters this adapter reports as *enabled* (`N`).
  ///
  /// Keyed by parameter number. Anything not listed prints its factory value
  /// with the `F` state, exactly as a stock adapter does — and a parameter
  /// that is off is not in effect however it is stored, which is the half of
  /// `AT PPS` that is easy to read past.
  final Map<int, int> enabledProgrammableParameters = {};

  /// Programmable parameters this adapter reports as **off** (`F`) while
  /// holding a value that is *not* the factory default.
  ///
  /// The case that distinguishes reading the state letter from ignoring it,
  /// and the one a stock adapter actually prints: the emulator used for the
  /// hardware walkthrough reports `2A:38 F` — bit 2 cleared in storage, the
  /// parameter disabled, so the factory `3C` with bit 2 *set* is what governs.
  /// Without this knob every `F` entry printed its own default and the two
  /// readings were indistinguishable.
  final Map<int, int> storedButOffProgrammableParameters = {};

  /// How many `7F xx 78` frames precede a command's terminal reply.
  ///
  /// Spread across that command's latency, so they land while the exchange is
  /// still open. A test that means to exercise Response Pending has to send
  /// one: waiting in silence and then answering is a different contract, and
  /// asserting the second while describing the first is how a test comes to
  /// protect nothing it claims to.
  final Map<String, int> pendingBefore = {};

  /// The factory summary, from the worked example on ELM327DSJ p.67.
  static const List<int> _ppFactoryDefaults = [
    0xFF, 0x00, 0xFF, 0x32, 0x01, 0xFF, 0xF1, 0x09, //
    0xFF, 0x00, 0x0A, 0xFF, 0x68, 0x0D, 0x9A, 0xD5, //
    0x0D, 0x00, 0xFF, 0x55, 0x50, 0x0A, 0xFF, 0x6D, //
    0x31, 0x31, 0xFF, 0xFF, 0x03, 0x0F, 0x4A, 0xFF, //
    0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0xFF, //
    0xFF, 0xFF, 0x3C, 0x02, 0xE0, 0x04, 0x80, 0x0A, //
  ];

  String _ppSummary() {
    final lines = <String>[];
    for (var row = 0; row < 12; row++) {
      final entries = <String>[];
      for (var column = 0; column < 4; column++) {
        final pp = row * 4 + column;
        final enabled = enabledProgrammableParameters[pp];
        final storedButOff = storedButOffProgrammableParameters[pp];
        final value = enabled ?? storedButOff ?? _ppFactoryDefaults[pp];
        final state = enabled == null ? 'F' : 'N';
        entries.add('${_hex(pp)}:${_hex(value)} $state');
      }
      lines.add(entries.join('     '));
    }
    return '${lines.join('\r')}\r>';
  }

  /// Whether the first OBD request still has to run the automatic search.
  ///
  /// `ATSP0` only *arms* the search; the adapter does not commit to a protocol
  /// until a request actually goes out, so `ATDP`/`ATDPN` before that must
  /// report the undecided `AUTO`/`A0`.
  final bool requiresProtocolSearch;

  /// Every command the adapter has been asked, in order. Tests assert on this
  /// to prove *what went on the wire*, not merely what came back — which is how
  /// you catch a global request being sent to a physical address.
  final List<String> commandLog = [];

  /// Replies installed *after* connect, so a test can let the handshake
  /// succeed and then make the adapter start refusing.
  ///
  /// A fault that is present from the first byte is the easy case; the one
  /// that matters is the adapter that works, is trusted, and then degrades —
  /// which is what a failing alternator or a hot dongle actually looks like.
  final Map<String, String> _runtimeForced = {};

  void forceReply(String command, String reply) =>
      _runtimeForced[command.toUpperCase()] = reply;

  /// Successive replies for one command, consumed in order.
  ///
  /// For behaviour that unfolds over several exchanges — a controller
  /// answering `7F 03 78` twice and then producing its real answer, which is
  /// what a legacy module erasing fault memory actually does.
  final Map<String, List<String>> _replySequences = {};

  void forceReplySequence(String command, List<String> replies) =>
      _replySequences[command.toUpperCase()] = [...replies];

  /// When true the adapter stops answering entirely, without dropping the
  /// link.
  ///
  /// This is the state a wedged dongle, an ignition switched off with the
  /// socket still open, or a half-dead Wi-Fi link leaves behind — and it is
  /// distinct from a disconnect, which the transport reports on its own. It is
  /// the case where nothing tells the app anything.
  bool goSilent = false;

  /// When true, `write` throws *after* the bytes have reached the adapter.
  ///
  /// `socket.add` hands data to the kernel before `flush` is awaited, so a
  /// reset that surfaces from `flush` says nothing about whether the command
  /// went out. The exception's type is not evidence either way.
  bool failWriteAfterAccepting = false;

  /// The same fault, armed for named commands only.
  ///
  /// A global exchange is four writes — `ATH1`, `ATSH`, the service, `ATH0` —
  /// and which one fails is the whole question when the caller has to decide
  /// whether a state-changing request reached the vehicle. Failing all of them
  /// only ever exercises the first.
  Set<String> failWriteAfterAcceptingFor = const {};

  /// The opposite fault: `write` refuses at its own precondition, before any
  /// byte is accepted.
  ///
  /// Every production transport opens `write` this way — no socket, no
  /// characteristic, no connection — and it is the one failure where "nothing
  /// was transmitted" is a fact and not an inference. Modelled separately from
  /// [failWriteAfterAcceptingFor] because the two are indistinguishable by
  /// exception *type*, which is exactly what the write audit exists to stop
  /// anyone relying on.
  Set<String> refuseWriteBeforeAcceptingFor = const {};

  /// The link dies after these commands are accepted and before any reply.
  ///
  /// The commonest Bluetooth failure at a car — the adapter has the bytes, the
  /// phone loses the link, and no acknowledgement can ever arrive. Distinct
  /// from every other fault here in that the transport reports the loss
  /// itself, which is what drives `onConnectionLost` and the session's
  /// generation counter.
  Set<String> dropLinkAfterWritingFor = const {};

  /// When true, `write`'s Future never completes but the bytes still arrive.
  ///
  /// `socket.add` hands data to the kernel before `flush` is awaited, so this
  /// is what a stalled Wi-Fi write really looks like: the adapter has the
  /// command and replies to it, and only the caller is left waiting.
  bool stallWriteCompletion = false;

  /// When true, `write` never completes.
  ///
  /// A half-dead TCP link: the phone carried out of range of the adapter's
  /// hotspot, no RST, the OS retransmitting for a quarter of an hour. Distinct
  /// from [goSilent], where the write succeeds and the answer never comes.
  bool stallWrites = false;

  bool _echo = true;
  bool _headersOn = false;
  bool _searchPending = true;
  String? _header;
  final List<Timer> _scheduled = [];

  @override
  TransportKind get kind => TransportKind.demo;

  @override
  String get displayName => 'Fake ELM327 (${protocol.description})';

  @override
  Future<void> connect() async {
    _searchPending = requiresProtocolSearch;
    setConnected(true);
  }

  @override
  Future<void> disconnect() async {
    for (final timer in _scheduled) {
      timer.cancel();
    }
    _scheduled.clear();
    setConnected(false);
    await disposeStreams();
  }

  /// The header currently installed.
  ///
  /// Before any `ATSH` that is the adapter's own default, which the datasheet
  /// gives as the *functional* address on every protocol — `7DF` on 11-bit
  /// CAN, `68 6A F1` on ISO 9141, `C1 33 F1` on KWP. This used to default to
  /// the engine's physical address, modelling the same fabrication production
  /// had: an un-addressed request reached one controller instead of all of
  /// them, so a fixture with two ECUs answered the handshake with one.
  String get activeHeader => _header ?? protocol.functionalHeader;

  @override
  Future<void> write(List<int> data) async {
    // The same type a real transport's precondition throws. This said
    // `TransportException` while every production transport was about to start
    // saying `WriteRefusedException`, which would have made the simulator more
    // forgiving than the hardware — the failure mode this file's own header
    // warns about.
    if (!isConnected) {
      throw const WriteRefusedException('fake adapter not connected');
    }
    // Never completes, and never throws — which is the shape that made this
    // worth modelling. An error would have been noticed.
    if (stallWrites) return Completer<void>().future;

    final raw = ascii.decode(data, allowInvalid: true).trim();
    if (refuseWriteBeforeAcceptingFor.contains(raw.toUpperCase())) {
      // Refused at the guard: the adapter is told nothing and answers nothing.
      throw const WriteRefusedException('fake adapter refused the write');
    }
    if (dropLinkAfterWritingFor.contains(raw.toUpperCase())) {
      // Handed over, then the link goes. No reply is possible, and the
      // transport says so on its own — which is the whole difference between
      // this and a write that merely failed.
      setConnected(false);
      return;
    }
    if (failWriteAfterAccepting ||
        failWriteAfterAcceptingFor.contains(raw.toUpperCase())) {
      // The shape a reset TCP link really has: `socket.add` took the bytes,
      // the adapter received them and is answering, and `flush` then throws.
      // Indistinguishable from "never sent" by exception type alone.
      _acceptAndAnswer(raw);
      throw const TransportException('connection reset by peer');
    }
    if (stallWriteCompletion) {
      // The shape a real TCP write actually has, and the one the stall knob
      // above cannot express: `socket.add` takes the bytes immediately and
      // `flush` is what hangs. The adapter therefore receives the command,
      // acts on it, and answers — while the caller's write Future never
      // settles. A deadline on that Future proves nothing about whether the
      // request went out, which is the whole of round 7's H-01.
      _acceptAndAnswer(raw);
      return Completer<void>().future;
    }
    _acceptAndAnswer(raw);
  }

  /// Everything a real adapter does once the bytes have arrived.
  void _acceptAndAnswer(String raw) {
    final command = raw.toUpperCase().replaceAll(' ', '');
    commandLog.add(command);

    final body = _respond(command);

    // Echo. A real adapter repeats the command until `ATE0` lands, so the reply
    // to the step *before* `ATE0` always begins with the command itself.
    final echoNow = _echo || (faults.echoNumericCommands && !command.startsWith('AT'));
    final reply = echoNow && raw.isNotEmpty ? '$raw\r$body' : body;

    if (command == 'ATE0') _echo = false;
    if (command == 'ATE1' || command == 'ATZ' || command == 'ATD') _echo = true;

    final emit = faults.swallowPromptFor.contains(command)
        ? reply.replaceAll('>', '')
        : reply;

    void send() => _emitChunked(emit);
    final latency = slowCommands[command] ?? responseLatency;

    // "Wait, I'm busy", sent while the controller is still working and
    // *before* the terminal reply, with no prompt after it — which is the
    // whole shape. A `7F xx 78` that arrives with its own prompt is a finished
    // exchange; one that arrives mid-exchange is the thing both the adapter's
    // five-second window and this app's extension exist for.
    final pending = pendingBefore[command];
    if (pending != null && pending > 0) {
      final frame =
          '${_ecus.first.responseId} 03 7F ${_hex(int.parse(command.substring(0, 2), radix: 16))} 78';
      for (var i = 0; i < pending; i++) {
        final at = Duration(
            microseconds: latency.inMicroseconds * (i + 1) ~/ (pending + 1));
        final timer = Timer(at, () => _emitChunked('$frame\r'));
        _scheduled.add(timer);
      }
    }

    if (latency == Duration.zero) {
      scheduleMicrotask(send);
    } else {
      final timer = Timer(latency, send);
      _scheduled.add(timer);
      _scheduled.removeWhere((t) => !t.isActive);
    }
  }

  /// Whether the adapter separates hex bytes with spaces (`ATS1`).
  ///
  /// True until the handshake turns it off, which is what a real adapter does.
  bool _spaces = true;

  /// Removes the spaces between hex byte pairs, and only those.
  ///
  /// Prose keeps its spacing: a real ELM327 does not print `BUSINIT:OK`.
  static final RegExp _hexPairGap = RegExp(r'(?<=[0-9A-F]) (?=[0-9A-F])');
  static final RegExp _dataLine = RegExp(r'^[0-9A-F][0-9A-F ]*$');

  String _applySpacing(String text) {
    if (_spaces) return text;
    return text
        .split('\r')
        .map((line) => _dataLine.hasMatch(line.trim())
            ? line.replaceAll(_hexPairGap, '')
            : line)
        .join('\r');
  }

  /// Every line this adapter actually put on the wire, after spacing.
  ///
  /// The command log records what was *asked*; this records what was
  /// *answered*, which is the only way a test can assert the shape of a reply
  /// rather than trusting the fixture that generated it. Round 17 needed it:
  /// a test claimed two KWP replies carried different length bytes while the
  /// fake was padding both to the same width.
  final List<String> emitted = [];

  void _emitChunked(String text) {
    for (final line in _applySpacing(text).split('\r')) {
      final stripped = line.replaceAll('>', '').trim();
      if (stripped.isNotEmpty) emitted.add(stripped);
    }
    List<int> bytes = ascii.encode(_applySpacing(text));
    if (faults.injectNulls) {
      bytes = Uint8ListLike.interleaveNulls(bytes);
    }

    final limit = faults.maxChunkBytes;
    if (limit == null || limit <= 0 || bytes.length <= limit) {
      emitBytes(bytes);
      return;
    }
    for (var i = 0; i < bytes.length; i += limit) {
      emitBytes(bytes.sublist(i, math.min(i + limit, bytes.length)));
    }
  }

  // --------------------------------------------------------------- AT ----

  String _respond(String command) {
    if (command.isEmpty) return '>';

    if (goSilent) return '';

    final sequence = _replySequences[command];
    if (sequence != null && sequence.isNotEmpty) {
      return '${sequence.removeAt(0)}\r>';
    }

    final forced = _runtimeForced[command] ?? faults.forcedReplies[command];
    if (forced != null) return '$forced\r>';

    if (command.startsWith('AT')) return _respondAt(command);

    // The first OBD request after an armed search makes the adapter announce
    // `SEARCHING...` and then go quiet for as long as the hunt takes.
    var prefix = '';
    if (_searchPending) {
      _searchPending = false;
      prefix = 'SEARCHING...\r';
    }
    return prefix + _respondObd(command);
  }

  String _respondAt(String command) {
    if (command == 'ATZ' || command == 'ATD') {
      _searchPending = requiresProtocolSearch;
      _headersOn = false;
      _header = null;
      return '$identity\r\r>';
    }
    if (command == 'ATI') return '$identity\r>';
    if (command == 'AT@1') return 'Fake OBD Adapter\r>';
    if (command == 'ATE0' || command == 'ATE1') return 'OK\r>';
    if (command == 'ATL0' || command == 'ATL1') return 'OK\r>';
    if (command == 'ATS0' || command == 'ATS1') {
      // Honoured, not merely acknowledged.
      //
      // The app's handshake sends `ATS0`, so every real adapter answers
      // *without* spaces — and this fake said OK and kept printing them. That
      // is the "agreed and did nothing" behaviour round 6 caught in
      // `DemoTransport`, sitting in the primary oracle, so the whole suite was
      // certifying the one rendering real hardware never produces.
      //
      // It matters because unspaced output is genuinely more ambiguous: the
      // client's own comment notes that `4100BE3FA813` can be read as a 29-bit
      // identifier plus two bytes. That is the reading the tests should have
      // been exercising all along.
      _spaces = command == 'ATS1';
      return 'OK\r>';
    }
    if (command == 'ATH0') {
      // Some adapters will not turn headers back off. The prompt still comes,
      // so the stream stays in step — which is the whole point of modelling
      // it: a refusal and a lost stream look nothing alike and were treated
      // alike.
      if (faults.refuseHeadersOff) return '${faults.unknownAtReply}\r>';
      _headersOn = false;
      return 'OK\r>';
    }
    if (command == 'ATH1') {
      if (faults.refuseHeaders) return '${faults.unknownAtReply}\r>';
      // The lying clone agrees and does nothing. Saying `OK` is the whole
      // deception — a refusal would be caught by the acknowledgement check.
      if (!faults.lieAboutHeaders) _headersOn = true;
      return 'OK\r>';
    }
    if (command == 'ATSP0') {
      _searchPending = requiresProtocolSearch;
      return 'OK\r>';
    }
    if (command.startsWith('ATSP')) {
      // Selecting a protocol explicitly commits to it immediately.
      _searchPending = false;
      return 'OK\r>';
    }
    if (command.startsWith('ATAT') || command.startsWith('ATST')) return 'OK\r>';
    if (command.startsWith('ATCAF') || command.startsWith('ATCFC')) return 'OK\r>';
    if (command == 'ATRV') return '${faults.voltageText ?? '13.9V'}\r>';

    if (command == 'ATDP') {
      return _searchPending ? 'AUTO\r>' : 'AUTO, ${protocol.description}\r>';
    }
    if (command == 'ATDPN') {
      if (_searchPending) return 'A0\r>';
      return 'A${forceProtocolNumber ?? protocol.number}\r>';
    }

    if (command.startsWith('ATSH')) {
      final value = command.substring(4);
      // A real adapter rejects a header whose width does not suit the bus. This
      // is what makes [C-01] visible: `ATSH 7E0` on ISO 9141 is not a valid
      // three-byte header, and answering `OK` to it — as the shipped demo does
      // for every unknown AT command — is what let the bug survive.
      if (value.length != protocol.headerDigits) return '?\r>';
      if (!RegExp(r'^[0-9A-F]+$').hasMatch(value)) return '?\r>';
      _header = value;
      return 'OK\r>';
    }

    if (command == 'ATPPS') {
      if (faults.refusePpSummary) return '${faults.unknownAtReply}\r>';
      return _ppSummary();
    }

    if (command.startsWith('ATCRA')) return 'OK\r>';

    return '${faults.unknownAtReply}\r>';
  }

  // -------------------------------------------------------------- OBD ----

  String _respondObd(String command) {
    final target = activeHeader;
    final functional = target == protocol.functionalHeader;

    // Verbatim fixtures win: they exist precisely so the framing code in this
    // file cannot influence what the parser sees.
    bool reaches(FakeEcu ecu) =>
        functional
            ? !ecu.missesFunctionalFor.contains(command.toUpperCase())
            : ecu.requestId == target;
    final literal = _ecus
        .where((ecu) =>
            reaches(ecu) && ecu.literalResponses.containsKey(command))
        .expand((ecu) => ecu.literalResponses[command]!)
        .toList();
    if (literal.isNotEmpty) return '${literal.join('\r')}\r>';

    // A multi-PID Mode 01 request is an ISO 15765 feature: the ECU answers one
    // message carrying `41` then each PID and its data. Modelling it matters
    // because the app batches by default on CAN, so without this every test
    // would exercise only the single-PID path the app rarely takes.
    if (protocol.isCan && _isMode01Batch(command)) {
      final assembled = _assembleMode01Batch(command, target, functional);
      if (assembled != null) return assembled;
      return 'NO DATA\r>';
    }

    final answering = _ecus
        .where((ecu) => reaches(ecu) && ecu.responses.containsKey(command))
        .toList();

    // No ECU at that address, or none implementing that request. A real bus
    // simply stays silent and the adapter times out.
    if (answering.isEmpty) return 'NO DATA\r>';

    final messages = <String>[];
    for (final ecu in answering) {
      messages.addAll(_frame(ecu, ecu.responses[command]!));
    }
    return '${messages.join('\r')}\r>';
  }

  /// `010C0D05` and friends: mode 01 followed by two or more PID bytes.
  static bool _isMode01Batch(String command) =>
      command.startsWith('01') && command.length > 4 && command.length.isEven;

  /// Builds the single combined reply an ECU gives to a batched Mode 01 read.
  ///
  /// Returns null when any requested PID is unimplemented — a real ECU answers
  /// only about what it supports, and the app's all-or-nothing batch handling
  /// is what has to cope with that.
  String? _assembleMode01Batch(String command, String target, bool functional) {
    final ecu = _ecus.firstWhere(
      (e) => functional || e.requestId == target,
      orElse: () => FakeEcu(name: '', requestId: '', responseId: ''),
    );
    if (ecu.name.isEmpty) return null;

    final payload = <int>[0x41];
    var answered = 0;
    for (var i = 2; i < command.length; i += 2) {
      final code = command.substring(i, i + 2);
      final single = ecu.responses['01$code'];
      // A real ECU answers about the PIDs it implements and simply omits the
      // rest — it does not refuse the whole request because one member is
      // unknown. Modelling that matters: it is what makes the app's
      // all-or-nothing batch handling visible instead of hypothetical.
      if (single == null || single.length < 2) continue;
      // The stored form is a complete reply (`41 05 82`); the batch wants just
      // the PID byte and its data.
      payload.addAll(single.skip(1));
      answered++;
    }
    if (answered == 0) return null;
    return '${_frame(ecu, payload).join('\r')}\r>';
  }

  /// Renders one ECU's payload as the lines an ELM327 would print.
  List<String> _frame(FakeEcu ecu, List<int> payload) {
    return protocol.isCan ? _frameCan(ecu, payload) : _frameLegacy(ecu, payload);
  }

  List<String> _frameCan(FakeEcu ecu, List<int> payload) {
    final hex = payload.map(_hex).toList();

    // Single frame: up to seven data bytes.
    if (hex.length <= 7) {
      if (!_headersOn) return [hex.join(' ')];
      // With headers on the adapter prints the responding CAN ID, the ISO-TP
      // PCI byte it strips when headers are off, and the frame's zero padding.
      // A Single Frame PCI is `0<len>`, so the length occupies the low nibble.
      //
      // The padding was missing here while `DemoTransport` had been taught to
      // produce it — two oracles disagreeing about a shape the docs call
      // settled, which is worse than either being wrong alone. The datasheet's
      // own example is `7E8 06 41 00 BE 3F B8 13 00`: six bytes declared, six
      // delivered, one `00` filling the frame out to eight.
      final padded = [...hex, ...List.filled(7 - hex.length, '00')];
      return [
        '${ecu.responseId} ${_hex(payload.length & 0x0F)} ${padded.join(' ')}'
      ];
    }

    final lines = <String>[];
    if (!_headersOn) {
      // Headers off: a bare total-length line, then `0:`-prefixed segments.
      lines.add(payload.length.toRadixString(16).toUpperCase().padLeft(3, '0'));
    }

    var index = 0;
    var seq = 0;
    while (index < hex.length) {
      final take = seq == 0 ? 6 : 7;
      final segment = hex.sublist(index, math.min(index + take, hex.length));
      final padded = [...segment, ...List.filled(take - segment.length, '00')];

      if (_headersOn) {
        // Datasheet p.44: with headers on there is no separate length line and
        // no `N:` prefix. The byte after the CAN ID is the PCI — high nibble
        // `1` for a First Frame whose low nibble plus the *next byte* form the
        // 12-bit total length, high nibble `2` for a Consecutive Frame whose
        // low nibble is the sequence number.
        final pci = seq == 0
            ? [0x10 | ((payload.length >> 8) & 0x0F), payload.length & 0xFF]
                .map(_hex)
                .join(' ')
            : _hex(0x20 | (seq & 0x0F));
        lines.add('${ecu.responseId} $pci ${padded.join(' ')}');
      } else {
        lines.add('${seq.toRadixString(16).toUpperCase()}: ${padded.join(' ')}');
      }
      index += take;
      seq++;
    }

    return _applySequenceFaults(lines, headerLines: _headersOn ? 0 : 1);
  }

  /// Legacy buses have no ISO-TP. Each message stands alone on its own line and
  /// repeats the service byte, which is exactly the shape that makes the app
  /// invent fault codes: it concatenates the lines and strips only the first
  /// service byte, so every later `43` shifts the DTC pairing.
  ///
  /// The per-message data limit is [legacyMessageBytes]. Confirm against the
  /// sourced ground truth before relying on any fixture built from this.
  List<String> _frameLegacy(FakeEcu ecu, List<int> payload) {
    if (payload.isEmpty) return const [];

    final service = payload.first;
    final data = payload.sublist(1);
    const perMessage = legacyMessageBytes - 1; // service byte occupies one

    final lines = <String>[];
    for (var i = 0; i < data.length; i += perMessage) {
      final slice = data.sublist(i, math.min(i + perMessage, data.length));
      // Padded to the full width on J1850 and ISO 9141, where fixed-width
      // messages are what the fixtures have always modelled. The datasheet
      // says "up to" seven data bytes, so this is a simplification — and a
      // deliberate gap: no test here exercises a short message on those buses.
      //
      // *Not* on KWP, because there the length lives in the header. Padding
      // everything to seven made every generated header `87…`, so a test
      // written to prove that a varying length byte still names one controller
      // put two identical headers on the wire and proved nothing.
      final isKwp = protocol == BusProtocol.kwp2000Slow ||
          protocol == BusProtocol.kwp2000Fast;
      final padded = isKwp
          ? slice
          : [...slice, ...List.filled(perMessage - slice.length, 0)];
      final message = [service, ...padded];
      if (!_headersOn) {
        lines.add(message.map(_hex).join(' '));
        continue;
      }
      // With `ATH1` the adapter prints the *complete* message — three header
      // bytes, the data, and the trailing checksum. Omitting the checksum here
      // modelled a shape no adapter produces, and production was written
      // against it: the checksum became the last DTC byte, made the remainder
      // odd, and every real legacy fault-code reply read as unparseable.
      final header = [
        for (var i = 0; i < ecu.responseId.length; i += 2)
          int.parse(ecu.responseId.substring(i, i + 2), radix: 16),
      ];
      // KWP's first header byte carries the length of *this* message, which
      // the datasheet says "varies from message to message". A fixture with a
      // fixed format byte declares a length its own line does not have, and a
      // test written against it proves nothing about real KWP wire.
      if (protocol == BusProtocol.kwp2000Slow ||
          protocol == BusProtocol.kwp2000Fast) {
        header[0] = 0x80 | (message.length & 0x3F);
      }
      final full = [...header, ...message];
      final checksum = protocol == BusProtocol.j1850pwm ||
              protocol == BusProtocol.j1850vpw
          ? _j1850Crc(full)
          : full.fold<int>(0, (a, b) => (a + b) & 0xFF);
      lines.add([...full, checksum].map(_hex).join(' '));
    }
    return lines;
  }

  /// SAE J1850 CRC-8, polynomial `0x1D`, as the standard specifies.
  static int _j1850Crc(List<int> bytes) {
    var crc = 0xFF;
    for (final byte in bytes) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 0x80) != 0 ? ((crc << 1) ^ 0x1D) & 0xFF : (crc << 1) & 0xFF;
      }
    }
    return (~crc) & 0xFF;
  }

  /// Data bytes per legacy message, service byte included.
  static const int legacyMessageBytes = 7;

  List<String> _applySequenceFaults(List<String> lines, {required int headerLines}) {
    final head = lines.take(headerLines).toList();
    final body = lines.skip(headerLines).toList();

    final drop = faults.dropSequenceIndex;
    if (drop != null && drop >= 0 && drop < body.length) {
      body.removeAt(drop);
    }
    if (faults.reorderSequenceLines && body.length > 1) {
      final moved = body.removeAt(0);
      body.add(moved);
    }
    return [...head, ...body];
  }

  static String _hex(int b) =>
      b.toRadixString(16).toUpperCase().padLeft(2, '0');
}

/// Small helper kept separate so the fault plumbing above stays readable.
class Uint8ListLike {
  /// Puts a NUL between every byte, the way a noisy link does. The client is
  /// supposed to strip these on arrival; a test proves it rather than assuming.
  static List<int> interleaveNulls(List<int> bytes) {
    final out = <int>[];
    for (final b in bytes) {
      out
        ..add(b)
        ..add(0);
    }
    return out;
  }
}
