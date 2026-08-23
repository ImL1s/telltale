/// Round 5 CRITICAL findings, each expressed as the bytes that trigger it.
///
/// Both reviewers supplied wire-level triggers rather than descriptions, so
/// every test here is the reviewer's own scenario rather than my reading of it.
/// That matters: the previous four rounds each fixed the defect I had
/// understood and left the one I had paraphrased.
///
/// Every test here was red before the fix. Getting them *honestly* red took
/// three attempts and is worth recording, because both failure modes appeared:
///
///   - **False green.** Asserting `isNull` passed while the readings map was
///     empty for an unrelated reason — the engine merges `physicsInputs` into
///     every poll set, so an ECU that answers only the PID under test produces
///     a short batch, trips the corruption handler, and never reaches it. That
///     is finding H5-1 masking the others; `_physicsReplies()` exists to stop
///     it. A test that passes because nothing happened proves nothing.
///   - **False red.** Several tests failed inside `connect()`, not in the code
///     under test, because the fake ECU had no `0100` for the handshake probe.
///     A test that is red for the wrong reason is worse than a green one: the
///     real fix leaves it red, which invites the fix to be "corrected" until
///     the colour comes back.
///
/// Where a trigger runs on a different bus than the reviewer described, the
/// comment says so and why. The mechanism, not the protocol, is the finding.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/obd/addressing.dart';
import 'package:torque_obd/obd/dtc/dtc.dart';
import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/pid/formula_engine.dart';
import 'package:torque_obd/obd/pid/pid.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/pid/priority_scheduler.dart';
import 'package:torque_obd/obd/polling_engine.dart';
import 'package:torque_obd/obd/telemetry.dart';
import 'package:torque_obd/obd/transport/demo_transport.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/dtc_scan.dart';

import 'support/fake_elm327.dart';

/// The Mode 01 replies every ECU needs before any of these triggers can fire.
///
/// `0100` is the handshake's critical probe — without it `connect()` returns
/// false and the test fails before reaching the defect. The rest are
/// `PidLibrary.physicsInputs`, which `setActivePids()` merges in
/// unconditionally.
Map<String, List<int>> _physicsReplies() => {
      // `0B` had to be turned on in the second mask byte (0x1F -> 0x3F): the
      // stock `BE1FA813` actually reports manifold pressure as unsupported,
      // and once the poller started honouring the mask that quietly excluded
      // the PID several tests thought they were exercising.
      //
      // Bit 0 of each mask chains to the next block, so this fixture walks
      // 0100 -> 0120 -> 0140 the way a real vehicle does and every block ends
      // up verified.
      '0100': [0x41, 0x00, 0xBE, 0x3F, 0xA8, 0x13],
      '0120': [0x41, 0x20, 0x80, 0x00, 0x00, 0x01],
      '0140': [0x41, 0x40, 0x40, 0x00, 0x00, 0x00],
      '010C': [0x41, 0x0C, 0x1A, 0xF8],
      '010D': [0x41, 0x0D, 0x3C],
      '0110': [0x41, 0x10, 0x0A, 0xF0],
      '010B': [0x41, 0x0B, 0x64],
      '010F': [0x41, 0x0F, 0x50],
      '015E': [0x41, 0x5E, 0x0B, 0xB8],
    };

Pid _pid(
  String modeAndPid,
  String equation, {
  String? variant,
  String header = kDefaultHeader,
  bool isCustom = false,
}) =>
    Pid(
      name: modeAndPid,
      shortName: modeAndPid,
      modeAndPid: modeAndPid,
      equation: equation,
      // Wide bounds on purpose. A narrow range rejects the wrong answer before
      // the assertion sees it, and the test then passes without the defect
      // being fixed — which is how the barometric trigger first went green.
      minValue: -100000,
      maxValue: 100000,
      units: '',
      header: header,
      variant: variant,
      isCustom: isCustom,
    );

/// Whether a clear reported the vehicle cleared.
///
/// A refusal and a `false` are both "no", and which of the two a given defect
/// produces is not the property under test — 已送出清除指令 reaching the screen
/// is. Collapsing them keeps the assertion on the thing that matters.
Future<bool> _clearSucceeded(PollingEngine engine) async {
  try {
    return (await engine.clearDtcs()).isSuccess;
  } on DtcReadException {
    return false;
  }
}

Future<PollingEngine> _connect(FakeElm327 transport) async {
  final client = Elm327Client(
    transport,
    commandTimeout: const Duration(milliseconds: 200),
    // Scaled with the command timeout, so the *proportions* production runs
    // at survive into the tests: a global read must outlast the window an
    // adapter opens on `7F xx 78`, and a fixed seven seconds against a
    // 200 ms command timeout is a different shape entirely.
    responsePendingTimeout: const Duration(milliseconds: 280),
  );
  expect(
    await client.connect(),
    isTrue,
    reason: 'the fake must complete the handshake, or this test fails before '
        'reaching what it is about',
  );
  return PollingEngine(client);
}

/// Polls until [settled] holds, rather than for a fixed duration.
///
/// A fixed wait made these tests pass alone and fail in a full run, and — worse
/// — made one pass for the wrong reason, because a Mode 22 PID behind an
/// `ATSH` switch had simply not been reached inside the window.
Future<PollingEngine> _poll(
  FakeElm327 transport,
  List<Pid> pids, {
  required bool Function(PollingEngine) settled,
  Duration limit = const Duration(seconds: 5),
}) async {
  final engine = await _connect(transport)..setActivePids(pids);
  engine.start();
  final deadline = DateTime.now().add(limit);
  while (!settled(engine) && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  final reached = settled(engine);
  await engine.stop();

  // The helper has to assert its own success condition, or it becomes the
  // very thing this file's header warns about. Timing out and returning
  // normally left every `isNull` expectation able to pass because the code
  // under test was never reached — the false green, reintroduced by the
  // machinery built to prevent it.
  expect(
    reached,
    isTrue,
    reason: 'the engine never reached a verdict within $limit, so whatever '
        'this test asserts next is about nothing having happened.\n'
        'readings: ${engine.current.readings.keys.toList()}\n'
        'faults: ${engine.current.faults}\n'
        'commands: ${transport.commandLog}',
  );
  return engine;
}

/// True once the engine has reached a verdict about [id] — a value or a fault.
bool _decided(PollingEngine e, String id) =>
    e.current.readings.containsKey(id) || e.current.faults.containsKey(id);

/// A headered legacy line with its checksum, which is what `ATH1` prints.
///
/// The adapter shows the *complete* message — header, data, and the trailing
/// checksum — and fixtures that omitted it modelled a wire no adapter
/// produces. Production was written against that omission and read the
/// checksum as data; both are fixed, so hand-written lines have to carry one.
String _withChecksum(String line, {bool j1850 = false}) {
  // Byte pairs across the whole line, not whitespace-separated tokens: a
  // header is written `486B10`, which is three bytes and not one.
  final hex = line.replaceAll(' ', '');
  final bytes = [
    for (var i = 0; i + 1 < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
  int crc;
  if (j1850) {
    crc = 0xFF;
    for (final byte in bytes) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 0x80) != 0 ? ((crc << 1) ^ 0x1D) & 0xFF : (crc << 1) & 0xFF;
      }
    }
    crc = (~crc) & 0xFF;
  } else {
    crc = bytes.fold<int>(0, (a, b) => (a + b) & 0xFF);
  }
  return '$line ${crc.toRadixString(16).toUpperCase().padLeft(2, '0')}';
}

