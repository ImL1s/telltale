/// Wire-contract oracle for the wave-2 community profiles.
///
/// Covers the wave-2 entries end to end: bundled verified catalog →
/// installer → polling engine → window slicing → formulas. The Zoe and
/// e-up! cases feed synthetic single-frame responses built byte-for-byte
/// from the encodings their corroborating sources agree on (no
/// vehicle-exact captures exist — recorded in their catalog limitations);
/// the Ioniq 6 and EV9 cases replay the pinned multi-frame E-GMP capture
/// through their own separate entries. "Installed but one byte off" still
/// fails here.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/pid/pid.dart';
import 'package:torque_obd/obd/polling_engine.dart';
import 'package:torque_obd/obd/powertrain_battery/powertrain_battery_catalog.dart';
import 'package:torque_obd/obd/powertrain_battery/powertrain_battery_probe.dart';
import 'package:torque_obd/obd/powertrain_battery/profile_pid_installer.dart';
import 'package:torque_obd/obd/telemetry.dart';

import 'support/fake_elm327.dart';

// The pinned Ioniq 5 E-GMP capture (OBDb, CC BY-SA 4.0) shared by the
// family-contract replays below. Payload bytes echo included.
const _p0101 = [
  0x62, 0x01, 0x01, 0xEF, 0xFB, 0xE7, 0xEF, 0x8E, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x0F, 0x1D, 0x3E, 0x21, 0x1E, 0x20, 0x1F, 0x20, 0x1E, 0x1F,
  0x00, 0x4B, 0xC3, 0x11, 0xC2, 0xA9, 0x00, 0x00, 0x87, 0x00, 0x05, 0x95,
  0x71, 0x00, 0x05, 0x8B, 0x78, 0x00, 0x04, 0x2F, 0x41, 0x00, 0x04, 0x08,
  0xA2, 0x02, 0xB4, 0xC8, 0xC0, 0x00, 0x02, 0xE8, 0x00, 0x00, 0x00, 0x00,
  0x0B, 0xB8,
];
const _p0105 = [
  0x62, 0x01, 0x05, 0xFF, 0xFB, 0x74, 0x0F, 0x01, 0x2C, 0x01, 0x01, 0x2C,
  0x1E, 0x20, 0x1E, 0x20, 0x1E, 0x20, 0x1E, 0x69, 0x2D, 0x6C, 0x34, 0x00,
  0x00, 0x50, 0x20, 0x00, 0x03, 0xC8, 0x85, 0x5C, 0xA8, 0x00, 0x90, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x1E, 0x20, 0x1F,
];

