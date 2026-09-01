/// End-to-end oracle for the shipped Hyundai/Kia BMS contract.
///
/// Everything else in the powertrain suite ultimately checks the catalog
/// against itself. This file feeds a pinned real-vehicle response capture
/// through the full production path — bundled verified catalog → installer →
/// polling engine → multi-frame reassembly → window slicing → formulas — and
/// asserts every shipped Ioniq 5 signal decodes to the value two independent
/// implementations agree on. "Legal but one byte off" fails here.
///
/// Capture provenance: OBDb/Hyundai-IONIQ-5 test case (CC BY-SA 4.0), pinned
/// at abfb2d2e1264706c857785b0daca40f240a4bfd3 — the same artifact the
/// catalog entry records. Expected values were cross-checked against the
/// WiCAN profile's independent formulas before being pinned below.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/pid/pid.dart';
import 'package:torque_obd/obd/polling_engine.dart';
import 'package:torque_obd/obd/powertrain_battery/powertrain_battery_catalog.dart';
import 'package:torque_obd/obd/powertrain_battery/profile_pid_installer.dart';
import 'package:torque_obd/obd/telemetry.dart';

import 'support/fake_elm327.dart';

// 220101 positive response, echo included: 59 payload bytes.
const _p0101 = [
  0x62, 0x01, 0x01, 0xEF, 0xFB, 0xE7, 0xEF, 0x8E, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x0F, 0x1D, 0x3E, 0x21, 0x1E, 0x20, 0x1F, 0x20, 0x1E, 0x1F,
  0x00, 0x4B, 0xC3, 0x11, 0xC2, 0xA9, 0x00, 0x00, 0x87, 0x00, 0x05, 0x95,
  0x71, 0x00, 0x05, 0x8B, 0x78, 0x00, 0x04, 0x2F, 0x41, 0x00, 0x04, 0x08,
  0xA2, 0x02, 0xB4, 0xC8, 0xC0, 0x00, 0x02, 0xE8, 0x00, 0x00, 0x00, 0x00,
  0x0B, 0xB8,
];

// 220105 positive response, echo included: 43 payload bytes.
const _p0105 = [
  0x62, 0x01, 0x05, 0xFF, 0xFB, 0x74, 0x0F, 0x01, 0x2C, 0x01, 0x01, 0x2C,
  0x1E, 0x20, 0x1E, 0x20, 0x1E, 0x20, 0x1E, 0x69, 0x2D, 0x6C, 0x34, 0x00,
  0x00, 0x50, 0x20, 0x00, 0x03, 0xC8, 0x85, 0x5C, 0xA8, 0x00, 0x90, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x1E, 0x20, 0x1F,
];

/// What two independent implementations decode from the capture above.
const _expected = <String, double>{
  'soc_bms': 71.0,
  'pack_current': 1.5,
  'pack_voltage': 748.6,
  'batt_temp_max': 33.0,
  'batt_temp_min': 30.0,
  'cell_volt_max': 3.9,
  'cell_volt_max_no': 17.0,
  'cell_volt_min': 3.88,
  'cell_volt_min_no': 169.0,
  'aux_batt_voltage': 13.5,
  'cum_charge_ah': 36593.7,
  'cum_discharge_ah': 36338.4,
  'cum_energy_charged': 27424.1,
  'cum_energy_discharged': 26435.4,
  'soh': 96.8,
  'soc_display': 72.0,
};

Future<Map<String, Reading>> _pollProfile(
  List<Pid> pids,
  Map<String, List<int>> responses,
) async {
  final transport = FakeElm327(
    protocol: BusProtocol.can11,
    ecus: [
      FakeEcu(
        name: 'ECM',
        requestId: '7E0',
        responseId: '7E8',
        responses: const {
          '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
        },
      ),
      FakeEcu(
        name: 'E-GMP BMS',
        requestId: '7E4',
        responseId: '7EC',
        responses: responses,
      ),
    ],
  );
  final client = Elm327Client(
    transport,
    commandTimeout: const Duration(milliseconds: 300),
  );
  expect(await client.connect(), isTrue);
  final engine = PollingEngine(client)
    ..setActivePids(
      pids,
      includeProfileDerivedInputs: false,
      authorizedProfilePidIds: {for (final pid in pids) pid.id},
    )
    ..start();
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (DateTime.now().isBefore(deadline) &&
      !pids.every(
        (pid) =>
            engine.current.readings.containsKey(pid.id) ||
            engine.current.faults.containsKey(pid.id),
      )) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  await engine.stop();
  final readings = Map.of(engine.current.readings);
  await engine.dispose();
  return readings;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<Pid> pids;

  setUpAll(() async {
    final snapshot = await PowertrainBatteryCatalogAsset.load(rootBundle);
    final ioniq5 = snapshot.catalog.profiles.singleWhere(
      (profile) => profile.id == 'hyundai-ioniq5-egmp-2021-2024-community',
    );
    pids = PowertrainProfilePidInstaller.build(ioniq5);
  });

  test('every shipped Ioniq 5 signal decodes the pinned capture exactly', () async {
    final readings = await _pollProfile(pids, {
      '220101': _p0101,
      '220105': _p0105,
    });

    expect(pids, hasLength(_expected.length));
    for (final pid in pids) {
      final reading = readings[pid.id];
      expect(
        reading,
        isNotNull,
        reason: '${pid.sourceSignalId} produced no reading',
      );
      expect(
        reading!.value,
        closeTo(_expected[pid.sourceSignalId]!, 0.0001),
        reason: pid.sourceSignalId,
      );
    }
  });

  test('a regenerating pack decodes as negative current', () async {
    // Same capture with the signed current bytes (payload offset 10..11)
    // replaced by 0xFF38: two's-complement -200 → -20.0 A. SIGNED() done
    // wrong — unsigned read, or sign applied to the low byte — produces
    // 6537.6 or a positive number instead, and either fails this pin.
    final charging = [..._p0101];
    charging[13] = 0xFF;
    charging[14] = 0x38;
    final readings = await _pollProfile(pids, {
      '220101': charging,
      '220105': _p0105,
    });

    final current = pids.singleWhere(
      (pid) => pid.sourceSignalId == 'pack_current',
    );
    expect(readings[current.id]?.value, closeTo(-20.0, 0.0001));
  });
}
