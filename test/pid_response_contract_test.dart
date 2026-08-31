/// Every request is a contract, and a reply that does not honour it is not
/// data.
///
/// Two defects live here. A single-PID poll that comes back truncated, wrong,
/// or not at all left the previous `Reading` in place with its old timestamp,
/// so a believable but obsolete number kept rendering as live — the clearest
/// plausible-wrong-number failure in the app. And a Mode 22 request handed the
/// whole payload to the formula without checking the service byte, so an ECU
/// saying "I refuse" became a sensor value.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/pid/pid.dart';
import 'package:torque_obd/obd/polling_engine.dart';
import 'package:torque_obd/obd/telemetry.dart';

import 'support/fake_elm327.dart';

const _coolant = Pid(
  name: 'Coolant',
  shortName: 'COOLANT',
  modeAndPid: '0105',
  equation: 'A-40',
  minValue: -40,
  maxValue: 215,
  units: '°C',
);

const _transTemp = Pid(
  name: 'Transmission oil',
  shortName: 'TRANS',
  modeAndPid: '221E1C',
  equation: 'A',
  minValue: 0,
  maxValue: 255,
  units: '°C',
  isCustom: true,
);

const _localBattery = Pid(
  name: 'Local battery value',
  shortName: 'LOCAL',
  modeAndPid: '2101',
  equation: 'A',
  minValue: 0,
  maxValue: 255,
  units: '',
  isCustom: true,
);

/// The engine always merges the physics inputs into the active set, whether or
/// not they are on the dashboard, so an ECU that cannot answer them leaves the
/// loop retrying instead of reaching the PID under test.
FakeEcu _ecm({Map<String, List<int>> extra = const {}}) => FakeEcu(
  name: 'ECM',
  requestId: '7E0',
  responseId: '7E8',
  responses: {
    '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
    '010C': [0x41, 0x0C, 0x1A, 0xF8], // rpm
    '010D': [0x41, 0x0D, 0x3C], // speed
    '010B': [0x41, 0x0B, 0x63], // MAP
    '010F': [0x41, 0x0F, 0x46], // IAT
    '0110': [0x41, 0x10, 0x07, 0xD0], // MAF
    '015E': [0x41, 0x5E, 0x00, 0x64], // ECU fuel rate, 5.0 L/h
    '0105': [0x41, 0x05, 0x82], // coolant, overridable below
    ...extra,
  },
);

/// Runs the poll loop until every requested PID has been decided.
///
/// This used to sleep a flat 250 ms and hope. Under a full-suite run that is
/// not always enough, and the snapshot came back empty — so the test failed
/// with an assertion about a value that was never fetched, which is the
/// failure mode `docs/verification/test-evidence.md` describes pointing the other way. The same
/// flat sleep in front of a *negative* assertion is a false green.
///
/// A PID is "decided" when it has produced either a reading or a fault, which
/// is exactly what these tests are about, and the wait fails loudly with the
/// command log if it never happens.
Future<TelemetrySnapshot> _pollFor(FakeElm327 transport, List<Pid> pids) async {
  final client = Elm327Client(
    transport,
    commandTimeout: const Duration(milliseconds: 120),
  );
  expect(await client.connect(), isTrue);
  final engine = PollingEngine(client)..setActivePids(pids);
  engine.start();

  bool decided() => pids.every(
    (p) =>
        engine.current.readings.containsKey(p.id) ||
        engine.current.faults.containsKey(p.id),
  );

  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!decided() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  final reached = decided();
  await engine.stop();
  final snapshot = engine.current;
  await engine.dispose();
  expect(
    reached,
    isTrue,
    reason:
        'no verdict for every PID within five seconds, so whatever this '
        'test asserts next is about nothing having happened. '
        'readings: ${snapshot.readings.keys.toList()} '
        'faults: ${snapshot.faults} '
        'commands: ${transport.commandLog}',
  );
  return snapshot;
}

/// A live session whose ECU replies can be rewritten mid-run.
///
/// Needed because the defect only shows once a *good* value exists: the failure
/// is not "no reading", it is "the previous reading kept rendering as live".
class _LiveSession {
  _LiveSession(this.ecu, this.transport, this.client, this.engine);

  final FakeEcu ecu;
  final FakeElm327 transport;
  final Elm327Client client;
  final PollingEngine engine;

  static Future<_LiveSession> start(List<Pid> pids) async {
    final ecu = _ecm();
    final transport = FakeElm327(protocol: BusProtocol.can11, ecus: [ecu]);
    final client = Elm327Client(
      transport,
      commandTimeout: const Duration(milliseconds: 120),
    );
    expect(await client.connect(), isTrue);
    final engine = PollingEngine(client)..setActivePids(pids);
    engine.start();
    return _LiveSession(ecu, transport, client, engine);
  }