Future<Map<String, Reading>> _pollProfile(
  List<Pid> pids, {
  required String requestId,
  required String responseId,
  required Map<String, List<int>> responses,
}) async {
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
        name: 'BMS',
        requestId: requestId,
        responseId: responseId,
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

  late List<Pid> zoePids;
  late List<Pid> eupPids;
  late List<Pid> ioniq6Pids;
  late List<Pid> soulPids;

  setUpAll(() async {
    final snapshot = await PowertrainBatteryCatalogAsset.load(rootBundle);
    List<Pid> build(String id) => PowertrainProfilePidInstaller.build(
      snapshot.catalog.profiles.singleWhere((profile) => profile.id == id),
    );
    zoePids = build('renault-zoe-ph1-2012-2019-community');
    eupPids = build('volkswagen-eup-gen2-2020-2023-community');
    ioniq6Pids = build('hyundai-ioniq6-egmp-2022-2024-community');
    soulPids = build('kia-soul-ev-sk3-2020-community');
  });

  test('Zoe Ph1 EVC signals decode source-agreed encodings exactly', () async {
    final readings = await _pollProfile(
      zoePids,
      requestId: '7E4',
      responseId: '7EC',
      responses: const {
        // raw 3775 / 50 = 75.5 %
        '222002': [0x62, 0x20, 0x02, 0x0E, 0xBF],
        // raw 33168: (33168 - 32768) / 4 = +100.0 A (discharging)
        '223204': [0x62, 0x32, 0x04, 0x81, 0x90],
        // raw 98 = 98 % SOH
        '223206': [0x62, 0x32, 0x06, 0x62],
        // raw 65 - 40 = 25 °C
        '222001': [0x62, 0x20, 0x01, 0x41],
      },
    );

    const expected = <String, double>{
      'soc_real': 75.5,
      'pack_current': 100.0,
      'soh': 98.0,
      'batt_temp': 25.0,
    };
    expect(zoePids, hasLength(expected.length));
    for (final pid in zoePids) {
      expect(
        readings[pid.id]?.value,
        closeTo(expected[pid.sourceSignalId]!, 0.0001),
        reason: pid.sourceSignalId,
      );
    }
  });

  test('a charging Zoe decodes as negative offset-binary current', () async {
    // raw 32368: (32368 - 32768) / 4 = -100.0 A. An unsigned or
    // two's-complement misread produces a large positive number instead.
    final readings = await _pollProfile(
      zoePids,
      requestId: '7E4',
      responseId: '7EC',
      responses: const {
        '222002': [0x62, 0x20, 0x02, 0x0E, 0xBF],
        '223204': [0x62, 0x32, 0x04, 0x7E, 0x70],
        '223206': [0x62, 0x32, 0x06, 0x62],
        '222001': [0x62, 0x20, 0x01, 0x41],
      },
    );
    final current = zoePids.singleWhere(
      (pid) => pid.sourceSignalId == 'pack_current',
    );
    expect(readings[current.id]?.value, closeTo(-100.0, 0.0001));
  });

  test('e-Up gen2 BMS signals decode source-agreed encodings exactly', () async {
    final readings = await _pollProfile(
      eupPids,
      requestId: '7E5',
      responseId: '7ED',
      responses: const {
        // raw 200 / 2.5 = 80.0 %
        '22028C': [0x62, 0x02, 0x8C, 0xC8],
        // raw 1200 / 4 = 300.0 V — inside the 84s physical window
        '221E3B': [0x62, 0x1E, 0x3B, 0x04, 0xB0],
      },
    );

    const expected = <String, double>{
      'soc_bms': 80.0,
      'pack_voltage': 300.0,
    };
    expect(eupPids, hasLength(expected.length));
    for (final pid in eupPids) {
      expect(
        readings[pid.id]?.value,
        closeTo(expected[pid.sourceSignalId]!, 0.0001),
        reason: pid.sourceSignalId,
      );
    }
  });

  test('an out-of-physics e-Up pack voltage is refused, not shown', () async {
    // raw 800 / 4 = 200.0 V — below the 84s floor of 235.2 V. The bound
    // must turn this into no reading rather than a plausible wrong one.
    final readings = await _pollProfile(
      eupPids,
      requestId: '7E5',
      responseId: '7ED',
      responses: const {
        '22028C': [0x62, 0x02, 0x8C, 0xC8],
        '221E3B': [0x62, 0x1E, 0x3B, 0x03, 0x20],
      },
    );
    final voltage = eupPids.singleWhere(
      (pid) => pid.sourceSignalId == 'pack_voltage',
    );
    expect(readings[voltage.id], isNull);
  });
  test('Ioniq 6 decodes the pinned Ioniq 5 capture identically', () async {
    // The Ioniq 6 entry claims the exact E-GMP 0101/0105 contract already
    // proven for the Ioniq 5, so the same pinned capture must decode to the
    // same values through this separate catalog entry and installer run.
    const expected = <String, double>{
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
    final readings = await _pollProfile(
      ioniq6Pids,
      requestId: '7E4',
      responseId: '7EC',
      responses: const {'220101': _p0101, '220105': _p0105},
    );
    expect(ioniq6Pids, hasLength(expected.length));
    for (final pid in ioniq6Pids) {
      expect(
        readings[pid.id]?.value,
        closeTo(expected[pid.sourceSignalId]!, 0.0001),
        reason: pid.sourceSignalId,
      );
    }
  });

  test('Soul EV decodes a family frame scaled to its 98s pack', () async {
    // Same byte layout as the pinned E-GMP capture, with two windows
    // rewritten for the Soul: the 800-V-class capture voltage (748.6 V)
    // sits outside the 98s bounds (240-420 V), so the voltage bytes become
    // raw 3700 -> 370.0 V, and the deterioration window gets a valid
    // raw 950 -> 95.0 %. The Soul entry excludes the three temperatures
    // (unsigned-only sources), so the expected map is the family set minus
    // temps plus its dual-source extra.
    final p0101 = [..._p0101];
    p0101[15] = 0x0E;
    p0101[16] = 0x74;
    final p0105 = [..._p0105];
    p0105[31] = 0x03;
    p0105[32] = 0xB6;
    final readings = await _pollProfile(
      soulPids,
      requestId: '7E4',
      responseId: '7EC',
      responses: {'220101': p0101, '220105': p0105},
    );
    const expected = <String, double>{
      'soc_bms': 71.0,
      'pack_current': 1.5,
      'pack_voltage': 370.0,
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
      'cell_deterioration_min': 95.0,
    };
    expect(soulPids, hasLength(expected.length));
    final ids = soulPids.map((pid) => pid.sourceSignalId).toSet();
    expect(
      ids.intersection({
        'batt_temp_max', 'batt_temp_min', 'battery_inlet_temp',
      }),
      isEmpty,
      reason: 'unsigned-only temperature sources must stay excluded',
    );
    for (final pid in soulPids) {
      expect(
        readings[pid.id]?.value,
        closeTo(expected[pid.sourceSignalId]!, 0.0001),
        reason: pid.sourceSignalId,
      );
    }
  });

  test('EV9 experimental entry decodes regen current signed, not absurd', () async {
    // The only evidence family (OBDb) labels this byte pair unsigned, and
    // its own capture then reads 6540.2 A. The entry ships the signed
    // decode: 0xFF 0x7A → SIGNED(255)*256+122 = -134 → /10 = -13.4 A.
    // Experimental entries cannot pass the installer (that refusal is
    // covered by the probe suite), so this pins the one-shot lab decode.
    final snapshot = await PowertrainBatteryCatalogAsset.load(rootBundle);
    final ev9 = snapshot.catalog.profiles.singleWhere(
      (profile) => profile.id == 'kia-ev9-egmp-2024-2025-experimental',
    );
    final command = ev9.commands.singleWhere(
      (command) => command.modeAndIdentifier == '220101',
    );
    final regen = [..._p0101];
    regen[13] = 0xFF;
    regen[14] = 0x7A;
    final result = PowertrainBatteryProbe.decode(
      profile: ev9,
      command: command,
      catalogSha256: snapshot.catalogSha256,
      response: ObdResponse(
        bytes: regen,
        frames: [ObdFrame(regen, sourceId: '7EC')],
        headersEnabled: true,
      ),
    );
    expect(result.passed, isTrue, reason: result.detail);
    final current = result.readings.singleWhere(
      (reading) => reading.signal.id == 'pack_current',
    );
    expect(current.value, closeTo(-13.4, 0.0001));
  });
}
