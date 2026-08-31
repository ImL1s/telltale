library;

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/pid/pid.dart';
import 'package:torque_obd/obd/pid/priority_scheduler.dart';
import 'package:torque_obd/obd/polling_engine.dart';
import 'package:torque_obd/obd/telemetry.dart';

import 'support/fake_elm327.dart';

Pid _profilePid({
  required String signal,
  required String equation,
  required int offset,
  required int length,
  int responseLength = 3,
  double minValue = 0,
  double maxValue = 1000,
  String profile = 'mg-zs-ev-au-2021',
  String response = '789',
}) => Pid(
  name: signal,
  shortName: signal,
  modeAndPid: '22B046',
  equation: equation,
  minValue: minValue,
  maxValue: maxValue,
  units: '',
  header: '781',
  isCustom: true,
  ownerProfileId: profile,
  sourceSignalId: signal,
  sourceRevision: '2f485fcb',
  expectedResponseId: response,
  dataOffsetBytes: offset,
  dataLengthBytes: length,
  responseDataLengthBytes: responseLength,
);

FakeEcu _ecu({
  String responseId = '789',
  List<int> payload = const [0x62, 0xB0, 0x46, 0x01, 0xF4, 0x7F],
}) => FakeEcu(
  name: 'BMS',
  requestId: '781',
  responseId: responseId,
  responses: {'22B046': payload},
);

FakeEcu _engineEcu() => FakeEcu(
  name: 'ECM',
  requestId: '7E0',
  responseId: '7E8',
  responses: const {
    '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
    '010D': [0x41, 0x0D, 0x3C],
    '015E': [0x41, 0x5E, 0x00, 0x64],
  },
);

FakeElm327 _transport(List<FakeEcu> ecus) =>
    FakeElm327(protocol: BusProtocol.can11, ecus: [_engineEcu(), ...ecus]);

Future<PollingEngine> _poll(FakeElm327 transport, List<Pid> pids) async {
  final client = Elm327Client(
    transport,
    commandTimeout: const Duration(milliseconds: 120),
  );
  expect(await client.connect(), isTrue);
  final engine = PollingEngine(client)
    ..setActivePids(pids, includeProfileDerivedInputs: false)
    ..start();
  final deadline = DateTime.now().add(const Duration(seconds: 3));
  while (DateTime.now().isBefore(deadline) &&
      !pids.every(
        (pid) =>
            engine.current.readings.containsKey(pid.id) ||
            engine.current.faults.containsKey(pid.id),
      )) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  await engine.stop();
  return engine;
}

void main() {
  group('profile PID metadata', () {
    test(
      'round-trips through JSON and copyWith without changing stable id',
      () {
        final original = _profilePid(
          signal: 'raw-soc',
          equation: '(A*256+B)/10',
          offset: 0,
          length: 2,
        );

        final decoded = Pid.fromJson(original.toJson());
        final copied = decoded.copyWith(name: 'Raw SOC renamed');

        expect(decoded.ownerProfileId, 'mg-zs-ev-au-2021');
        expect(decoded.sourceSignalId, 'raw-soc');
        expect(decoded.sourceRevision, '2f485fcb');
        expect(decoded.expectedResponseId, '789');
        expect(decoded.dataOffsetBytes, 0);
        expect(decoded.dataLengthBytes, 2);
        expect(decoded.responseDataLengthBytes, 3);
        expect(copied.id, original.id);
        expect(copied.id, contains('mg-zs-ev-au-2021'));
        expect(copied.id, contains('raw-soc'));
      },
    );

    test(
      'profile signal identity cannot collide across profiles or signals',
      () {
        final first = _profilePid(
          signal: 'raw-soc',
          equation: 'A',
          offset: 0,
          length: 1,
        );
        final otherSignal = _profilePid(
          signal: 'status',
          equation: 'A',
          offset: 0,
          length: 1,
        );
        final otherProfile = _profilePid(
          signal: 'raw-soc',
          equation: 'A',
          offset: 0,
          length: 1,
          profile: 'mg4',
        );

        expect({first.id, otherSignal.id, otherProfile.id}, hasLength(3));
      },
    );

    test('legacy/manual JSON remains compatible', () {
      final pid = Pid.fromJson({
        'name': 'Manual',
        'shortName': 'M',
        'modeAndPid': '221234',
        'equation': 'A',
        'minValue': 0,
        'maxValue': 255,
        'units': '',
        'header': '7E0',
        'isCustom': true,
      });

      expect(pid.ownerProfileId, isNull);
      expect(pid.expectedResponseId, isNull);
      expect(pid.dataOffsetBytes, isNull);
      expect(pid.dataLengthBytes, isNull);
      expect(pid.responseDataLengthBytes, isNull);
      expect(pid.id, 'custom:7E0:221234');
    });
  });

  group('profile polling is disabled', () {
    test('active profile PID is rejected without reaching transport', () async {
      final pid = _profilePid(
        signal: 'raw-soc',
        equation: '(A*256+B)/10',
        offset: 0,
        length: 2,
      );
      final transport = _transport([_ecu()]);
      final client = Elm327Client(
        transport,
        commandTimeout: const Duration(milliseconds: 120),
      );
      expect(await client.connect(), isTrue);
      final engine = PollingEngine(client)
        ..setActivePids([pid], includeProfileDerivedInputs: false)
        ..start();
      addTearDown(engine.dispose);

      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(engine.current.readings[pid.id], isNull);
      expect(engine.current.faults[pid.id], PidFault.refusedUnsafeService);
      expect(transport.commandLog, isNot(contains('22B046')));
    });

    test('forged queued profile PID is rejected at the wire sink', () async {
      final pid = _profilePid(
        signal: 'raw-soc',
        equation: '(A*256+B)/10',
        offset: 0,
        length: 2,
      );
      const speed = Pid(
        name: 'Speed',
        shortName: 'Speed',
        modeAndPid: '010D',
        equation: 'A',
        minValue: 0,
        maxValue: 255,
        units: 'km/h',
        header: '7E0',
      );
      final scheduler = PriorityScheduler();
      final transport = _transport([_ecu()]);
      final client = Elm327Client(
        transport,
        commandTimeout: const Duration(milliseconds: 120),
      );
      expect(await client.connect(), isTrue);
      final engine = PollingEngine(client, scheduler: scheduler)
        ..setActivePids(const [speed], includeProfileDerivedInputs: false);

      // Bypass the active-set gate to model stale/forged queued work.
      scheduler.enqueue(pid, pid.priority);
      engine.start();
      addTearDown(engine.dispose);

      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (DateTime.now().isBefore(deadline) &&
          !engine.current.readings.containsKey(speed.id)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(engine.current.readings[speed.id]?.value, 60);
      expect(engine.current.faults[pid.id], PidFault.refusedUnsafeService);
      expect(transport.commandLog, isNot(contains('22B046')));
    });

    test('ordinary PID display bounds do not reject a reading', () async {
      const pid = Pid(
        name: 'Narrow speed gauge',
        shortName: 'Speed',
        modeAndPid: '010D',
        equation: 'A',
        minValue: 0,
        maxValue: 10,
        units: 'km/h',
        header: '7E0',
        isCustom: true,
        variant: 'narrow-display-range',
      );
      final engine = await _poll(_transport(const []), const [pid]);
      addTearDown(engine.dispose);

      expect(engine.current.readings[pid.id]?.value, 60);
      expect(engine.current.faults[pid.id], isNull);
    });
  });
}