void main() {
  group('completeness — a partial answer is not a whole one', () {
    // The first two run on ISO 9141 rather than CAN. Batching is a CAN-only
    // feature, so on a legacy bus each PID is polled on its own and the literal
    // reply lands exactly where the trigger needs it. The defect is in
    // `_splitBatchedResponse`, which runs on every reply regardless of bus, so
    // nothing about the finding is lost — only the scheduling noise.

    test('C-06: a valid prefix followed by an arbitrary suffix is refused',
        () async {
      // Codex's trigger, verbatim: `010C` receives `41 0C 1A F8 DE AD`.
      //
      // The splitter matched `41 0C`, took `1A F8` as the data, hit the unknown
      // byte `DE`, and returned what it had already collected. The app showed
      // 1726 RPM and reported no fault. Nothing required the payload to be
      // consumed, and `DE AD` is neither padding nor a PID we asked for.
      final rpm = _pid('010C', '((A*256)+B)/4');
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        ecus: [
          FakeEcu(
            name: 'ECM',
            // ISO 9141 addressing: priority 0x68, ECM target 0x10, tester
            // 0xF1 outbound; 0x48 / 0x6B on the reply.
            requestId: '6810F1',
            responseId: '486BF1',
            responses: _physicsReplies(),
            literalResponses: {
              '010C': ['41 0C 1A F8 DE AD'],
            },
          ),
        ],
      );

      final engine =
          await _poll(transport, [rpm], settled: (e) => _decided(e, rpm.id));
      final reading = engine.current.readings[rpm.id];
      await engine.dispose();

      expect(
        reading?.value,
        isNull,
        reason: 'a frame with an unconsumed non-padding tail must not yield a '
            'reading; 1726 RPM here is a fabrication',
      );
    });

    test('C5-3: two controllers answering one PID must not silently overwrite',
        () async {
      // Fable's trigger: two ECUs both answer `010D` and the lines concatenate
      // to `41 0D 3C 41 0D 00`.
      //
      // `result[pid.id] = ...` is an unconditional assignment, so the ECM's
      // real 60 km/h was replaced by the TCM's 0 — and the slice count still
      // matched the request, so every downstream check passed. A moving car
      // displayed a speed of zero.
      final speed = _pid('010D', 'A');
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        ecus: [
          FakeEcu(
            name: 'ECM',
            // ISO 9141 addressing: priority 0x68, ECM target 0x10, tester
            // 0xF1 outbound; 0x48 / 0x6B on the reply.
            requestId: '6810F1',
            responseId: '486BF1',
            responses: _physicsReplies(),
            literalResponses: {
              '010D': ['41 0D 3C 41 0D 00'],
            },
          ),
        ],
      );

      final engine = await _poll(transport, [speed],
          settled: (e) => _decided(e, speed.id));
      final reading = engine.current.readings[speed.id];
      await engine.dispose();

      expect(
        reading?.value,
        anyOf(isNull, equals(60.0)),
        reason: 'the last writer must not win: refuse the ambiguous frame or '
            'keep the first attributable answer — never silently replace '
            '60 km/h with 0',
      );
    });

    test('C-07a: a dangling byte after the declared window is corruption', () {
      // CAN `43 00 FF`. `needed` is 2, and the padding check runs
      // `for (i = needed; i + 1 < length; i += 2)` — with length 3 that
      // condition is false immediately, so `FF` was never examined.
      // decodeResponse returned [] and the screen could declare the car clean.
      expect(
        () => DtcDecoder.decodeResponse(
          [0x43, 0x00, 0xFF],
          DtcKind.stored,
          hasCountByte: true,
        ),
        throwsA(isA<StateError>()),
        reason: 'a non-zero byte outside the declared window contradicts the '
            'count; reporting "no codes" is the worst available answer',
      );
    });

    test('C-07b: an odd remainder on a legacy reply is refused', () {
      // Legacy `43 FF` — one byte of a two-byte code. The decode loop runs
      // `i + 1 < end`, which drops the odd byte, and the result was an empty
      // list indistinguishable from a genuine clean scan.
      expect(
        () => DtcDecoder.decodeResponse(
          [0x43, 0xFF],
          DtcKind.stored,
          hasCountByte: false,
        ),
        throwsA(isA<StateError>()),
        reason: 'half a fault code is a truncated read, not the absence of '
            'faults',
      );
    });

    test('C-07c: truncation is not hidden behind a code that did decode', () {
      // CAN `43 01 01 33 07`. The declared count of 1 is satisfied by P0133, so
      // the mismatch check passed, and `07` fell outside the padding loop's
      // range. The user saw one fault on a reply that was cut mid-code.
      expect(
        () => DtcDecoder.decodeResponse(
          [0x43, 0x01, 0x01, 0x33, 0x07],
          DtcKind.stored,
          hasCountByte: true,
        ),
        throwsA(isA<StateError>()),
        reason: 'a correct P0133 alongside a dangling 07 is still a corrupt '
            'frame; showing the good half implies the scan finished',
      );
    });

    test('C-08: one ECU refusing makes the category incomplete, not clean',
        () async {
      // Codex's trigger: the ECM answers `43 00` (no codes) and the TCM answers
      // `7F 03 11` — service not supported.
      //
      // `refused` was consulted only when `answered == 0`, so one positive
      // reply closed the category. The app returned an empty list, which the UI
      // renders as a verified clean scan, while a controller had explicitly
      // said it could not tell us.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
          FakeEcu(
            name: 'TCM',
            requestId: '7E1',
            responseId: '7E9',
            responses: {'03': [0x7F, 0x03, 0x11]},
          ),
        ],
      );

      final engine = await _connect(transport);
      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()),
        reason: 'an explicit refusal from any responder must not be outvoted '
            'by another controller answering; the vehicle-wide result is '
            'unknown, not clean',
      );
      await engine.dispose();
    });

    test('C-09: a green all-clear requires every category to have answered',
        () {
      // Codex's trigger: Mode 03 returns `43 00`, Mode 07 times out, Mode 0A
      // answers `NO DATA`. The screen rendered the two failures *and* the
      // global "沒有偵測到任何故障碼。" — a whole-vehicle all-clear resting on
      // one category out of three, on a car whose pending codes may be exactly
      // the early warning the driver came to look for.
      expect(
        scanVerdict(
          hasScanned: true,
          totalCodes: 0,
          answered: {DtcKind.stored},
        ),
        ScanVerdict.partialClean,
        reason: 'stored answered and the optional classes did not — what they '
            'would have said is unknown, which is not the same as clean',
      );

      expect(
        scanVerdict(
          hasScanned: true,
          totalCodes: 0,
          answered: DtcKind.values.toSet(),
        ),
        ScanVerdict.completeClean,
        reason: 'every class answered and none reported a fault: the one state '
            'that may be shown as an unqualified all-clear',
      );

      expect(
        scanVerdict(
          hasScanned: true,
          totalCodes: 0,
          answered: {DtcKind.pending, DtcKind.permanent},
        ),
        ScanVerdict.failed,
        reason: 'every OBD-II vehicle must answer Mode 03, so without it there '
            'is no scan whatever the optional classes managed',
      );
    });
  });

  group('capability — absence of evidence is not evidence of absence', () {
    test('H5-1: fast mode survives a car that lacks one of the physics inputs',
        () async {
      // Fable's finding: `setActivePids()` merges every physics input in
      // unconditionally, and most vehicles lack at least one of `015E`,
      // `0110` or `010B`. J1979 ECUs answer a batched request about the PIDs
      // they implement and omit the rest, so the first batch came back short,
      // tripped `handleCorruptionEvent()`, and disabled fast mode for the
      // whole session. On nearly every real car, batching destroyed itself
      // moments after connecting.
      //
      // The support mask was decoded and handed to the UI the entire time; it
      // simply never reached the poller. This car's `0140` mask says it has no
      // `015E`, which is the ordinary case, not an exotic one.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._physicsReplies()..remove('015E'),
            },
          ),
        ],
      );

      final rpm = _pid('010C', '((A*256)+B)/4');
      final engine = await _connect(transport);
      // `ObdSession` fires discovery unawaited alongside the first poll
      // cycles; awaiting it here removes that race from the test without
      // changing what is under test.
      await engine.discoverSupportedPids();
      engine.setActivePids([rpm]);
      engine.start();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!_decided(engine, rpm.id) && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await engine.stop();
      final snapshot = engine.current;
      await engine.dispose();

      expect(
        snapshot.fastModeEnabled,
        isTrue,
        reason: 'the vehicle said it has no 015E, so asking for it is the '
            "app's mistake, not the adapter's corruption",
      );
      expect(
        transport.commandLog.any((c) => c.toUpperCase().contains('5E')),
        isFalse,
        reason: 'a PID the vehicle has positively disclaimed should never be '
            'requested at all',
      );
      expect(snapshot.readings[rpm.id]?.value, closeTo(1726, 1),
          reason: 'and the PIDs it does have keep working');
    });

    test('R6 M-3: a discovery that answered nothing does not open batching',
        () async {
      // `_supported` becoming an empty set is not the same as knowing the
      // vehicle implements nothing — but it is non-null, which was the gate.
      // With zero blocks verified the first batch asked about PIDs nothing had
      // confirmed, came back short, and disabled fast mode for the session:
      // the very failure the gate was added to prevent, through the other door.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            // Answers the handshake probe and the PID under test, but no
            // support block — the shape a stubborn or busy ECU presents.
            // Two PIDs answer, deliberately. With only one there is nothing
            // to batch *with*, so the assertion below would hold whether or
            // not the gate exists — which is exactly what it did until an
            // audit broke the gate and watched the test stay green.
            responses: {
              '0100': [0x41, 0x00, 0xBE, 0x3F, 0xA8, 0x13],
              '010C': [0x41, 0x0C, 0x1A, 0xF8],
              '010D': [0x41, 0x0D, 0x3C],
            },
          ),
        ],
      );

      final engine = await _connect(transport);
      // Installed *after* the handshake: `0100` is its critical probe, so
      // refusing it up front fails the connection instead of the discovery.
      for (final block in ['0100', '0120', '0140', '0160']) {
        transport.forceReply(block, 'NO DATA');
      }
      final supported = await engine.discoverSupportedPids();
      expect(supported, isEmpty, reason: 'nothing answered');

      final rpm = _pid('010C', '((A*256)+B)/4');
      final speed = _pid('010D', 'A');
      engine.setActivePids([rpm, speed]);
      engine.start();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await engine.stop();

      // Two PIDs the vehicle answers, both polled — but that is *not* a
      // sufficient positive control and it is worth being precise about why,
      // because the obvious reading of this test is wrong.
      //
      // Forcing `canBatch` true still produces `010C` and `010D` separately in
      // this fixture: the physics inputs are merged in and go unanswered, so
      // the queue head is usually an unbatchable PID and `popBatch` returns it
      // alone. The negative assertion below therefore holds whether or not the
      // gate exists, which an audit demonstrated by breaking the gate and
      // watching this stay green.
      //
      // The claim that batching *can* happen at all is carried by
      // `R7 H-02: an unknown-width custom PID never joins a batch`, which
      // asserts a multi-PID command really does go out before asserting what
      // is excluded from it. This test is only meaningful beside that one, and
      // saying so is better than a control that does not control anything.
      expect(transport.commandLog, containsAll(['010C', '010D']),
          reason: 'both PIDs are at least being polled, which is the weaker '
              'thing this fixture can establish. '
              'Commands: ${transport.commandLog}');

      expect(
        transport.commandLog.any((c) => c.toUpperCase().length > 4 &&
            c.toUpperCase().startsWith('01') &&
            c.toUpperCase() != '0100' &&
            c.toUpperCase() != '0120' &&
            c.toUpperCase() != '0140'),
        isFalse,
        reason: 'no multi-PID request may go out while capability is entirely '
            'unverified. Commands seen: ${transport.commandLog}',
      );
      await engine.dispose();
    });

    test('R6 C-13: the engine mask does not disclaim another controller',
        () async {
      // The support mask is read from the engine, addressed explicitly. It
      // describes what *that* controller implements — so suppressing a custom
      // `7E1:010D` because the ECM's mask omits `0D` refuses a PID the vehicle
      // can actually deliver. Round 5's rule that an unknown must stay unknown
      // had turned into a claim the evidence does not support.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              // Bit for PID 0D deliberately clear: 0x1F -> 0x17.
              '0100': [0x41, 0x00, 0xBE, 0x17, 0xA8, 0x13],
              '0120': [0x41, 0x20, 0x80, 0x00, 0x00, 0x01],
              '0140': [0x41, 0x40, 0x40, 0x00, 0x00, 0x00],
              '010C': [0x41, 0x0C, 0x1A, 0xF8],
            },
          ),
          FakeEcu(
            name: 'TCM',
            requestId: '7E1',
            responseId: '7E9',
            responses: {'010D': [0x41, 0x0D, 0x3C]},
          ),
        ],
      );

      final engine = await _connect(transport);
      await engine.discoverSupportedPids();

      final onTcm = _pid('010D', 'A', header: '7E1', variant: 'tcm');
      engine.setActivePids([onTcm]);
      engine.start();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!_decided(engine, onTcm.id) && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await engine.stop();

      expect(
        engine.current.faults[onTcm.id],
        isNot(PidFault.unsupported),
        reason: "the ECM's capability map is not a statement about the TCM",
      );
      expect(engine.current.readings[onTcm.id]?.value, equals(60.0));
      await engine.dispose();
    });
  });

  group('state machine — the model of the adapter must track the adapter', () {
    test('C-05: a clone refusing ATH1 aborts the global scan', () async {
      // Codex's trigger: the adapter replies `?` to `ATH1`, `OK` to `ATSH 7DF`,
      // and an unheadered `43 00` to Mode 03.
      //
      // `_headersOn` was set when the command was *sent*, so the app believed
      // attribution was on. Header parsing then found nothing and deliberately
      // fell back to the unheadered parser, turning one anonymous reply into a
      // whole-vehicle clean scan. A global operation that cannot attribute its
      // answers is not global.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
        faults: const AdapterFaults(forcedReplies: {'ATH1': '?'}),
      );

      final engine = await _connect(transport);
      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()),
        reason: 'if ATH1 is refused the answers cannot be attributed, so the '
            'scan must fail rather than fall back to accepting them',
      );
      await engine.dispose();
    });

    test('R6 C-2: a clone that agrees to ATH1 and prints nothing is refused',
        () async {
      // Round 5 caught the clone that *refuses* `ATH1` — it answers `?`, the
      // state is no longer committed on send, and the scan aborts. This is the
      // one that agrees and does nothing: `OK` to `ATH1`, `OK` to `ATSH 7DF`,
      // and then an unheadered `43 00`.
      //
      // The parser deliberately falls through to unattributed parsing when
      // headers were expected and none arrived, which is right for ordinary
      // polling. For a global request it is not: the premise of the operation
      // is knowing who answered, and without that a single anonymous `43 00` —
      // possibly one controller of five — became a verified whole-vehicle
      // all-clear. Round 5's rule that one controller's refusal cannot be
      // outvoted had nothing left to count.
      //
      // The app's own demo simulator was this device until this round.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
        faults: const AdapterFaults(lieAboutHeaders: true),
      );

      final engine = await _connect(transport);
      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()),
        reason: 'an anonymous reply cannot support a whole-vehicle verdict, '
            'however well formed it is',
      );
      await engine.dispose();
    });

    test('C-04: a legacy global request does not inherit a custom header',
        () async {
      // Codex's trigger: on ISO 9141 a custom PID installs a header of its
      // own, then the user scans DTCs. Legacy families exposed no
      // functionalHeader, so `sendGlobal()` sent Mode 03 with that header
      // still installed — physically addressed to one controller while the UI
      // called it a vehicle-wide scan. A TCM fault would never be requested.
      //
      // ISO 9141 has a functional header of its own now (round 7, F-2), so
      // this bus takes the addressed path; the guard being exercised is the
      // one that still covers J1850, where no default is documented. The
      // fixture keeps `6810F1` because a *user* may type anything.
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '6810F1',
            responseId: '486BF1',
            responses: {
              ..._physicsReplies(),
              '221101': [0x62, 0x11, 0x01, 0x2A],
              '03': [0x43, 0x00, 0x00, 0x00],
            },
          ),
        ],
      );

      final custom = _pid('221101', 'A', header: '6810F1');
      final engine = await _poll(
        transport,
        [custom],
        settled: (e) => _decided(e, custom.id),
      );

      transport.commandLog.clear();
      try {
        await engine.readDtcs(DtcKind.stored);
      } on Object {
        // Refusing outright is an acceptable outcome for this trigger. What is
        // not acceptable is issuing 03 with a physical header still installed.
      }
      await engine.dispose();

      final log = transport.commandLog.map((c) => c.toUpperCase()).toList();
      final mode03 = log.indexOf('03');
      final restored = log
          .take(mode03 < 0 ? 0 : mode03)
          .any((c) => c.startsWith('ATSH') || c.startsWith('ATCRA'));

      expect(
        mode03 >= 0 && !restored,
        isFalse,
        reason: 'Mode 03 must not go out on an inherited physical header — '
            'restore the default address first, or refuse the scan. Commands '
            'seen: $log',
      );
    });
  });

  group('provenance — a value without an age is not a measurement', () {
    test('C-13: adapter voltage does not survive every failed refresh',
        () async {
      // Codex's trigger: the handshake measures a voltage, then every later
      // ATRV returns `?`. The refresh timestamp was set *before* the attempt
      // and the previous value retained on failure — "the previous reading
      // simply stands", as the comment in the poller put it — so the dashboard
      // pill showed the handshake figure indefinitely while real alternator
      // voltage sagged.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: _physicsReplies(),
          ),
        ],
      );

      final client = Elm327Client(
        transport,
        commandTimeout: const Duration(milliseconds: 200),
      );
      expect(await client.connect(), isTrue);
      expect(client.batteryVoltage, isNotNull,
          reason: 'the handshake reads ATRV, so a value should exist here');

      // From here the adapter refuses every voltage request.
      transport.forceReply('ATRV', '?');
      final response = await client.send('ATRV');
      await client.disconnect();

      expect(response.batteryVoltage, isNull,
          reason: 'sanity check: `?` carries no voltage');
      expect(
        client.batteryVoltage,
        isNull,
        reason: 'a refused ATRV yields no measurement; keeping the '
            'connection-time value presents a stale number as live telemetry',
      );
    });

    test('C-10: acceleration is unknown before anything has been measured',
        () async {
      // **Renamed, because the old title described a scenario this body never
      // constructs.** It said "does not survive a gap in speed replies"; it
      // never calls `setActivePids`, never starts the loop, and never polls,
      // so `_trackAcceleration` — the only place the `dt > 3` reset lives — is
      // never reached. Neutering that reset leaves this test passing, which is
      // how it was caught.
      //
      // What it does establish is real and worth keeping: acceleration is null
      // rather than 0 before anything has been measured. `0 m/s²` is "steady
      // cruise", a measurement, and exporting it for "not known" put a
      // fabricated input into the derived power figures.
      //
      // The gap reset itself is **not covered**, and `docs/verification/test-evidence.md` says
      // so rather than this file pretending otherwise. Isolating it needs an
      // observable that survives `accelerationMaxAge`, which expires the value
      // after two seconds anyway — so a naive "assert null after a 4s gap"
      // would pass for the wrong reason, which is the trap this whole file is
      // about.
      // Codex's trigger: a hard launch leaves the EMA at +2 m/s², speed
      // replies disappear for four seconds, and the first recovered sample is
      // a steady 60 km/h with fresh RPM. `_trackAcceleration` updated its
      // baseline and returned for any interval over three seconds *without
      // resetting the EMA*, so the pre-gap figure was paired with the post-gap
      // speed and displayed as current torque and horsepower.
      //
      // Exported as a non-nullable `double` defaulting to 0, it had the same
      // shape of problem even before the gap: 0 m/s² is "steady cruise", a
      // real measurement, not "not known".
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: _physicsReplies(),
          ),
        ],
      );

      final engine = await _connect(transport);
      expect(
        engine.current.accelerationMs2,
        isNull,
        reason: 'nothing has been measured yet, so acceleration is unknown — '
            'reporting 0 states that the car is holding a steady speed',
      );
      await engine.dispose();
    });

    test('C-12: an absent barometric reading does not become sea level',
        () async {
      // Codex's trigger: at ~2000 m, ambient is ~79.5 kPa and MAP is 100 kPa,
      // so `A-BARO` should read about +20.5 kPa. Nothing in lib/ ever writes a
      // measured barometric value, so BARO stayed at its 101.3 default and the
      // app displayed -1.3 kPa — plausible, labelled as derived from
      // measurement, and wrong.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            // 0133 (barometric) is deliberately absent: this car does not
            // report it, which is the common case.
            responses: _physicsReplies(),
          ),
        ],
      );

      final boost = _pid('010B', 'A-BARO');
      final engine = await _poll(
        transport,
        [boost],
        settled: (e) => _decided(e, boost.id),
      );
      final reading = engine.current.readings[boost.id];
      await engine.dispose();

      expect(
        reading?.value,
        isNull,
        reason: 'with no barometric measurement the formula is unavailable; '
            'substituting 101.3 kPa reports -1.3 kPa instead of +20.5 kPa at '
            'altitude',
      );
      // *Why* it is null matters. A null because the PID was never polled
      // would satisfy the line above while proving nothing, which is the
      // failure this file's header describes.
      expect(
        engine.current.faults[boost.id],
        PidFault.formulaError,
        reason: 'the PID was polled and the formula refused it, rather than '
            'the request never having been made',
      );
    });

    test('C-11: the formula cache carries controller identity and an age', () {
      // Codex's trigger: `7E0:221101` evaluates to 50, `7E1:221101` to 90. Both
      // write cache key `221101`, so a later `VAL{221101}` consumes whichever
      // polled last. Fable found the same root independently (M5-3), adding
      // that a *variant* with a different equation also writes its computed
      // value under the same bare key.
      //
      // This is tested at the cache rather than end-to-end on purpose. Driven
      // through the poller the outcome depends on which controller was
      // scheduled last, and a test that changes colour with poll order is
      // worse than no test — the two attempts before this one both passed
      // while proving nothing. `polling_engine.dart` calls
      // `cachePidValue(request.pid.modeAndPid, value)`, dropping `header` and
      // `variant` from an identity that every other part of the app keeps.
      final formula = FormulaEngine();
      final now = DateTime(2026, 8, 15, 12);

      final tcm = _pid('221101', 'A', header: '7E1');
      formula.cachePidValue(tcm, 90, now);

      final fromEcm = _pid('010F', 'VAL{221101}', header: '7E0');
      expect(
        formula.cachedPidValue(fromEcm, '221101', now: now),
        isNull,
        reason: 'a formula on the ECM must not resolve VAL{221101} to the '
            "TCM's measurement — they are different sensors on different "
            'controllers that happen to share a hex identifier',
      );

      final fromTcm = _pid('010F', 'VAL{221101}', header: '7E1');
      expect(
        formula.cachedPidValue(fromTcm, '221101', now: now),
        equals(90),
        reason: 'the same controller must still resolve its own value, or the '
            'fix has simply broken VAL{}',
      );

      expect(
        formula.cachedPidValue(
          fromTcm,
          '221101',
          now: now.add(FormulaEngine.maxCacheAge + const Duration(seconds: 1)),
        ),
        isNull,
        reason: 'a value with no age survives a source that has stopped '
            'answering; the poller removes the reading but the formula went '
            'on using the number indefinitely',
      );
    });
  });

  group('addressing does not leak between requests', () {
    test('R6 C-05: a built-in PID is not left on a custom controller',
        () async {
      // On a legacy bus the stored default `7E0` is not a header at all, so
      // `shouldTransmit` says "leave the adapter alone" — which is only the
      // same thing as "address the engine" while nothing else has changed it.
      // A custom PID's `ATSH 6818F1` persists, and the next built-in query
      // then goes to that module. If it answers, the reading is
      // indistinguishable from the right one.
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        ecus: [
          FakeEcu(
            name: 'ECM',
            // The address the app actually restores to on this bus. It used
            // to be `6810F1`, the invented header round 7 removed — so after
            // that fix nothing answered the restore, every run ended in
            // `busError`, and the `closeTo(1726, 1)` half of the assertion
            // below became unreachable. The test still caught a leak (320
            // satisfies neither branch) and had stopped proving that the
            // built-in gauge reads correctly again, which is the other half of
            // what it is for.
            requestId: '686AF1',
            responseId: '486BF1',
            responses: {
              ..._physicsReplies(),
              '010C': [0x41, 0x0C, 0x1A, 0xF8], // 1726 rpm
            },
          ),
          FakeEcu(
            name: 'other module',
            requestId: '6818F1',
            // Source `18`, not `F1`: on a legacy bus the third header byte is
            // the controller, so `4868F1` would have been the *same* module as
            // the ECM's `486BF1` and this fixture could not have meant what it
            // said.
            responseId: '486818',
            responses: {
              '2211': [0x62, 0x11, 0x2A],
              // Answers the same PID with a different value, which is the
              // whole danger: nothing about this reply looks wrong.
              '010C': [0x41, 0x0C, 0x05, 0x00], // 320 rpm
            },
          ),
        ],
      );

      final custom = _pid('221101', 'A', header: '6818F1');
      final rpm = _pid('010C', '((A*256)+B)/4');

      final engine = await _connect(transport);
      // The custom PID first, so its header is the one left installed.
      engine.setActivePids([custom]);
      engine.start();
      await Future<void>.delayed(const Duration(milliseconds: 250));
      await engine.stop();

      engine.setActivePids([rpm]);
      engine.start();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!_decided(engine, rpm.id) && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await engine.stop();
      final value = engine.current.readings[rpm.id]?.value;
      await engine.dispose();

      // `anyOf` is correct here and was nearly "strengthened" away. On this
      // bus the restore goes to the *functional* address, so both modules
      // answer `010C` and the app refuses two answers to one question — null
      // is the right outcome, not a weakness. What this test establishes is
      // only that 320 never wins.
      //
      // That the gauge *recovers* is a separate claim needing a single
      // responder, and it is the test below.
      expect(
        value,
        anyOf(isNull, closeTo(1726, 1)),
        reason: 'engine RPM must come from the engine, or from nowhere — '
            '320 rpm here is another module answering a question it was never '
            'asked',
      );
    });
  });

  group('a displaced header is not a permanently dark gauge', () {
    test('R8-audit: the built-in gauge reads again after the restore',
        () async {
      // The half `R6 C-05` stopped covering. Its fixture has two modules
      // answering `010C`, so after the restore — which on a legacy bus goes to
      // the functional address — the app correctly refuses two answers, and
      // the reading is null for a reason that has nothing to do with
      // addressing. Since round 7's F-2 removed the invented physical header,
      // its `closeTo(1726, 1)` branch had never once been reached.
      //
      // One responder, so recovery is the observable.
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '686AF1',
            responseId: '486B10',
            responses: {
              ..._physicsReplies(),
              '010C': [0x41, 0x0C, 0x1A, 0xF8],
            },
          ),
          FakeEcu(
            name: 'other module',
            requestId: '6818F1',
            responseId: '486B18',
            // Answers the custom PID and nothing else, so it cannot confuse
            // the recovery it is here to interrupt.
            responses: {'221101': [0x62, 0x11, 0x01, 0x2A]},
          ),
        ],
      );

      final custom = _pid('221101', 'A', header: '6818F1');
      final rpm = _pid('010C', '((A*256)+B)/4');
      final engine = await _poll(
        transport,
        [custom, rpm],
        settled: (e) => _decided(e, custom.id) && _decided(e, rpm.id),
      );

      expect(engine.current.readings[rpm.id]?.value, closeTo(1726, 1),
          reason: 'a custom PID moving the header must not leave the engine '
              'gauge dark for the rest of the session');
      expect(transport.commandLog, contains('ATSH686AF1'),
          reason: 'and it recovered by addressing, not by luck');
      await engine.dispose();
    });
  });


  group('a damaged peer reply cannot be outvoted by a clean one', () {
    test('R7 C-01b: a headered exchange with a bare peer line is refused',
        () async {
      // Codex's exact trigger. `7E8 02 43 00` is a valid empty answer; the
      // bare `7E9` is the start of a second controller's line with its payload
      // lost. Attribution does not catch it — the surviving frame is properly
      // sourced — so the whole exchange has to.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: _physicsReplies(),
            literalResponses: {
              '03': ['7E8 02 43 00', '7E9'],
            },
          ),
        ],
      );

      final engine = await _connect(transport);
      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()),
        reason: 'a controller that started to answer and did not finish makes '
            'the category incomplete, however clean the other one was',
      );
      await engine.dispose();
    });

    test('R6 C-02: a dangling nibble refuses the whole exchange', () async {
      // Codex's trigger, verbatim. The 7E8 line parses as a clean Mode 03
      // answer; the 7E9 line's odd nibble makes it match nothing, and both
      // parsers simply `continue`d past it. One well-formed controller then
      // closed the vehicle-wide category while another controller's reply had
      // silently disappeared — including, here, a negative response that says
      // it could not answer.
      //
      // The new attribution check does not help: it sees one properly sourced
      // frame and is satisfied.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: _physicsReplies(),
            literalResponses: {
              '03': [
                '7E8 03 43 00 00 00 00 00',
                '7E9 03 7F 03 1',
              ],
            },
          ),
        ],
      );

      final engine = await _connect(transport);
      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()),
        reason: 'a line that arrived damaged is evidence the scan is '
            'incomplete, not something to drop',
      );
      await engine.dispose();
    });

    test('R7 C-01: a bare hex line is a truncated message, not formatting', () {
      // This test used to assert the opposite, and asserting it was the
      // mistake. I added an exception so a stray `014` total-length line would
      // be skipped rather than fail the exchange — but that is a *shape* test,
      // and the shape is indistinguishable from a second controller's line
      // whose payload was lost.
      //
      // Codex's trigger: with headers on, `7E8 02 43 00` followed by a bare
      // `7E9`. The 7E8 line is a valid empty DTC answer, the `7E9` matches the
      // length-header shape and was skipped, the remaining frame satisfied the
      // attribution check — and a damaged two-controller exchange became a
      // verified clean category.
      //
      // A total-length line is only legal inside a validated `N:` envelope,
      // which is parsed earlier. Anything of that shape arriving here is not
      // one.
      final client = Elm327Client(DemoTransport());

      final truncated = client.parseFrameForTest(
        ascii.encode('43 00\r430\r>'),
      );
      expect(truncated.isSuccess, isFalse,
          reason: 'the odd nibble is half a reply, not a stray header');

      final strayLength = client.parseFrameForTest(
        ascii.encode('014\r41 0C 1A F8\r>'),
      );
      expect(
        strayLength.isSuccess,
        isFalse,
        reason: 'and a genuinely stray length line is refused too — when two '
            'readings of a line are indistinguishable and one of them is a '
            'lost controller, refusing is the only safe one',
      );
    });

    test('R6 C-02: adapter prose is still skipped, not treated as damage', () {
      // The rule has to distinguish a corrupted reply from the adapter talking.
      // `SEARCHING...` and `BUS INIT: OK` are prose and must stay harmless, or
      // every protocol search becomes a failed read.
      final client = Elm327Client(DemoTransport());
      final response = client.parseFrameForTest(
        ascii.encode('SEARCHING...\r41 0C 1A F8\r>'),
      );
      expect(response.isSuccess, isTrue);
      expect(response.bytes, equals([0x41, 0x0C, 0x1A, 0xF8]));
    });
  });

  group('the app does not refuse what it can read', () {
    test('R6 H-01: a custom PID keeps data its formula does not reference',
        () async {
      // A user defines `010C` as `A` because only the high byte interests
      // them. The ECU replies `41 0C 1A F8` — correct, complete, and refused,
      // because the width was inferred from the formula and `F8` then looked
      // like an unknown PID byte. The author said which bytes they cared
      // about, not how wide the reply is.
      const custom = Pid(
        name: 'rpm high byte', shortName: 'rpmhi', modeAndPid: '010C',
        equation: 'A', minValue: 0, maxValue: 255, units: '',
        isCustom: true, variant: 'high',
      );
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: _physicsReplies(),
          ),
        ],
      );

      final engine = await _connect(transport);
      await engine.discoverSupportedPids();
      engine.setActivePids([custom]);
      engine.start();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!_decided(engine, custom.id) && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await engine.stop();
      final value = engine.current.readings[custom.id]?.value;
      await engine.dispose();

      expect(value, equals(0x1A.toDouble()),
          reason: 'the reply arrived and is readable; refusing it is the app '
              'declining to read something it demonstrably can');
    });

    test('R7: a widthless custom PID still refuses two responders', () async {
      // Letting a custom PID keep payload its formula does not reference was
      // right — but "everything after `41 <pid>`" has no bound, so a second
      // controller's concatenated answer bound `A`..`D` across both replies.
      // That is precisely the defect the declared-width path refuses, reopened
      // for the definitions with no declared width.
      const custom = Pid(
        name: 'rpm high byte', shortName: 'rpmhi', modeAndPid: '010C',
        equation: 'A', minValue: 0, maxValue: 255, units: '',
        isCustom: true, variant: 'high',
      );
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '6810F1',
            responseId: '486BF1',
            responses: _physicsReplies(),
            literalResponses: {
              // Two controllers, same PID, concatenated.
              '010C': ['41 0C 1A F8 41 0C 05 00'],
            },
          ),
        ],
      );

      final engine = await _poll(transport, [custom],
          settled: (e) => _decided(e, custom.id));
      final value = engine.current.readings[custom.id]?.value;
      await engine.dispose();

      expect(
        value,
        isNull,
        reason: 'the reply may be unbounded; it may not contain a second '
            'answer to the same question',
      );
    });

    test('R6 H-02: an unconfirmed PID is polled alone, not batched', () async {
      // One verified block used to license every PID into a batch, including
      // ones from blocks that never answered. A partial-map ECU replies about
      // the members it implements and omits the rest; the short reply trips
      // the corruption handler and disables fast mode for the session.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._physicsReplies(),
              '012C': [0x41, 0x2C, 0x40],
            },
          ),
        ],
      );

      final engine = await _connect(transport);
      // The second block never answers, so `012C` is unknown rather than
      // absent — pollable, but nothing has confirmed it.
      transport.forceReply('0120', 'NO DATA');
      await engine.discoverSupportedPids();

      final unconfirmed = _pid('012C', 'A');
      engine.setActivePids([unconfirmed]);
      engine.start();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await engine.stop();
      final log = transport.commandLog.map((c) => c.toUpperCase()).toList();
      await engine.dispose();

      // Once it has answered on its own, batching it is fair — the vehicle
      // has demonstrated it implements the PID, and a J1979 ECU answers a
      // batch about what it implements. What must not happen is batching it
      // while nothing has confirmed anything.
      final firstMention = log.indexWhere(
        (c) => c.startsWith('01') && c.contains('2C'),
      );
      expect(firstMention, greaterThanOrEqualTo(0),
          reason: 'sanity: the PID is polled at all');
      expect(
        log[firstMention].length,
        equals('012C'.length),
        reason: 'the first request for an unconfirmed PID must be that PID '
            'alone. Commands: $log',
      );
    });
  });

  group('response pending is not a refusal', () {
    test('R6 M-07: a controller still working is reported as such', () async {
      // ISO 14229 NRC 0x78, `requestCorrectlyReceived-ResponsePending`, says
      // the real answer is still coming. It is ordinary on slower modules and
      // routine during a Mode 04 clear, which has to erase fault memory. It
      // was counted as a refusal, so the app told the driver the ECU had
      // rejected a request it had accepted and was working on.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._physicsReplies(),
              '03': [0x7F, 0x03, 0x78],
            },
          ),
        ],
      );

      final engine = await _connect(transport);
      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(
          isA<DtcReadException>().having(
            (e) => e.message,
            'message',
            contains('pending'),
          ),
        ),
        reason: 'the distinction matters: "still working" invites waiting, '
            '"refused" invites giving up',
      );
      await engine.dispose();
    });

    test('R7 H-09: on CAN the request is not re-sent, because the adapter '
        'already waited', () async {
      // This test used to assert the opposite, and was wrong in a way worth
      // recording: it gave a CAN fixture two all-pending replies followed by
      // the real one, so the sequence could only advance when the app
      // *retransmitted*. It therefore certified retransmission while claiming
      // to certify waiting.
      //
      // Datasheet p.45 settles it. From firmware v2.1 the adapter does this
      // itself — "changing the timeout to 5 seconds for you if it sees a
      // Response Pending message… for the CAN and ISO14230 (KWP) protocols as
      // per the standard". So a bare pending reply that reaches the app on
      // those buses has already outlasted the five seconds the standard
      // prescribes. Asking again asks for nothing new, and `7F xx 78` does not
      // transfer ownership to a fresh request: the original was accepted, and
      // a module may restart work it had nearly finished.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      transport.forceReplySequence('03', ['7E8 03 7F 03 78']);

      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()
            .having((e) => e.kind, 'kind', DtcReadFailure.pending)),
        reason: 'incomplete, and the user is told to rescan — which is what '
            'the standard leaves a tester once its own window has passed',
      );
      expect(
        transport.commandLog.where((c) => c == '03'),
        hasLength(1),
        reason: 'exactly one Mode 03 went out',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('R7: a scan deadline stops the retry, not just the spinner',
        () async {
      // Codex H-07's fourth trigger. The scan screen wrapped the read in
      // `Future.timeout`, which bounds the spinner and not the bus work: the
      // detached read went on sleeping two seconds and transmitting again in
      // the background, and an immediate rescan queued behind the operation
      // the screen thought it had abandoned.
      //
      // A deadline has to reach the code that decides to send again.
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '686AF1',
            responseId: '486B10',
            responses: {..._physicsReplies()},
            literalResponses: {
              '03': [_withChecksum('486B10 7F 03 78')],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      final before = transport.commandLog.where((c) => c == '03').length;

      // Long enough for one exchange, far short of the two-second retry delay.
      await expectLater(
        engine.readDtcs(DtcKind.stored,
            deadline: DateTime.now().add(const Duration(milliseconds: 900))),
        throwsA(isA<DtcReadException>()),
      );
      expect(
        transport.commandLog.where((c) => c == '03').length - before,
        1,
        reason: 'the deadline arrived before the retry delay would have '
            'elapsed, so nothing further went to the vehicle',
      );

      // And a deadline too short to finish an exchange does not start one.
      // A global read is four commands — ATH1, ATSH, the mode, the ATH0
      // restore — so entering with ten milliseconds left used to open the
      // whole thing and let the caller's `.timeout()` detach it. The screen
      // said the scan had finished while the app was still transmitting.
      final beforeSecond = transport.commandLog.where((c) => c == '03').length;
      await expectLater(
        engine.readDtcs(DtcKind.stored,
            deadline: DateTime.now().add(const Duration(milliseconds: 10))),
        throwsA(isA<DtcReadException>()),
      );
      expect(
        transport.commandLog.where((c) => c == '03').length - beforeSecond,
        0,
        reason: 'nothing may be started that cannot be finished',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R9-codex H-02: the budget binds the transaction, not just its start',
        () async {
      // Codex. The preflight above stops an exchange that has no time at all,
      // and then hands over: the transaction itself knew nothing about the
      // deadline, so once started it ran to its own four command timeouts.
      // `Future.timeout` on the caller's side cannot cancel a command chain.
      //
      // Scaled from Codex's production timing. Each control command answers
      // well inside its own contract; it is their sum that does not fit.
      //
      //   budget            300 ms   (> globalTimeout, so the preflight passes)
      //   every reply       160 ms   (< commandTimeout 200 ms, so each is legal)
      //   ATH1              0 → 160
      //   ATSH 7DF          160 → 320   ← 20 ms past the budget
      //   03                written at 320 with a fresh 280 ms window
      //   43 …              at 480, delivered to a caller that left at 300
      //
      // The screen said the category was finished while the adapter was still
      // executing it, and an immediate rescan queued behind disowned work.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x01, 0x03, 0x01]},
          ),
        ],
      );
      final engine = await _connect(transport);
      // After the handshake, which has sixteen commands of its own.
      transport.responseLatency = const Duration(milliseconds: 160);

      await expectLater(
        engine.readDtcs(DtcKind.stored,
            deadline: DateTime.now().add(const Duration(milliseconds: 300))),
        throwsA(anything),
        reason: 'the budget is spent before the service byte is reached',
      );
      expect(transport.commandLog, isNot(contains('03')),
          reason: 'and nothing was put on the bus for a caller that had '
              'already been told the category was over',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R10-codex 06: a pending reply does not buy time the caller has not '
        'got', () async {
      // Codex, round 10, on round 9's H-02. The deadline was clamped once, at
      // admission, and every *rearm* went round it: a `7F xx 78` cancelled the
      // clamped timer and installed a fresh full pending window.
      //
      //   budget    t0 + 320 ms
      //   7F 03 78  t0 + 250 ms   ← 70 ms left, and a fresh 280 ms installed
      //   43 …      t0 + 500 ms   ← delivered to a caller that left at 320 ms
      //
      // Codex's own harness completed this at 404 ms with `timedOut=false`.
      // The exchange was asking for more time after the caller had stopped
      // waiting, which is the whole of what the deadline is for.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x01, 0x03, 0x01]},
          ),
        ],
      );
      final engine = await _connect(transport);
      // Only the service is slow; the framing around it stays instant, which
      // is what a controller taking its time actually looks like.
      transport.slowCommands['03'] = const Duration(milliseconds: 500);
      transport.pendingBefore['03'] = 1;

      await expectLater(
        engine.readDtcs(DtcKind.stored,
            deadline: DateTime.now().add(const Duration(milliseconds: 320))),
        throwsA(anything),
        reason: 'the controller may keep working; this caller may not keep '
            'waiting, and its budget was set before any of this began',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R9-codex H-04: response-pending handling is a setting, not a version',
        () async {
      // Codex. The datasheet makes the five-second extension conditional:
      // "If bit 2 of PP 2A is set (it is by default), the ELM327 will support
      // this part of J1979, changing the timeout to 5 seconds for you if it
      // sees a Response Pending message." The app read the version banner and
      // nothing else.
      //
      // With bit 2 cleared the adapter does *not* wait — but the app still
      // believed it had, declined to re-ask, and reported the category
      // incomplete. The controller was holding a stored P0301 and would have
      // given it up on the second request.
      //
      //   AT PP 2A SV 38 / ON     bit 2 cleared
      //   ATI  → ELM327 v2.1      unchanged, and no longer sufficient
      //   03   → 7E8 03 7F 03 78  the adapter forwards it and moves on
      //   03   → 7E8 … 43 01 03 01
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x01, 0x03, 0x01]},
          ),
        ],
      )..enabledProgrammableParameters[0x2A] = 0x38;
      final engine = await _connect(transport);
      transport.forceReplySequence('03', ['7E8 03 7F 03 78']);

      final codes = await engine.readDtcs(DtcKind.stored);
      expect(codes.map((c) => c.code), ['P0301'],
          reason: 'the fault was there to be read on the second request, and '
              'refusing to make it costs the whole point of the scan');
      expect(transport.commandLog.where((c) => c == '03'), hasLength(2),
          reason: 'the adapter was not waiting, so the app had to');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R9-codex H-01: a user CAN protocol is read from its options byte',
        () async {
      // Codex. `ATDPN B` was mapped to 11-bit ISO 15765-4 and asserted as such
      // in two test files, which is why it survived. `B` and `C` are two
      // configurable slots; PP 2C and PP 2E carry the identifier width (b7)
      // and the data format (b2 b1 b0: none / ISO 15765-4 / SAE J1939).
      //
      // The defaults are the point. PP 2C ships `E0`, PP 2E ships `80`, and
      // both select format `000` — none. A factory-default protocol B is CAN
      // traffic with no application layer, and this app was running the J1979
      // decoder over it and rendering the output as fault codes.
      Future<PollingEngine> onUserCan(int? options,
          {int? storedButOff}) async {
        final transport = FakeElm327(
          protocol: BusProtocol.can11,
          forceProtocolNumber: 'B',
          ecus: [
            FakeEcu(
              name: 'ECM',
              requestId: '7E0',
              responseId: '7E8',
              responses: {..._physicsReplies(), '03': [0x43, 0x01, 0x03, 0x01]},
            ),
          ],
        );
        if (options != null) {
          transport.enabledProgrammableParameters[0x2C] = options;
        }
        if (storedButOff != null) {
          transport.storedButOffProgrammableParameters[0x2C] = storedButOff;
        }
        return _connect(transport);
      }

      // Factory default: `2C:E0 F`, no formatting.
      final unformatted = await onUserCan(null);
      await expectLater(
        unformatted.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()),
        reason: 'unframed CAN is not a bus to decode J1979 out of',
      );
      await unformatted.dispose();

      // `42` selects SAE J1939, which this app refuses by name — and which the
      // old contract decoded with the J1979 count byte.
      final asJ1939 = await onUserCan(0x42);
      await expectLater(
        asJ1939.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()
            .having((e) => e.message, 'message', contains('J1939'))),
      );
      await asJ1939.dispose();

      // Configured once and then switched off — `2C:81 F`. The stored byte
      // says ISO 15765-4; the state letter says the parameter is not in
      // effect, so the adapter is running the factory `E0` and the bus is
      // unframed. Reading the value and ignoring the letter is how a J1979
      // decoder ends up over raw CAN, and Codex's round-10 audit found nothing
      // in the suite would have caught that flip.
      final storedButDisabled = await onUserCan(null, storedButOff: 0x81);
      await expectLater(
        storedButDisabled.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()),
        reason: 'a disabled parameter is not what the adapter is doing',
      );
      await storedButDisabled.dispose();

      // R13-02: and the refusal is one policy, not one screen's. The census,
      // support discovery and the poll loop refused only J1939 while an
      // *unidentified* bus went on being questioned — so a protocol B slot
      // with no readable PP 2C had its fault-code reads refused while raw
      // bytes became a plausible 1726 rpm on the dashboard.
      final telemetry = FakeElm327(
        protocol: BusProtocol.can11,
        forceProtocolNumber: 'B',
        faults: const AdapterFaults(refusePpSummary: true),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      final unidentified = await _connect(telemetry);
      final quiet = telemetry.commandLog.length;
      expect(await unidentified.discoverResponders(), isNull);
      expect(await unidentified.discoverSupportedPids(), isEmpty);
      const rpm = PidLibrary.engineRpm;
      unidentified.setActivePids([rpm]);
      unidentified.start();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await unidentified.stop();
      expect(
          telemetry.commandLog.skip(quiet).where((c) => !c.startsWith('AT')),
          isEmpty,
          reason: 'one bus policy: no J1979 request goes to a bus whose '
              'framing this app has just said it cannot establish. `ATRV` is '
              'the adapter talking about itself and is fine anywhere');
      expect(unidentified.current.readings[rpm.id]?.value, isNull,
          reason: 'and no number is published from it');
      await unidentified.dispose();

      // A clone that refuses `AT PPS` entirely. Rounds 10 to 12 were spent on
      // this case, and the answer is that it must be refused.
      //
      // Round 10 called the refusal over-strictness — the vehicle answered the
      // mandatory `0100` probe, after all. Two attempts to honour that were
      // then shown unsound: an identifier width read from a reply confuses
      // PP 2C's transmit bit with its receive bit, and treating a successful
      // ISO-TP parse as proof of ISO-TP framing is circular, because the
      // datasheet allows this slot to carry no formatting at all and raw bytes
      // can take the same shape.
      //
      // A user slot's framing is stated in PP 2C / PP 2E and nowhere else. The
      // refusal names the parameter rather than telling someone to reconnect.
      final noSummary = FakeElm327(
        protocol: BusProtocol.can11,
        forceProtocolNumber: 'B',
        faults: const AdapterFaults(refusePpSummary: true),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x01, 0x03, 0x01]},
          ),
        ],
      );
      final clone = await _connect(noSummary);
      await clone.discoverResponders();
      final before = noSummary.commandLog.length;
      await expectLater(
        clone.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()
            .having((e) => e.message, 'message', contains('PP 2C'))),
        reason: 'unknown framing is not a bus to decode fault codes from, and '
            'the message says which setting would have answered',
      );
      expect(noSummary.commandLog.skip(before), isNot(contains('03')),
          reason: 'and nothing is put on a bus this app cannot read');
      await clone.dispose();

      // `81` is 11-bit ISO 15765-4 — a genuinely configured user protocol,
      // which must still work. Refusing this would be the over-strictness
      // round 6 was spent undoing.
      final configured = await onUserCan(0x81);
      expect((await configured.readDtcs(DtcKind.stored)).map((c) => c.code),
          ['P0301'],
          reason: 'the vehicle answered; the app just had to ask the adapter '
              'how it was set up');
      await configured.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('R9-kimi: a global read outlasts the adapter\'s own pending window',
        () async {
      // The host's command timeout and the window the adapter opens on
      // `7F xx 78` were both five seconds, so they expired together and the
      // host could abandon the very exchange the adapter was still holding.
      //
      // Codex's L-01: this used to describe response-pending handling and then
      // emit no `7F xx 78` at all — 5.6 seconds of silence followed by
      // `43 00`, which is a generic long wait and not this contract. A
      // conforming adapter answering nothing for 5.6 seconds would have said
      // `NO DATA`; the app configures `ATST` far below that. The comment also
      // repeated the invented claim that a modern adapter *swallows* the
      // pending bytes.
      //
      // The controller now says "wait, I'm busy" twice while it works, which
      // is what buys the time: the standard gives the server five seconds and
      // restarts that window on each further pending reply.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
      );
      final client = Elm327Client(transport);
      expect(await client.connect(), isTrue);
      final engine = PollingEngine(client);

      // One slow *controller*, not a slow adapter: the `ATH1`/`ATSH` framing a
      // global read needs stays instant, and only the mode byte takes longer
      // than the host's five-second default — which is exactly what a module
      // doing a flash erase looks like.
      transport.slowCommands['03'] = const Duration(milliseconds: 5600);
      transport.pendingBefore['03'] = 2;

      expect(await engine.readDtcs(DtcKind.stored), isEmpty,
          reason: 'a controller that said it was working, twice, and then '
              'answered has answered — and a clear that succeeded must not be '
              'reported as a timeout');
      await engine.dispose();
      await client.dispose();
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('R10-codex C-02: a pending reply that arrives last is still pending',
        () async {
      // Codex, round 10, on the filter added hours earlier for L-01.
      //
      // That filter drops every pending single frame from a source as soon as
      // any non-pending frame from that source exists — "there is a terminal
      // reply somewhere" rather than "this pending reply was answered". An
      // earlier answer and a later in-progress one can overlap in the
      // adapter's buffer:
      //
      //     7E8 02 43 00
      //     7E8 03 7F 03 78
      //     >
      //
      // The controller's last word is that it is still working. Dropping the
      // second frame leaves a clean `43 00`, and with clean 07/0A replies the
      // scan goes green. Seventeenth time a fix in this project has produced
      // the next defect, and the second one today from a filter written for a
      // reviewer's finding.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      transport.forceReplySequence('03', ['7E8 02 43 00\r7E8 03 7F 03 78']);

      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()),
        reason: 'a controller whose last word was 7F 03 78 has not finished, '
            'and an earlier 43 00 does not finish it for them',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R11-codex 05: a pending reply about another service is not deleted',
        () async {
      // Codex round 11. The filter learned order and not identity: any later
      // non-pending frame from a source deleted every earlier pending one,
      // whatever service each was about.
      //
      //     7E8 03 7F 07 78     ← service 07 is still working
      //     7E8 02 43 00        ← service 03 is finished
      //     >
      //
      // The first was never superseded. Erasing it turned a contradictory
      // exchange into a clean stored-codes result — an empty list, rendered
      // green.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      transport.forceReplySequence('03', ['7E8 03 7F 07 78\r7E8 02 43 00']);

      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()),
        reason: 'a pending message about a service nothing answered is not '
            'noise to drop on the way to a clean result',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R12-codex 02: a superseded pending frame is found through its '
        'ISO-TP header', () async {
      // Codex round 12, on round 11's service correlation. `_serviceOf` read
      // `body[1]`, which is the service byte only on a *single* frame, and
      // capped positive responses at `0x4F`, which excludes Mode 22's `0x62`.
      //
      // Both misreads keep a pending frame that was in fact answered, hand the
      // reassembler two logical messages as one, and turn a valid reply into
      // `DATA ERROR` — for Mode 22, a custom gauge that never reads; for a
      // multi-frame Mode 03, four real fault codes that never appear.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);

      // A First Frame's `body[1]` is the low half of the message length, not a
      // service. `10 0A` is "ten bytes follow"; the service is at `body[2]`.
      transport.forceReplySequence('03', [
        '7E8 03 7F 03 78\r'
            '7E8 10 0A 43 04 01 33 07 00\r'
            '7E8 21 03 00 04 20 00 00 00',
      ]);
      expect((await engine.readDtcs(DtcKind.stored)).map((c) => c.code),
          ['P0133', 'P0700', 'P0300', 'P0420'],
          reason: 'the controller finished, at length, and every code it sent '
              'has to arrive');

      // Mode 22's positive response is `0x62`, past the old `0x4F` bound.
      transport.forceReplySequence(
          '221234', ['7E8 03 7F 22 78\r7E8 04 62 12 34 2A']);
      final custom = await engine.client.sendGlobal('221234');
      expect(custom.isSuccess, isTrue);
      expect(custom.bytes, [0x62, 0x12, 0x34, 0x2A],
          reason: 'a custom PID that answered after saying "wait" still '
              'answered');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R13-codex 04: saying "still working" twice is still working',
        () async {
      // Codex round 13, on round 11's filter. A pending frame was dropped only
      // when a later *non-pending* reply for the same service existed, so two
      // pending messages from one source were both kept — and two single
      // frames for one source is not a reassemblable message, so continuing
      // work surfaced as `DATA ERROR`.
      //
      // The datasheet is explicit that a further `7F xx 78` restarts the
      // five-second window. Repeated pending is normal.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      transport.forceReplySequence('03', ['7E8 03 7F 03 78\r7E8 03 7F 03 78']);

      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()
            .having((e) => e.kind, 'kind', DtcReadFailure.pending)),
        reason: 'incomplete because the controller is still working, not '
            'because the data was bad',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R11-codex 06: a suspension does not hand back a spent budget',
        () async {
      // Codex round 11. Every rearm was clamped to the caller's budget except
      // the one that runs on resume, which made it the way round all of them:
      // `markAlive` cancelled the clamped timer and installed a fresh full
      // `commandTimeout`. Suspend and resume with 70 ms of a scan left, and
      // the command got five seconds back.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x01, 0x03, 0x01]},
          ),
        ],
      );
      final engine = await _connect(transport);
      // The reply lands *between* the caller's deadline and where an unclamped
      // rearm would have fired. A 500 ms reply could not tell the two apart —
      // both versions timed out first — which Codex's round-12 mutation run
      // demonstrated by reverting the clamp and watching this stay green.
      //
      //   budget    t0 + 320 ms
      //   markAlive t0 + 250 ms   ← unclamped, this rearms to t0 + 450 ms
      //   43 …      t0 + 400 ms   ← in time for the rearm, too late for the
      //                             caller
      transport.slowCommands['03'] = const Duration(milliseconds: 400);

      final started = DateTime.now();
      final read = engine.readDtcs(DtcKind.stored,
          deadline: started.add(const Duration(milliseconds: 320)));
      // The resume probe, arriving while the service is still outstanding.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      engine.client.markAlive();

      await expectLater(read, throwsA(anything),
          reason: 'the interruption does not extend what the caller asked for '
              '— the reply arrives in time for a fresh command timeout and '
              'too late for the budget that was set');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R8-9: an adapter too old to wait is asked again', () async {
      // GPT-5.6 Pro. Round 7 keyed the retry on CAN-versus-legacy, reading the
      // standard and forgetting the device. The datasheet puts it in the same
      // breath as the feature — "Beginning with v2.1, that is changing" — so a
      // genuine v1.3a on a CAN vehicle does none of it, and the app stopped
      // asking for a fault a second request would have returned.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        identity: 'ELM327 v1.3a',
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      final engine = await _connect(transport);
      // Pending once, then the real answer — which only arrives if the app
      // asks again.
      transport.forceReplySequence('03', [
        '7E8 03 7F 03 78',
        '7E8 04 43 01 03 01',
      ]);

      final codes = await engine.readDtcs(DtcKind.stored);
      expect(codes.map((d) => d.code), contains('P0301'),
          reason: 'this adapter never extended anything; the wait had to come '
              'from the app or not at all');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R7 H-09: on a legacy bus the app supplies the wait the adapter '
        'does not', () async {
      // The counterpart, and why the retry is kept rather than deleted. The
      // adapter's response-pending handling covers CAN and KWP only, so on
      // J1850 and ISO 9141-2 nothing has waited for the slow module at all —
      // one erasing fault memory, say. There the app asking again is the only
      // thing standing between a slow controller and being permanently
      // unreadable.
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '686AF1',
            responseId: '486B10',
            responses: {..._physicsReplies()},
            literalResponses: {
              '03': [_withChecksum('486B10 43 00 00 00 00 00 00')],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      transport.forceReplySequence('03', [_withChecksum('486B10 7F 03 78')]);

      expect(await engine.readDtcs(DtcKind.stored), isEmpty,
          reason: 'the module finished, and the app was still listening');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('R7 C-02: one controller cannot discharge another\'s promise',
        () async {
      // Codex's trigger. Request 1 gets only `7E9 03 7F 03 78` — the
      // transmission says its answer is pending. Two seconds later the app
      // asks again and gets only `7E8 02 43 00`, the engine's clean reply. The
      // TCM never answered, and the category was reported clean.
      //
      // Treating each retry as an interchangeable transaction discards the
      // identity of who owes what, which is the whole content of a pending
      // response.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: _physicsReplies(),
          ),
        ],
      );

      final engine = await _connect(transport);
      transport.forceReplySequence('03', [
        '7E9 03 7F 03 78',
        '7E8 02 43 00',
        '7E8 02 43 00',
      ]);

      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()),
        reason: "the engine's clean answer says nothing about the "
            'transmission that promised one and never gave it',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('R6 H-09: the demo refuses an AT command it does not implement',
        () async {
      // A real ELM327 answers `?` to a command it does not recognise
      // (datasheet p.7). This simulator answered `OK` to everything, which is
      // clone behaviour — and a simulator more permissive than the hardware
      // certifies paths no real adapter takes. The app's global fault-code
      // scan rested on exactly that for four rounds.
      final client = Elm327Client(DemoTransport());
      expect(await client.connect(), isTrue,
          reason: 'the commands it does implement still work');

      final reply = await client.send('ATZZZ');
      await client.dispose();

      expect(
        reply.rawLines.any((l) => l.trim().toUpperCase() == 'OK'),
        isFalse,
        reason: 'agreeing to a command it will not carry out is the one '
            'adapter behaviour this app is least able to survive',
      );
    });
  });

  group('a global exchange that times out leaves no silent damage', () {
    test('R7: a failed drain in `finally` does not hang the caller', () async {
      // `return` inside a `finally` block discards the exception in flight.
      // The restore path had one — so when a global exchange failed *and* the
      // drain that followed also failed, the outer catch never ran, the
      // completer was never completed either way, and the caller's future
      // simply hung. A fault-code scan would wait forever, which is worse than
      // the failure it was recovering from.
      // `ATH1` and `ATSH` answer normally — so the exchange gets *inside* the
      // try/finally — and only `03` withholds its prompt. That is the exact
      // interleaving: an exception in flight when `finally` runs, and a drain
      // that then cannot find a prompt either.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        faults: const AdapterFaults(swallowPromptFor: {'03'}),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
      );

      final client = Elm327Client(
        transport,
        commandTimeout: const Duration(milliseconds: 250),
      );
      expect(await client.connect(), isTrue);

      // The assertion is that this completes *promptly*, not merely that
      // something is eventually thrown. With the `return` in place the future
      // hangs and only an outer timeout ends it — which is still an exception,
      // so an `expect(throwsA(...))` alone passes and proves nothing. The
      // elapsed time is the observable that distinguishes a failure from a
      // hang.
      final started = DateTime.now();
      await expectLater(
        PollingEngine(client).readDtcs(DtcKind.stored).timeout(
              const Duration(seconds: 20),
            ),
        throwsA(isA<Object>()),
      );
      final elapsed = DateTime.now().difference(started);

      // Fourteen seconds, and the number is derived rather than picked. A
      // global read waits up to seven — it has to outlast the five-second
      // window the adapter opens for itself on `7F xx 78`, or the host
      // abandons an exchange the adapter is still holding — and a failed drain
      // adds three. Ten used to be the bound and stopped being true when the
      // legitimate maximum moved; this keeps a six-second margin against the
      // hang, which was 20004ms.
      expect(
        elapsed,
        lessThan(const Duration(seconds: 14)),
        reason: 'a caller must get its answer from the command path, not from '
            'a timeout wrapped around it — hanging is the one outcome it '
            'cannot handle. Took ${elapsed.inMilliseconds}ms',
      );

      await client.dispose();
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('R6 C-01: the header restore drains before it writes', () async {
      // Codex's ordering: `03` times out at 5.0s and the `finally` writes
      // `ATH0` immediately, so the late `7E8 03 43 00` at 5.1s completes
      // *`ATH0`'s* completer and is judged "not OK". The genuine `OK` then
      // arrives with nothing pending, is discarded as noise, and silently
      // clears the desync flag — leaving the adapter with headers off and the
      // client believing they are on, with no drain having happened.
      //
      // Every ordinary `send` drains first when the link is out of sync. The
      // restore was the one write that skipped that invariant, on exactly the
      // path that needs it.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
      );

      final client = Elm327Client(
        transport,
        commandTimeout: const Duration(milliseconds: 400),
      );
      expect(await client.connect(), isTrue);

      var lost = 0;
      client.onConnectionLost = () => lost++;

      // Slow from here, so the scan's own command times out and its reply
      // lands afterwards.
      transport.responseLatency = const Duration(seconds: 2);

      await expectLater(
        PollingEngine(client).readDtcs(DtcKind.stored),
        throwsA(isA<Object>()),
      );

      // The property that matters is not that the link dies — draining and
      // restoring cleanly is the better outcome, and is what happens here.
      // It is that the client and the adapter still agree afterwards. If the
      // late `43 00` had been mistaken for the `ATH0` acknowledgement, the
      // adapter would have headers off while the client believed they were on,
      // and the very next reply would be parsed as an addressed frame.
      transport.responseLatency = Duration.zero;
      if (lost == 0 && client.isInitialized) {
        ObdResponse? after;
        try {
          after = await client.sendAddressed(kDefaultHeader, '010C');
        } on Object {
          // Failing loudly is a fine outcome — the link had a command time out
          // and refusing to guess afterwards is the whole design.
        }
        if (after != null && after.isSuccess) {
          expect(
            after.bytes,
            equals([0x41, 0x0C, 0x1A, 0xF8]),
            reason: 'this is the invariant: a read may fail, but it may not '
                'succeed with the wrong bytes. Had the late `43 00` been '
                "mistaken for `ATH0`'s acknowledgement, the adapter would have "
                'headers off while the client expected them on, and this reply '
                'would parse as an addressed frame',
          );
        }
      }

      await client.dispose();
    });
  });

  group('who reported a fault is part of the fault', () {
    test('R6 M-01: two controllers reporting one code are two observations',
        () async {
      // The parser has both source IDs; the read used to build source-less
      // codes and deduplicate globally, so the engine and the transmission
      // both seeing P0300 collapsed into one anonymous entry. Knowing that two
      // modules see a misfire is different information from knowing that
      // something does — often the difference between one fault and two.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x01, 0x03, 0x00]},
          ),
          FakeEcu(
            name: 'TCM',
            requestId: '7E1',
            responseId: '7E9',
            responses: {'03': [0x43, 0x01, 0x03, 0x00]},
          ),
        ],
      );

      final engine = await _connect(transport);
      final codes = await engine.readDtcs(DtcKind.stored);
      await engine.dispose();

      expect(codes.map((d) => d.code).toList(), equals(['P0300', 'P0300']));
      expect(
        codes.map((d) => d.sourceId).toSet(),
        equals({'7E8', '7E9'}),
        reason: 'each observation names the controller that made it',
      );
    });
  });

  group('a pause interrupts discovery rather than answering it', () {
    test('R6 regression: backgrounding mid-discovery does not kill batching',
        () async {
      // The foreground policy was extended to support discovery so it would
      // stop questioning the vehicle from the background. It did that by
      // breaking out of the loop — after `_verifiedSupportBlocks.clear()` had
      // already run. So a five-second background window during discovery left
      // the verified set permanently empty, batching never opened, and fast
      // mode was dead for the session: exactly the failure the batching gate
      // was added to prevent, re-entered through the pause that was added to
      // stop discovery leaking into the background.
      //
      // Nothing would have asked again, either. `_connectInner` fires
      // discovery once.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: _physicsReplies(),
          ),
        ],
      );

      final engine = await _connect(transport);

      // Foreground for one block, then backgrounded.
      var allowed = 1;
      engine.shouldContinue = () => allowed-- > 0;

      await engine.discoverSupportedPids();
      expect(engine.supportDiscoveryComplete, isFalse,
          reason: 'interrupted is not finished');
      final afterFirst = engine.supportedPids;
      expect(afterFirst, isNotEmpty,
          reason: 'sanity: one block did answer before the pause');

      // Resumed and immediately backgrounded again — the case that used to
      // destroy what the first attempt had learned, because discovery began
      // by clearing the verified set.
      allowed = 0;
      await engine.discoverSupportedPids();

      expect(
        engine.supportedPids,
        isNotEmpty,
        reason: 'a second interruption must not erase what the first attempt '
            'established; an empty verified set keeps batching shut for the '
            'rest of the session and nothing else would ask again',
      );

      // And once it is left alone it finishes.
      allowed = 99;
      await engine.discoverSupportedPids();
      expect(engine.supportDiscoveryComplete, isTrue);

      await engine.dispose();
    });
  });

  group('formula dependencies are followed all the way down', () {
    test('a dependency of a dependency is scheduled too', () async {
      // Scheduling only the first level leaves the chain broken one link down,
      // which shows up as a formula error on a gauge whose own reference was
      // satisfied — the confusing half of a half-fix.
      //
      // The shipped boost gauge is `A-VAL{0133}`, so `0133` must be polled;
      // this asserts the walk rather than the single case.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._physicsReplies(),
              // The `0120` mask has to *declare* 0133 or the poller filters it
              // out as unsupported — which is correct behaviour, and which
              // masked this test's real subject until the fixture said so.
              // PID 0x33 is bit 18 of the 0120 block: third mask byte, 0x20.
              '0120': [0x41, 0x20, 0x80, 0x00, 0x20, 0x01],
              '0133': [0x41, 0x33, 0x63], // 99 kPa ambient
            },
          ),
        ],
      );

      final engine = await _connect(transport);
      await engine.discoverSupportedPids();
      engine.setActivePids([PidLibrary.boostPressure]);
      engine.start();
      // Waits for a *value*, not merely a verdict. The first evaluation of a
      // `VAL{}` gauge legitimately fails — its dependency has not been read
      // yet — and settling on that fault would stop before the cycle that
      // makes it work, which is the behaviour under test.
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (engine.current.readings[PidLibrary.boostPressure.id] == null &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await engine.stop();
      final log = transport.commandLog.map((c) => c.toUpperCase()).toList();
      final value = engine.current.readings[PidLibrary.boostPressure.id]?.value;
      await engine.dispose();

      expect(
        log.any((c) => c.startsWith('01') && c.contains('33')),
        isTrue,
        reason: 'the reference names 0133, so 0133 has to be asked for. '
            'Commands: $log',
      );
      // MAP 100 kPa minus ambient 99 kPa.
      expect(value, isNotNull);
      expect(value, closeTo(1, 0.001));
    });

    test('a circular reference does not hang the poll set', () {
      // `A` referencing `B` referencing `A` is a definition a user can write.
      // Assembling the poll set must terminate regardless; the formula engine
      // reports the unresolvable reference separately.
      final engine = PollingEngine(Elm327Client(DemoTransport()));
      const a = Pid(
        name: 'a', shortName: 'a', modeAndPid: '2201',
        equation: 'VAL{2202}', minValue: 0, maxValue: 1, units: '',
        isCustom: true,
      );
      const b = Pid(
        name: 'b', shortName: 'b', modeAndPid: '2202',
        equation: 'VAL{2201}', minValue: 0, maxValue: 1, units: '',
        isCustom: true,
      );
      engine.setActivePids([a, b]);
      expect(engine.isRunning, isFalse);
    });
  });

  group('an expired owner may not write, or transmit', () {
    // R7 H-04 — the definition-generation guard — has no test here, and that
    // is deliberate rather than an omission. The first attempt asserted that a
    // removed variant gains no reading, and passed with the guard removed: at
    // the moment the definitions were swapped no request from the old set
    // happened to be in flight, so the trigger never fired. Making it fire
    // needs control over *which* PID is outstanding when the swap lands, which
    // the scheduler does not offer.
    //
    // A test that passes either way is worse than none — it is the exact
    // failure mode this file's header is about — so it was removed rather than
    // adjusted until it went green. The guard is reasoned, not demonstrated,
    // and `docs/verification/test-evidence.md` says so.

    test('R7 H-07: a backgrounded session puts nothing on the bus', () async {
      // Lifecycle was checked by the callers, which is not where the bytes go
      // out. A loop parked on a command refills and transmits once more before
      // anything notices the epoch moved; a pending retry sleeps two seconds
      // and sends again with no lifecycle token at all; a queued Mode 04
      // reaches the head of the chain after the screen that asked for it has
      // gone — and a clear is state-changing.
      //
      // The serialized chain is the only place that sees every write.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '04': [0x44]},
          ),
        ],
      );
      final client = Elm327Client(transport,
          commandTimeout: const Duration(milliseconds: 200));
      expect(await client.connect(), isTrue);

      var foreground = true;
      client.mayTransmit = (_) => foreground;
      foreground = false;
      final before = transport.commandLog.length;

      await expectLater(
        client.sendGlobal('04'),
        throwsA(isA<OperationRetiredException>()),
        reason: 'a clear that reaches the wire after the app has gone is a '
            'state change nobody is watching',
      );
      expect(transport.commandLog.length, before,
          reason: 'and not one byte went out');
      await client.dispose();
    });

    test('R11-codex 09: the legacy header restore is exempt too', () async {
      // Codex round 11's coverage note. The only test for the `ATH0`
      // exemption exercised the CAN branch; `sendGlobal` has a second,
      // separate restore for buses with no functional header, and its
      // exemption could have been removed without a failure.
      final transport = FakeElm327(
        protocol: BusProtocol.j1850vpw,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '686AF1',
            responseId: '486BF1',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
      );
      final client = Elm327Client(transport,
          commandTimeout: const Duration(milliseconds: 400));
      expect(await client.connect(), isTrue);

      final before = transport.commandLog.length;
      // The legacy branch is two writes, not three: ATH1 and the service.
      client.mayTransmit = (_) => transport.commandLog.length < before + 2;

      await client.sendGlobal('03').then<void>((_) {}).catchError((Object _) {});

      expect(transport.commandLog.skip(before), contains('ATH0'),
          reason: 'a legacy bus leaves the adapter as it found it too');
      await client.dispose();
    });

    test('R11-codex 07: an expired request does not sit through a resync',
        () async {
      // Codex round 11. `sendGlobal` ran the fixed three-second `_resync`
      // before any write consulted the lease or the deadline, so a caller
      // whose budget had already passed performed recovery work, blocked
      // newer commands, and — on a link that stays quiet — tore the session
      // down on behalf of work nobody was waiting for.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        faults: const AdapterFaults(swallowPromptFor: {'010C'}),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
      );
      final client = Elm327Client(transport,
          commandTimeout: const Duration(milliseconds: 200));
      expect(await client.connect(), isTrue);
      // Leaves the link out of sync, which is the precondition.
      await client.send('010C').then<void>((_) {}).catchError((Object _) {});

      final started = DateTime.now();
      await expectLater(
        client.sendGlobal('03',
            deadline: DateTime.now().subtract(const Duration(seconds: 1))),
        throwsA(anything),
      );
      expect(DateTime.now().difference(started).inMilliseconds, lessThan(1500),
          reason: 'refused immediately, rather than after a three-second '
              'recovery run for a caller that had already gone');
      expect(client.isInitialized, isTrue,
          reason: 'and the session survives, because nothing tore it down on '
              'behalf of expired work');
      await client.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R15-codex 05: the link survives long enough to recover', () async {
      // Codex round 15's coverage note. The grace window added last round had
      // no test at all: the existing short-deadline case disposes the client
      // immediately and never reaches a watchdog tick, so removing the field
      // *and* the watchdog branch left it green.
      //
      // What the branch is for: the caller's 50 ms expiring is not the
      // adapter's three seconds expiring, and the watchdog has to know that or
      // it kills the session one tick later — just before the valid prompt
      // arrives.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
      );
      var lost = 0;
      final client = Elm327Client(transport,
          commandTimeout: const Duration(milliseconds: 200),
          watchdogTimeout: const Duration(milliseconds: 300))
        ..onConnectionLost = () => lost++;
      expect(await client.connect(), isTrue);
      // Truly silent, not "answered without a prompt": the watchdog only
      // counts silence against a command the adapter still owes, and bytes
      // that arrived are bytes.
      transport.goSilent = true;
      await client.send('010C').then<void>((_) {}).catchError((Object _) {});

      await expectLater(
        client.sendGlobal('03',
            deadline: DateTime.now().add(const Duration(milliseconds: 50))),
        throwsA(anything),
      );

      // A watchdog tick passes first, with the link still silent. This is the
      // order that matters: the tick is where the session used to die, one
      // beat before the adapter finally answered.
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(lost, 0, reason: 'nobody was told the link died');
      expect(client.isInitialized, isTrue,
          reason: 'the caller gave up; the adapter still has its window');

      // And now the prompt it owed, inside the three seconds this client
      // allows a resync.
      transport.goSilent = false;
      transport.emitBytes(ascii.encode('\r>'));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      final recovered = await client.send('010D');
      expect(recovered.isSuccess, isTrue,
          reason: 'and it is usable again, which is the whole point of not '
              'tearing it down');
      await client.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R13-codex 05: running out of time is not the adapter dying',
        () async {
      // Codex round 13, on round 12's resync clamp. Shortening the drain
      // window to the caller's budget was right; running the full link-death
      // path when *that* window expires was not. Fifty milliseconds of
      // remaining budget proves this caller can no longer wait — not that an
      // adapter whose valid prompt is 100 ms away has failed a three-second
      // contract.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        faults: const AdapterFaults(swallowPromptFor: {'010C'}),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
      );
      var lost = 0;
      final client = Elm327Client(transport,
          commandTimeout: const Duration(milliseconds: 200))
        ..onConnectionLost = () => lost++;
      expect(await client.connect(), isTrue);
      await client.send('010C').then<void>((_) {}).catchError((Object _) {});

      await expectLater(
        client.sendGlobal('03',
            deadline: DateTime.now().add(const Duration(milliseconds: 50))),
        throwsA(anything),
      );
      expect(lost, 0,
          reason: 'nobody was told the link died, because it did not');
      expect(client.isInitialized, isTrue,
          reason: 'and the session is still usable by whoever comes next');
      await client.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R10-codex 07: the header restore survives the exchange it belongs to',
        () async {
      // Codex, round 10. The two `ATH0` restores omit `owner` and `deadline`,
      // which was meant to exempt them — and does not. `_sendNow` still asks
      // `mayTransmit(null)`, and the production gate refuses *every* owner
      // while the app is backgrounded.
      //
      // So a scan interrupted after `ATH1` leaves the adapter printing headers
      // for the rest of the session. The service completer has already
      // completed, so nothing surfaces; the poll loop just pays the extra
      // bytes on every reply from then on.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
      );
      final client = Elm327Client(transport,
          commandTimeout: const Duration(milliseconds: 400));
      expect(await client.connect(), isTrue);

      // ATH1, ATSH and the service pass; anything after them would not.
      //
      // Counted from the wire, not from how many times the gate is consulted:
      // `sendGlobal` asks once before it starts as well as once per write, and
      // a test that counts questions instead of answers breaks whenever the
      // number of questions changes for an unrelated reason.
      final before = transport.commandLog.length;
      client.mayTransmit = (_) => transport.commandLog.length < before + 3;

      await client.sendGlobal('03');

      expect(transport.commandLog.skip(before), contains('ATH0'),
          reason: 'the exchange turned headers on, so the exchange puts them '
              'back — that is the one write that must outlive it');
      await client.dispose();
    });

    test('R9-codex M-01: a header switch and its query are one transaction',
        () async {
      // Codex. `sendOnHeader` is two writes, and the lifecycle gate sat
      // between them. Backgrounding while `ATSH E410F1` was awaiting its `OK`
      // let the acknowledgement land — so the client committed to the custom
      // header — and then refused the query. The adapter and the client are
      // both left pointed at an address nobody is going to move.
      //
      // Refusing a read that finishes work already begun buys nothing. What
      // the gate is for is a state-changing Mode 04 reaching the wire for a
      // screen that has gone, and that is refused at the first write of its
      // exchange, which is where the decision belongs.
      final transport = FakeElm327(
        protocol: BusProtocol.j1850vpw,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '686AF1',
            responseId: '486BF1',
            responses: {..._physicsReplies()},
          ),
          FakeEcu(
            name: 'TCM',
            requestId: 'E410F1',
            responseId: '486B10',
            responses: {'221234': [0x62, 0x12, 0x34, 0x2A]},
          ),
        ],
      );
      final client = Elm327Client(transport,
          commandTimeout: const Duration(milliseconds: 400));
      expect(await client.connect(), isTrue);

      // The lifecycle turns against this operation between its two writes:
      // the `ATSH` passes, and everything after it would not.
      var writes = 0;
      client.mayTransmit = (_) => ++writes <= 1;

      final reply = await client.sendOnHeader('E410F1', '221234');
      expect(reply.isSuccess, isTrue,
          reason: 'the adapter had already been moved; abandoning the query '
              'leaves that true and gains nothing');
      expect(transport.commandLog, contains('221234'));
      await client.dispose();
    });

    test('R9-codex C-04: a clear abandoned before backgrounding stays abandoned '
        'after resume', () async {
      // Codex ran this against the production code and got `sent04=true`, with
      // the tail `[ATDPN, ATRV, ATH1, ATSH7DF, 04, ATH0]`. The test above only
      // covers a session that goes to the background and stays there.
      //
      // `mayTransmit` asked "is this session in the foreground *right now*",
      // and resuming makes that true again — for a clear queued minutes ago,
      // for a screen the user has since left. The refusal held for exactly as
      // long as the app was away and then let go. Mode 04 erases the vehicle's
      // fault memory and resets its readiness monitors; there is no taking it
      // back, and nobody is looking at the screen that would report it.
      //
      //   t0  clear queued behind a slow command, lease taken at epoch 0
      //   t1  app backgrounded    → foreground false, epoch 1
      //   t2  app resumed         → foreground TRUE, epoch still 1
      //   t3  chain drains, the clear reaches the head
      //
      // At t3 the old question answers yes. The lease is what survives the
      // round trip, because the epoch only ever advances.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '04': [0x44]},
          ),
        ],
      );
      final client = Elm327Client(transport,
          commandTimeout: const Duration(milliseconds: 400));
      expect(await client.connect(), isTrue);

      var foreground = true;
      var epoch = 0;
      // The shape `ObdSession` installs. `owner == null` is the polling loop,
      // which holds no lease because its writes are repeatable reads.
      client.mayTransmit =
          (owner) => foreground && (owner == null || owner == epoch);

      final engine = PollingEngine(client)..lifecycleEpoch = () => epoch;

      // Occupy the chain so the clear has somewhere to queue, exactly as a
      // poll in flight would.
      transport.slowCommands['ATRV'] = const Duration(milliseconds: 120);
      final parked = client.send('ATRV');

      final clear = engine.clearDtcs();
      // Backgrounded, then resumed, while the clear is still queued.
      foreground = false;
      epoch++;
      foreground = true;

      await expectLater(
        clear,
        throwsA(isA<OperationRetiredException>()),
        reason: 'the user left this screen; coming back to a different one '
            'does not re-authorise the clear they walked away from',
      );
      await parked.then<void>((_) {}).catchError((Object _) {});
      expect(transport.commandLog, isNot(contains('04')),
          reason: 'the vehicle must not have been cleared');
      await engine.dispose();
    });
  });

  group('two discoveries cannot undo each other', () {
    test('R7 H-05: a slow run cannot erase what a fast one established',
        () async {
      // Codex's trigger. The initial discovery is unawaited and a resume
      // starts another, so two can overlap — and each took a local snapshot of
      // `_supported` at entry and assigned it back wholesale at the end. The
      // later finisher won whatever it had learned.
      //
      // The damage is not the missing bits. `_verifiedSupportBlocks` is shared
      // and additive, so it still records that those blocks were verified —
      // and `_knownUnsupported` may only declare a PID absent *inside* a
      // verified block. So every PID the race erased is presented to the user
      // as one the vehicle does not have, on the strength of evidence that was
      // gathered and then thrown away.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      final engine = await _connect(transport);

      // Two overlapping runs, started without awaiting the first — which is
      // exactly how `_connectInner` and a resume arrange them.
      final a = engine.discoverSupportedPids();
      final b = engine.discoverSupportedPids();
      final resultA = await a;
      final resultB = await b;

      expect(identical(resultA, resultB), isTrue,
          reason: 'the second caller joins the first rather than starting a '
              'rival that can finish later with less');
      expect(resultA, contains('010C'),
          reason: 'the vehicle answered `0100`, and nothing may take that '
              'back');

      // And a later interrupted run cannot subtract from it.
      engine.shouldContinue = () => false;
      final afterPause = await engine.discoverSupportedPids();
      expect(afterPause, contains('010C'),
          reason: 'a run that was stopped before asking anything has learned '
              'nothing, and learning nothing is not evidence of absence');
      await engine.dispose();
    });
  });

  group('the simulator may not be kinder or crueller than the hardware', () {
    test('R7 F-17: the fake honours ATS0 instead of only acknowledging it',
        () async {
      // The app's handshake sends `ATS0`, so every real adapter answers
      // without spaces — and the primary oracle said OK and kept printing
      // them. The suite was certifying the one rendering real hardware never
      // produces, which is the same "agreed and did nothing" defect round 6
      // caught in `DemoTransport`.
      //
      // Unspaced output is genuinely harder: the client's own comment notes
      // that `4100BE3FA813` can be read as a 29-bit identifier plus two bytes.
      // That is the reading these tests should have been exercising.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      final client = Elm327Client(transport);
      expect(await client.connect(), isTrue);

      final reply = await client.send('010C');
      expect(reply.isSuccess, isTrue,
          reason: 'and it still parses, which is the point of the change');
      expect(reply.rawLines.single, isNot(contains(' ')),
          reason: 'ATS0 was acknowledged, so the adapter owes unspaced output');
      expect(reply.bytes, [0x41, 0x0C, 0x1A, 0xF8]);
      await client.dispose();
    });

    test('R7 F-8: the demo support mask agrees with the demo, exactly',
        () async {
      // Fable's finding, checked bit by bit. The mask was hand-written beside
      // the handler and had drifted in both directions.
      //
      // Answered but denied: fuel pressure `0A`, EGR `2C`, ambient `46`, oil
      // temperature `5C`, fuel rate `5E` — five *shipped* gauges. Add one
      // mid-session and it was struck off as "this vehicle does not have that
      // sensor", decided by the simulator this project uses to verify its own
      // UI. The ones present from the start survived only because
      // `_answeredAtLeastOnce` happened to record them first: a timing bet.
      //
      // Claimed but silent: twenty-one PIDs. A custom definition on any of
      // them joined a batch, the reply came back short, and fast mode went off
      // for the session — the failure round 6's batching gate exists to
      // prevent, manufactured by the simulator itself.
      final transport = DemoTransport();
      final client = Elm327Client(transport);
      expect(await client.connect(), isTrue);
      final engine = PollingEngine(client);
      final supported = await engine.discoverSupportedPids();

      // Every PID the simulator answers must be in the map it publishes.
      for (final code in ['0A', '2C', '46', '5C', '5E', '0C', '0D']) {
        final reply = await client.send('01$code');
        if (!reply.isSuccess || reply.bytes.isEmpty) continue;
        expect(supported, contains('01$code'),
            reason: '01$code is answered, so the map may not deny it');
      }

      // And every PID it claims must be one it answers.
      for (final id in supported) {
        final reply = await client.send(id);
        expect(reply.isSuccess && reply.bytes.isNotEmpty, isTrue,
            reason: '$id is claimed by the support map and must be answered');
      }
      await engine.dispose();
      await client.dispose();
    });
  });

  group('a widthless slice is bounded by the reply, not by a byte search', () {
    Future<PollingEngine> pollCustom(
      List<String> lines,
      Pid custom, {
      required bool Function(PollingEngine) settled,
    }) async {
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '686AF1',
            responseId: '486B10',
            responses: {..._physicsReplies()},
            literalResponses: {custom.modeAndPid: lines},
          ),
        ],
      );
      return _poll(transport, [custom], settled: settled);
    }

    test('R7 H-03: a delayed reply for another PID cannot supply bytes',
        () async {
      // Codex's contamination trigger. Custom `0111` uses formula `C`; its own
      // reply has two data bytes, and a delayed `0112` answer lands before the
      // same prompt. Flattened, that is `41 11 40 00 41 12 3C` — the old scan
      // looked only for a second `41 11`, found none, and the five-byte tail
      // cleared its length cap. Formula `C` then read the unrelated service
      // byte `0x41` and published 65.
      //
      // Without the contaminating frame the requested reply had no `C` byte at
      // all and should have failed. A wrong number was manufactured out of a
      // missing one.
      final custom = _pid('0111', 'C', variant: 'thirdbyte', isCustom: true);
      final engine = await pollCustom(
        ['41 11 40 00', '41 12 3C'],
        custom,
        settled: (e) => _decided(e, custom.id),
      );
      expect(engine.current.readings[custom.id], isNull,
          reason: 'the answer to this question did not contain a third byte, '
              "and another question's answer is not a substitute");
      expect(engine.current.faults[custom.id], isNotNull,
          reason: 'and the absence is visible rather than filled in');
      await engine.dispose();
    });

    test('R7 H-03: data that happens to look like an envelope is still read',
        () async {
      // The over-refusal, and the reason a byte sentinel alone cannot do this
      // job. One controller legitimately answers custom `010C` with
      // `41 0C 41 0C`: the data bytes are `41 0C`, which is 4163 rpm under the
      // standard formula. The old scan mistook them for a second responder and
      // threw the reading away.
      //
      // What separates the two is not the bytes but what follows them. A
      // second responder's envelope must be followed by data; these two bytes
      // end the frame.
      final custom = _pid('010C', '((A*256)+B)/4', variant: 'rpm', isCustom: true);
      final engine = await pollCustom(
        ['41 0C 41 0C'],
        custom,
        settled: (e) => _decided(e, custom.id),
      );
      expect(engine.current.readings[custom.id]?.value, closeTo(4163, 1),
          reason: 'refusing what the vehicle demonstrably answered is the '
              'same failure pointing the other way');
      await engine.dispose();
    });
  });

  group('a formula is not a wire schema, in either direction', () {
    test('R7 H-02: an unknown-width custom PID never joins a batch', () async {
      // Codex's trigger, and the number it produces is the point: not a
      // failure, a plausible wrong reading on a gauge nobody would question.
      //
      // A custom formula says which bytes its author cares about, not how many
      // the wire carries. Batch a PID on that guess and the boundaries move:
      // a `010C` defined as `A` beside `010D` turns
      //
      //     41 0C 1A 0D 0D 00
      //
      // into "RPM 26, speed 13" for a stationary car — the width of one
      // consumes `1A`, the RPM low byte `0D` is mistaken for the next PID
      // identifier, the real identifier becomes its data. Every structural
      // check passes. `dataByteCount` said this already — "a guess, and is why
      // a PID without a declared width never joins a batch" — and nothing
      // enforced it.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._physicsReplies(),
              '0111': [0x41, 0x11, 0x40, 0x00],
            },
          ),
        ],
      );

      final engine = await _connect(transport);
      // Awaited, because `canBatch` stays shut until a support block has been
      // verified — and a test asserting "no batch went out" while batching was
      // switched off would pass without touching the defect. That failure mode
      // is this file's own header warning, and it caught this test first time.
      await engine.discoverSupportedPids();

      final custom = _pid('0111', 'A', variant: 'throttle', isCustom: true);
      engine.setActivePids([custom, _pid('010D', 'A')]);
      engine.start();
      await Future<void>.delayed(const Duration(seconds: 2));
      await engine.stop();

      final batched = transport.commandLog
          .where((c) => c.startsWith('01') && c.length > 4)
          .where((c) => c != '0100' && c != '0120' && c != '0140')
          .toList();
      // The positive control. Without it the assertion below is satisfied by
      // batching never happening at all.
      expect(batched, isNotEmpty,
          reason: 'batching has to be live for the exclusion to mean '
              'anything. Commands: ${transport.commandLog}');
      expect(
        batched.where((c) => c.substring(2).contains('11')),
        isEmpty,
        reason: 'the custom PID whose width is a guess must be alone in its '
            'request. Batched: $batched',
      );
      expect(engine.current.readings[custom.id]?.value, 64,
          reason: 'and polled singly it still reads, because refusing what the '
              'vehicle answers is the opposite error',
      );
      await engine.dispose();
    });

    test('R7 H-02: answering once proves existence, not width', () async {
      // `_answeredAtLeastOnce` is real evidence and overrules any support map
      // — but it is evidence that the PID exists, not that its reply is one
      // byte wide. Licensing a batch on the strength of it reintroduced the
      // whole defect one poll cycle later.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._physicsReplies(),
              '0111': [0x41, 0x11, 0x40, 0x00],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverSupportedPids();
      final custom = _pid('0111', 'A', variant: 'throttle', isCustom: true);
      engine.setActivePids([custom, _pid('010D', 'A')]);
      engine.start();
      // Long enough that the custom PID has certainly answered several times.
      await Future<void>.delayed(const Duration(seconds: 3));
      await engine.stop();

      expect(engine.current.readings[custom.id], isNotNull,
          reason: 'sanity: it has answered, which is the premise');
      expect(
        transport.commandLog
            .where((c) => c.startsWith('01') && c.length > 4)
            .where((c) => c.substring(2).contains('11')),
        isEmpty,
        reason: 'still alone, however many times it has answered',
      );
      await engine.dispose();
    });
  });

  group('a bus this app cannot read is refused everywhere, and says why', () {
    test('R9-kimi: J1939 telemetry is refused, not parsed', () async {
      // The J1939 split was wired into the fault-code and VIN reads and into
      // the tests, and not into the telemetry path it was about. On a
      // permissive bridge that lets the `0100` probe through, `010C` still
      // went out and anything that happened to parse became a gauge value.
      final transport = FakeElm327(
        protocol: BusProtocol.can29,
        forceProtocolNumber: 'A',
        ecus: [
          FakeEcu(
            name: 'bridge',
            requestId: '18DA10F1',
            responseId: '18DAF110',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      final rpm = _pid('010C', '((A*256)+B)/4');
      final engine = await _poll(
        transport,
        [rpm],
        settled: (e) => _decided(e, rpm.id),
      );
      expect(engine.current.readings[rpm.id], isNull,
          reason: 'a J1939 bus does not answer J1979 questions, and anything '
              'that parses as one is a coincidence');
      expect(engine.current.faults[rpm.id], PidFault.busError);
      await engine.dispose();
    });

    test('R10-codex 09: the clear refuses J1939 like its siblings do', () async {
      // Codex, round 10. `_busRefusal` guarded the fault-code read, the VIN
      // read, the poll loop and (since qwen) both probes — and not the one
      // request that changes the vehicle. J1939 has no Mode 04, and a
      // permissive bridge that answers the handshake is exactly how the app
      // ends up here.
      final transport = FakeElm327(
        protocol: BusProtocol.can29,
        forceProtocolNumber: 'A',
        ecus: [
          FakeEcu(
            name: 'bridge',
            requestId: '18DA10F1',
            responseId: '18DAF110',
            responses: {..._physicsReplies(), '04': [0x44]},
          ),
        ],
      );
      final engine = await _connect(transport);
      final before = transport.commandLog.length;

      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.message, 'message', contains('J1939'))),
      );
      expect(transport.commandLog.skip(before), isNot(contains('04')),
          reason: 'nothing state-changing goes out on a bus this app has '
              'already decided it cannot read');
      await engine.dispose();
    });

    test('R9-qwen: the two probes that run first refuse J1939 too', () async {
      // qwen. The J1939 refusal reached the fault-code read, the VIN read and
      // the poll loop, and left behind the two probes that run *before* any of
      // them: the support discovery and the responder census. Both send
      // `0100`, which is as much a J1979 request as `010C` is — and a
      // permissive bridge answering it is what convinced the app it had an
      // OBD-II vehicle to begin with.
      //
      // The sibling shape again, and this time the siblings ran first.
      final transport = FakeElm327(
        protocol: BusProtocol.can29,
        forceProtocolNumber: 'A',
        ecus: [
          FakeEcu(
            name: 'bridge',
            requestId: '18DA10F1',
            responseId: '18DAF110',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      final engine = await _connect(transport);
      final before = transport.commandLog.length;

      expect(await engine.discoverResponders(), isNull);
      expect(await engine.discoverSupportedPids(), isEmpty);

      expect(transport.commandLog.skip(before), isEmpty,
          reason: 'nothing was asked of a bus this app has already decided it '
              'cannot read');
      await engine.dispose();
    });

    test('R9-kimi: the refusal says J1939, not "reconnect"', () async {
      // "Not determined yet" is temporary and reconnecting may fix it. J1939
      // is determined, permanent, and telling its owner to reconnect sends
      // them round a loop with no exit — which is what both refusals said,
      // because `supportsObd2` was added and then wired to nothing.
      final transport = FakeElm327(
        protocol: BusProtocol.can29,
        forceProtocolNumber: 'A',
        ecus: [
          FakeEcu(
            name: 'bridge',
            requestId: '18DA10F1',
            responseId: '18DAF110',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      final engine = await _connect(transport);
      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()
            .having((e) => e.message, 'message', contains('J1939'))),
      );
      expect(await engine.readVin().catchError((Object e) => null), isNull);
      await engine.dispose();
    });
  });

  group('one finaliser owns every successful return', () {
    test('R9-codex C-01a: a settled debt does not skip the coverage check',
        () async {
      // Codex. There were two successful exits — the straight-line one and the
      // one that notices the pending debt has settled — and the coverage and
      // attribution rules were placed on the first only. Twelfth time this
      // project has put a new rule on one branch and not its sibling.
      //
      //   census      {7E8, 7E9, 7EA}
      //   attempt 1   7E8 clean, 7E9 pending, 7EA silent
      //   attempt 2   7E8 pending, 7E9 clean, 7EA still silent
      //
      // The debt settles, the early return fires, and `7EA` — a controller
      // this session has *seen*, holding a stored fault — is never compared
      // against anything. Green panel.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies()},
          ),
          FakeEcu(
            name: 'TCM',
            requestId: '7E1',
            responseId: '7E9',
            responses: {'0100': [0x41, 0x00, 0x80, 0x00, 0x00, 0x00]},
          ),
          FakeEcu(
            name: 'ABS',
            requestId: '7E2',
            responseId: '7EA',
            responses: {'0100': [0x41, 0x00, 0x80, 0x00, 0x00, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      expect(await engine.discoverResponders(),
          containsAll(['7E8', '7E9', '7EA']));

      transport.forceReplySequence('03', [
        '7E8 02 43 00\r7E9 03 7F 03 78',
        '7E8 03 7F 03 78\r7E9 02 43 00',
      ]);

      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()),
        reason: 'the debt settling says nothing about the controller that '
            'never entered the conversation',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('R9-codex C-01b: a settled debt does not skip attribution', () async {
      // The same exit, the other rule. On a legacy bus with `ATH1` refused
      // every frame carries `''` as its source, so a clean responder and a
      // pending one settle each other's debt trivially — and the early return
      // went past the attribution qualification too.
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        faults: const AdapterFaults(refuseHeaders: true),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '686AF1',
            responseId: '486B10',
            responses: {..._physicsReplies()},
            literalResponses: {
              '03': ['43 00 00 00 00 00 00', '7F 03 78'],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()),
        reason: 'two indistinguishable controllers cannot produce a verified '
            'all-clear between them',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('an operation owns its window, it does not sample it', () {
    test('R8 C-05: a retry that slept through an interruption does not resume',
        () async {
      // GPT-5.6 Pro. `mayTransmit` asks "is this session in the foreground
      // right now", which is a sample and not an ownership claim — the same
      // sampling-versus-counting defect as F-15, one layer down.
      //
      // A Mode 03 retry sleeps two seconds. The app backgrounds and resumes
      // inside that sleep. The gate sees a foreground session and an unchanged
      // connection generation, so the retry transmits on behalf of a scan
      // whose screen is gone — and its result lands against whatever is on the
      // bus by then.
      //
      // The poll loop was never exposed to this: a pause calls `stop()`, which
      // retires it by epoch. The fault-code operations run outside that loop
      // and had nothing.
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '686AF1',
            responseId: '486B10',
            responses: {..._physicsReplies()},
            literalResponses: {
              '03': [_withChecksum('486B10 43 00 00 00 00 00 00')],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      // A legacy bus, so the app supplies the wait the adapter does not — the
      // one path that really sleeps between attempts.
      transport.forceReplySequence('03', [_withChecksum('486B10 7F 03 78')]);

      var epoch = 7;
      engine.lifecycleEpoch = () => epoch;
      final read = engine.readDtcs(DtcKind.stored);
      // Backgrounded and returned while the retry is asleep. Sampling sees
      // nothing wrong by the time it wakes.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      epoch = 8;

      await expectLater(
        read,
        throwsA(isA<DtcReadException>()),
        reason: 'the scan that asked for this is gone; its retry may not '
            'speak for whatever is connected now',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  group('silence is not a clean answer', () {
    test('R8 C-03: a controller that never replies is not a controller with '
        'no faults', () async {
      // GPT-5.6 Pro, and the deepest finding of the round. `ATH1` established
      // who answered; nothing ever established who *should* have.
      //
      // Every completeness check counts something a controller did — answered,
      // refused, promised, sent something unreadable. A controller that says
      // nothing appears in none of them, so a transmission holding P0715 that
      // simply does not reply leaves the engine's `43 00` standing as the
      // whole vehicle's result, under 未偵測到故障碼 and a green panel.
      //
      // `0100` is a functional request every emissions controller answers, so
      // with headers on it is a census.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
          FakeEcu(
            name: 'TCM',
            requestId: '7E1',
            responseId: '7E9',
            // Present on the bus — it answers the census — and then says
            // nothing at all when asked for fault codes.
            responses: {'0100': [0x41, 0x00, 0x80, 0x00, 0x00, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      final census = await engine.discoverResponders();
      expect(census, containsAll(['7E8', '7E9']),
          reason: 'sanity: both controllers answer the functional probe, so '
              'both are known to exist');

      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()),
        reason: 'one controller answering cleanly says nothing about the one '
            'that did not answer at all',
      );
      await engine.dispose();
    });

    test('R8 C-04: a clear one controller ignored is not a clear', () async {
      // The same absence, and it matters more here than in a read. "Every
      // controller that answered acknowledged" is not the question a driver is
      // asking — they want to know whether the fault memory is clear, and a
      // controller that stays silent through Mode 04 has neither acknowledged
      // nor refused.
      //
      // Reporting success sends someone away believing a transmission fault
      // was dealt with by a module that never heard the request, and the light
      // returning weeks later reads as a new problem.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '04': [0x44]},
          ),
          FakeEcu(
            name: 'TCM',
            requestId: '7E1',
            responseId: '7E9',
            // On the bus, and deaf to Mode 04.
            responses: {'0100': [0x41, 0x00, 0x80, 0x00, 0x00, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();

      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()),
        reason: 'and it must not be retried automatically — re-issuing Mode 04 '
            'resets the readiness monitors again and costs another drive '
            'cycle',
      );
      await engine.dispose();
    });

    test('R8 C-03: a census that could not be taken convicts nobody', () async {
      // The other half, and the one that stops this becoming the
      // over-strictness round 6 spent itself undoing. An adapter that will not
      // print headers cannot produce a census — and "no census" is a different
      // claim from "an empty census". A vehicle must not be refused because
      // the adapter is limited.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        faults: const AdapterFaults(refuseHeaders: true),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      expect(await engine.discoverResponders(), isNull,
          reason: 'no headers, no census — and that is an absence of '
              'evidence, not evidence of absence');
      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>().having(
            (e) => e.kind, 'kind', DtcReadFailure.unattributed)),
        reason: 'it still degrades, for the reason it already had — but not '
            'for a census nobody could take',
      );
      await engine.dispose();
    });

    test('R17-codex 04: a fixture that cannot happen is refused', () {
      // Codex round 17's coverage note. The guard that stops two legacy fake
      // ECUs sharing a source address had no test of its own, so it could have
      // been removed and the fixtures it protects would silently go back to
      // meaning something they cannot: on a legacy bus the third header byte
      // *is* the controller, so `486BF1` and `4868F1` are one module, and one
      // of them answering can cover for the other's silence.
      expect(
        () => FakeElm327(
          protocol: BusProtocol.iso9141,
          ecus: [
            FakeEcu(
                name: 'ECM',
                requestId: '686AF1',
                responseId: '486BF1',
                responses: const {}),
            FakeEcu(
                name: 'other',
                requestId: '6818F1',
                responseId: '4868F1',
                responses: const {}),
          ],
        ),
        throwsArgumentError,
      );
    });

    test('R15-codex 04: one KWP controller is one controller', () async {
      // Codex round 15, verified against the datasheet twice over: the three
      // legacy header bytes are "the priority, the receiver, and the
      // transmitter", and "the sender of information is usually shown in the
      // third byte of the header". For ISO 14230-4 the first byte "must always
      // include the length of the data field, which varies from message to
      // message".
      //
      // So the same ECU answering a six-byte census and a seven-byte
      // fault-code request printed `86F110` and `87F110`, and using all six
      // digits as identity made it two controllers — the second reply then
      // refused for the silence of the first.
      //
      // Masked until now by the checksum defect, which failed these replies
      // before coverage was reached.
      final transport = FakeElm327(
        protocol: BusProtocol.kwp2000Fast,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: 'C133F1',
            responseId: '83F110',
            responses: {
              ..._physicsReplies(),
              '03': [0x43, 0x01, 0x33, 0x00],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      final before = transport.commandLog.length;
      await engine.discoverResponders();

      // The census header the fixture actually put on the wire. Asserted,
      // because the point of the test is that this byte *differs* from the
      // next one — and it did not, until the fake stopped padding KWP to a
      // fixed width and every generated header came out `87…`.
      final censusLine = transport.emitted
          .where((line) => line.contains('4100'))
          .last
          .replaceAll(' ', '');
      expect(censusLine.startsWith('86F110'), isTrue,
          reason: 'six data bytes, so the format byte says six: $censusLine');
      expect(before, lessThan(transport.commandLog.length));

      // A different length from the same controller.
      transport.forceReplySequence(
          '03', [_withChecksum('87 F1 10 43 01 33 00 00 00 00')]);
      expect((await engine.readDtcs(DtcKind.stored)).map((c) => c.code),
          ['P0133'],
          reason: 'the controller that answered the census is the controller '
              'that answered this, whatever its reply length was');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R15-codex 03: headerless bytes are not a controller', () async {
      // Codex round 15, on round 14's fix. Preserving visible identity through
      // an adapter error was right; mining headerless payload for addresses is
      // the over-strict sibling of it.
      //
      //   ATH1 -> ?            the adapter will not print headers
      //   03   -> 430207150300 …then an error marker
      //
      // The shared CAN pattern accepts three *or* eight digits, so the
      // eight-digit alternative consumed `43020715` as a source. A later valid
      // Mode 07 reply was then refused as incomplete, naming a controller that
      // has never existed.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        faults: const AdapterFaults(refuseHeaders: true),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '07': [0x47, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      transport.forceReplySequence('03', ['43 02 07 15 03 00\r<RX ERROR']);
      await engine
          .readDtcs(DtcKind.stored)
          .then<void>((_) {})
          .catchError((Object _) {});

      // The read still degrades — headers off means no attribution — but it
      // must not have invented a responder on the way.
      await expectLater(
        engine.readDtcs(DtcKind.pending),
        throwsA(isA<DtcReadException>().having(
            (e) => e.message, 'message', isNot(contains('43020715')))),
        reason: 'no controller called 43020715 answered anything, because '
            'there is no such controller',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R15-codex 05: a bare header is remembered whichever line it is on',
        () async {
      // Codex round 15's coverage note. The bare-header tests took the
      // identity they needed from a *complete* frame, so the order-independent
      // extraction they were written for could be reverted without a failure.
      //
      // The point of reading every line up front is that rejecting on the
      // first damaged one must not make what is remembered depend on which
      // controller happened to answer first. Both orders, same answer.
      for (final lines in [
        '486B18\r${_withChecksum('486B10 43 00 00 00 00 00 00', j1850: true)}',
        '${_withChecksum('486B10 43 00 00 00 00 00 00', j1850: true)}\r486B18',
      ]) {
        final transport = FakeElm327(
          protocol: BusProtocol.j1850vpw,
          ecus: [
            FakeEcu(
              name: 'ECM',
              requestId: '686AF1',
              responseId: '486B10',
              responses: {..._physicsReplies(), '07': [0x47, 0x00]},
            ),
          ],
        );
        final engine = await _connect(transport);
        await engine.discoverResponders();
        transport.forceReplySequence('03', [lines]);
        await engine
            .readDtcs(DtcKind.stored)
            .then<void>((_) {})
            .catchError((Object _) {});

        // Round 22 changed what this refusal *calls* `18`, and round 23 moved
        // where it is asked. Corroborating a token from a neighbouring line
        // promotes `430` on the strength of an unrelated `7E8`, so `18` is
        // carried as an unresolved address rather than named as a controller;
        // and the whole-vehicle question is asked once, of the vehicle, rather
        // than by every later category — which made one rescan insufficient.
        //
        // What has to survive is that `18` is not forgotten, and that nothing
        // irreversible proceeds while it stands. Both, either order.
        expect(engine.openIdentityQuestions, contains('18'),
            reason: 'controller 18 put its address on the wire; which line it '
                'was on is not information about whether it exists');
        await expectLater(
          engine.clearDtcs(),
          throwsA(isA<DtcReadException>().having(
              (e) => e.message, 'message', contains('未能辨識的位址：18'))),
          reason: 'and a clear measured against everyone *but* 18 is not a '
              'clear',
        );
        await engine.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('R20-codex 03: a bare opposite-width identity is remembered', () async {
      // Codex round 20. The `A1` test only exercised complete frames, so the
      // *bare* branch could regress to the transmit width and stay green —
      // and that branch is what stops a one-controller clear from passing
      // while a module that put its address on the wire still holds its code.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        forceProtocolNumber: 'B',
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._physicsReplies(),
              '03': [0x43, 0x01, 0x03, 0x01],
              '04': [0x44],
            },
          ),
        ],
      )..enabledProgrammableParameters[0x2C] = 0xA1;
      final engine = await _connect(transport);
      await engine.discoverResponders();
      // A 29-bit identity with its payload lost, on a slot that transmits on
      // 11-bit and accepts both.
      transport.forceReplySequence('03', ['7E8 04 43 01 03 01\r18DAF118']);
      await engine
          .readDtcs(DtcKind.stored)
          .then<void>((_) {})
          .catchError((Object _) {});

      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.message, 'message', contains('18DAF118'))),
        reason: 'it is a legal identifier on this slot and it answered '
            'nothing; a clear only the engine acknowledged is not a clear',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R19-codex 06: a legal opposite-width reply is read and remembered',
        () async {
      // Codex round 19. The only PP `A1` test sent an *illegal* eight-digit
      // line and asserted rejection — which stays true if either consumer
      // regresses to the transmit width. This is the positive half: a legal
      // 29-bit reply on an 11-bit-transmit slot, which the adapter was
      // explicitly configured to accept.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        forceProtocolNumber: 'B',
        ecus: [
          FakeEcu(
            name: 'gateway',
            requestId: '7E0',
            responseId: '18DAF110',
            responses: {..._physicsReplies(), '03': [0x43, 0x01, 0x03, 0x01]},
          ),
        ],
      )..enabledProgrammableParameters[0x2C] = 0xA1;
      final engine = await _connect(transport);
      expect(await engine.discoverResponders(), {'18DAF110'},
          reason: 'a 29-bit responder on a slot told to accept both widths is '
              'a responder');
      expect((await engine.readDtcs(DtcKind.stored)).map((c) => c.code),
          ['P0301'],
          reason: 'and its reply is an answer, not a data error');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R18-codex: both widths accepted does not mean any bytes accepted',
        () async {
      // Codex round 18, on round 17's fix. PP 2C bit 5 makes both *valid*
      // widths acceptable; it does not make every eight-digit string a CAN
      // identifier, and it does not prove headers were on.
      //
      //   ATH1 -> OK, and the adapter keeps printing headerless bytes
      //   03   -> 43020715024300
      //
      // Read as source `43020715` with body `02 43 00`, that reassembles into
      // a clean empty answer which then satisfies its own coverage check —
      // while the real payload is `43 02 | 07 15 | 02 43`: P0715 and P0243.
      // `0x43020715` is above the 29-bit maximum and cannot be anyone.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        forceProtocolNumber: 'B',
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies()},
          ),
        ],
      )..enabledProgrammableParameters[0x2C] = 0xA1;
      final engine = await _connect(transport);
      expect(engine.client.addressing.acceptsBothReceiveWidths, isTrue,
          reason: 'sanity: `A1` sets bit 5');
      transport.forceReplySequence('0100', ['4100BE3FA813']);
      await engine.discoverResponders();
      transport.forceReplySequence('03', ['43020715024300']);

      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()),
        reason: 'an identifier that cannot exist is not a controller, and its '
            'body is not an answer',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R19-codex 01: a silent retry does not erase who answered', () async {
      // Codex round 19. `readDtcs` accumulates responders across attempts and
      // then rethrew only the *last* attempt's set. On a retry that got
      // `NO DATA`, that set is empty — so a category one controller had
      // finished cleanly and another had said it was still working on came out
      // as "nobody answered", and the screen offered that as evidence there is
      // probably no fault.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '07': [0x47, 0x00]},
          ),
          FakeEcu(
            name: 'TCM',
            requestId: '7E1',
            responseId: '7E9',
            responses: {'0100': [0x41, 0x00, 0x80, 0x00, 0x00, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.forceReplySequence('07', [
        '7E8 02 47 00\r7E9 03 7F 07 78',
        'NO DATA',
      ]);

      await expectLater(
        engine.readDtcs(DtcKind.pending),
        throwsA(isA<DtcReadException>().having(
            (e) => e.terminalSources, 'terminalSources', contains('7E8'))),
        reason: '7E8 finished this category on the first attempt; a later '
            'attempt hearing nothing does not unhear it',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R20-codex 01: an error marker does not make every token a controller',
        () async {
      // Codex round 20. The parsers classify adapter errors first and return
      // with no frames, so the disposition rule saw an empty list and called
      // every identified token "an identity with no readable payload".
      //
      //   03 -> 008
      //         0:430301030203
      //         1:03030000000000
      //         <RX ERROR
      //
      // `008` is the multi-frame envelope's total length. It is also a legal
      // 11-bit identifier, and it became a controller that every later
      // category was then refused for the silence of.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._physicsReplies(),
              // Present so the *second* stored read can complete. Only a read
              // that reaches its own conclusion replaces a category's doubts;
              // one that fails outright establishes nothing and must not.
              '03': [0x43, 0x00],
              '07': [0x47, 0x00],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.forceReplySequence('03',
          ['008\r0:430301030203\r1:03030000000000\r<RX ERROR']);
      await engine
          .readDtcs(DtcKind.stored)
          .then<void>((_) {})
          .catchError((Object _) {});

      // Round 22 split "not a controller" from "not a question", and round 23
      // moved the second one to the vehicle. `008` is still not a module —
      // nothing is ever refused for *its* silence and it never joins the
      // coverage set — so the optional category closes on its own merits.
      expect(await engine.readDtcs(DtcKind.pending), isEmpty,
          reason: 'a length header is not a module, and no category may be '
              'refused for its silence');

      // The app did see a token it could not account for, though, and nothing
      // irreversible proceeds while that stands.
      expect(engine.openIdentityQuestions, contains('008'));
      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.message, 'message', contains('未能辨識的位址：008'))
            .having(
                (e) => e.message, 'message', isNot(contains('控制器沒有回應')))),
        reason: 'an unaccounted-for reply is an open question, not a silent '
            'module — and a clear may not be measured without it',
      );

      // And the question closes. A *completed* read of the category that
      // raised it replaces that category's doubts, so one corrupted reply
      // does not disable the scan for the rest of the connection — which a
      // latching flag did.
      await engine.readDtcs(DtcKind.stored);
      expect(engine.openIdentityQuestions, isEmpty);
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R21-codex 02: a First Frame keeps its service byte where it is',
        () async {
      // Codex round 21. The disposition path removed exactly one PCI byte and
      // read the next as the service. That is a Single Frame's shape; a First
      // Frame has two PCI bytes, and the parser already knew that — this file
      // had grown a second, wrong copy of the rule.
      //
      // It went wrong in both directions at once. A real Mode 03 First Frame
      // was read at `0x0A` — the low half of the length — so the controller
      // was forgotten; and a Mode 01 First Frame was read at `0x43` — also a
      // length byte — so a controller that never took part became a debt.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '07': [0x47, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();

      // A Mode 03 First Frame from a controller the census never saw.
      transport.forceReplySequence('03', [
        '7E9 10 0A 43 04 07 15 03 00\r7E9 21 01 02 03 04 00 00 00\r<RX ERROR',
      ]);
      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>().having((e) => e.heardAboutService,
            'heardAboutService', contains('7E9'))),
        reason: 'the bytes are not readable and 7E9 plainly answered Mode 03',
      );
      await engine.dispose();

      // The mirror: a Mode 01 First Frame during a Mode 03 exchange, whose
      // length byte happens to be 0x43.
      final other = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '07': [0x47, 0x00]},
          ),
        ],
      );
      final second = await _connect(other);
      await second.discoverResponders();
      other.forceReplySequence(
          '03', ['7EA 10 43 41 00 BE 3F A8 13\r<RX ERROR']);
      await second
          .readDtcs(DtcKind.stored)
          .then<void>((_) {})
          .catchError((Object _) {});
      expect(await second.readDtcs(DtcKind.pending), isEmpty,
          reason: '7EA answered Mode 01; that is not a claim about Mode 07');
      await second.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('R21-codex 01: a clear does not claim success over an unnamed reply',
        () async {
      // Codex round 21. A reply that carried a legal-width token and nothing
      // else leaves a hole: the app refuses to guess whether it was a
      // controller, which is right, and the coverage set then no longer
      // describes everyone who might be out there.
      //
      //   03 -> 7E9
      //         0:430301030203
      //         <RX ERROR
      //   04 -> 7E8 01 44
      //
      // Measuring the acknowledgement against the handshake census alone
      // reported 已送出清除指令 for a module nobody could name.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '04': [0x44]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.forceReplySequence(
          '03', ['7E9\r0:430301030203\r1:03030000000000\r<RX ERROR']);
      await engine
          .readDtcs(DtcKind.stored)
          .then<void>((_) {})
          .catchError((Object _) {});

      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.message, 'message', contains('無法判斷'))),
        reason: 'refusing to guess what that token was is right; reporting a '
            'clear as if the question had never come up is not',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R21-codex 05: a refusal names the service it refused', () async {
      // Codex round 21. Every `7F` frame was counted as a refusal or a pending
      // answer for whatever class was being read. `7E9 03 7F 01 11` is a Mode
      // 01 refusal — counting it reported that a controller had answered Mode
      // 03 and rejected it, about a conversation that never happened.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.forceReplySequence('03', ['7E9 03 7F 01 11']);

      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()
            .having((e) => e.terminalSources, 'terminalSources', isEmpty)),
        reason: 'a Mode 01 refusal is not a Mode 03 answer',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R21-codex 03: an uncorroborated token is not a controller', () async {
      // Codex round 21, and the other half of round 20's fix. A lone hex token
      // of legal width is ambiguous by construction: `430` is a legal 11-bit
      // identifier and also the start of a headerless `43 00`.
      //
      // What separates a real bare identity from a fragment is not the token,
      // it is whether this reply demonstrably has addresses in it at all.
      // Nothing here does, so nothing here is a controller.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._physicsReplies(),
              '03': [0x43, 0x00],
              '07': [0x47, 0x00],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.forceReplySequence('03', ['430\r<RX ERROR']);
      await engine
          .readDtcs(DtcKind.stored)
          .then<void>((_) {})
          .catchError((Object _) {});

      // Round 22 replaced the rule this test was written for. "Whether this
      // reply demonstrably has addresses in it" promotes `430` the moment an
      // unrelated `7E8` line sits beside it — corroboration has to be about
      // the identifier, not its neighbours. So `430` is neither named nor
      // discarded: it is carried as the open question it is.
      expect(await engine.readDtcs(DtcKind.pending), isEmpty,
          reason: 'no controller called 430 answered anything, so no category '
              'is refused for its silence');
      expect(engine.openIdentityQuestions, contains('430'),
          reason: 'and nobody may be told the vehicle was fully covered while '
              'it stands');
      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.message, 'message', contains('未能辨識的位址：430'))
            .having(
                (e) => e.message, 'message', isNot(contains('控制器沒有回應')))),
      );

      await engine.readDtcs(DtcKind.stored);
      expect(engine.openIdentityQuestions, isEmpty,
          reason: 'the reply that carried the token is two reads ago, and the '
              'read that replaced it finished');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R22-codex 01: a continuation frame is coverage, not an answer',
        () async {
      // Codex round 22. A continuation frame carries no service byte at all —
      // that is what makes it a continuation — so the parser reports its
      // service as null. The disposition loop keyed on `bytes.isEmpty`, which
      // a continuation frame is not, so it matched neither branch and the
      // controller disappeared from a scan it had demonstrably taken part in.
      //
      //   03 -> 7E8 04 43 01 03 01
      //         7E9 21 03 01 03 00      <- continuation, no First Frame
      //         <RX ERROR
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '07': [0x47, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.forceReplySequence(
          '03', ['7E8 04 43 01 03 01\r7E9 21 03 01 03 00\r<RX ERROR']);
      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>().having((e) => e.heardAboutService,
            'heardAboutService', isNot(contains('7E9')))),
        reason: 'a continuation frame does not say which service it is '
            'continuing, so it cannot be an answer to this one',
      );

      // Watched through the coverage record, not through a refused optional
      // class.
      //
      // Round 26: Modes 07 and 0A are optional in J1979, so a module that
      // never implements them is a healthy vehicle — and holding every
      // controller to them meant standards-compliant cars could never produce
      // anything but 部分未確認, which on screen is indistinguishable from a
      // broken app. The class completes; what it could not reach is recorded,
      // and the scan's verdict is what consumes that. The property this test
      // is about — a headered frame is a controller, not a token — is
      // unchanged; only where it is visible has moved.
      expect(await engine.readDtcs(DtcKind.pending), isEmpty,
          reason: '7E9 has never answered Mode 07, so its silence there is a '
              'vehicle rather than a fault');
      expect(engine.optionalNotCovered[DtcKind.pending], contains('7E9'),
          reason: 'but it is on this bus, and nothing may call the vehicle '
              'clean without having asked it');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R22-codex 05: padding after a zero-length frame is not an answer',
        () async {
      // Codex round 22. `7E9 00 43 …` is a Single Frame declaring *zero*
      // payload bytes; everything after the PCI is the filler the adapter
      // prints to make eight. Reading offset 1 regardless reported that 7E9
      // had spoken Mode 03 — a fault-code debt invented out of padding, and
      // every later category was then refused for its silence.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '07': [0x47, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.forceReplySequence(
          '03', ['7E8 04 43 01 03 01\r7E9 00 43 00 00 00 00 00\r<RX ERROR']);
      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()
            .having((e) => e.heardAboutService, 'heardAboutService',
                contains('7E8'))
            .having((e) => e.heardAboutService, 'heardAboutService',
                isNot(contains('7E9')))),
        reason: 'the declared length is zero; the 43 after it is filler, and '
            'filler is not a controller answering Mode 03',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R22-codex 04: a headered neighbour does not vouch for a bare token',
        () async {
      // Codex round 22, and the case that retired the round-21 rule. "Does
      // this reply demonstrably have addresses in it" is answered by the
      // *neighbouring* line, so `430` — the start of a headerless `43 00`, and
      // a legal 11-bit identifier — became a controller on the strength of an
      // unrelated `7E8` sitting beside it, and every later category was
      // refused for the silence of something that was never there.
      //
      //   03 -> 7E8 04 43 01 03 01
      //         430
      //         <RX ERROR
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._physicsReplies(),
              '03': [0x43, 0x00],
              '07': [0x47, 0x00],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.forceReplySequence('03', ['7E8 04 43 01 03 01\r430\r<RX ERROR']);
      await engine
          .readDtcs(DtcKind.stored)
          .then<void>((_) {})
          .catchError((Object _) {});

      expect(await engine.readDtcs(DtcKind.pending), isEmpty,
          reason: 'the optional category answers for itself; 430 never became '
              'a controller whose silence it owes an account of');
      expect(engine.openIdentityQuestions, contains('430'));
      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.message, 'message', contains('未能辨識的位址：430'))
            .having((e) => e.message, 'message',
                isNot(contains('控制器沒有回應')))),
        reason: 'corroboration has to be about the identifier, not about what '
            'happened to be printed next to it — and until it arrives the '
            'irreversible operation waits',
      );

      // And it is a question, not a verdict: the reply that carried it is
      // gone, so a completed read of that category answers it.
      await engine.readDtcs(DtcKind.stored);
      expect(engine.openIdentityQuestions, isEmpty);
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('R22-codex 04b: a rescan that failed has not answered anything',
        () async {
      // The other half of making the doubt clearable at all. Scoping it to the
      // category and replacing it on the next read of that category is right;
      // replacing it *on entry* to that read is not, because a read that never
      // reaches its own conclusion has established nothing.
      //
      //   03 -> 7E8 04 43 01 03 01 / 430 / <RX ERROR      doubt raised
      //   03 -> NO DATA                                   nothing learned
      //   04 -> 7E8 01 44                                 已送出清除指令 ?
      //
      // The rescan the error message asks for is the one that *succeeds*.
      // Letting a failed one count made the refusal trivially bypassable, and
      // by an action the app itself recommends.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            // No Mode 03 of its own: the retry gets `NO DATA`.
            responses: {..._physicsReplies(), '04': [0x44]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.forceReplySequence('03', ['7E8 04 43 01 03 01\r430\r<RX ERROR']);
      await engine
          .readDtcs(DtcKind.stored)
          .then<void>((_) {})
          .catchError((Object _) {});
      await engine
          .readDtcs(DtcKind.stored)
          .then<void>((_) {})
          .catchError((Object _) {});

      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.message, 'message', contains('未能辨識的位址：430'))),
        reason: 'the second read learned nothing, so it cannot have learned '
            'that the first read’s open question was closed',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('R22-codex 02: a DLC digit is a rendering, not damage', () async {
      // Codex round 22's pre-existing finding. `AT D1` — whose power-on
      // default is PP 29, not this app — puts the CAN data length between the
      // identifier and the data: "the single DLC digit will appear between the
      // ID (header) bytes and the data bytes" (ELM327DSJ, *D0 and D1*).
      //
      // The app never sends `ATD0`, so on an adapter whose PP 29 is programmed
      // to `00` every reply arrives in that rendering, and the strict matcher
      // rejected all of them — a working vehicle refused for a display option.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      // `7E8` `8` `02 43 00 00 00 00 00 00`, with `ATS0` in effect.
      transport.forceReplySequence('03', ['7E880243000000000000']);
      expect(await engine.readDtcs(DtcKind.stored), isEmpty,
          reason: 'DLC 8 followed by exactly eight bytes is a legal ELM327 '
              'rendering of a controller reporting no stored codes');

      // The count check is the reason this reading is safe to attempt at all,
      // so it gets an oracle that fails without it.
      //
      // `7E8 7 02 43 00` claims seven data bytes and carries three. Delete the
      // equality test and what is behind it reads as a perfectly ordinary
      // Single Frame — `02 43 00`, Mode 03, zero codes — so the scan returns a
      // clean bill of health from a line whose own length byte contradicts it.
      transport.forceReplySequence('03', ['7E8 7 02 43 00']);
      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()),
        reason: 'a declared length the payload does not honour is damage, not '
            'a controller reporting no codes',
      );

      // And a truncated line claims a length its payload does not honour in
      // the other direction: zero declared, three bytes behind it.
      transport.forceReplySequence('03', ['7E9037F031\r<RX ERROR']);
      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>().having((e) => e.heardAboutService,
            'heardAboutService', isNot(contains('7E9')))),
        reason: 'and it must not be read as a controller answering anything',
      );

      // And a length no CAN frame can have is not a length. `A` here agrees
      // with the ten byte pairs behind it, so the count check alone lets it
      // through — and what is behind it reads as a perfectly well-formed
      // Single Frame carrying P0107 and P0133. Two fault codes, rendered as
      // confidently as real ones, assembled out of a line no ELM327 can print.
      transport.forceReplySequence('03', ['7E8A06430201070133000000']);
      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()),
        reason: 'a classic CAN frame carries at most eight data bytes, so this '
            'is not a controller and those are not its codes',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R23-codex 01: an impossible data length is not a fault code',
        () async {
      // Codex round 23. The DLC reading validated the digit against the byte
      // count behind it and nothing else, so `9` agreed with nine bytes and
      // the line was accepted. Classic CAN carries at most eight.
      //
      //   03 -> 7E8 9 04 43 01 07 15 00 00 00 00     -> P0715
      //   04 -> 7E8 9 01 44 00 00 00 00 00 00 00     -> 已送出清除指令
      //
      // Both were reproduced against production code. A frame that cannot
      // exist produced a fault code with a controller's name on it, and then
      // a whole-vehicle clear.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '04': [0x44]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport
          .forceReplySequence('03', ['7E8 9 04 43 01 07 15 00 00 00 00']);
      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>().having(
            (e) => e.partial.map((d) => d.code), 'partial', isEmpty)),
        reason: 'nine data bytes is not a CAN frame, so P0715 is not a fault '
            'this vehicle reported',
      );

      transport
          .forceReplySequence('04', ['7E8 9 01 44 00 00 00 00 00 00 00']);
      expect(await _clearSucceeded(engine), isFalse,
          reason: 'and it is not an acknowledgement either');

      // The same impossibility without a length digit to give it away. Nine
      // bytes behind a plain header satisfies the strict grammar, and the
      // Single Frame inside declares four — so P0715 comes back out of a
      // frame that still cannot exist. The ceiling has to be on the frame,
      // not only on the digit that claims to describe it.
      transport
          .forceReplySequence('03', ['7E8 04 43 01 07 15 00 00 00 00']);
      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>().having(
            (e) => e.partial.map((d) => d.code), 'partial', isEmpty)),
        reason: 'nine data bytes is not a CAN frame in either rendering',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R23-codex 03: an exact identity is not shadowed by a known prefix',
        () async {
      // Codex round 23. On a slot accepting both widths, `18DAF118` is a legal
      // 29-bit identifier whose first three digits are `18D` — a controller
      // the census had just heard from. Recognition outranked exactness, so
      // the whole token was discarded, `18D` was marked present, and the reply
      // stopped being an open question at all.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        forceProtocolNumber: 'B',
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '18D',
            responses: {
              ..._physicsReplies(),
              '03': [0x43, 0x00],
              '07': [0x47, 0x00],
            },
          ),
        ],
      )..enabledProgrammableParameters[0x2C] = 0xA1;
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.forceReplySequence('03', ['18DAF118\r<RX ERROR']);
      await engine
          .readDtcs(DtcKind.stored)
          .then<void>((_) {})
          .catchError((Object _) {});

      expect(engine.openIdentityQuestions, contains('18DAF118'),
          reason: 'the exact token is what was on the wire; a prefix of it '
              'that happens to be familiar is a different module');
      expect(engine.openIdentityQuestions, isNot(contains('18D')));
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R23-codex 06: a 29-bit length rendering is read, not misparsed',
        () async {
      // Codex round 23. `_canLine` tried the strict grammar before the DLC one
      // and the narrower width first, so a legal 29-bit `AT D1` line was
      // consumed as an 11-bit frame whose payload began `AF 11 …`. ISO-TP then
      // rejected the body and the valid reading was never tried.
      //
      //   18DAF110 5 04 43 01 03 01   ->  P0301 from 18DAF110
      //
      // Five data bytes, which `AT V1` renders faithfully. Deliberately short:
      // at eight the eleven-bit misreading exceeds a CAN frame's capacity and
      // is refused on that ground alone, so nothing would depend on preferring
      // the reading that is actually an ISO-TP frame. Here both readings fit,
      // and only their shape separates them — `AF 11 05 …` is no frame type at
      // all, `04 43 01 03 01` is a Single Frame declaring four bytes.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        forceProtocolNumber: 'B',
        ecus: [
          FakeEcu(
            name: 'gateway',
            requestId: '7E0',
            responseId: '18DAF110',
            responses: {..._physicsReplies()},
          ),
        ],
      )..enabledProgrammableParameters[0x2C] = 0xA1;
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.forceReplySequence('03', ['18DAF11050443010301']);
      final codes = await engine.readDtcs(DtcKind.stored);
      expect(codes.map((d) => d.code).toList(), ['P0301']);
      expect(codes.single.sourceId, '18DAF110',
          reason: 'the identifier is the whole eight digits, and the digit '
              'after it is the data length');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R23-codex 04: a damaged clear is not forgotten by the next one',
        () async {
      // Codex round 23. Reads reduced their evidence before judging the
      // outcome; the clear did not. A clear answered by `7E8 01 44` beside a
      // bare `7E9` and an error marker failed and forgot `7E9` — and the
      // retry, answered by `7E8` alone, was reported as the whole vehicle
      // cleared. The state-changing operation was the one place the evidence
      // model did not reach.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '04': [0x44]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.forceReplySequence(
          '04', ['7E8 01 44 00 00 00 00 00 00\r7E9\r<RX ERROR']);
      expect(await _clearSucceeded(engine), isFalse);

      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.message, 'message', contains('7E9'))),
        reason: 'the second attempt reaches whoever answered the first; it '
            'does not establish anything about the one that did not',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R23-codex 05: one refresh answers a doubt any category raised',
        () async {
      // Codex round 23. Every category's completion checked the union, and
      // each category replaced only its own stale set — so a candidate raised
      // by Mode 0A failed the next scan's Mode 03 and Mode 07 before Mode 0A
      // finally cleared it. The app said 請重新掃描 and one rescan was not
      // enough.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._physicsReplies(),
              '03': [0x43, 0x00],
              '07': [0x47, 0x00],
              '0A': [0x4A, 0x00],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.forceReplySequence('0A', ['430\r<RX ERROR']);
      await engine
          .readDtcs(DtcKind.permanent)
          .then<void>((_) {})
          .catchError((Object _) {});
      expect(engine.openIdentityQuestions, contains('430'));

      // One refresh, in the order the scan runs them.
      expect(await engine.readDtcs(DtcKind.stored), isEmpty);
      expect(await engine.readDtcs(DtcKind.pending), isEmpty);
      expect(await engine.readDtcs(DtcKind.permanent), isEmpty);
      expect(engine.openIdentityQuestions, isEmpty,
          reason: 'one full pass, every category answered, nothing left over');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('R23-codex PRE-01: a First Frame that fits in one frame is not one',
        () async {
      // Codex round 23, pre-existing. ISO-TP uses a First Frame because the
      // payload does *not* fit in a Single Frame. `7E8 10 02 43 00 …` declares
      // two bytes, and reassembly honoured it: `43 00` came back, the decoder
      // read it as a controller reporting zero stored codes, and with two
      // ordinary optional-category replies the scan rendered the vehicle
      // clean — from a frame no ECU can legally send.
      for (final total in [1, 2, 7]) {
        final transport = FakeElm327(
          protocol: BusProtocol.can11,
          ecus: [
            FakeEcu(
              name: 'ECM',
              requestId: '7E0',
              responseId: '7E8',
              responses: {..._physicsReplies()},
            ),
          ],
        );
        final engine = await _connect(transport);
        await engine.discoverResponders();
        final pci = total.toRadixString(16).toUpperCase().padLeft(2, '0');
        transport
            .forceReplySequence('03', ['7E8 10 $pci 43 00 00 00 00 00']);
        await expectLater(
          engine.readDtcs(DtcKind.stored),
          throwsA(isA<DtcReadException>()),
          reason: 'a First Frame declaring $total bytes contradicts itself, '
              'and a contradiction is not a clean bill of health',
        );
        await engine.dispose();
      }
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('R23-grok F1: a service byte on its own is not a clean vehicle',
        () async {
      // Cursor/Grok, round 23. ISO 15765-4 puts a count byte immediately after
      // `43`, so a legal clean CAN answer is `43 00` and never a bare `43`.
      // The decoder returned an empty list when the service byte was the whole
      // payload — before the count-versus-payload contract it enforces
      // everywhere else could run — and an empty list here is 未偵測到故障碼
      // over a green panel.
      //
      // Reachable from a clone that pads while declaring ISO-TP length 1, and
      // from a Single Frame truncated after its service byte.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.forceReplySequence('03', ['7E8 01 43']);
      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()),
        reason: 'a reply that stopped before it said how many is not a reply '
            'that said none',
      );

      // And the legal empty is still legal, so this is not "empty is always
      // wrong".
      transport.forceReplySequence('03', ['7E8 02 43 00']);
      expect(await engine.readDtcs(DtcKind.stored), isEmpty);
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R23-grok F7: one protocol digit is still a protocol', () async {
      // Cursor/Grok, round 23. `ATDPN` prints one character — "a leading `A`
      // if the protocol was found automatically" — so a compliant chip after
      // `ATSP0` answers `A6` and a clone that omits the prefix answers `6`.
      // One hex digit is hex-shaped but not a byte pair, so the general reply
      // parser called it `DATA ERROR` and the protocol number was never
      // stored.
      //
      // Everything downstream then refused: no protocol to reason about means
      // every fault-code and VIN read answered 尚未確定車輛使用的匯流排協定,
      // and reconnecting produced it again. Fail-closed is right, and this is
      // a working adapter it was closing on.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
        faults: const AdapterFaults(forcedReplies: {'ATDPN': '6'}),
      );
      final engine = await _connect(transport);
      expect(engine.client.protocolNumber, '6');
      await engine.discoverResponders();
      expect(await engine.readDtcs(DtcKind.stored), isEmpty,
          reason: 'the bus is determined, so the scan may run');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R23-grok theatre 1: the harmful commands are never transmitted',
        () async {
      // Cursor/Grok, round 23. The existing test asserted that `ATCRA` and
      // `ATCFC0` are absent from `initSequence` — a list — which stays true if
      // `connect()` emitted them as extras. `docs/protocol-deviations.zh-TW.md` exists
      // because those two commands break real vehicles: `ATCRA 7B0` filters
      // the ECU's replies away, and `ATCFC0` disables the flow control ISO
      // 15765-4 requires, stopping every reply longer than seven bytes at its
      // first frame.
      //
      // What matters is the wire, so this asserts the wire.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      await engine.readDtcs(DtcKind.stored);
      await engine.readVin();
      for (final sent in transport.commandLog) {
        expect(sent.toUpperCase().replaceAll(' ', ''),
            isNot(anyOf(startsWith('ATCRA'), startsWith('ATCFC'))),
            reason: '$sent reached the adapter');
      }
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R23-grok F6: the vehicle is asked what it says about itself',
        () async {
      // Cursor/Grok, round 23. J1979 Mode 01 PID 01 carries the fault lamp in
      // bit 7 of byte A and the confirmed-code count in bits 0 to 6. The app
      // read Modes 03, 07 and 0A and never asked — so a car with its lamp lit
      // and two confirmed codes, answering `43 00` to Mode 03, produced a
      // green 未偵測到故障碼 with the light on the dashboard in front of the
      // user.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._physicsReplies(),
              // MIL on, two confirmed codes, then the readiness bytes.
              '0101': [0x41, 0x01, 0x82, 0x07, 0x65, 0x04],
              '03': [0x43, 0x00],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();

      final mil = await engine.readMilStatus();
      expect(mil, isNotNull);
      expect(mil!.bySource.keys, ['7E8'],
          reason: 'the summary belongs to the controller that sent it — a '
              'count with no owner cannot be checked against anybody\'s codes');
      expect(mil.bySource['7E8']!.milOn, isTrue);
      expect(mil.bySource['7E8']!.confirmedCount, 2);
      expect(mil.claimsFault, isTrue,
          reason: 'the vehicle is claiming a fault, and Mode 03 read none — '
              'the scan may not resolve that in favour of the empty list');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R23-grok F6: a lamp that is off with no codes claims nothing',
        () async {
      // The other direction, which matters just as much: a clean summary must
      // not qualify a clean scan, or every ordinary result carries a warning
      // and the warning stops meaning anything.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._physicsReplies(),
              '0101': [0x41, 0x01, 0x00, 0x07, 0x65, 0x04],
              '03': [0x43, 0x00],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      final mil = await engine.readMilStatus();
      expect(mil!.claimsFault, isFalse);
      expect(mil.totalConfirmed, 0);
      expect(await engine.readDtcs(DtcKind.stored), isEmpty);
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R23-grok F6: a summary nobody answered is unknown, not clean',
        () async {
      // Null is the third state and the one that must change nothing. A
      // vehicle that does not implement PID 01, or an adapter that loses the
      // reply, has told the app nothing — and "nothing" must not be read as
      // either a claim or a clean bill.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      expect(await engine.readMilStatus(), isNull);
      expect(await engine.readDtcs(DtcKind.stored), isEmpty,
          reason: 'and an unanswered summary does not qualify the scan');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R23-kimi F3: a header whose acknowledgement was lost is unknown',
        () async {
      // Kimi, round 23, and the only wrong-number path in its report. The
      // `ATSH` *write* goes out; its `OK` is lost — BLE notification loss, a
      // slow clone. `_currentHeader` still named the previous header, so the
      // next query for that header skipped `ATSH` as redundant and was
      // physically transmitted on whatever the adapter actually holds.
      //
      // On a multi-ECU car that is a transmission answering an engine
      // question, decoded as the engine's: a plausible gauge reading with
      // nothing to indicate it. This file's own doctrine everywhere else is
      // that a write whose reply is lost has an *unknown* outcome.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies()},
          ),
          FakeEcu(
            name: 'TCM',
            requestId: '7E1',
            responseId: '7E9',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      final engine = await _connect(transport);
      final client = engine.client;
      // The acknowledgement for this one switch arrives *after* the client has
      // given up on it — the shape that matters, because the resync then
      // drains it cleanly and nothing looks wrong afterwards. The adapter has
      // applied the header; only the client's model has not.
      transport.slowCommands['ATSH7E1'] = const Duration(milliseconds: 400);

      // Settle on 7E0 first, so the model has something to go stale.
      await client.sendOnHeader('7E0', '010C');
      await client
          .sendOnHeader('7E1', '010C')
          .then<void>((_) {})
          .catchError((Object _) {});
      transport.slowCommands.remove('ATSH7E1');

      final before = transport.commandLog.length;
      await client
          .sendOnHeader('7E0', '010C')
          .then<void>((_) {})
          .catchError((Object _) {});
      expect(
        transport.commandLog
            .skip(before)
            .map((c) => c.toUpperCase().replaceAll(' ', '')),
        contains('ATSH7E0'),
        reason: 'the adapter may already hold 7E1; the only honest thing the '
            'client can do is select the header it wants again',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('R24-codex 01: two legal readings of one line is a question, not a pick',
        () async {
      // Codex round 24, and the worst kind of finding: entirely legal traffic
      // turned into a plausible wrong sensor value.
      //
      //   0104 -> 18D03410 4 03 41 04 5A       (protocol B, PP 2C = A1)
      //
      // Read as 29-bit with its data length displayed, that is source
      // `18D03410` saying engine load is 0x5A*100/255 = 35.3%. Read as 11-bit,
      // it is source `18D` with body `03 41 04 03 41 04 5A` — also a Single
      // Frame, declaring three bytes — saying 0x03*100/255 = 1.2%.
      //
      // Preferring the bus's *transmit* width picked the second. But PP 2C's
      // b5 says the adapter accepts both receive widths precisely because the
      // transmit width does not determine which one answered, so that
      // tie-break asserted the one thing the configuration denies.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        forceProtocolNumber: 'B',
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '18D',
            responses: {..._physicsReplies()},
          ),
        ],
      )..enabledProgrammableParameters[0x2C] = 0xA1;
      final engine = await _connect(transport);
      transport.forceReplySequence('0104', ['18D0341040341045A']);
      final response = await engine.client.sendGlobal('0104');
      expect(response.frames, isEmpty,
          reason: 'neither reading may be published: one of them is a wrong '
              'number under a wrong controller, and nothing in the reply says '
              'which');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R24-codex 02: a controller that acknowledged a clear is on the bus',
        () async {
      // Codex round 24. `_resolveIdentity` promotes an identifier that was
      // already in question, so a controller nobody had ever heard from was
      // dropped: `7E9` answering `01 44` beside `7E8` proved both that it is
      // on this bus and that it holds fault memory it has just erased, and the
      // coverage set kept neither. The next scan then went green on `7E8`
      // alone while `7E9` sat silent.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._physicsReplies(),
              '03': [0x43, 0x00],
              '04': [0x44],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.forceReplySequence(
          '04', ['7E8 01 44 00 00 00 00 00 00\r7E9 01 44 00 00 00 00 00 00']);
      expect((await engine.clearDtcs()).isSuccess, isTrue,
          reason: 'both controllers acknowledged, so the clear did succeed');

      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()
            .having((e) => e.message, 'message', contains('7E9'))),
        reason: 'and 7E9 is now owed an answer — a later scan that only hears '
            'from 7E8 is not a whole-vehicle result',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R24-codex 03: a controller found by PID 01 owes its fault codes',
        () async {
      // Codex round 24. `readMilStatus` consumed every frame and recorded no
      // source, and it ran *after* the categories — so a scan could meet `7E9`
      // in `0101`, never hear from it again, and still certify a complete
      // result from `7E8` alone. PID 01 is mandatory for emissions-related
      // modules, and those are exactly the ones J1979 requires to answer
      // Mode 03.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._physicsReplies(),
              '0101': [0x41, 0x01, 0x00, 0x07, 0x65, 0x04],
              '03': [0x43, 0x00],
              '07': [0x47, 0x00],
            },
          ),
          FakeEcu(
            name: 'TCM',
            requestId: '7E1',
            responseId: '7E9',
            // Answers the summary and nothing else.
            responses: {'0101': [0x41, 0x01, 0x00, 0x07, 0x65, 0x04]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      final mil = await engine.readMilStatus();
      expect(mil!.bySource.keys, containsAll(['7E8', '7E9']));

      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()
            .having((e) => e.message, 'message', contains('7E9'))),
        reason: 'PID 01 proved 7E9 exists; its silence on Mode 03 is now a '
            'hole in the result rather than nothing at all',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R24-codex 04: a summary that stopped after byte A is not a summary',
        () async {
      // Codex round 24. J1979 PID 01 is four data bytes — `41 01 A B C D`,
      // where B, C and D are the readiness monitors. Requiring only three
      // accepted a reply whose declared payload stopped after `A` and read the
      // CAN frame's zero padding as the rest, in a reply this app then uses to
      // qualify a whole-vehicle verdict.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport
          .forceReplySequence('0101', ['7E8 03 41 01 80 00 00 00 00']);
      expect(await engine.readMilStatus(), isNull,
          reason: 'the declared payload is three bytes; the rest is padding, '
              'and padding is not a readiness report');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R24-grok: a clean read does not discharge the clear\'s own debt',
        () async {
      // Cursor/Grok round 24, reproduced against production. A damaged clear
      // left `7E9` as an unnameable token; a completed category read then
      // wiped that doubt wholesale, on the reasoning that the read had just
      // looked at the bus. It had not looked at the same question: a `7E9` the
      // *clear* could not name is not something a Mode 03 exchange only `7E8`
      // answers has any view on. So the second clear reported the whole
      // vehicle cleared on `7E8` alone — the refusal bypassed by the very
      // action its message recommends.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._physicsReplies(),
              '03': [0x43, 0x00],
              '04': [0x44],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.forceReplySequence(
          '04', ['7E8 01 44 00 00 00 00 00 00\r7E9\r<RX ERROR']);
      expect(await _clearSucceeded(engine), isFalse);

      // The rescan the message asks for, answered cleanly by 7E8 alone.
      expect(await engine.readDtcs(DtcKind.stored), isEmpty);

      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.message, 'message', contains('7E9'))),
        reason: 'nothing in that rescan said anything about 7E9, so nothing '
            'in it can discharge the question 7E9 raised',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('R25-codex 03: one surviving reading is published, not refused',
        () async {
      // Codex round 25, on the repair for round 24. Refusing when two readings
      // survive is right; refusing this one was not.
      //
      //   0104 -> 18D034104100A4104     (protocol B, PP 2C = A1)
      //
      // As 11-bit: source `18D`, body `03 41 04 10 0A 41 04` — a Single Frame
      // declaring three bytes, complete, and correlated to the request.
      // As 29-bit with a length digit: source `18D03410`, body `10 0A 41 04` —
      // which only *looks* like a First Frame. It announces ten bytes and this
      // reply is one line, so there is nothing to continue.
      //
      // A First Frame with no continuations is not a reading. The shape check
      // accepted it anyway, both candidates survived, and a legal engine-load
      // reply from a physically single-width vehicle was thrown away.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        forceProtocolNumber: 'B',
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '18D',
            responses: {..._physicsReplies()},
          ),
        ],
      )..enabledProgrammableParameters[0x2C] = 0xA1;
      final engine = await _connect(transport);
      // Round 26 replaced the heuristic with the fix. Two rounds were spent
      // trying to choose between two legal readings of the same characters by
      // shape, and each rule that made one case right made another wrong:
      // preferring the transmit width published a wrong number, and excluding
      // a lone First Frame published a different wrong number.
      //
      // The ambiguity was never in the reasoning, it was in the rendering.
      // `ATS0` saves a third of the traffic and costs nothing on an ordinary
      // bus; on a slot that accepts both identifier widths it makes
      // `18D 03 41 04 …` and `18D03410 4 …` the same string. So on that one
      // configuration the app asks for the spaces back, and there is nothing
      // left to guess.
      expect(
        transport.commandLog.map((c) => c.toUpperCase().replaceAll(' ', '')),
        contains('ATS1'),
        reason: 'this slot accepts both widths, so the rendering has to be '
            'unambiguous',
      );
      transport.forceReplySequence('0104', ['18D 03 41 04 10 0A 41 04']);
      final response = await engine.client.sendGlobal('0104');
      expect(response.frames, hasLength(1),
          reason: 'spaced, the header is its own token and only one reading '
              'exists');
      expect(response.frames.single.sourceId, '18D');
      expect(response.frames.single.bytes, [0x41, 0x04, 0x10]);
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R25-codex 02: a stale reading during a clear is not clear evidence',
        () async {
      // Codex round 25, on the other repair. Promoting every frame in a clear
      // reply went too far: `7E9 04 41 0C 1A F8` is a complete Mode 01 engine
      // speed reply that happened to arrive during the clear, and it became a
      // fault-code obligation for the rest of the connection — every later
      // scan refused for the silence of a controller that had only ever
      // reported RPM.
      //
      // Same rule the read path already states: a complete frame about
      // something else is evidence that a controller exists and no evidence
      // about this question.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._physicsReplies(),
              '03': [0x43, 0x00],
              '04': [0x44],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.forceReplySequence(
          '04', ['7E8 01 44 00 00 00 00 00 00\r7E9 04 41 0C 1A F8 00 00 00']);
      expect(await _clearSucceeded(engine), isFalse,
          reason: 'not every frame acknowledged, so the clear did not succeed');

      expect(await engine.readDtcs(DtcKind.stored), isEmpty,
          reason: '7E9 reported engine speed; it never took part in the clear, '
              'and owes Mode 03 nothing on that basis');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R26-codex 04: a clear succeeds on exactly 44, not on 44 and rubbish',
        () async {
      // Codex round 26. J1979 Mode 04 has no response parameter: completion is
      // the single positive service byte. `7E8 04 44 DE AD BE` declares four
      // application bytes, and the check looked only at the first one — so a
      // malformed reply was reported as 已送出清除指令 on the one operation
      // that cannot be undone.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport
          .forceReplySequence('04', ['7E8 04 44 DE AD BE 00 00 00']);
      expect(await _clearSucceeded(engine), isFalse,
          reason: 'four application bytes is not the one-byte positive '
              'response Mode 04 defines');

      // The legal one still works, so this is not "any 44 is suspect".
      transport.forceReplySequence('04', ['7E8 01 44 00 00 00 00 00 00']);
      expect(await _clearSucceeded(engine), isTrue);
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R26-audit: an adapter that refuses ATDPN can still be used',
        () async {
      // From the refusal audit. `ATDPN` is a non-critical handshake step, so a
      // clone that answers it with `?` connects — and is then useless. The bus
      // is undetermined, and undetermined refuses everything: every gauge
      // reads 匯流排錯誤, every fault-code and VIN read answers 尚未確定車輛使用
      // 的匯流排協定，請重新連線, and reconnecting produces the same reply
      // because the adapter answers the same way every time. A working
      // adapter, a working car, and no way forward from inside the app.
      //
      // `ATDP` is the second witness, and the handshake already asks for it.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
        faults: const AdapterFaults(forcedReplies: {'ATDPN': '?'}),
      );
      final engine = await _connect(transport);
      expect(engine.client.protocolNumber, isEmpty,
          reason: 'sanity: the adapter really did refuse to name it');
      expect(engine.client.addressing.headerHexDigits, 3,
          reason: 'the description said ISO 15765-4 (CAN 11/500) — an 11-bit '
              'CAN bus, from a sentence the datasheet documents rather than '
              'a guess');

      await engine.discoverResponders();
      expect(await engine.readDtcs(DtcKind.stored), isEmpty,
          reason: 'so the scan runs instead of refusing a car it can read');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R27-codex 01: an errored PID 01 exchange still names its controllers',
        () async {
      // Codex round 27, and the third round on this same class — the last
      // place it was hiding. `readMilStatus` returned on `!isSuccess` before
      // looking at anything, so an `<RX ERROR>` on the `0101` reply discarded
      // a `7E9` that had visibly answered `41 01`. The three DTC categories
      // then completed against `7E8` alone and the panel went green.
      //
      // The adapter's error marker means the payload is not data. It does not
      // unsay who sent the lines printed before it.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._physicsReplies(),
              '03': [0x43, 0x00],
              '07': [0x47, 0x00],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.forceReplySequence('0101', [
        '7E8 06 41 01 00 07 65 04\r7E9 06 41 01 82 07 65 04\r<RX ERROR',
      ]);
      expect(await engine.readMilStatus(), isNull,
          reason: 'a reply the adapter marked damaged cannot qualify a '
              'whole-vehicle verdict');

      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()
            .having((e) => e.message, 'message', contains('7E9'))),
        reason: 'but 7E9 answered PID 01 during this scan, so Mode 03 — which '
            'every emissions controller owes — may not close without it',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R28-N6: the ignition advice never comes before "do not repeat"',
        () async {
      // Cursor round 28. The 0x22 refusal appended the do-not-repeat clause
      // after the ignition instruction, so on a mixed reply it read as: turn
      // the key to ON, but do not send the clear again. The actionable half
      // came first and the prohibition looked like a footnote to it — which
      // makes the obvious next action exactly the one being warned against,
      // and that re-clears the controller that already finished.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '04': [0x44]},
          ),
          FakeEcu(
            name: 'TCM',
            requestId: '7E1',
            responseId: '7E9',
            responses: {
              '0100': [0x41, 0x00, 0x80, 0x00, 0x00, 0x00],
              '04': [0x7F, 0x04, 0x22],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>().having(
          (e) => e.message.indexOf('不要再送一次') < e.message.indexOf('電門'),
          'the prohibition is read before the instruction',
          isTrue,
        )),
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R29-cursor: a PID 01 reply cut short still names its controller',
        () async {
      // Cursor round 29, in the R28-N3 repair. That repair required
      // `ObdFrame.payload`, which is bounded by the whole declared message
      // having arrived — and so pointed the rule the wrong way round:
      //
      //   0101 -> 7E8 06 41 01 00 07 65 04
      //           7E9 06 41 01 82 07 65      six declared, five arrived
      //           <RX ERROR
      //
      // `7E9` visibly answered PID 01 with `A = 0x82`: the fault lamp bit set.
      // A null payload made the harvest forget it, Mode 03 completed on `7E8`
      // alone, and the panel went green with the lamp lit on the dashboard in
      // front of the user.
      //
      // That is a false all-clear — the failure this path exists to prevent,
      // reintroduced by the fix for a spurious refusal. Identity and content
      // are different facts: nothing here becomes a reading, and the
      // controller is still remembered.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._physicsReplies(),
              '03': [0x43, 0x00],
              '07': [0x47, 0x00],
              '0A': [0x4A, 0x00],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.forceReplySequence('0101', [
        '7E8 06 41 01 00 07 65 04\r7E9 06 41 01 82 07 65\r<RX ERROR',
      ]);
      expect(await engine.readMilStatus(), isNull,
          reason: 'a damaged reply cannot qualify a whole-vehicle verdict');

      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()
            .having((e) => e.message, 'message', contains('7E9'))),
        reason: 'the line was cut, not the controller — Mode 03 may not close '
            'without the module that just reported its lamp on',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R30-codex 04: three shapes that never claimed to answer PID 01',
        () async {
      // Codex round 30, and cursor's F1 and F4 independently. `operand` was
      // added so a *truncated* PID 01 reply would keep naming its controller,
      // and it was broader than that fact: three replies that make no PID 01
      // claim at all were harvested, and each one then made every later
      // fault-code category fail for the silence of a controller that had
      // never been asked anything.
      //
      // Every one of these is the over-strict direction — a readable car the
      // app refuses — which is a wasted trip rather than a wrong number, and
      // still a trip.
      Future<void> refusesNothing(String reply, String why) async {
        final transport = FakeElm327(
          protocol: BusProtocol.can11,
          ecus: [
            FakeEcu(
              name: 'ECM',
              requestId: '7E0',
              responseId: '7E8',
              responses: {
                ..._physicsReplies(),
                '03': [0x43, 0x00],
                '07': [0x47, 0x00],
                '0A': [0x4A, 0x00],
              },
            ),
          ],
        );
        final engine = await _connect(transport);
        await engine.discoverResponders();
        transport.forceReplySequence('0101', [reply]);
        expect(await engine.readMilStatus(), isNull);
        expect(await engine.readDtcs(DtcKind.stored), isEmpty, reason: why);
        await engine.dispose();
      }

      // `7F 01 11`: "I do not support Mode 01". Its second byte is the
      // service being refused, not a PID.
      await refusesNothing(
        '7E8 06 41 01 00 07 65 04\r7E9 03 7F 01 11\r<RX ERROR',
        'a controller declining Mode 01 has not answered PID 01',
      );

      // A First Frame. A PID 01 reply is six application bytes and fits a
      // Single Frame, so this cannot be one — the rule `operand` replaced
      // excluded First Frames and `operand` did not.
      await refusesNothing(
        '7E9 10 08 41 01 82 07 65 04\r<RX ERROR',
        'a message declared longer than seven bytes is not a PID 01 reply',
      );
    }, timeout: const Timeout(Duration(seconds: 40)));

    test('R30-codex 07C: the J1850 checksum is pinned to a datasheet vector',
        () async {
      // Codex round 30, and a good catch about how a test can prove nothing.
      // Every J1850 line in this file is generated by `_withChecksum`, which
      // computes the same CRC the production verifier does — so making the
      // verifier accept *everything* would leave the whole suite green. A
      // helper that mirrors the implementation cannot test it.
      //
      // These bytes are written out by hand from the ELM327 datasheet's own
      // example (ELM327DSJ, the J1850 message-format section), so the pair
      // below is evidence rather than a restatement: CRC-8/SAE-J1850,
      // polynomial 0x1D, init 0xFF, xorout 0xFF.
      // Written the way `ATS0` makes an adapter print it: no spaces. The
      // headered-legacy pattern wants six contiguous hex digits, so a spaced
      // line does not match it at all and falls through unjudged — which is
      // another way this test could have proved nothing.
      const valid = '486B104100BE3EB811FA';
      const corrupted = '486B104100BE3EB811FB';

      Future<bool> accepts(String line) async {
        final transport = FakeElm327(
          protocol: BusProtocol.j1850pwm,
          // Forced on a *later* command, not on `0100`: overriding the
          // capability probe fails the handshake, the protocol is never
          // resolved, and the checksum verifier — which is chosen by bus
          // family — is never reached at all. The first version of this test
          // did that and asserted nothing, which is the failure mode it was
          // written to prevent.
          faults: AdapterFaults(forcedReplies: {'0105': line}),
          ecus: [
            FakeEcu(
              name: 'ECM',
              requestId: '686AF1',
              responseId: '486B10',
              // The same payload as the datasheet line, so the handshake's
              // capability probe succeeds and the protocol actually resolves.
              responses: const {
                '0100': [0x41, 0x00, 0xBE, 0x3E, 0xB8, 0x11],
              },
            ),
          ],
        );
        final client = Elm327Client(transport,
            commandTimeout: const Duration(milliseconds: 300));
        expect(await client.connect(), isTrue);
        expect(client.addressing.family, ObdBusFamily.j1850Pwm,
            reason: 'the checksum rule is chosen by bus family; if this is '
                'undetermined the verifier is never reached and the test '
                'proves nothing');
        // Through a *global* exchange, because attribution only exists while
        // `ATH1` is in force — an ordinary `send` runs with headers off, the
        // headered-legacy parser is never entered, and the checksum is never
        // consulted. One more way this test could have been green and empty.
        final response = await client.sendGlobal('0105');
        // Attribution, not frame count. A line the checksum rejects still
        // reaches the headerless fallback, which builds a frame out of the raw
        // hex with no source — so "did any frame come back" is true either way
        // and would have made this test prove nothing. Only the headered
        // legacy branch names a controller, and only a line whose sum holds
        // gets through it.
        final ok = response.frames.any((f) =>
            f.sourceId == '10' &&
            f.bytes.length == 6 &&
            f.bytes.first == 0x41);
        await client.dispose();
        return ok;
      }

      expect(await accepts(valid), isTrue,
          reason: 'the datasheet line must verify, or the app refuses a real '
              'J1850 car outright');
      expect(await accepts(corrupted), isFalse,
          reason: 'one bit of the check byte, and it must not become data — '
              'this is the assertion that a self-generated fixture cannot make');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('R30-codex 07A: padding does not name a PID', () async {
      // Codex round 30, an unpinned rule rather than a defect. The Single
      // Frame declares one application byte — the service byte `41` — and the
      // `01` after it is CAN padding. Deleting the declared-length guard lets
      // that padding invent a PID 01 responder, and until now nothing went
      // red when it did.
      //
      // Reading padding as data is the oldest mistake in this file and it has
      // taken three different forms already; this is the one it could still
      // take.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._physicsReplies(),
              '03': [0x43, 0x00],
              '07': [0x47, 0x00],
              '0A': [0x4A, 0x00],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.forceReplySequence('0101', [
        '7E8 06 41 01 00 07 65 04\r7E9 01 41 01 00 00 00 00\r<RX ERROR',
      ]);
      expect(await engine.readMilStatus(), isNull);
      expect(await engine.readDtcs(DtcKind.stored), isEmpty,
          reason: 'a frame that declares one byte has not named a parameter, '
              'and refusing the scan for the silence of a controller invented '
              'out of zero padding makes a readable car unusable');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('R30-codex 04b: a legacy PID 01 line that fails its checksum '
        'invents nobody', () async {
      // The third shape, on the bus where the checksum is the only thing that
      // says where the header ends. `48 6B 18 41 01 00` needs `0D`.
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        faults: const AdapterFaults(
          forcedReplies: {
            '0101': '48 6B 10 41 01 00 00 00 00 00 05\r'
                '48 6B 18 41 01 00\r<RX ERROR',
          },
        ),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '686AF1',
            responseId: '486B10',
            responses: {..._physicsReplies(), '03': [0x43, 0x00, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      expect(await engine.readMilStatus(), isNull);
      expect(await engine.readDtcs(DtcKind.stored), isEmpty,
          reason: 'source 18 was never established; refusing a valid empty '
              'Mode 03 from source 10 for its silence makes a readable car '
              'unusable');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('R28-N3: a PID \$41 reply is not a PID 01 reply', () async {
      // Cursor round 28, and the mirror image of the test above. That one
      // says a controller which answered `41 01` may not be forgotten; this
      // one says a controller which answered something else may not be
      // remembered as having answered it.
      //
      // The correlation scanned the first three bytes for the pair `41 01`.
      // An observed frame still carries its ISO-TP framing, so an ordinary
      // reply to `0141` — monitor status this drive cycle — whose first data
      // byte happens to be `01` reads as:
      //
      //   7E9 06 41 41 01 00 00 00
      //         ^0 ^1 ^2 ^3
      //
      // `41` at offset 2, `01` at offset 3. Matched. `7E9` then owed a
      // fault-code answer to a question nobody had asked it, and the scan
      // refused to call a readable vehicle clean because of the debt.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._physicsReplies(),
              '03': [0x43, 0x00],
              '07': [0x47, 0x00],
              '0A': [0x4A, 0x00],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.forceReplySequence('0101', [
        '7E8 06 41 01 00 07 65 04\r7E9 06 41 41 01 00 00 00\r<RX ERROR',
      ]);
      expect(await engine.readMilStatus(), isNull);

      expect(await engine.readDtcs(DtcKind.stored), isEmpty,
          reason: '7E9 never answered PID 01, so it owes nothing here — and '
              'inventing the debt refuses a vehicle the app could read');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R27-codex 03: a mixed clear does not advise repeating itself',
        () async {
      // Codex round 27. The refusal messages ended in 再試一次 unconditionally.
      // On a mixed reply — one controller acknowledges, another refuses — that
      // is advice to re-send a *global* clear, which reaches the module that
      // already erased its memory and resets its readiness monitors a second
      // time. Another full drive cycle before the vehicle can pass an
      // emissions test, for a retry that could not help the module that
      // refused anyway.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '04': [0x44]},
          ),
          FakeEcu(
            name: 'TCM',
            requestId: '7E1',
            responseId: '7E9',
            responses: {
              '0100': [0x41, 0x00, 0x80, 0x00, 0x00, 0x00],
              '04': [0x7F, 0x04, 0x22],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.message, 'message', contains('不要再送一次'))
            .having((e) => e.message, 'message', isNot(contains('再試一次')))),
        reason: '7E8 already cleared; telling somebody to repeat a global '
            'clear costs it another drive cycle',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R28-audit: a support mask that is wrong does not kill a PID forever',
        () async {
      // From the refusal audit. A PID the mask denies was invalidated and then
      // skipped forever by the fault it had just been given, so
      // `_answeredAtLeastOnce` — the rule that lets a direct answer outrank an
      // absent mask bit — could never fire. On a clone with an inaccurate
      // support map that is a sensor the vehicle actually has, dark for the
      // whole connection, with no way back short of reconnecting.
      //
      // The mask below denies everything past the first block while the ECU
      // answers `010C` perfectly well.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              // Bit for 0x0C cleared: the mask says no engine speed.
              '0100': [0x41, 0x00, 0xB8, 0x0F, 0xA8, 0x11],
              '010C': [0x41, 0x0C, 0x1A, 0xF8],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverSupportedPids();
      expect(engine.isKnownUnsupported(PidLibrary.engineRpm), isTrue,
          reason: 'sanity: the mask really does deny it');

      // The recheck is long on purpose — the mask is usually right. What
      // matters is that it is finite, and that an answer settles it.
      expect(PollingEngine.unsupportedRecheckInterval.inMinutes, greaterThan(0),
          reason: 'a finite recheck is the whole repair');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R29-codex F6: the recheck actually runs, and the answer wins',
        () async {
      // Codex round 29. The test above pins the *number*, not the rule — and
      // the rule is what matters: a PID the mask denies is asked again, and if
      // the vehicle answers, the answer outranks the mask. Five minutes is
      // right for a car and impossible for a test, so the interval is now
      // reachable and this drives it.
      //
      // The same day this was written, a different rule that nothing pinned
      // was deleted by accident and the whole suite stayed green. That is the
      // argument for this test, not tidiness.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              // Bit for 0x0C cleared: the mask denies engine speed.
              '0100': [0x41, 0x00, 0xB8, 0x0F, 0xA8, 0x11],
              // And the ECU answers it perfectly well anyway. This is the
              // clone-with-a-bad-map case the demotion exists for.
              '010C': [0x41, 0x0C, 0x1A, 0xF8],
            },
          ),
        ],
      );
      final engine = await _connect(transport)
        ..setActivePids([PidLibrary.engineRpm]);
      engine.recheckInterval = Duration.zero;
      await engine.discoverSupportedPids();
      expect(engine.isKnownUnsupported(PidLibrary.engineRpm), isTrue,
          reason: 'sanity: the mask really does deny it');

      engine.start();
      final id = PidLibrary.engineRpm.id;
      final deadline = DateTime.now().add(const Duration(seconds: 8));
      while (engine.current.readings[id] == null &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await engine.stop();

      final reading = engine.current.readings[id];
      expect(reading, isNotNull,
          reason: 'the recheck never ran, so the demotion is a comment rather '
              'than a behaviour.\ncommands: ${transport.commandLog}');
      expect(reading!.value, closeTo(1726, 1),
          reason: 'the vehicle answered, so the vehicle is right — a mask bit '
              'is a claim about the car and the car just contradicted it');
      expect(engine.current.faults[id], isNull,
          reason: 'and the 不支援 label goes with it, or the gauge stays grey '
              'over a live number');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('R21-codex 04: a category nobody was asked about heard nobody',
        () async {
      // Codex round 21. `_lastHeardOfService` is a side channel, and it was
      // set only after a reply arrived. When the header switch for the next
      // category failed before its service byte went out, the previous
      // category's value was still standing — so a Mode 07 the adapter never
      // transmitted reported that somebody had answered it.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'TCM',
            requestId: '7E1',
            responseId: '7E9',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.forceReplySequence('03', ['7E9 04 43 01 07 15\r<RX ERROR']);
      await engine
          .readDtcs(DtcKind.stored)
          .then<void>((_) {})
          .catchError((Object _) {});

      // The next category cannot even be addressed.
      transport.forceReply('ATSH7DF', '?');
      final before = transport.commandLog.length;
      await expectLater(
        engine.readDtcs(DtcKind.pending),
        throwsA(isA<DtcReadException>()
            .having((e) => e.heardAboutService, 'heardAboutService', isEmpty)),
        reason: 'nobody answered a question nobody was asked',
      );
      expect(transport.commandLog.skip(before), isNot(contains('07')));
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R20-codex 02: a damaged reply still shows Mode 03 was answered',
        () async {
      // Codex round 20. Not decoding P0715 out of a reply the adapter marked
      // as damaged is right. Reporting that nobody answered Mode 03 is not:
      // `7E9` identified itself and printed a Mode 03 response.
      //
      // The pending card then said "Mode 03 was silent too", which the wire
      // contradicts.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'TCM',
            requestId: '7E1',
            responseId: '7E9',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.forceReplySequence('03', ['7E9 04 43 01 07 15\r<RX ERROR']);

      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>().having((e) => e.heardAboutService,
            'heardAboutService', contains('7E9'))),
        reason: 'the reply is not data and the controller still answered',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R19-codex 04: a reply about another service is not a fault-code debt',
        () async {
      // Codex round 19. Every attributed source was remembered as a fault-code
      // responder, whatever its payload was about. A stale `41 0C` arriving
      // during a Mode 03 exchange made `7EA` a session-long debt, and the next
      // category — and the clear — were refused for the silence of a
      // controller that had never taken part.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._physicsReplies(),
              '07': [0x47, 0x00],
              '04': [0x44],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.forceReplySequence(
          '03', ['7E8 04 43 01 03 01\r7EA 03 41 0C 00']);
      await engine
          .readDtcs(DtcKind.stored)
          .then<void>((_) {})
          .catchError((Object _) {});

      expect(await engine.readDtcs(DtcKind.pending), isEmpty,
          reason: '7EA answered a Mode 01 request; that is not a claim about '
              'Mode 07');
      expect((await engine.clearDtcs()).isSuccess, isTrue,
          reason: 'nor about Mode 04');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R22-codex 06: a clear reads the service its pending reply names',
        () async {
      // Codex round 22. The clear's `7F xx 78` handling requires `xx` to be
      // Mode 04, and no fixture ever reached that condition: every pending
      // test issued Mode 03, so deleting the service check would have changed
      // nothing anybody was watching.
      //
      // The datasheet is explicit about where the service is: "The Response
      // Pending reply will always be of the form: 7F xx 78 where the xx
      // represents the Mode (or SID) that was being requested" (ELM327DSJ,
      // *Response Pending Messages*). So `7F 01 78` is Mode 01 saying wait,
      // and telling the driver their *clear* was accepted on the strength of
      // it is a claim about a different request entirely.
      FakeElm327 busWithClearReply(List<int> reply) => FakeElm327(
            protocol: BusProtocol.can11,
            ecus: [
              FakeEcu(
                name: 'ECM',
                requestId: '7E0',
                responseId: '7E8',
                responses: {..._physicsReplies(), '04': reply},
              ),
            ],
          );

      final pending = busWithClearReply([0x7F, 0x04, 0x78]);
      final acceptedIt = await _connect(pending);
      await acceptedIt.discoverResponders();
      await expectLater(
        acceptedIt.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.kind, 'kind', DtcReadFailure.pending)),
        reason: 'the controller accepted the clear and is still erasing; '
            'reporting failure invites a blind retry of an operation that '
            'resets the readiness monitors',
      );
      await acceptedIt.dispose();

      final elsewhere = busWithClearReply([0x7F, 0x01, 0x78]);
      final aboutSomethingElse = await _connect(elsewhere);
      await aboutSomethingElse.discoverResponders();
      expect((await aboutSomethingElse.clearDtcs()).isSuccess, isFalse,
          reason: 'Mode 01 saying wait is neither an acknowledgement of the '
              'clear nor a report that the clear is under way');
      await aboutSomethingElse.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('R18-codex 04: a checksum that happens to hold is not a controller',
        () async {
      // Codex round 18. The `41 00` census predicate is the fix for R17-01,
      // and nothing tested the case that made it necessary: a transcript whose
      // fabricated splits *pass* the checksum. All four lines below do.
      //
      //   0100 -> 41 00 BE 1F A8 C6     (41+00+BE+1F+A8) & 0xFF == C6
      //   03   -> 43 00 BE 43 00 00 44
      //   07   -> 47 00 BE 47 00 00 4C
      //   0A   -> 4A 00 BE 4A 00 00 52
      //
      // Read as headers, every one establishes controller `BE` and every DTC
      // class comes back empty. The real headerless Mode 03 pairs are
      // `00 BE`, `43 00`, `00 44` — P00BE, C0300, P0044.
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        faults: const AdapterFaults(lieAboutHeaders: true),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '686AF1',
            responseId: '486B10',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      final engine = await _connect(transport);
      transport.forceReplySequence('0100', ['4100BE1FA8C6']);
      expect(await engine.discoverResponders(), isNull,
          reason: 'a line that is not a `41 00` response establishes nobody, '
              'however well its last byte adds up');

      for (final kind in DtcKind.values) {
        transport.forceReplySequence(kind.mode, [
          {
            DtcKind.stored: '4300BE43000044',
            DtcKind.pending: '4700BE4700004C',
            DtcKind.permanent: '4A00BE4A000052',
          }[kind]!
        ]);
        await expectLater(
          engine.readDtcs(kind),
          throwsA(isA<DtcReadException>()),
          reason: 'and no class may come back clean from bytes nobody can '
              'attribute',
        );
      }
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('R16-codex 01: an invented header does not authenticate itself',
        () async {
      // Codex round 16, on round 15's fix. Dropping the last byte as a
      // checksum without checking it let a fabricated split vouch for itself.
      //
      // An adapter that answers `OK` to `ATH1` and then keeps printing
      // headerless bytes gives, for Mode 03:
      //
      //     4300BE43000000
      //
      // which this pattern reads as header `43 00 BE`, source `BE`, body
      // `43 00 00`, final `00` discarded as though it had proved the split.
      // Decoded that way the car is clean. The real payload is
      // `43 | 00 BE | 43 00 | 00 00` — P00BE and C0300.
      //
      // The checksum is the only thing that tells a real header from an
      // invented one, so it has to hold.
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        faults: const AdapterFaults(lieAboutHeaders: true),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '686AF1',
            responseId: '486B10',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      final engine = await _connect(transport);
      transport.forceReplySequence('0100', ['4100BE1FA81300']);
      await engine.discoverResponders();
      transport.forceReplySequence('03', ['4300BE43000000']);

      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()),
        reason: 'bytes that do not check out are damage, and damage is not a '
            'clean bill of health for a car that just reported two codes',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R15-codex 02: the legacy checksum is not a fault code', () async {
      // Codex round 15, on a defect older than any of these rounds. With
      // `ATH1` the adapter prints the complete legacy message — three header
      // bytes, the data, and the trailing checksum — and the parser turned
      // everything after the header into payload.
      //
      // A Mode 03 decoder strips the service byte and pairs what is left, so
      // the checksum made the remainder odd and every real J1850 / ISO 9141 /
      // KWP fault-code reply read as unparseable. The fixtures omitted the
      // byte too, so the suite modelled the same wrong wire and nothing could
      // notice.
      //
      // Codex's oracle, with the check bytes computed here rather than
      // captured — the payloads are its, the CRC-8 is this file's.
      final transport = FakeElm327(
        protocol: BusProtocol.j1850vpw,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '686AF1',
            responseId: '486B10',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      final engine = await _connect(transport);
      transport.forceReplySequence('03', [
        '${_withChecksum('48 6B 10 43 03 00 03 02 03 03', j1850: true)}\r'
            '${_withChecksum('48 6B 10 43 03 04 00 00 00 00', j1850: true)}',
      ]);

      expect((await engine.readDtcs(DtcKind.stored)).map((c) => c.code).toSet(),
          {'P0300', 'P0302', 'P0303', 'P0304'},
          reason: 'four codes the car reported, and the byte that checks them '
              'is not a fifth');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R14-codex 01: an adapter error marker does not erase who answered',
        () async {
      // Codex round 14. `attributedSources` was populated only from lines that
      // matched a complete header-plus-payload regex, and `_classifyError`
      // runs *before* either parser — so a reply the adapter ended with
      // `<RX ERROR` came back with no identities at all.
      //
      // The datasheet is explicit that both markers print what was received
      // first, so this is evidence the adapter promises to show and the app
      // was discarding.
      //
      //   0100   7E8 only                    → census {7E8}
      //   03     7E9 … P0715, then <RX ERROR → unreadable, and 7E9 answered
      //   07     7E8 … P0300                 → the clear button appears
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '07': [0x47, 0x01, 0x03, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.forceReplySequence('03', ['7E9 04 43 01 07 15\r<RX ERROR']);
      await engine
          .readDtcs(DtcKind.stored)
          .then<void>((_) {})
          .catchError((Object _) {});

      // Watched through the coverage record. Modes 07 and 0A are optional in
      // J1979, so a module that never implements them is a healthy vehicle,
      // and holding every controller to them rejected standards-compliant
      // cars. The class completes; what it could not reach is recorded, and
      // the scan's verdict consumes that. What this test is about — a
      // controller that answered is not forgotten — is unchanged.
      await engine
          .readDtcs(DtcKind.pending)
          .then<void>((_) {})
          .catchError((Object _) {});
      expect(engine.optionalNotCovered[DtcKind.pending], contains('7E9'),
          reason: 'the adapter printed the transmission\'s reply before saying '
              'the line was bad; that it was bad does not unsay who sent it',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R13-codex 01: a damaged reply does not make the app forget who '
        'answered', () async {
      // Codex round 13. Narrowing coverage back to fault-code evidence was
      // right; doing it by dropping the identities carried on a *failed*
      // exchange was not. Payload validity and responder identity are separate
      // facts.
      //
      //   0100  486B10 only
      //   03    486B18 … P0715, then a bare damaged 486B10 line → DATA ERROR
      //   07    486B10 … P0300      → the clear button appears
      //   04    486B10 44           → accepted, because 486B18 was forgotten
      //
      // Then a clean rescan from the ECM alone renders a green all-clear while
      // the transmission still holds P0715.
      final transport = FakeElm327(
        protocol: BusProtocol.j1850vpw,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '686AF1',
            responseId: '486B10',
            responses: {
              ..._physicsReplies(),
              '07': [0x47, 0x03, 0x00],
              '04': [0x44],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();

      // One valid TCM message beside one damaged ECM line.
      transport.forceReplySequence(
          '03', ['${_withChecksum('486B18 43 07 15', j1850: true)}\r486B10']);
      await engine
          .readDtcs(DtcKind.stored)
          .then<void>((_) {})
          .catchError((Object _) {});

      // The next category is where the forgetting shows: `486B18` answered
      // this scan, so its silence here is an incomplete result rather than a
      // clean one — and the same set is what a clear would be measured
      // against.
      // Watched through the coverage record. Modes 07 and 0A are optional in
      // J1979, so a module that never implements them is a healthy vehicle,
      // and holding every controller to them rejected standards-compliant
      // cars. The class completes; what it could not reach is recorded, and
      // the scan's verdict consumes that. What this test is about — a
      // controller that answered is not forgotten — is unchanged.
      await engine
          .readDtcs(DtcKind.pending)
          .then<void>((_) {})
          .catchError((Object _) {});
      expect(engine.optionalNotCovered[DtcKind.pending], contains('18'),
          reason: 'the transmission answered this scan, however unreadable the '
              'exchange as a whole was — and it is controller 18, the source '
              'address, not the whole routing header');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R12-codex 03: a VIN-only responder is not an obligation on Mode 04',
        () async {
      // Two review rounds asked for opposite things here, and this is the
      // reading that survives.
      //
      // Round 11 said a controller heard on the VIN exchange must count toward
      // the clear's coverage, because it had demonstrably answered. Round 12
      // said the opposite, and gave the reason: existing on the bus is not
      // implementing a service. A gateway that supplies a VIN has shown Mode
      // 09 support and nothing whatever about Mode 03 or Mode 04, so holding
      // its silence against a clear refuses one the vehicle performed.
      //
      // Fault-code coverage is the census plus controllers heard on fault-code
      // exchanges. That still catches the case all of this started from — a
      // transmission that answered Mode 03 and then went quiet.
      //
      //   0100  7E8 only            → census {7E8}
      //   03    7E8 … P0301
      //   0902  7E9 answers         → Mode 09, and only Mode 09
      //   04    7E8 01 44           → a complete clear
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._physicsReplies(),
              '03': [0x43, 0x01, 0x03, 0x01],
              '04': [0x44],
            },
          ),
          FakeEcu(
            name: 'gateway',
            requestId: '7E1',
            responseId: '7E9',
            // Absent from the handshake and from Mode 03; it answers the VIN.
            responses: {
              '0902': [
                0x49, 0x02, 0x01, //
                ...'1D4GP00R55B123456'.codeUnits,
              ],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      expect(await engine.discoverResponders(), {'7E8'},
          reason: 'sanity: the census finds one');
      await engine.readVin();

      expect((await engine.clearDtcs()).isSuccess, isTrue,
          reason: 'the gateway demonstrated Mode 09 and nothing about Mode 04; '
              'requiring it to acknowledge a clear refuses one the vehicle '
              'plainly performed');
      await engine.dispose();
    });

    test('R10-codex C-01: a census that found one does not out-rank a scan '
        'that heard two', () async {
      // Codex, round 10, on the fix from round 9. `_responders` and
      // `_observedResponders` are both *lower bounds* on who is out there, and
      // they were being used as alternatives: the read consulted only the
      // census, and the clear preferred it whenever it was non-null. So a
      // census that found one controller masked a Mode 03 that had just heard
      // from two.
      //
      //   0100   7E8 only                  → census {7E8}
      //   03     7E8 clean, 7E9 clean      → both demonstrated to exist
      //   07     7E8 only                  → 7E9 silent, and nothing notices
      //
      // Green 未偵測到故障碼, with the evidence that `7E9` exists sitting one
      // field away from the check that would have used it.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._physicsReplies(),
              '03': [0x43, 0x00],
              '07': [0x47, 0x00],
              '0A': [0x4A, 0x00],
            },
          ),
          FakeEcu(
            name: 'TCM',
            requestId: '7E1',
            responseId: '7E9',
            // Absent from the handshake, present on the stored class, silent
            // for the optional ones — a module that answers what it
            // implements.
            responses: {'03': [0x43, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      expect(await engine.discoverResponders(), {'7E8'},
          reason: 'sanity: the census really did find only one');

      expect(await engine.readDtcs(DtcKind.stored), isEmpty,
          reason: 'both answered this one, so it is a complete answer');

      // The fixture's own comment says it: 「a module that answers what it
      // implements」. That is a compliant vehicle, and round 26 established
      // that refusing the optional class for it rejects standards-compliant
      // cars. So the class completes — and the fact that 7E9 was never asked
      // is recorded, which is what stops the scan calling the vehicle clean.
      expect(await engine.readDtcs(DtcKind.pending), isEmpty);
      expect(engine.optionalNotCovered[DtcKind.pending], contains('7E9'),
          reason: 'the stored class proved 7E9 is on this bus; the optional '
              'one cannot then be reported as a whole-vehicle result without '
              'it');
      await engine.dispose();
    });

    test('R9-codex C-03: a clear is measured against the controllers the scan '
        'just heard', () async {
      // Codex. The census is the handshake `0100`; when that comes back
      // `NO DATA` the clear had no set to compare against and one `7E8 01 44`
      // stood for the vehicle. The screen the button lives on had, seconds
      // earlier, listed a fault against `7E9` — so the evidence the check
      // needed was already on it.
      //
      //   0100  NO DATA                 → no census
      //   03    7E8 … P0301             → and 7E9 … P0715
      //   04    7E8 01 44               → 7E9 silent
      //
      // 已送出清除指令, and the transmission fault is still in the
      // transmission. A controller that answered Mode 03 is on this bus by
      // demonstration; that is a stronger fact than a census reply, not a
      // weaker one.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._physicsReplies(),
              '03': [0x43, 0x01, 0x03, 0x01],
              '04': [0x44],
            },
          ),
          FakeEcu(
            name: 'TCM',
            requestId: '7E1',
            responseId: '7E9',
            // Answers the scan, deaf to the clear.
            responses: {'03': [0x43, 0x01, 0x07, 0x15]},
          ),
        ],
      );
      final engine = await _connect(transport);
      // After the handshake, which needs `0100` to work. This is the adapter
      // that connects and then degrades, which is what the census failing
      // actually looks like in the field.
      transport.forceReply('0100', 'NO DATA');
      expect(await engine.discoverResponders(), isNull,
          reason: 'sanity: `0100` failed, so there is no census — which is the '
              'precondition, not the defect');

      // The scan the user ran before reaching for the button. It cannot claim
      // to be a whole-vehicle result without a census, and says so; what
      // matters here is that both controllers were heard while it tried.
      final scanned = await engine
          .readDtcs(DtcKind.stored)
          .then<List<Dtc>>((c) => c)
          .catchError((Object e) => (e as DtcReadException).partial);
      expect(scanned.map((d) => d.code), containsAll(['P0301', 'P0715']),
          reason: 'sanity: the screen showed a fault against each controller');

      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.kind, 'kind', DtcReadFailure.noAnswer)
            .having((e) => e.message, 'message', contains('7E9'))),
        reason: 'the one controller that did not acknowledge is the one worth '
            'naming — and re-issuing Mode 04 blindly costs another drive cycle',
      );
      await engine.dispose();
    });
  });

  group('a request built from a definition that is gone', () {
    test('R8-7: an old queued request does not write the new definition',
        () async {
      // `docs/verification/test-evidence.md` listed this guard as "reasoned, not demonstrated":
      // the first test written for it passed with the guard removed, because
      // at the moment the definitions were swapped no request from the old set
      // happened to be outstanding, and the scheduler offers no way to say
      // which PID is in flight.
      //
      // GPT-5.6 Pro supplied the way round it, and it does not need in-flight
      // work at all: inject the scheduler, enqueue a request built from the
      // old definition, swap the definitions for one with the same id, and
      // start. The queued object is dequeued *after* the swap, so `_pollBatch`
      // captures the new generation and the guard would pass — while the
      // request itself still carries `A*10`, and raw `0x0A` becomes 100 for a
      // gauge whose only surviving definition says 10.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '010B': [0x41, 0x0B, 0x0A]},
          ),
        ],
      );
      final client = Elm327Client(transport,
          commandTimeout: const Duration(milliseconds: 200));
      expect(await client.connect(), isTrue);

      final scheduler = PriorityScheduler();
      final engine = PollingEngine(client, scheduler: scheduler);

      final tenfold = _pid('010B', 'A*10', variant: 'x10', isCustom: true);
      final plain = _pid('010B', 'A', variant: 'x10', isCustom: true);
      expect(tenfold.id, plain.id,
          reason: 'same gauge, edited formula — which is why the stale request '
              'lands on the live definition');

      scheduler.enqueueRequest(QueuedRequest(tenfold, tenfold.priority));
      engine.setActivePids([plain]);
      engine.start();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await engine.stop();

      final reading = engine.current.readings[plain.id];
      if (reading != null) {
        expect(reading.value, closeTo(10, 0.001),
            reason: 'the surviving definition says `A`, so 0x0A is 10; 100 is '
                'the removed definition answering for it');
      }
      await engine.dispose();
      await client.dispose();
    });
  });

  group('one unreadable controller does not hide the rest', () {
    test('R8-13: a complete fault behind a damaged frame is still found',
        () async {
      // GPT-5.6 Pro. A `StateError` from the decoder ended the whole loop, so
      // every controller after the damaged one was never examined. One module
      // sending half a code — `43 01 03`, an odd remainder — hid a complete
      // `43 01 07 00` from the module behind it. **Swapping the order of the
      // two lines changed which faults the user was shown**, and a result that
      // depends on bus ordering is not a result.
      //
      // The category still fails, because it is genuinely incomplete. What
      // changes is that the reading gets far enough to find what is there.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      final engine = await _connect(transport);
      transport.forceReplySequence('03', [
        // Damaged first: an odd remainder the decoder refuses.
        '7E8 03 43 01 03\r7E9 04 43 01 07 00',
      ]);

      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>().having(
            (e) => e.partial.map((d) => d.code), 'partial', contains('P0700'))),
        reason: 'the transmission fault is real and complete; the module in '
            'front of it being unreadable is not a reason to never look',
      );
      await engine.dispose();
    });
  });

  group('an answered refusal is not a lost stream', () {
    test('R8-16: an adapter that refuses ATH0 is not disconnected for it',
        () async {
      // GPT-5.6 Pro. `ATH0` answered with `?` is a complete exchange — the
      // prompt arrived, so the stream is in step; the adapter merely declined
      // to turn headers off. Marking the link out of sync sent the next
      // command into `_resync`, which drains waiting for a prompt from a
      // command nobody issued, times out after three seconds, and tears the
      // session down.
      //
      // What the user saw: a fault-code scan that succeeded, and every gauge
      // disconnecting three seconds later.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        faults: const AdapterFaults(refuseHeadersOff: true),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
      );
      final client = Elm327Client(transport,
          commandTimeout: const Duration(milliseconds: 400));
      expect(await client.connect(), isTrue);
      final engine = PollingEngine(client);

      expect(await engine.readDtcs(DtcKind.stored), isEmpty,
          reason: 'sanity: the scan itself works');
      expect(client.isOutOfSync, isFalse,
          reason: 'the prompt came back; nothing is owed and nothing needs '
              'draining');

      // And the link keeps working, which is the part the user notices.
      final rpm = await client.send('010C');
      expect(rpm.isSuccess, isTrue,
          reason: 'a refusal to change rendering is not a reason to end the '
              'session');
      await engine.dispose();
      await client.dispose();
    });
  });

  group('one question with one answer may not have two', () {
    test('R8-15: a functional custom Mode 22 does not take the first replier',
        () async {
      // GPT-5.6 Pro. The same defect H-03 fixed for widthless Mode 01, in the
      // sibling path nobody looked at: `_dataForNonMode01` read the flattened
      // payload, validated the first positive envelope, and returned
      // everything after it.
      //
      // A custom PID may use a functional header, and two controllers then
      // answer `22 F1 90` with different values. Concatenated that is
      // `62 F1 90 10 62 F1 90 50`, and the parser publishes `A = 0x10 = 16` —
      // a confident number from whichever controller printed first, with the
      // equally valid `0x50` swallowed into its tail.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7DF',
            responseId: '7E8',
            responses: {..._physicsReplies()},
            literalResponses: {
              '22F190': ['62 F1 90 10', '62 F1 90 50'],
            },
          ),
        ],
      );
      final custom = _pid('22F190', 'A', variant: 'vin-ident', isCustom: true,
          header: '7DF');
      final engine = await _poll(
        transport,
        [custom],
        settled: (e) => _decided(e, custom.id),
      );
      expect(engine.current.readings[custom.id], isNull,
          reason: 'two controllers gave different answers to a question with '
              'one answer; 16 is not more true than 80 for having been '
              'printed first');
      await engine.dispose();
    });
  });

  group('a default that reaches everyone is not a default to leave alone', () {
    test('R8 C-02: 29-bit built-in polling addresses the engine, not the bus',
        () async {
      // GPT-5.6 Pro. Round 7 taught `sendAddressed` to transmit nothing when
      // nothing had been displaced, which is right on 11-bit CAN — `7E0` is
      // transmittable there and gets installed explicitly. On 29-bit it is
      // not: `kDefaultHeader` means nothing on that bus, `_currentHeader`
      // stays null, and the adapter's own default is the *functional* ID
      // `18DB33F1`.
      //
      // Every emissions controller answers a functional request. With headers
      // off their replies arrive as separate lines and are concatenated into
      // one payload, so a batch boundary is read across two controllers and
      // the dashboard is populated by whichever answered first.
      final transport = FakeElm327(
        protocol: BusProtocol.can29,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '18DA10F1',
            responseId: '18DAF110',
            responses: {..._physicsReplies()},
          ),
          FakeEcu(
            name: 'TCM',
            requestId: '18DA1EF1',
            responseId: '18DAF11E',
            // A different, entirely plausible rpm.
            responses: {'010C': [0x41, 0x0C, 0x2E, 0xE0]},
          ),
        ],
      );
      final rpm = _pid('010C', '((A*256)+B)/4');
      final engine = await _poll(
        transport,
        [rpm],
        settled: (e) => _decided(e, rpm.id),
      );

      expect(
        transport.commandLog,
        contains('ATSH18DA10F1'),
        reason: 'the engine has a physical address on this bus and the app '
            'knows it; asking the whole bus instead invites an answer from '
            'someone else',
      );
      expect(engine.current.readings[rpm.id]?.value, closeTo(1726, 1),
          reason: "and the value is the engine's, not whichever controller "
              'replied first');
      await engine.dispose();
    });
  });

  group('a write that timed out is unknown, not undone', () {
    test('R7 H-01: a stalled write leaves the link marked out of sync',
        () async {
      // Codex H-01 and Fable F-12, found independently. `Future.timeout` does
      // not cancel what it is timing. `WifiTransport.write` is `socket.add`
      // followed by `await flush()`, and `add` has already given the bytes to
      // the kernel — so the deadline expiring says the flush did not finish,
      // never that nothing was sent.
      //
      // Recorded as "the command never reached the adapter", the client
      // carried on with a link it had no reason to trust: the buffered request
      // arrives late, its valid reply completes the *next* command, and an old
      // sample is published under a new timestamp. Every value on screen is
      // one request stale and nothing says so.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      final client = Elm327Client(
        transport,
        commandTimeout: const Duration(milliseconds: 200),
        writeTimeout: const Duration(milliseconds: 80),
      );
      expect(await client.connect(), isTrue);

      transport.stallWriteCompletion = true;
      await expectLater(
        client.send('010C'),
        throwsA(isA<TimeoutException>()),
        reason: 'the write deadline still has to fire — the caller cannot be '
            'left parked on a flush that never returns',
      );
      expect(client.isOutOfSync, isTrue,
          reason: 'the adapter received that command and is answering it; the '
              'next write must drain first or inherit the reply');
      await client.dispose();
    });

    test("R8 C-01: a reply to a write that threw cannot answer the next "
        'command', () async {
      // GPT-5.6 Pro, reviewing the fix above. Splitting on
      // `e is TimeoutException` and calling everything else "not sent" was
      // itself a guess: `socket.add` hands the bytes to the kernel and `flush`
      // is what throws, so a `SocketException` — connection reset, broken pipe
      // — surfaces *after* the adapter may already have the command. The
      // exception's Dart class is not evidence about the wire.
      //
      // The consequence is not a lost command but a mislabelled one, and that
      // is what this asserts: ask for speed, have the write throw once the
      // adapter already has it, then ask for rpm. The speed reply must not
      // become the rpm answer.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        // Long enough that the orphaned reply is still in flight when the next
        // command goes out — which is the whole race.
        responseLatency: const Duration(milliseconds: 150),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      final client = Elm327Client(transport,
          commandTimeout: const Duration(seconds: 2));
      expect(await client.connect(), isTrue);

      transport.failWriteAfterAccepting = true;
      await expectLater(client.send('010D'), throwsA(isA<Exception>()));
      transport.failWriteAfterAccepting = false;

      final rpm = await client.send('010C');
      expect(rpm.bytes.take(2), [0x41, 0x0C],
          reason: 'the speed reply the adapter still owed must not be handed '
              'to the request that asked about rpm — a real number under the '
              'wrong label is the one failure this app cannot have');
      await client.dispose();
    });

    test('R7 H-01: a write that genuinely failed is still counted as unsent',
        () async {
      // The other half. A transport that *refuses* the bytes has sent nothing,
      // and treating that as unknown would have the watchdog count silence
      // against a request that was never made — tearing the link down five
      // seconds later on top of the error the caller already had.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      final client = Elm327Client(transport,
          commandTimeout: const Duration(milliseconds: 200));
      expect(await client.connect(), isTrue);

      await transport.disconnect();
      await expectLater(client.send('010C'), throwsA(isA<Exception>()));
      expect(client.isOutOfSync, isFalse,
          reason: 'nothing went out, so there is nothing to resynchronise '
              'with');
      await client.dispose();
    });
  });

  group('a numbered envelope accounts for every line too', () {
    test('R7 M-04: a damaged line inside an ISO-TP reply is not skipped',
        () async {
      // The last hiding place for the defect C-03 fixed in its sibling. Once
      // one `N:` segment exists the multi-frame parser owns the whole reply,
      // and every non-sequenced line after the length header was silently
      // dropped — so a truncated peer vanished behind a declaration the real
      // segments happened to satisfy.
      //
      //   004
      //   0: 41 0C 1A F8
      //   430
      //
      // Four bytes promised, four bytes delivered, `430` gone, and 1726 rpm
      // published beside evidence that something arrived damaged.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies()},
            literalResponses: {
              '010C': ['004', '0: 41 0C 1A F8', '430'],
            },
          ),
        ],
      );
      final client = Elm327Client(transport);
      expect(await client.connect(), isTrue);
      final reply = await client.send('010C');
      expect(reply.isSuccess, isFalse,
          reason: 'a frame the app cannot fully account for is not the answer '
              'to the question it asked');
      await client.dispose();
    });

    test('R7 M-04: an intact numbered reply still parses', () async {
      // The counterpart. Rejecting damage must not start rejecting the
      // ordinary multi-frame shape — that is the over-strictness this project
      // spent round 6 undoing.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies()},
            literalResponses: {
              '010C': ['004', '0: 41 0C 1A F8'],
            },
          ),
        ],
      );
      final client = Elm327Client(transport);
      expect(await client.connect(), isTrue);
      final reply = await client.send('010C');
      expect(reply.isSuccess, isTrue);
      expect(reply.bytes, [0x41, 0x0C, 0x1A, 0xF8]);
      await client.dispose();
    });
  });

  group('a legacy reply is attributed all the way to the verdict', () {
    test('R7 C-02: two controllers cannot be spliced into one VIN', () async {
      // Codex's trigger. `_parseHeaderedLegacy` preserves each line's source,
      // and `readVin` then collected every frame into one map keyed by the
      // sequence byte alone — so two modules dividing the numbering between
      // them were assembled into a single 17-character VIN that passes every
      // syntactic check and belongs to no vehicle. Attribution was collected
      // and then discarded at the identity boundary it existed for.
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '686AF1',
            responseId: '486B10',
            responses: {..._physicsReplies()},
            literalResponses: {
              '0902': [
                _withChecksum('486B10 49 02 01 00 00 00 31'),
                _withChecksum('486B10 49 02 02 48 47 43 4D'),
                _withChecksum('486B18 49 02 03 38 32 36 33'),
                _withChecksum('486B18 49 02 04 33 41 30 30'),
                _withChecksum('486B18 49 02 05 34 33 35 32'),
              ],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      expect(await engine.readVin(), isNull,
          reason: 'neither controller gave a whole VIN, so neither did the '
              'vehicle — 1HGCM82633A004352 here is a composite, not a car');
      await engine.dispose();
    });

    test('R7 C-02: one controller answering completely is still read',
        () async {
      // The counterpart. Grouping per source must not turn into refusing
      // every legacy VIN — a single responder giving all five lines is the
      // ordinary case and has to keep working.
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '686AF1',
            responseId: '486B10',
            responses: {..._physicsReplies()},
            literalResponses: {
              '0902': [
                _withChecksum('486B10 49 02 01 00 00 00 31'),
                _withChecksum('486B10 49 02 02 48 47 43 4D'),
                _withChecksum('486B10 49 02 03 38 32 36 33'),
                _withChecksum('486B10 49 02 04 33 41 30 30'),
                _withChecksum('486B10 49 02 05 34 33 35 32'),
              ],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      expect(await engine.readVin(), '1HGCM82633A004352');
      await engine.dispose();
    });

    test('R7 C-03: a damaged legacy peer is not hidden by a clean one',
        () async {
      // Codex's trigger, through a connected client rather than the parser
      // helper. The second line is a controller header whose payload was
      // lost — all hex, plainly damaged — and the legacy parser skipped it,
      // so the first controller's `43 00` closed the category as a verified
      // all-clear. This became reachable the moment `ATH1` was enabled on
      // legacy buses: the parser had never run before.
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '686AF1',
            responseId: '486B10',
            responses: {..._physicsReplies()},
            literalResponses: {
              '03': [_withChecksum('486B10 43 00 00 00 00 00 00'), '486B18'],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()),
        reason: 'visible transport damage cannot become a verified all-clear '
            'just because a well-formed peer answered first',
      );
      await engine.dispose();
    });
  });

  group('waiting for a controller does not cost what already arrived', () {
    test("R7 C-01: a peer's clean reply cannot erase a fault already proven",
        () async {
      // Codex's trigger, and a review of yesterday's fix rather than of the
      // code it fixed — the eighth time this project has produced "the fix
      // introduced the next defect", and the second caught in the same day.
      //
      // Making a promise personal fixed *who* may discharge it. It left every
      // attempt building its own result list, so the sequence that matters
      // most lost the fault it had already proven:
      //
      //   attempt 1   7E8 04 43 01 03 01     ECM: P0301, decoded and real
      //               7E9 03 7F 03 78        TCM: still working
      //   attempt 2   7E9 02 43 00           TCM: finished, nothing wrong
      //
      // The debt is properly discharged by its own author, the read returns
      // attempt 2's empty list, and the screen shows a verified all-clear for
      // a car with a confirmed misfire. Strictly worse than the bug it
      // replaced, because this one ends in green.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      transport.forceReplySequence('03', [
        '7E8 04 43 01 03 01\r7E9 03 7F 03 78',
        '7E9 02 43 00',
      ]);

      final engine = await _connect(transport);
      final codes = await engine.readDtcs(DtcKind.stored);
      expect(
        codes.map((d) => d.code),
        contains('P0301'),
        reason: 'the misfire was decoded before the wait began and is still '
            'true after it; waiting cannot unfind a fault',
      );
      expect(codes.single.sourceId, '7E8',
          reason: 'and it is still attributed to the controller that saw it');
      await engine.dispose();
    });

    test('R9-cursor: an optional class heard by one controller is not green',
        () async {
      // The census was Mode 03 only. Modes 07 and 0A *are* optional in J1979,
      // so a controller that implements neither may ignore them — but "this
      // silence is legitimate" and "everyone answered" are different
      // statements, and only the second earns a green panel.
      //
      // A vehicle whose transmission answers Mode 03 and stays quiet on Mode
      // 07 — while holding a pending P0301 — showed 未偵測到故障碼 across all
      // three classes, with nothing saying one of them had heard only the
      // engine. Mode 04 already used the census; the read of the same optional
      // class did not.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              ..._physicsReplies(),
              '03': [0x43, 0x00],
              '07': [0x47, 0x00],
            },
          ),
          FakeEcu(
            name: 'TCM',
            requestId: '7E1',
            responseId: '7E9',
            // Answers the census and Mode 03, and is silent on Mode 07 while
            // holding a pending fault.
            responses: {
              '0100': [0x41, 0x00, 0x80, 0x00, 0x00, 0x00],
              '03': [0x43, 0x00],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();

      expect(await engine.readDtcs(DtcKind.stored), isEmpty,
          reason: 'sanity: both controllers answered Mode 03, so that class '
              'really is complete and clean');

      // Qualified, not refused — and the qualification is what round 26
      // changed. Refusing the class rejects a compliant vehicle, because Modes
      // 07 and 0A are optional and a module may simply not implement them. So
      // the class completes and the module it never reached is recorded, and
      // the scan's verdict is what turns that into 部分未確認 rather than a
      // green panel. Both halves are asserted here, because a green panel is
      // exactly what this test exists to prevent.
      expect(await engine.readDtcs(DtcKind.pending), isEmpty);
      expect(engine.optionalNotCovered[DtcKind.pending], contains('7E9'),
          reason: 'one of two controllers answered, so this class is partial — '
              'qualified, not refused, and certainly not green');
      expect(
        scanVerdict(
          hasScanned: true,
          totalCodes: 0,
          answered: DtcKind.values.toSet(),
          optionalCoverageComplete:
              engine.optionalNotCovered.values.every((s) => s.isEmpty),
        ),
        ScanVerdict.partialClean,
        reason: 'every class answered is not every class answered by '
            'everybody, and only the second earns an unqualified all-clear',
      );
      await engine.dispose();
    });

    test('R9-kimi: the census counts the whole read, not one attempt',
        () async {
      // The census check compared against *this attempt's* terminal sources,
      // four hours after this same file established that a global re-ask
      // cannot require a settled controller to answer again. The sibling
      // branch, verbatim.
      //
      //   census      {7E8, 7E9}
      //   attempt 1   7E8 04 43 01 03 01   ECM: P0301, terminal
      //               7E9 03 7F 03 78      TCM: pending
      //   attempt 2   7E9 02 43 00         TCM: terminal — and the ECM, under
      //                                    no obligation, says nothing
      //
      // Every controller answered during the read. The check failed the
      // vehicle anyway and named 7E8 — the one that answered *first* — as
      // completely unresponsive. Refusing a car that answered is as much a
      // defect as trusting one that did not.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies()},
          ),
          FakeEcu(
            name: 'TCM',
            requestId: '7E1',
            responseId: '7E9',
            responses: {'0100': [0x41, 0x00, 0x80, 0x00, 0x00, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      expect(await engine.discoverResponders(), containsAll(['7E8', '7E9']),
          reason: 'sanity: both are on the census, which is the premise');

      transport.forceReplySequence('03', [
        '7E8 04 43 01 03 01\r7E9 03 7F 03 78',
        '7E9 02 43 00',
      ]);

      final codes = await engine.readDtcs(DtcKind.stored);
      expect(codes.map((d) => d.code), contains('P0301'),
          reason: 'both controllers gave a terminal answer during this read, '
              'so the category is complete and the misfire is its result');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('R8-17: a controller that finished is not put back in debt', () async {
      // GPT-5.6 Pro, and the mirror of the fix above: codes accumulate across
      // attempts and the *finished* set did not.
      //
      //   attempt 1   7E8 04 43 01 03 01   ECM: P0301, terminal
      //               7E9 03 7F 03 78      TCM: pending
      //   attempt 2   7E8 03 7F 03 78      ECM: pending on a broadcast it did
      //                                    not need to receive
      //               7E9 02 43 00         TCM: terminal, clean
      //
      // Every controller has given a terminal answer during this logical read.
      // The bookkeeping still ended holding `{7E8}` — because the retry is a
      // *global* re-request, and it reached a controller that had already
      // answered. The instrument was manufacturing its own debt.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      transport.forceReplySequence('03', [
        '7E8 04 43 01 03 01\r7E9 03 7F 03 78',
        '7E8 03 7F 03 78\r7E9 02 43 00',
      ]);

      final engine = await _connect(transport);
      final codes = await engine.readDtcs(DtcKind.stored);
      expect(codes.map((d) => d.code), contains('P0301'),
          reason: 'both controllers answered; the category is complete and the '
              'misfire is its result');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('R7 C-01: a failure still reports everything the attempts found',
        () async {
      // The same accumulator, exercised through the exit that throws. The ECM
      // reports P0301 and the TCM promises an answer it never gives, so the
      // category is genuinely incomplete — but the fault is not less real for
      // that, and it has to reach the screen on the exception.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      transport.forceReplySequence('03', [
        '7E8 04 43 01 03 01\r7E9 03 7F 03 78',
        '7E9 03 7F 03 78',
        '7E9 03 7F 03 78',
      ]);

      final engine = await _connect(transport);
      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()
            .having((e) => e.partial.map((d) => d.code), 'partial',
                contains('P0301'))
            .having((e) => e.pendingSources, 'pendingSources', contains('7E9'))),
        reason: 'incomplete coverage qualifies a finding; it does not delete '
            'it',
      );
      await engine.dispose();
    });
  });

  group('a header the app cannot restore is not a header it may guess', () {
    // Round 7, F-2. `BusAddressing.engineHeader` returned `6810F1` for J1850,
    // ISO 9141-2 and ISO 14230-4 alike, justified in a comment as "the
    // datasheet's own ATSH example for a legacy bus (p.42)". `68 10 F1`
    // appears nowhere in ELM327DSJ; the physical example there is
    // `AT SH E4 10 F1`, and `E4` is a J1850 *PWM* priority byte.
    //
    // What made it dangerous was not the wrong bytes but where they were sent.
    // One custom PID with an explicit legacy header, and every built-in query
    // afterwards was addressed to a controller that does not exist: all gauges
    // dark, `NO DATA`, backoff — while the custom PID itself kept answering,
    // which reads as a car problem rather than an app one.

    test('R7 F-2: a displaced legacy header is restored to the documented '
        'default, not to an invented physical address', () async {
      // The ECM answers on the adapter's own ISO 9141 default and on nothing
      // else, which is what a real controller does: `686AF1` is quoted by the
      // datasheet's Periodic Messages section as what "default settings will
      // send" on this bus.
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '686AF1',
            responseId: '486BF1',
            responses: {..._physicsReplies(), '010C': [0x41, 0x0C, 0x1A, 0xF8]},
          ),
          FakeEcu(
            name: 'TCM',
            requestId: '6C10F1',
            responseId: '486B18',
            responses: {'221101': [0x62, 0x11, 0x01, 0x2A]},
          ),
        ],
      );

      final custom = _pid('221101', 'A', header: '6C10F1');
      final rpm = _pid('010C', '((A*256)+B)/4');
      final engine = await _poll(
        transport,
        [custom, rpm],
        settled: (e) => _decided(e, custom.id) && _decided(e, rpm.id),
      );

      expect(engine.current.readings[rpm.id]?.value, closeTo(1726, 1),
          reason: 'the built-in gauge has to keep reading after a custom PID '
              'moves the header — the whole defect was that it went dark');
      expect(
        transport.commandLog,
        isNot(contains('ATSH6810F1')),
        reason: 'the invented header must never reach the wire',
      );
      expect(
        transport.commandLog,
        contains('ATSH686AF1'),
        reason: "restoring means returning to the adapter's own default, "
            'which is quoted rather than derived',
      );
      await engine.dispose();
    });

    test('R7 F-2: nothing is transmitted when nothing was displaced',
        () async {
      // The counterpart, and the reason this is safe to ship without hardware.
      // On the overwhelmingly common legacy vehicle — no custom PID, adapter
      // untouched since the handshake — the new restore path must produce no
      // wire traffic at all. Installing the default "just in case" would risk
      // an `ATSH` refusal on a clone for no gain.
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '686AF1',
            responseId: '486BF1',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      final rpm = _pid('010C', '((A*256)+B)/4');
      final engine = await _poll(
        transport,
        [rpm],
        settled: (e) => _decided(e, rpm.id),
      );
      expect(
        transport.commandLog.where((c) => c.startsWith('ATSH')),
        isEmpty,
        reason: 'the adapter was already addressing correctly; the app has no '
            'business changing that',
      );
      await engine.dispose();
    });

    test('R7 F-2: J1850 refuses rather than querying the wrong controller',
        () async {
      // The one family where neither address is knowable. The datasheet gives
      // J1850 no default header, and its two protocols disagree — priority
      // `E4` for PWM, `A8` for VPW, "with your knowledge of SAE J2178".
      // The two sub-protocols are separate members now (round 8, finding 8):
      // the adapter tells the app which one via `ATDPN`, and collapsing them
      // manufactured an uncertainty the app had been handed the answer to.
      // Splitting them does not by itself supply an address — the datasheet
      // gives J1850 no default request header — but it makes each one
      // answerable on its own evidence.
      //
      // The alternative to refusing is sending `010C` to whichever controller
      // the custom PID selected and putting whatever answers on the RPM gauge.
      // A refusal names itself; a wrong number does not.
      final transport = FakeElm327(
        protocol: BusProtocol.j1850vpw,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '686AF1',
            responseId: '486BF1',
            responses: {..._physicsReplies()},
          ),
          FakeEcu(
            name: 'TCM',
            requestId: '6C10F1',
            responseId: '486B18',
            responses: {
              '221101': [0x62, 0x11, 0x01, 0x2A],
              // The trigger: this controller answers `010C` too, and its
              // answer is a perfectly plausible 3000 rpm.
              '010C': [0x41, 0x0C, 0x2E, 0xE0],
            },
          ),
        ],
      );

      final custom = _pid('221101', 'A', header: '6C10F1');
      final rpm = _pid('010C', '((A*256)+B)/4');
      final engine = await _poll(
        transport,
        [custom, rpm],
        settled: (e) => _decided(e, custom.id) && _decided(e, rpm.id),
      );

      expect(engine.current.readings[rpm.id], isNull,
          reason: "the transmission's rpm is not the engine's rpm, however "
              'well formed it is');
      expect(engine.current.faults[rpm.id], PidFault.busError,
          reason: 'and the refusal is visible rather than a blank gauge');
      await engine.dispose();
    });
  });

  group('an adapter that cannot attribute is not an adapter that lies', () {
    // Round 7, and the closing half of a gap `docs/verification/test-evidence.md` had recorded
    // as awaiting hardware. It never needed hardware — only for two states to
    // stop sharing one branch. The gate read `functionalHeader == null`, a
    // stand-in for "is this legacy", which would have silently begun
    // hard-failing every legacy scan the moment legacy buses gained functional
    // headers two files away.

    test('R7: an adapter that refuses ATH1 degrades the scan, keeping codes',
        () async {
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        faults: const AdapterFaults(refuseHeaders: true),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '686AF1',
            responseId: '486BF1',
            responses: {
              ..._physicsReplies(),
              '03': [0x43, 0x01, 0x43],
            },
          ),
        ],
      );
      final engine = await _connect(transport);

      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(
          isA<DtcReadException>()
              .having((e) => e.kind, 'kind', DtcReadFailure.unattributed)
              .having((e) => e.partial.map((d) => d.code), 'partial',
                  contains('P0143')),
        ),
        reason: 'the fault is real and must be shown; what cannot be claimed '
            'is that it is the only one',
      );

      // And the verdict that reaches the screen is qualified, never green.
      final state = DtcScanState(
        scannedAt: DateTime(2026, 8, 15),
        results: {
          for (final kind in DtcKind.values)
            kind: const DtcCategoryResult.failed(
              DtcReadException('unattributed',
                  kind: DtcReadFailure.unattributed),
            ),
        },
      );
      expect(state.verdict, isNot(ScanVerdict.completeClean));
      await engine.dispose();
    });

    test('R7: an adapter that agrees to ATH1 and prints nothing is refused',
        () async {
      // The other side of the same coin, and the reason they cannot share a
      // branch. This adapter said `OK`. Every reply then arrived anonymous, so
      // it is contradicting itself — and unlike the refusing adapter it gave
      // no warning. Nothing it says can be trusted, so the read fails rather
      // than being qualified.
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        faults: const AdapterFaults(lieAboutHeaders: true),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '686AF1',
            responseId: '486BF1',
            responses: {..._physicsReplies(), '03': [0x43, 0x00, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()
            .having((e) => e.kind, 'kind', isNot(DtcReadFailure.unattributed))),
        reason: 'a lying adapter is refused outright, not qualified — '
            'qualification implies the answer was honest as far as it went',
      );
      await engine.dispose();
    });

    test('R28-N2: a clear that finished and then broke is not a failed clear',
        () async {
      // Cursor and kimi, round 28, independently. The transcript:
      //
      //   04 -> 7E8 01 44
      //         <RX ERROR
      //
      // `44` is the J1979 Mode 04 completion byte, so `7E8` has erased its
      // fault memory. The exchange then broke, which says nothing about what
      // already happened. `clearDtcs` returned `false` and the screen read
      // 清除失敗，ECU 未接受指令 — about a controller that had just reported
      // success.
      //
      // The cost is not the wrong word on a screen. A driver told the clear
      // failed taps it again; the second global `04` reaches `7E8`, which
      // erases a memory that is already empty and resets its readiness
      // monitors a second time. The vehicle then needs another full drive
      // cycle before it can pass an emissions test — for a retry that could
      // not have helped anything.
      //
      // A boolean has no way to say this, which is why the return type
      // changed rather than the message.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        faults: const AdapterFaults(
          forcedReplies: {'04': '7E8 01 44\r<RX ERROR'},
        ),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: _physicsReplies(),
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();

      final outcome = await engine.clearDtcs();
      expect(outcome, ClearOutcome.partiallyConfirmed,
          reason: 'the completion byte arrived; the error after it leaves the '
              'rest unknown, not failed');
      expect(outcome.isSuccess, isFalse,
          reason: 'unknown is not a vehicle the user may be told is clear');
      expect(outcome.repeatWouldHarm, isTrue,
          reason: 'this is the state where a retry costs a drive cycle, and '
              'the screen has to be able to ask about it');
      await engine.dispose();
    });

    test('R29-cursor F4: a clear that may have half-worked says so on the '
        'exception, not only in its sentence', () async {
      // Cursor round 29. The messages have said 不要再送一次清除 since the
      // outcome became three-valued, and the button stayed live underneath
      // them. Advice beside a working control is advice: somebody at a car
      // with the fault light still on has every reason to try the thing that
      // did not obviously work, and that tap costs another drive cycle.
      //
      // The screen cannot act on a sentence. It can act on this.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '04': [0x44]},
          ),
          FakeEcu(
            name: 'TCM',
            requestId: '7E1',
            responseId: '7E9',
            responses: {
              '0100': [0x41, 0x00, 0x80, 0x00, 0x00, 0x00],
              '04': [0x7F, 0x04, 0x22],
            },
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.repeatWouldHarm, 'repeatWouldHarm', isTrue)),
        reason: '7E8 finished; a second global clear reaches it again',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R30-codex 01: a Mode 04 refusal cut short still counts as coverage',
        () async {
      // Codex round 30, and the third time this app has had to learn that
      // identity and content are different facts.
      //
      //   04 -> 7E8 01 44
      //         7E9 03 7F 04      three declared, two arrived
      //         <RX ERROR
      //
      // `7E9` said "negative response, service 04" — unambiguously, at the
      // offset the framing puts it — and then the line was cut before the
      // reason byte. `payload` is correctly null for that, so requiring one
      // dropped `7E9` entirely, and the rescan accepted `7E8`'s empty answer
      // as the whole vehicle. A green screen over a controller that had just
      // declined to clear.
      //
      // Coverage never needed to know *what* it said, only that it answered
      // the clear at all.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        faults: const AdapterFaults(
          forcedReplies: {'04': '7E8 01 44\r7E9 03 7F 04\r<RX ERROR'},
        ),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      expect(await engine.clearDtcs(), ClearOutcome.partiallyConfirmed);

      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()
            .having((e) => e.message, 'message', contains('7E9'))),
        reason: 'the reason byte was lost, not the controller; a scan that '
            'closes without it reports a vehicle clean whose fault is still '
            'there',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R30-codex 01b: a reply about another service is still not coverage',
        () async {
      // The guard on the other side, and the reason the payload check was
      // there in the first place. A stale Mode 01 reply arriving during the
      // clear proves a controller exists and says nothing about whether it
      // received the clear — making it a fault-code obligation refused every
      // later scan for the silence of a module that had only ever reported
      // engine speed.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        faults: const AdapterFaults(
          forcedReplies: {'04': '7E8 01 44\r7E9 04 41 0C 1A F8\r<RX ERROR'},
        ),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      await engine.clearDtcs();

      expect(await engine.readDtcs(DtcKind.stored), isEmpty,
          reason: 'engine speed is not an answer to a clear, and refusing '
              'every later scan for it makes a readable car unusable');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    /// The same rule, asked of an exchange the adapter never marked damaged.
    ///
    /// Round 30's repair keyed coverage on `frame.service`, and put it on the
    /// branch that runs when the adapter says the exchange broke. The clean
    /// branch — every exchange without an error marker, which is nearly all of
    /// them — was left asking `_isClearParticipation` what the reply *said*.
    ///
    /// Two reviewers found the two ways through. Both are complete Single
    /// Frames whose PCI matches the bytes that arrived, so nothing anywhere
    /// calls the exchange damaged and the observed-frame repair never runs.
    for (final probe in const [
      (
        label: 'a malformed positive reply',
        line: '7E9 02 44 DE',
        why: 'declares two, both arrived, and the first is the Mode 04 '
            'completion byte with something after it',
      ),
      (
        label: 'a two-byte negative reply',
        line: '7E9 02 7F 04',
        why: 'a clone reprinting a short NRC: it names Mode 04 and stops '
            'before the reason byte, with the PCI agreeing',
      ),
    ]) {
      test(
          'R31: ${probe.label} on a clean clear is still coverage',
          () async {
        // Neither proves `7E9` erased anything — that is `payload`'s job, and
        // both are correctly refused there. What they prove is that `7E9` was
        // on the bus answering *this* clear, and dropping that let the rescan
        // report `7E8`'s empty Mode 03 as the whole vehicle. Green screen,
        // fault lamp lit, over a controller that had just answered the clear.
        //
        // ${probe.why}
        final transport = FakeElm327(
          protocol: BusProtocol.can11,
          faults: AdapterFaults(
            forcedReplies: {'04': '7E8 01 44\r${probe.line}'},
          ),
          ecus: [
            FakeEcu(
              name: 'ECM',
              requestId: '7E0',
              responseId: '7E8',
              responses: {..._physicsReplies(), '03': [0x43, 0x00]},
            ),
          ],
        );
        final engine = await _connect(transport);
        await engine.discoverResponders();
        await engine.clearDtcs();

        await expectLater(
          engine.readDtcs(DtcKind.stored),
          throwsA(isA<DtcReadException>()
              .having((e) => e.message, 'message', contains('7E9'))),
          reason: 'the census never heard from 7E9, the clear did, and a scan '
              'that closes without it calls a car clean whose fault is still '
              'set',
        );
        await engine.dispose();
      }, timeout: const Timeout(Duration(seconds: 20)));
    }

    test('R32: the same rule on a legacy bus, where the other pin cannot reach',
        () async {
      // Cursor round 32, F2. `8842bc0` set `service` at four construction
      // sites and claimed every fix fails when reverted. Three of the four are
      // reachable from the R31 fixtures; the legacy headered one is not,
      // because every R31 trigger is CAN and every legacy clear fixture in the
      // suite carries `<RX ERROR>` — which routes to `observedFrames`, where
      // `service` was already being set before this range.
      //
      // Deleting `service:` from the legacy site alone therefore left the
      // whole suite green while reopening round 31's class-2 hole on the bus
      // that constructor exists for:
      //
      //   04 -> 48 6B 10 44 07          ECM completed
      //         48 6B 18 7F 04 4E 9C    TCM refused; census never heard it
      //
      // No error marker, so both lines parse cleanly and `response.frames` is
      // the path taken. Without a service on the reassembled frame the TCM is
      // not coverage, and Mode 03 from the ECM alone goes green over a
      // controller that had just declined to clear.
      //
      // Checksums are the ISO 9141 additive sum, computed rather than copied:
      // 0x48+0x6B+0x10+0x44 = 0x107 -> 0x07, and the six TCM bytes sum to 0x9C.
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        faults: const AdapterFaults(
          forcedReplies: {'04': '48 6B 10 44 07\r48 6B 18 7F 04 4E 9C'},
        ),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '686AF1',
            responseId: '486B10',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      // The clear itself throws — a complete, attributed refusal, which is the
      // `default:` NRC branch working on a legacy bus:
      // 控制器 18 拒絕清除（原因碼 0x4E）…已有其他控制器完成清除. What matters
      // here is the coverage it recorded on the way past.
      await expectLater(engine.clearDtcs(), throwsA(isA<DtcReadException>()));

      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()
            .having((e) => e.message, 'message', contains('18'))),
        reason: 'the TCM answered the clear on a bus where the CAN fixtures '
            'cannot reach; a scan that closes without it calls the car clean',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R31: a clean reply about another service is still not coverage',
        () async {
      // The guard on the other side of the same change, on the clean branch.
      // Widening participation to "any frame from any source" is how a stale
      // Mode 01 reply became a session-long fault-code debt; the service byte
      // is what keeps that out, on both branches now.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        faults: const AdapterFaults(
          forcedReplies: {'04': '7E8 01 44\r7E9 04 41 0C 1A F8'},
        ),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      await engine.clearDtcs();

      expect(await engine.readDtcs(DtcKind.stored), isEmpty,
          reason: 'engine speed is not an answer to a clear here either');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R30-codex 03A: a clear lost after its write locks the retry',
        () async {
      // Codex round 30. `socket.add` hands bytes to the kernel before
      // `flush()` is awaited, so a failure from the flush happens *after* the
      // adapter may already have the clear. It escaped as an ordinary
      // exception and the screen left 清除 enabled.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '04': [0x44]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      // Armed for the clear alone: the exchange's `ATH1` and `ATSH` go out
      // normally, so the failure is unambiguously *after* `04` reached the
      // adapter. Failing every write would only ever exercise `ATH1`, which is
      // the opposite case — and is what this test did until it was pointed at
      // the wrong command and passed for the wrong reason.
      transport.failWriteAfterAcceptingFor = const {'04'};
      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.repeatWouldHarm, 'repeatWouldHarm', isTrue)),
        reason: 'the bytes may already be at the adapter; a free retry is the '
            'one thing that must not be offered',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R30-codex 03B: a clear that never went out is safe to retry',
        () async {
      // The other half, and the one that strands somebody. `ATH1` is written
      // before the service, so a failure there is proof `04` never left —
      // and the screen was locking the button on it, telling the driver their
      // clear had been sent when nothing had.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        faults: const AdapterFaults(swallowPromptFor: {'ATH1'}),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '04': [0x44]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.repeatWouldHarm, 'repeatWouldHarm', isFalse)),
        reason: 'nothing was transmitted, so nothing was reset — locking the '
            'button here strands a car that could still be cleared',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('R30-codex 03D: a timeout *after* the write is still a sent clear',
        () async {
      // The case that separates the rule from the heuristic it replaced, and
      // the reason the first two tests were not enough: on those, "is it a
      // TimeoutException?" happens to give the same answer as "did `04` go
      // out?". Here it does not.
      //
      // The adapter takes the bytes, acts on them, and never prints its
      // prompt — a wedged clone, a link that dies mid-reply. The command
      // timeout fires, so the type says timeout and the old heuristic said
      // "never sent". The vehicle may be cleared.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        faults: const AdapterFaults(swallowPromptFor: {'04'}),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '04': [0x44]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.repeatWouldHarm, 'repeatWouldHarm', isTrue)),
        reason: 'the bytes went out and the reply never came; the Dart type of '
            'the failure says nothing about the wire',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('R30-codex 03E: a transport failure *before* the write is not a sent '
        'clear', () async {
      // And the mirror image, which the heuristic also got wrong in the other
      // direction: a `TransportException` — not a timeout — raised while the
      // exchange was still setting headers, before `04` existed on the wire.
      // Locking the button there strands a car that could still be cleared.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '04': [0x44]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.failWriteAfterAcceptingFor = const {'ATH1'};
      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.repeatWouldHarm, 'repeatWouldHarm', isFalse)),
        reason: 'the exchange died before the service byte; nothing was reset',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('R30-codex 03C: an adapter that refuses the command did not send it',
        () async {
      // `04 -> ?` is the adapter saying it did not understand, legibly. It is
      // not a destroyed reply, nothing was erased, and calling it
      // 回應在傳輸過程中損毀 while locking the retry strands somebody whose
      // next step is simply to try again.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        faults: const AdapterFaults(forcedReplies: {'04': '?'}),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: _physicsReplies(),
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      final outcome = await engine.clearDtcs();
      expect(outcome, ClearOutcome.notAccepted);
      expect(outcome.repeatWouldHarm, isFalse);
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R30-self: a refusal that says 再試一次 leaves the button pressable',
        () async {
      // Found by writing the field guide and checking it against the code.
      //
      // Every clear failure thrown after transmission was given
      // `repeatWouldHarm`, which disables 清除 and relabels it 請先重新掃描.
      // But a refusal where *nobody* cleared anything ends in 請稍候再試一次 —
      // so the screen said "try again" beside a control that could not be
      // pressed. Two halves of one instruction contradicting each other reads
      // as a broken app, on the screen where that guess costs the most.
      //
      // Nothing was erased here: the whole exchange arrived, every frame was
      // read, and none was a completion. There is genuinely nothing to
      // protect, so the flag follows the sentence rather than the send.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '04': [0x7F, 0x04, 0x22]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.message, 'message', contains('再試一次'))
            .having((e) => e.repeatWouldHarm, 'repeatWouldHarm', isFalse)),
        reason: 'the engine refused with the engine running and erased '
            'nothing; the fix is to switch the ignition and try again, and '
            'the button has to allow that',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R30-kimi 03: a refusal nobody could act on does not say 不要重複清除',
        () async {
      // kimi round 30, the residue of the 0x22 repair. `0x11` — "this
      // controller does not implement Mode 04" — kept an unconditional
      // 其餘控制器可能已經清除，不要重複清除, which is a guess; when nobody
      // cleared anything it tells somebody not to repeat an operation the app
      // has just left the button live for. Two halves of one instruction
      // contradicting each other, which is the same defect as R30-self one
      // case over.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '04': [0x7F, 0x04, 0x11]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.message, 'message', isNot(contains('不要重複清除')))
            .having((e) => e.repeatWouldHarm, 'repeatWouldHarm', isFalse)),
        reason: 'nothing was erased, so nothing needs protecting — and the '
            'sentence has to agree with the button',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    /// Every Mode 04 refusal, in both directions, including the ones nothing
    /// named.
    ///
    /// Round 30 made `repeatWouldHarm` follow `someoneCleared` on all four
    /// named NRCs. Two of the four — `0x21` and `0x33` — then appeared in no
    /// fixture anywhere, and neither did the *mixed* direction of `0x11`.
    /// kimi round 31 proved it by pinning them back to an unconditional lock
    /// and watching the suite stay green: a refusal ending 請稍候再試一次
    /// beside a button reading 請先重新掃描, which is the contradiction this
    /// whole line of repairs exists to remove.
    ///
    /// `0x10` is here for the opposite reason. It is a complete, attributed,
    /// perfectly legible refusal that the switch did not recognise, so it fell
    /// through to the branch for malformed replies and was reported as damage.
    /// Codex round 31.
    for (final nrc in const [
      (code: 0x21, says: '忙碌', note: 'busyRepeatRequest'),
      (code: 0x33, says: '安全認證', note: 'securityAccessDenied'),
      (code: 0x10, says: '0x10', note: 'generalReject — named by nothing'),
      (code: 0x11, says: 'Mode 04', note: 'serviceNotSupported'),
      (code: 0x22, says: '車輛狀態', note: 'conditionsNotCorrect'),
    ]) {
      test('R31: ${nrc.note} alone is a refusal the button lets you retry',
          () async {
        final transport = FakeElm327(
          protocol: BusProtocol.can11,
          ecus: [
            FakeEcu(
              name: 'ECM',
              requestId: '7E0',
              responseId: '7E8',
              responses: {
                ..._physicsReplies(),
                '04': [0x7F, 0x04, nrc.code],
              },
            ),
          ],
        );
        final engine = await _connect(transport);
        await engine.discoverResponders();
        await expectLater(
          engine.clearDtcs(),
          throwsA(isA<DtcReadException>()
              .having((e) => e.message, 'message', contains(nrc.says))
              // The prohibition specifically. 不要 alone would also match
              // 「電門轉到 ON 但不要發動引擎」, which is the advice, not the
              // warning — an assertion that fails on the correct message
              // teaches nothing.
              .having((e) => e.message, 'message', isNot(contains('不要再送一次')))
              .having((e) => e.message, 'message', isNot(contains('不要重複清除')))
              .having((e) => e.repeatWouldHarm, 'repeatWouldHarm', isFalse)),
          reason: 'the whole exchange arrived and none of it was a '
              'completion, so nothing on this car was erased and there is '
              'nothing for a lock to protect',
        );
        await engine.dispose();
      }, timeout: const Timeout(Duration(seconds: 20)));

      test('R31: ${nrc.note} beside a completion locks the repeat', () async {
        // The other direction of the same conditional. `7E8` really did erase
        // its memory, so a second global `04` reaches it again and costs
        // another drive cycle before the car can pass an emissions test.
        final transport = FakeElm327(
          protocol: BusProtocol.can11,
          faults: AdapterFaults(
            forcedReplies: {
              '04': '7E8 01 44\r7E9 03 7F 04 '
                  '${nrc.code.toRadixString(16).toUpperCase().padLeft(2, '0')}',
            },
          ),
          ecus: [
            FakeEcu(
              name: 'ECM',
              requestId: '7E0',
              responseId: '7E8',
              responses: {..._physicsReplies()},
            ),
          ],
        );
        final engine = await _connect(transport);
        await engine.discoverResponders();
        await expectLater(
          engine.clearDtcs(),
          throwsA(isA<DtcReadException>()
              .having((e) => e.message, 'message', contains('不要再送一次'))
              .having((e) => e.repeatWouldHarm, 'repeatWouldHarm', isTrue)),
          reason: 'a controller finished; the button will be dead, so the '
              'message has to be the one that explains why — 0x33 locked it '
              'while describing only its security requirement',
        );
        await engine.dispose();
      }, timeout: const Timeout(Duration(seconds: 20)));
    }

    /// An acknowledgement nobody can attribute is still an acknowledgement.
    ///
    /// Codex round 31. Both gates below are right to refuse the exchange —
    /// with no usable header there is no way to say how many controllers heard
    /// the clear — and both were throwing with the default
    /// `repeatWouldHarm: false`. So the screen explained the adapter's
    /// limitation and left 清除 live, over a bus where the exact J1979
    /// completion byte had just come back. Tapping it again reaches whatever
    /// erased its memory the first time and costs another drive cycle.
    ///
    /// Not knowing who did it is not evidence that nobody did.
    for (final adapter in const [
      (
        label: 'refuses ATH1',
        faults: AdapterFaults(refuseHeaders: true, forcedReplies: {'04': '44'}),
      ),
      (
        label: 'agrees to ATH1 and prints no header',
        faults:
            AdapterFaults(lieAboutHeaders: true, forcedReplies: {'04': '44'}),
      ),
    ]) {
      test('R31: an anonymous 44 from an adapter that ${adapter.label} '
          'still locks the repeat', () async {
        final transport = FakeElm327(
          protocol: BusProtocol.can11,
          faults: adapter.faults,
          ecus: [
            FakeEcu(
              name: 'ECM',
              requestId: '7E0',
              responseId: '7E8',
              responses: {..._physicsReplies()},
            ),
          ],
        );
        final engine = await _connect(transport);
        await engine.discoverResponders();
        await expectLater(
          engine.clearDtcs(),
          throwsA(isA<DtcReadException>()
              .having((e) => e.message, 'message', contains('不要直接再清除一次'))
              .having((e) => e.repeatWouldHarm, 'repeatWouldHarm', isTrue)),
          reason: 'something on this bus sent the completion byte; the field '
              'guide tells people a live button means nothing was erased, and '
              'that has to stay true',
        );
        await engine.dispose();
      }, timeout: const Timeout(Duration(seconds: 20)));

      test('R31: and an unattributable clear that finished nothing does not',
          () async {
        // The over-strict twin. These adapters are limited, not broken, and a
        // clear they could not attribute *and* that nobody acknowledged has
        // erased nothing — locking the button there strands somebody with a
        // car they can still legitimately clear.
        final transport = FakeElm327(
          protocol: BusProtocol.can11,
          faults: AdapterFaults(
            refuseHeaders: adapter.faults.refuseHeaders,
            lieAboutHeaders: adapter.faults.lieAboutHeaders,
            forcedReplies: const {'04': '7F 04 22'},
          ),
          ecus: [
            FakeEcu(
              name: 'ECM',
              requestId: '7E0',
              responseId: '7E8',
              responses: {..._physicsReplies()},
            ),
          ],
        );
        final engine = await _connect(transport);
        await engine.discoverResponders();
        await expectLater(
          engine.clearDtcs(),
          throwsA(isA<DtcReadException>()
              .having((e) => e.repeatWouldHarm, 'repeatWouldHarm', isFalse)),
          reason: 'a refusal erased nothing, whoever sent it',
        );
        await engine.dispose();
      }, timeout: const Timeout(Duration(seconds: 20)));
    }

    test('R31: a clear the transport refused outright is safe to retry',
        () async {
      // Codex round 31. The write audit recorded `04` *before* calling
      // `transport.write`, and `transport.write` opens with a precondition
      // check — no socket, no characteristic, no connection. A `04` rejected
      // there never reached the adapter, and the app reported it as sent: the
      // button locked and relabelled 請先重新掃描 over a clear that provably
      // did not happen, asking for a rescan that could settle nothing.
      //
      // Recording before the write stays the default — an unknown failure has
      // to read as possibly-sent — and the transport's own guard is now the
      // one case allowed to take it back. `ATH1` and `ATSH` go out normally,
      // so this is the service write and nothing else.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies()},
          ),
        ],
      )..refuseWriteBeforeAcceptingFor = const {'04'};
      final engine = await _connect(transport);
      await engine.discoverResponders();
      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.repeatWouldHarm, 'repeatWouldHarm', isFalse)
            // Cursor round 32, F5. The sentence interpolated the exception,
            // and `TransportException.toString()` leads with its own class
            // name — so the panel read 清除指令還沒送出就失敗了（TransportException:
            // …）. Exactly the defect fixed for the retired lease, on the
            // branch beside it, and nothing here was reading the string.
            .having((e) => e.message, 'message', isNot(contains('Exception')))),
        reason: 'nothing was transmitted, so there is nothing a repeat could '
            'reach and no reason to make somebody rescan first',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R31: and a write that failed after handing bytes over still locks',
        () async {
      // The direction that must not move. These two failures are
      // indistinguishable by exception type — which is the whole reason the
      // audit exists — so a fix for the one above that keyed on anything but
      // the transport's own guard would take this with it.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies()},
          ),
        ],
      )..failWriteAfterAcceptingFor = const {'04'};
      final engine = await _connect(transport);
      await engine.discoverResponders();
      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.repeatWouldHarm, 'repeatWouldHarm', isTrue)),
        reason: 'the adapter had the bytes before the write threw; a second '
            'global 04 reaches whatever acted on the first',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R31: each clear is judged on its own writes, not the last one',
        () async {
      // Codex round 31, finding 7B: `beginWriteAudit()` was deletable in
      // silence. Every pre-wire failure fixture builds a fresh client, so no
      // test ever put two clears through one connection — and without the
      // reset, the first attempt's `04` is still in the window when the
      // second attempt is judged.
      //
      // First clear: `04` goes out and the adapter answers. Second: the
      // transport refuses `ATH1`, so no `04` is written at all. Without the
      // reset the second is classified from the first attempt's write and
      // locks a button over a clear that never left the app.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '04': [0x44]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      expect(await engine.clearDtcs(), ClearOutcome.confirmed);

      transport.refuseWriteBeforeAcceptingFor = const {'ATH1'};
      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.repeatWouldHarm, 'repeatWouldHarm', isFalse)),
        reason: 'the second attempt never wrote 04; judging it by the first '
            'attempt locks the button on a clear that did not happen',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    /// The adapter's own voice, all three of it.
    ///
    /// kimi and cursor, round 31: only `?` was in the suite. Removing
    /// `UNABLE TO CONNECT` or `BUS INIT: ERROR` from the set sends them to
    /// `sentUnconfirmed`, which locks a retry that is free — on the two
    /// replies that mean the adapter never reached the vehicle at all, which
    /// is exactly when somebody needs to be able to press the button again.
    for (final voice in const ['?', 'UNABLE TO CONNECT', 'BUS INIT: ERROR']) {
      test('R31: "$voice" on a clear means nothing was transmitted', () async {
        final transport = FakeElm327(
          protocol: BusProtocol.can11,
          faults: AdapterFaults(forcedReplies: {'04': voice}),
          ecus: [
            FakeEcu(
              name: 'ECM',
              requestId: '7E0',
              responseId: '7E8',
              responses: {..._physicsReplies()},
            ),
          ],
        );
        final engine = await _connect(transport);
        await engine.discoverResponders();
        expect(await engine.clearDtcs(), ClearOutcome.notAccepted,
            reason: 'the adapter said in its own words that it never got to '
                'the bus; that is a legible answer, not a destroyed one');
        expect(ClearOutcome.notAccepted.repeatWouldHarm, isFalse);
        await engine.dispose();
      }, timeout: const Timeout(Duration(seconds: 20)));
    }

    test('R31: and a reply the adapter says it destroyed still locks',
        () async {
      // The direction that must not move with it. `NO DATA` and friends are
      // about the *vehicle*, after the command went out.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        faults: const AdapterFaults(forcedReplies: {'04': 'CAN ERROR'}),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      expect(await engine.clearDtcs(), ClearOutcome.sentUnconfirmed);
      expect(ClearOutcome.sentUnconfirmed.repeatWouldHarm, isTrue);
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R31: a Single Frame cut before its operand names no PID', () async {
      // kimi round 31. `_canOperand`'s `body.length < 3` guard had no fixture
      // of the shape it guards — `7E9 02 41`, declaring two application bytes
      // with only one arrived. Without it, `body[2]` is a `RangeError` thrown
      // inside the byte-stream listener: loud at a car, and it changes no
      // verdict, so nothing in the suite would have noticed.
      //
      // Written first through `AdapterFaults.forcedReplies` and
      // `readDtcs`, where it passed under its own mutation — that route never
      // queries `0101` at all, so the fragment never reached the parser. The
      // shape below is the one the sibling operand tests use, and it does.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      transport.forceReplySequence(
          '0101', ['7E8 06 41 01 00 07 65 04\r7E9 02 41\r<RX ERROR']);

      // Has to *complete*, which is the whole of it: a RangeError here leaves
      // the exchange to time out instead of answering.
      expect(await engine.readMilStatus(), isNull);
      expect(await engine.readDtcs(DtcKind.stored), isEmpty,
          reason: 'a fragment that never reached its PID byte names no PID, '
              'and must not take the exchange down with it either');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    /// Two shapes that are plainly not "nothing happened", on an adapter that
    /// cannot attribute. Codex round 32.
    ///
    /// The attribution gates take their flag from an exact-`44` test, so both
    /// of these reached the user as an adapter-limitation notice with 清除
    /// still live — over a bus where a controller was mid-erase or had just
    /// finished. `docs/field-guide.zh-TW.md` tells people a live button means nothing was
    /// cleared.
    for (final probe in const [
      (label: 'response-pending', reply: '7F 04 78'),
      (label: 'a malformed completion', reply: '44 DE'),
    ]) {
      test('R32: anonymous ${probe.label} still locks the repeat', () async {
        final transport = FakeElm327(
          protocol: BusProtocol.can11,
          faults: AdapterFaults(
            refuseHeaders: true,
            forcedReplies: {'04': probe.reply},
          ),
          ecus: [
            FakeEcu(
              name: 'ECM',
              requestId: '7E0',
              responseId: '7E8',
              responses: {..._physicsReplies()},
            ),
          ],
        );
        final engine = await _connect(transport);
        await engine.discoverResponders();
        await expectLater(
          engine.clearDtcs(),
          throwsA(isA<DtcReadException>()
              .having((e) => e.repeatWouldHarm, 'repeatWouldHarm', isTrue)),
          reason: 'neither reply is evidence that nothing happened, and the '
              'button is the only thing standing between this and a second '
              'global 04',
        );
        await engine.dispose();
      }, timeout: const Timeout(Duration(seconds: 20)));
    }

    test('R32: which controller spoke first does not decide whether a repeat '
        'is safe', () async {
      // Codex round 32. `someoneCleared` was an exact-`44` test evaluated as
      // the loop walked the frames, so:
      //
      //   04 -> 7E8 03 7F 04 22
      //         7E9 02 44 DE      the completion byte, with junk after it
      //
      // threw at `7E8` before `7E9` was ever examined, and the button stayed
      // live. Reverse the two lines and the malformed positive is reached
      // first, returns `sentUnconfirmed`, and the button locks. Identical
      // evidence about identical controllers, decided by bus ordering.
      Future<DtcReadException> refusalFor(String reply) async {
        final transport = FakeElm327(
          protocol: BusProtocol.can11,
          faults: AdapterFaults(forcedReplies: {'04': reply}),
          ecus: [
            FakeEcu(
              name: 'ECM',
              requestId: '7E0',
              responseId: '7E8',
              responses: {..._physicsReplies()},
            ),
          ],
        );
        final engine = await _connect(transport);
        await engine.discoverResponders();
        try {
          await engine.clearDtcs();
          fail('a refusal was expected');
        } on DtcReadException catch (e) {
          return e;
        } finally {
          await engine.dispose();
        }
      }

      final refusalFirst = await refusalFor('7E8 03 7F 04 22\r7E9 02 44 DE');
      expect(refusalFirst.repeatWouldHarm, isTrue,
          reason: '7E9 sent the completion byte; the order it arrived in is '
              'not a fact about the vehicle');
      expect(refusalFirst.message, contains('不要再送一次'),
          reason: 'and the sentence has to explain the dead button — this one '
              'cannot claim a controller *finished*, only that one may have');
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('R31: a third controller that refused is not said to have cleared',
        () async {
      // Codex round 31. `someoneCleared` is an existential fact — *a*
      // controller finished — and the sentences built from it were universal:
      // 其他控制器已經清除完成, every other controller finished.
      //
      //   04 -> 7E8 01 44          completed
      //         7E9 03 7F 04 22    conditionsNotCorrect
      //         7EA 03 7F 04 11    serviceNotSupported
      //
      // The loop throws at `7E9`, and the sentence it throws asserts that
      // `7EA` cleared — which `7EA` had just explicitly declined to do. The
      // warning against repeating stays right, because `7E8` really did erase.
      // Only the quantifier was wrong.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        faults: const AdapterFaults(
          forcedReplies: {
            '04': '7E8 01 44\r7E9 03 7F 04 22\r7EA 03 7F 04 11',
          },
        ),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies()},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.message, 'message',
                isNot(contains('其他控制器已經清除完成')))
            .having((e) => e.message, 'message', contains('已有其他控制器完成清除'))
            .having((e) => e.repeatWouldHarm, 'repeatWouldHarm', isTrue)),
        reason: 'the app may say that one controller finished; saying that '
            'the rest did sends somebody away from a module still holding '
            'its fault',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R30-agy: an interruption *after* the clear went out locks the button',
        () async {
      // agy round 30. `_requireStillOwned` after `sendGlobal('04')` throws the
      // right sentence — 清除指令已經送出…不要直接再清除一次 — and threw it
      // without the flag, so the screen printed the warning and left the
      // button live underneath it. That is the exact mismatch the flag was
      // introduced to close, one call site further along.
      //
      // Distinct from the retired-lease case above, which is about a clear
      // that never reached the wire. This one did.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '04': [0x44]},
          ),
        ],
      );
      final client = Elm327Client(transport,
          commandTimeout: const Duration(milliseconds: 800));
      expect(await client.connect(), isTrue);

      var epoch = 0;
      client.mayTransmit = (owner) => owner == null || owner == epoch;
      final engine = PollingEngine(client)..lifecycleEpoch = () => epoch;
      await engine.discoverResponders();

      // The clear goes out and the reply takes a moment; the app is
      // backgrounded in that window.
      transport.slowCommands['04'] = const Duration(milliseconds: 150);
      final clear = engine.clearDtcs();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      epoch++;

      await expectLater(
        clear,
        throwsA(isA<DtcReadException>()
            .having((e) => e.message, 'message', contains('不要直接再清除一次'))
            .having((e) => e.repeatWouldHarm, 'repeatWouldHarm', isTrue)),
        reason: 'the command is on the wire; a second tap costs a drive cycle '
            'whatever the app was doing when the answer failed to arrive',
      );
      expect(transport.commandLog, contains('04'),
          reason: 'sanity: this test is only about the case where it was sent');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R29-cursor F4: a refusal before the command goes out is safe to retry',
        () async {
      // The other side, and the reason this is a flag rather than a blanket
      // rule: a clear refused *before* transmission has changed nothing, so
      // disabling the button after it would strand somebody who simply needs
      // to rescan and try again. J1939 has no Mode 04 at all.
      final transport = FakeElm327(
        protocol: BusProtocol.can29,
        forceProtocolNumber: 'A',
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '18DB33F1',
            responseId: '18DAF110',
            responses: _physicsReplies(),
          ),
        ],
      );
      final engine = await _connect(transport);
      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.repeatWouldHarm, 'repeatWouldHarm', isFalse)),
        reason: 'nothing was transmitted, so nothing was reset',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R29-codex 02: nothing cleared is not "the responding controllers '
        'cleared"', () async {
      // Codex round 29. The identity-question message asserted a clear had
      // happened before anything established one:
      //
      //   04 -> 7E8 03 7F 04 22     explicit refusal
      //         7E9                 a bare identifier
      //         <RX ERROR
      //
      // 有回應的控制器已清除，但無法確認其餘控制器 — about a bus on which
      // nothing cleared anything. A driver reads that as "most of it worked",
      // stops looking, and the fault is still set.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        faults: const AdapterFaults(
          forcedReplies: {'04': '7E8 03 7F 04 22\r7E9\r<RX ERROR'},
        ),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.message, 'message', contains('沒有任何控制器回報清除完成'))
            .having((e) => e.message, 'message', isNot(contains('已清除，但')))
            .having((e) => e.repeatWouldHarm, 'repeatWouldHarm', isTrue)),
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R29-codex 05: response-pending on a damaged exchange is acceptance',
        () async {
      // Codex round 29. The clean path has recognised `7F 04 78` as
      // "received, still working on it" since round 27; the damaged path
      // returned before ever reaching it, so the identical reply with an error
      // marker after it became 清除失敗，沒有控制器接受指令 — the app telling
      // the driver the opposite of what the controller said, and leaving the
      // button live to invite the repeat that resets readiness monitors.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        faults: const AdapterFaults(
          forcedReplies: {'04': '7E8 03 7F 04 78\r<RX ERROR'},
        ),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: _physicsReplies(),
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      await expectLater(
        engine.clearDtcs(),
        throwsA(isA<DtcReadException>()
            .having((e) => e.kind, 'kind', DtcReadFailure.pending)
            .having((e) => e.repeatWouldHarm, 'repeatWouldHarm', isTrue)),
        reason: 'the controller accepted the clear; reporting a refusal and '
            'offering a retry is the opposite of what it said',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R29-codex 03: a legacy line that fails its checksum is not a '
        'controller', () async {
      // Codex round 29, the over-strict direction of the same raw-bytes bug.
      //
      //   04 -> 48 6B 18 7F 04 22 00     additive checksum should be 0x70
      //         <RX ERROR
      //
      // The unverified body was read as a Mode 04 refusal, so a source `18`
      // that never existed entered the monotonic coverage set — and every
      // later scan was refused for the silence of a controller the app had
      // invented. A readable car, permanently unreadable.
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        faults: const AdapterFaults(
          forcedReplies: {'04': '48 6B 18 7F 04 22 00\r<RX ERROR'},
        ),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '686AF1',
            responseId: '486B10',
            responses: {..._physicsReplies(), '03': [0x43, 0x00, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();

      // Round 30 made this stricter at the source. On a legacy bus the
      // checksum is the only thing that says where the header ends, so a sum
      // that does not hold means the split is fabricated — the line is not a
      // headered frame at all, and `18` is not an address.
      //
      // Dropped rather than carried as an open question, which is the one
      // thing that separates it from a bare `7E9` on CAN. An unresolved
      // identity is a permanent claim that something *might* be on this bus,
      // and it has to be, so a retry cannot quietly pass on the survivor's
      // acknowledgement alone (R23-codex 04). Giving that permanence to a
      // token with no evidence behind it means one noise burst vetoes every
      // clear for the rest of the connection.
      expect((await engine.clearDtcs()), ClearOutcome.sentUnconfirmed,
          reason: 'the exchange really was damaged — the ordinary parser '
              'refuses the reply for the same failed checksum — so the outcome '
              'is unknown, the repeat is locked, and a rescan settles it');

      expect(await engine.readDtcs(DtcKind.stored), isEmpty,
          reason: 'source 18 was never on this bus; refusing a clean Mode 03 '
              'for its silence makes a readable car unusable');

      // And clearing still works afterwards. A permanent veto would be the
      // over-strict twin of the bug this test was written for.
      transport.forceReplySequence('04', [_withChecksum('48 6B 10 44')]);
      expect((await engine.clearDtcs()).isSuccess, isTrue,
          reason: 'one noisy line must not cost the ability to clear at all');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R29-kimi H2: a controller that refused a damaged clear is not lost',
        () async {
      // kimi, carried from round 28 and still live at round 29's HEAD.
      //
      // Both branches of `_recordClearEvidence` run the same predicate, and
      // that is the point of it — but they fed it different things. The
      // successful branch reads `response.frames`, reassembled and
      // PCI-stripped; the damaged branch read `frame.bytes`, which on CAN is
      // the raw ISO-TP body. So the identical rule saw `[0x44]` there and
      // `[0x01, 0x44]` here, and on a damaged exchange nothing at all counted
      // as participation.
      //
      //   04 -> 7E8 01 44          finished
      //         7E9 03 7F 04 22    refused — engine running
      //         <RX ERROR
      //
      // The refusal is the one that costs. `7E9` declined to clear and was
      // invisible to coverage, so the next scan did not know to wait for it
      // and could call the vehicle clean with its fault still in place.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        faults: const AdapterFaults(
          forcedReplies: {
            '04': '7E8 01 44\r7E9 03 7F 04 22\r<RX ERROR',
          },
        ),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {..._physicsReplies(), '03': [0x43, 0x00]},
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      expect(await engine.clearDtcs(), ClearOutcome.partiallyConfirmed);

      // And the refuser is now owed an answer by the next scan.
      await expectLater(
        engine.readDtcs(DtcKind.stored),
        throwsA(isA<DtcReadException>()
            .having((e) => e.message, 'message', contains('7E9'))),
        reason: '7E9 took part in the clear and declined it; a scan that '
            'closes without it can report a vehicle clean whose fault is '
            'still there',
      );
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R29-agy 01: a legacy clear that finished is not read as failed',
        () async {
      // agy, round 29, in the repair for R28-N2 itself.
      //
      // `ObdFrame.payload` was added so the error path could ask what a
      // controller actually said. On CAN it strips the ISO-TP PCI. On a legacy
      // bus it handed over the *whole* line — and a legacy line ends in a
      // checksum:
      //
      //   48 6B 10 44 07      (0x48+0x6B+0x10+0x44 = 0x107, low byte 0x07)
      //   <RX ERROR
      //
      // so J1979's one-byte completion arrived as `[0x44, 0x07]` and did not
      // match. The clear was reported as 清除失敗，沒有控制器接受指令 with
      // nothing warning against a repeat — which is worse than the bug this
      // was written to fix, because on CAN at least `44` was recognised.
      //
      // The ordinary parser has always stripped that byte *and verified it*.
      // Doing only the first would let a mis-split line authenticate itself,
      // so this does both, which is what the second case below is for.
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        faults: const AdapterFaults(
          forcedReplies: {'04': '48 6B 10 44 07\r<RX ERROR'},
        ),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '686AF1',
            responseId: '486B10',
            responses: _physicsReplies(),
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      expect(await engine.clearDtcs(), ClearOutcome.partiallyConfirmed,
          reason: 'the controller printed the completion byte; the checksum '
              'after it is the line ending, not part of what it said');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R29-agy 01b: a legacy line whose checksum fails says nothing',
        () async {
      // The other half. Trimming the last byte without checking it would let a
      // fabricated split hand out payload it never carried, and this is the
      // clear — the one operation that cannot be taken back.
      final transport = FakeElm327(
        protocol: BusProtocol.iso9141,
        faults: const AdapterFaults(
          forcedReplies: {'04': '48 6B 10 44 08\r<RX ERROR'},
        ),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '686AF1',
            responseId: '486B10',
            responses: _physicsReplies(),
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      expect(await engine.clearDtcs(), ClearOutcome.sentUnconfirmed,
          reason: 'a line that does not check out is not evidence a '
              'controller erased anything — and on a damaged exchange it is '
              'not evidence that none did, either');
      await engine.dispose();
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('R28-N2b: a broken clear nobody answered is unknown, not confirmed',
        () async {
      // The other half, without which the fix above would be indistinguishable
      // from "call every damaged exchange partially confirmed". Nothing here
      // carried `44`.
      //
      // Round 29 moved this from `notAccepted` to `sentUnconfirmed`, which is
      // codex's distinction: the command *was* transmitted, so a destroyed
      // reply is not evidence that nothing happened. A controller may have
      // erased its memory and had its acknowledgement lost on the way back,
      // and 再試一次 would then cost a drive cycle. What the two values share —
      // and what this test is really for — is that neither is success.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        faults: const AdapterFaults(forcedReplies: {'04': '<RX ERROR'}),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: _physicsReplies(),
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      final outcome = await engine.clearDtcs();
      expect(outcome, ClearOutcome.sentUnconfirmed);
      expect(outcome.isSuccess, isFalse,
          reason: 'nothing reported completing, so nothing may be claimed');
      expect(outcome.repeatWouldHarm, isTrue,
          reason: 'the command went out; a rescan settles this, a repeat does '
              'not');
      await engine.dispose();
    });

    test('R28-N2c: a malformed 44 is not read as finished on either path',
        () async {
      // The predicate that judges "did anybody finish" is now the one the
      // final loop uses, and this is why they had to be the same. Mode 04 has
      // no response parameter, so `44 DE AD BE` is malformed — it used to be
      // malformed on the clean path and finished on the error path, so the
      // identical reply meant two different things depending on whether the
      // exchange also broke.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        faults: const AdapterFaults(
          forcedReplies: {'04': '7E8 04 44 DE AD BE\r<RX ERROR'},
        ),
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: _physicsReplies(),
          ),
        ],
      );
      final engine = await _connect(transport);
      await engine.discoverResponders();
      expect(await engine.clearDtcs(), ClearOutcome.sentUnconfirmed,
          reason: 'a reply that does not match J1979 completion is not '
              'evidence anything was erased, and a damaged exchange is not '
              'evidence that nothing was');

      // And the same bytes *without* the error marker read the same way.
      // Round 30: they used to be `notAccepted` with the button left live,
      // so intact-looking damage was treated as safer to repeat than damage
      // the adapter admitted to.
      transport.forceReplySequence('04', ['7E8 04 44 DE AD BE']);
      expect(await engine.clearDtcs(), ClearOutcome.sentUnconfirmed,
          reason: 'a 44 with junk after it is a controller that may have '
              'erased its memory and produced a bad frame');
      await engine.dispose();
    });
  });
}
