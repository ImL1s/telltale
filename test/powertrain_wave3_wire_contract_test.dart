/// Wire-contract oracle for the wave-3 community and experimental profiles.
///
/// Covers the new entries end to end: bundled verified catalog → installer
/// → polling engine → window slicing → formulas. Synthetic single-frame
/// responses are built from the encodings the corroborating sources agree
/// on. Experimental e-TNGA uses the one-shot probe path because that tier
/// cannot install. "Installed but one byte off" still fails here.
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

  late List<Pid> mg4Pids;
  late List<Pid> mg5Pids;
  late List<Pid> atto3Pids;

  setUpAll(() async {
    final snapshot = await PowertrainBatteryCatalogAsset.load(rootBundle);
    List<Pid> build(String id) => PowertrainProfilePidInstaller.build(
      snapshot.catalog.profiles.singleWhere((profile) => profile.id == id),
    );
    mg4Pids = build('mg-mg4-2022-2026');
    mg5Pids = build('mg-mg5-ev-2020-2023');
    atto3Pids = build('byd-atto3-2022-2024-community');
  });

  test(
    'MG4 functional 7DF/7ED signals decode source-agreed encodings',
    () async {
      final readings = await _pollProfile(
        mg4Pids,
        requestId: '7DF',
        responseId: '7ED',
        responses: const {
          // 1400 * 0.25 = 350.0 V
          '22B041': [0x62, 0xB0, 0x41, 0x05, 0x78],
          '22B042': [0x62, 0xB0, 0x42, 0x05, 0x78],
          // (40400 - 40000) * 0.025 = 10.0 A
          '22B043': [0x62, 0xB0, 0x43, 0x9D, 0xD0],
          // 100/2 - 40 = 10.0 C
          '22B056': [0x62, 0xB0, 0x56, 0x64],
          '22B05C': [0x62, 0xB0, 0x5C, 0x64],
          // 9800 / 100 = 98.0 %
          '22B061': [0x62, 0xB0, 0x61, 0x26, 0x48],
        },
      );
      const expected = <String, double>{
        'dc_bus_voltage': 350.0,
        'pack_voltage': 350.0,
        'pack_current': 10.0,
        'hv_battery_temp': 10.0,
        'battery_coolant_temp': 10.0,
        'battery_soh': 98.0,
      };
      expect(mg4Pids, hasLength(expected.length));
      for (final pid in mg4Pids) {
        expect(
          readings[pid.id]?.value,
          closeTo(expected[pid.sourceSignalId]!, 0.0001),
          reason: pid.sourceSignalId,
        );
      }
    },
  );

  test(
    'MG5 physical 7E5/7ED subset decodes the shared SAIC formulas',
    () async {
      final readings = await _pollProfile(
        mg5Pids,
        requestId: '7E5',
        responseId: '7ED',
        responses: const {
          '22B042': [0x62, 0xB0, 0x42, 0x05, 0x78],
          '22B061': [0x62, 0xB0, 0x61, 0x26, 0x48],
          '22B056': [0x62, 0xB0, 0x56, 0x64],
        },
      );
      const expected = <String, double>{
        'pack_voltage': 350.0,
        'battery_soh': 98.0,
        'hv_battery_temp': 10.0,
      };
      expect(mg5Pids, hasLength(expected.length));
      for (final pid in mg5Pids) {
        expect(
          readings[pid.id]?.value,
          closeTo(expected[pid.sourceSignalId]!, 0.0001),
          reason: pid.sourceSignalId,
        );
      }
    },
  );

  test('Atto 3 little-endian 0008/0009 decode, not the short-file BE trap', () async {
    final readings = await _pollProfile(
      atto3Pids,
      requestId: '7E7',
      responseId: '7EF',
      responses: const {
        '220005': [0x62, 0x00, 0x05, 0x4B],
        // LE 0x0172 = 370 V. BE would be 0x7201 = 29185 V and must not appear.
        '220008': [0x62, 0x00, 0x08, 0x72, 0x01],
        // LE 0x13EC = 5100 → (5100-5000)/10 = 10.0 A
        '220009': [0x62, 0x00, 0x09, 0xEC, 0x13],
        '220032': [0x62, 0x00, 0x32, 0x41],
      },
    );
    const expected = <String, double>{
      'soc': 75.0,
      'pack_voltage': 370.0,
      'pack_current': 10.0,
      'pack_temp': 25.0,
    };
    expect(atto3Pids, hasLength(expected.length));
    for (final pid in atto3Pids) {
      expect(
        readings[pid.id]?.value,
        closeTo(expected[pid.sourceSignalId]!, 0.0001),
        reason: pid.sourceSignalId,
      );
    }
  });

  test('an out-of-physics Atto 3 pack voltage is refused, not shown', () async {
    // LE 100 V sits under the 200 V floor.
    final readings = await _pollProfile(
      atto3Pids,
      requestId: '7E7',
      responseId: '7EF',
      responses: const {
        '220005': [0x62, 0x00, 0x05, 0x4B],
        '220008': [0x62, 0x00, 0x08, 0x64, 0x00],
        '220009': [0x62, 0x00, 0x09, 0xEC, 0x13],
        '220032': [0x62, 0x00, 0x32, 0x41],
      },
    );
    final voltage = atto3Pids.singleWhere(
      (pid) => pid.sourceSignalId == 'pack_voltage',
    );
    expect(readings[voltage.id], isNull);
  });

  test('e-TNGA experimental 1F5B/106C decode pinned capture bytes', () async {
    final snapshot = await PowertrainBatteryCatalogAsset.load(rootBundle);
    final etnga = snapshot.catalog.profiles.singleWhere(
      (profile) => profile.id == 'toyota-etnga-bev-2022-2024',
    );
    expect(
      () => PowertrainProfilePidInstaller.build(etnga),
      throwsA(isA<PowertrainProfileInstallException>()),
    );

    final soc = PowertrainBatteryProbe.decode(
      profile: etnga,
      command: etnga.commands.singleWhere(
        (command) => command.modeAndIdentifier == '221F5B',
      ),
      catalogSha256: snapshot.catalogSha256,
      response: const ObdResponse(
        bytes: [0x62, 0x1F, 0x5B, 0x9D],
        frames: [
          ObdFrame([0x62, 0x1F, 0x5B, 0x9D], sourceId: '7DA'),
        ],
        headersEnabled: true,
      ),
    );
    expect(soc.passed, isTrue, reason: soc.detail);
    expect(soc.readings.single.value, closeTo(0x9D * 100 / 255, 0.0001));

    final blocks = PowertrainBatteryProbe.decode(
      profile: etnga,
      command: etnga.commands.singleWhere(
        (command) => command.modeAndIdentifier == '22106C',
      ),
      catalogSha256: snapshot.catalogSha256,
      response: const ObdResponse(
        bytes: [0x62, 0x10, 0x6C, 0x7F, 0x7F, 0x7B],
        frames: [
          ObdFrame([0x62, 0x10, 0x6C, 0x7F, 0x7F, 0x7B], sourceId: '7DA'),
        ],
        headersEnabled: true,
      ),
    );
    expect(blocks.passed, isTrue, reason: blocks.detail);
    expect(
      blocks.readings
          .singleWhere((reading) => reading.signal.id == 'block_soc_max')
          .value,
      closeTo(63.5, 0.0001),
    );
    expect(
      blocks.readings
          .singleWhere((reading) => reading.signal.id == 'block_soc_min')
          .value,
      closeTo(61.5, 0.0001),
    );
    expect(etnga.commands.map((command) => command.identifier).toSet(), {
      '1F5B',
      '106C',
    });
  });

  test(
    'MG4 250 A pack current still displays inside the 400 A bound',
    () async {
      final currentPid = mg4Pids.singleWhere(
        (pid) => pid.sourceSignalId == 'pack_current',
      );
      final readings = await _pollProfile(
        [currentPid],
        requestId: '7DF',
        responseId: '7ED',
        responses: const {
          // (50000 - 40000) * 0.025 = 250 A — above the old ZS EV 200 A copy
          '22B043': [0x62, 0xB0, 0x43, 0xC3, 0x50],
        },
      );
      expect(readings[currentPid.id]?.value, closeTo(250.0, 0.0001));
    },
  );

  test('a second ECU answering MG4 functional 7DF is refused', () async {
    final voltage = mg4Pids.singleWhere(
      (pid) => pid.sourceSignalId == 'pack_voltage',
    );
    final transport = FakeElm327(
      protocol: BusProtocol.can11,
      ecus: [
        FakeEcu(
          name: 'ECM',
          requestId: '7E0',
          responseId: '7E8',
          responses: const {
            '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
            '22B042': [0x62, 0xB0, 0x42, 0x05, 0x78],
          },
        ),
        FakeEcu(
          name: 'BMS',
          requestId: '7DF',
          responseId: '7ED',
          responses: const {
            '22B042': [0x62, 0xB0, 0x42, 0x05, 0x78],
          },
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
        [voltage],
        includeProfileDerivedInputs: false,
        authorizedProfilePidIds: {voltage.id},
      )
      ..start();
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (DateTime.now().isBefore(deadline) &&
        !engine.current.readings.containsKey(voltage.id) &&
        !engine.current.faults.containsKey(voltage.id)) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    await engine.stop();
    expect(engine.current.readings[voltage.id], isNull);
    expect(engine.current.faults[voltage.id], isNotNull);
    await engine.dispose();
  });
}
