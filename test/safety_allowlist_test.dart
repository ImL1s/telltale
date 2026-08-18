/// A telemetry reader must not be able to actuate an ECU.
///
/// Custom PIDs are free-form hex and the scheduler sends them repeatedly for as
/// long as their gauge is on the dashboard. Without a rule that reaches past
/// reading: `2F` InputOutputControlByIdentifier actuates outputs, `2E`
/// WriteDataByIdentifier writes configuration, `31` RoutineControl starts
/// routines. This is a vehicle-safety boundary, not input validation, so it is
/// an allowlist — a service absent from it is refused even if it would work.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/pid/pid.dart';
import 'package:torque_obd/obd/pid/pid_csv.dart';
import 'package:torque_obd/obd/polling_engine.dart';

import 'support/fake_elm327.dart';

void main() {
  group('which services may be polled', () {
    test('the read-only ones are allowed', () {
      expect(PollableServices.isPollable('010C'), isTrue); // current data
      expect(PollableServices.isPollable('020500'), isTrue); // freeze frame
      expect(PollableServices.isPollable('0902'), isTrue); // vehicle info
      expect(PollableServices.isPollable('221E1C'), isTrue); // ReadDataByIdentifier
    });

    test('a request missing part of its envelope is refused', () {
      // This file used to assert that `0205` is pollable. Codex named it as an
      // unsafe expectation, and it is: SAE J1979 defines Mode 02 as service,
      // PID *and* freeze-frame number. A conforming ECU expects `02 05 00` and
      // may answer nothing. The permissive clone that answers `42 05 00 7B`
      // anyway is the dangerous case — the reply matched the two bytes the
      // user supplied, `A` bound to the frame index `00`, and `A-40` displayed
      // -40 °C where the real reading was 83 °C.
      expect(PollableServices.isPollable('0205'), isFalse);
      expect(PollableServices.rejectionReason('0205'), contains('幀編號'));

      // Mode 22 identifiers are two bytes; one is not a shorter form of it.
      expect(PollableServices.isPollable('2211'), isFalse);

      // And the well-formed versions still pass, so this is a shape check
      // rather than a blanket refusal.
      expect(PollableServices.isPollable('020500'), isTrue);
      expect(PollableServices.isPollable('221101'), isTrue);
    });

    test('anything that writes, controls or resets is refused', () {
      for (final request in [
        '2F011203', // InputOutputControlByIdentifier — actuates an output
        '2E1234',   // WriteDataByIdentifier
        '310112',   // RoutineControl
        '1101',     // ECUReset
        '2701',     // SecurityAccess
        '2801',     // CommunicationControl
        '1400',     // ClearDiagnosticInformation
      ]) {
        expect(
          PollableServices.isPollable(request),
          isFalse,
          reason: '$request must never be scheduled',
        );
        expect(PollableServices.rejectionReason(request), isNotNull);
      }
    });

    test('malformed requests are refused too', () {
      expect(PollableServices.isPollable('01'), isFalse); // too short
      expect(PollableServices.isPollable('010C0'), isFalse); // odd length
      expect(PollableServices.isPollable('01ZZ'), isFalse); // not hex
    });
  });

  group('CSV import', () {
    const columns = 'Name,ShortName,ModeAndPID,Equation,Min Value,Max Value,'
        'Units,Header,Priority,Redline,Variant\r\n';

    test('refuses a row that would actuate an output', () {
      // Codex's trigger verbatim: header 7E0, ModeAndPID 2F011203, enabled.
      final result = PidCsv.parse(
        '${columns}Actuate,ACT,2F011203,A,0,100,x,7E0\r\n',
      );
      expect(result.pids, isEmpty);
      expect(result.errors.single, contains('2F'));
    });

    test('still accepts an ordinary ReadDataByIdentifier row', () {
      final result = PidCsv.parse(
        '${columns}Trans,TR,221E1C,A,0,150,C,7E1\r\n',
      );
      expect(result.errors, isEmpty);
      expect(result.pids.single.modeAndPid, '221E1C');
    });
  });

  group('the polling engine is the last line of defence', () {
    test('a definition stored by an older build is never transmitted',
        () async {
      // The editor and the importer both refuse it now, but a PID persisted
      // before this rule existed would otherwise be scheduled on every cycle.
      const dangerous = Pid(
        name: 'Actuator',
        shortName: 'ACT',
        modeAndPid: '2F011203',
        equation: 'A',
        minValue: 0,
        maxValue: 100,
        units: '',
        isCustom: true,
      );

      final transport = FakeElm327(
        protocol: BusProtocol.can11,
        ecus: [
          FakeEcu(
            name: 'ECM',
            requestId: '7E0',
            responseId: '7E8',
            responses: {
              '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
              '010C': [0x41, 0x0C, 0x1A, 0xF8],
              '010D': [0x41, 0x0D, 0x3C],
              '010B': [0x41, 0x0B, 0x63],
              '010F': [0x41, 0x0F, 0x46],
              '0110': [0x41, 0x10, 0x07, 0xD0],
              // Deliberately answered, so the test fails loudly if it is sent.
              '2F011203': [0x6F, 0x01, 0x12, 0x03],
            },
          ),
        ],
      );
      final client = Elm327Client(
        transport,
        commandTimeout: const Duration(milliseconds: 120),
      );
      expect(await client.connect(), isTrue);
      final engine = PollingEngine(client)..setActivePids([dangerous]);
      engine.start();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await engine.stop();

      expect(
        transport.commandLog.where((c) => c.startsWith('2F')),
        isEmpty,
        reason: 'an actuation request must never reach the bus',
      );
      expect(engine.current.readings[dangerous.id], isNull);
      await engine.dispose();
    });
  });
}
