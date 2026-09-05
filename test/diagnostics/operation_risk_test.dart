/// Operation risk is independent of data evidence.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/diagnostics/availability.dart';
import 'package:torque_obd/obd/pid/pid.dart';

void main() {
  test('bounded reads are allowed without VIN, catalog, or field logs', () {
    for (final request in ['010C', '010D', '020500', '0902', '221E1C']) {
      expect(AvailabilityPolicy.riskFor(request), OperationRisk.boundedRead);
      expect(AvailabilityPolicy.allowSend(modeAndPid: request), isTrue);
      expect(PollableServices.isPollable(request), isTrue);
    }
  });

  test('DTC reads are bounded reads even though they are not gauges', () {
    expect(AvailabilityPolicy.riskFor('03'), OperationRisk.boundedRead);
    expect(AvailabilityPolicy.allowSend(modeAndPid: '03'), isTrue);
  });

  test('clear requires snapshot and confirmation', () {
    expect(AvailabilityPolicy.riskFor('04'), OperationRisk.clear);
    expect(AvailabilityPolicy.allowSend(modeAndPid: '04'), isFalse);
    expect(
      AvailabilityPolicy.allowSend(
        modeAndPid: '04',
        gate: const OperationGate(clearSnapshotReady: true),
      ),
      isFalse,
    );
    expect(
      AvailabilityPolicy.allowSend(
        modeAndPid: '04',
        gate: const OperationGate(
          clearSnapshotReady: true,
          clearConfirmed: true,
        ),
      ),
      isTrue,
    );
  });

  test('actuate and program stay closed without a recipe', () {
    expect(AvailabilityPolicy.riskFor('2F011203'), OperationRisk.stateChange);
    expect(AvailabilityPolicy.riskFor('310112'), OperationRisk.stateChange);
    expect(AvailabilityPolicy.riskFor('2E1234'), OperationRisk.program);
    expect(AvailabilityPolicy.riskFor('1101'), OperationRisk.program);
    expect(AvailabilityPolicy.allowSend(modeAndPid: '2F011203'), isFalse);
    expect(AvailabilityPolicy.allowSend(modeAndPid: '2E1234'), isFalse);
  });
}
