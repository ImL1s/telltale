/// Missing VIN / catalog still polls generic OBD; user import stays labelled.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/diagnostics/availability.dart';
import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/pid/pid.dart';
import 'package:torque_obd/obd/pid/pid_csv.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/polling_engine.dart';
import 'package:torque_obd/obd/telemetry.dart';
import 'package:torque_obd/state/vehicle_identity.dart';

import '../support/fake_elm327.dart';

void main() {
  test('generic OBD still reads RPM when VIN is absent', () async {
    final adapter = FakeElm327(
      protocol: BusProtocol.can11,
      ecus: [
        FakeEcu(
          name: 'ECM',
          requestId: '7E0',
          responseId: '7E8',
          responses: {
            '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
            '010C': [0x41, 0x0C, 0x1A, 0xF8],
          },
        ),
      ],
    );
    final client = Elm327Client(
      adapter,
      commandTimeout: const Duration(milliseconds: 200),
    );
    expect(await client.connect(), isTrue);
    final engine = PollingEngine(client)
      ..setActivePids([PidLibrary.engineRpm], includeProfileDerivedInputs: true)
      ..start();
    addTearDown(engine.dispose);

    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline) &&
        engine.current.valueOf(PidLibrary.engineRpm) == null) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await engine.stop();

    final rpm = engine.current.valueOf(PidLibrary.engineRpm);
    expect(rpm, isNotNull);
    expect(rpm, greaterThan(0));
    final session = AvailabilityPolicy.genericObdSession(
      identity: const VehicleIdentity.unavailable(),
    );
    expect(session.availability, FeatureAvailability.usableWithNotice);
    expect(
      AvailabilityPolicy.allowSend(modeAndPid: PidLibrary.engineRpm.modeAndPid),
      isTrue,
    );
  });

  test('user-imported PID is custom and not required to come from the catalog', () {
    const columns =
        'Name,ShortName,ModeAndPID,Equation,Min Value,Max Value,Units,Header\r\n';
    final result = PidCsv.parse(
      '${columns}My MAP,MAP,010B,A,0,255,kPa,7E0\r\n',
    );
    expect(result.errors, isEmpty);
    expect(result.pids.single.isCustom, isTrue);
    expect(PollableServices.isPollable(result.pids.single.modeAndPid), isTrue);
    final status = AvailabilityPolicy.forPid(
      pid: result.pids.single,
      reading: Reading(
        pid: result.pids.single,
        value: 40,
        rawBytes: const [0x41, 0x0B, 0x28],
        timestamp: DateTime.now(),
      ),
    );
    expect(status.evidence, EvidenceKind.userSupplied);
    expect(status.badgeText, contains('使用者提供'));
  });
}