  /// Waits for a condition rather than a fixed delay.
  ///
  /// Fixed sleeps are flaky once the whole suite runs concurrently: the loop
  /// gets fewer cycles under load and a test that passes alone fails in a
  /// batch, which teaches everyone to distrust the suite.
  Future<TelemetrySnapshot> settleUntil(
    bool Function(TelemetrySnapshot) done, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final snapshot = engine.current;
      if (done(snapshot)) return snapshot;
    }
    return engine.current;
  }

  Future<void> dispose() async {
    await engine.stop();
    await engine.dispose();
  }
}

void main() {
  group('a single-PID reply that breaks the contract invalidates the reading', () {
    test('a good reply produces a reading', () async {
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          _ecm(
            extra: {
              '0105': [0x41, 0x05, 0x82],
            },
          ),
        ],
      );
      final snapshot = await _pollFor(transport, [_coolant]);
      expect(snapshot.readings[_coolant.id]?.value, closeTo(90, 0.001));
    });

    test(
      'a reading that stops arriving does not keep rendering as live',
      () async {
        // The defect in its actual shape. Coolant reads 90 °C, then the ECU
        // starts truncating. The old code found no slice for the PID, took the
        // `continue` branch, and left the 90 °C `Reading` in place with its
        // original timestamp — so a driver kept seeing a believable temperature
        // from a sensor that had stopped answering.
        final session = await _LiveSession.start([_coolant]);
        addTearDown(session.dispose);

        final good = await session.settleUntil(
          (s) => s.readings.containsKey(_coolant.id),
        );
        expect(good.readings[_coolant.id]?.value, closeTo(90, 0.001));

        session.ecu.responses['0105'] = [0x41, 0x05]; // data byte gone
        final after = await session.settleUntil(
          (s) => !s.readings.containsKey(_coolant.id),
        );

        expect(
          after.readings[_coolant.id],
          isNull,
          reason: 'the stale 90 °C must not survive a malformed reply',
        );
      },
    );

    test('a reply about a different PID does not update the reading', () async {
      // `41 0C` is a valid answer — to a question nobody asked here.
      final session = await _LiveSession.start([_coolant]);
      addTearDown(session.dispose);
      await session.settleUntil((s) => s.readings.containsKey(_coolant.id));

      session.ecu.responses['0105'] = [0x41, 0x0C, 0x1A, 0xF8];
      final after = await session.settleUntil(
        (s) => !s.readings.containsKey(_coolant.id),
      );
      expect(after.readings[_coolant.id], isNull);
    });
  });

  group('Mode 22 negative responses are errors, not sensor bytes', () {
    test('a valid reply produces a reading', () async {
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          _ecm(
            extra: {
              '221E1C': [0x62, 0x1E, 0x1C, 0x5A],
            },
          ),
        ],
      );
      final snapshot = await _pollFor(transport, [_transTemp]);
      expect(snapshot.readings[_transTemp.id]?.value, closeTo(90, 0.001));
    });

    test('request-out-of-range does not become 127', () async {
      // `7F 22 31`. The formula `A` consumed 0x7F and displayed 127 — a
      // perfectly plausible oil temperature, invented from a refusal.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          _ecm(
            extra: {
              '221E1C': [0x7F, 0x22, 0x31],
            },
          ),
        ],
      );
      final snapshot = await _pollFor(transport, [_transTemp]);
      expect(snapshot.readings[_transTemp.id], isNull);
      expect(snapshot.faults[_transTemp.id], isNotNull);
    });

    test('response-pending does not become 127 either', () async {
      // `7F 22 78` means "still working, wait". Datasheet-documented, and the
      // one negative response that must not be treated as final.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          _ecm(
            extra: {
              '221E1C': [0x7F, 0x22, 0x78],
            },
          ),
        ],
      );
      final snapshot = await _pollFor(transport, [_transTemp]);
      expect(snapshot.readings[_transTemp.id], isNull);
    });

    test('a reply echoing a different DID is rejected', () async {
      // Asked for 1E1C, answered about 1234. A late or interleaved reply from
      // another request must not be read as this one's data.
      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          _ecm(
            extra: {
              '221E1C': [0x62, 0x12, 0x34, 0x5A],
            },
          ),
        ],
      );
      final snapshot = await _pollFor(transport, [_transTemp]);
      expect(snapshot.readings[_transTemp.id], isNull);
    });
  });

  group('Mode 21 is excluded from ordinary PID polling', () {
    test(
      'a stored custom PID is refused before its command reaches the bus',
      () async {
        final transport = FakeElm327(
          protocol: BusProtocol.can11,
          ecus: [
            _ecm(
              extra: {
                // Deliberately valid-looking: even an answer must not make the
                // ordinary/custom PID path transmit this experimental service.
                '2101': [0x61, 0x01, 0x5A],
              },
            ),
          ],
        );
        final snapshot = await _pollFor(transport, [_localBattery]);

        expect(snapshot.readings[_localBattery.id], isNull);
        expect(
          snapshot.faults[_localBattery.id],
          PidFault.refusedUnsafeService,
        );
        expect(
          transport.commandLog.where((command) => command == '2101'),
          isEmpty,
        );
      },
    );
  });
}
