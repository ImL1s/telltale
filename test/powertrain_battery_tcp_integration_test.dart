/// Real-socket integration proof for the experimental battery probe path.
///
/// The normal local suite skips this file because it requires the deterministic
/// TCP peer in `tool/powertrain_battery_rig/simulator.py`. CI starts that peer
/// explicitly and makes absence a failure with:
///
///     flutter test test/powertrain_battery_tcp_integration_test.dart \
///       --dart-define=POWERTRAIN_BATTERY_RIG_REQUIRED=true \
///       --dart-define=POWERTRAIN_BATTERY_RIG_PORT=35000
///
/// This exercises a real loopback TCP socket and the production Riverpod,
/// session, one-use consent, and probe implementations. The peer is synthetic,
/// so passing is not adapter, vehicle, BMS, request-header, or scaling proof.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/obd/powertrain_battery/powertrain_battery_catalog.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/obd/transport/wifi_transport.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/state/powertrain_battery_experiments.dart';
import 'package:torque_obd/state/powertrain_battery_profiles.dart';

const _rigRequired = bool.fromEnvironment('POWERTRAIN_BATTERY_RIG_REQUIRED');
const _rigHost = String.fromEnvironment(
  'POWERTRAIN_BATTERY_RIG_HOST',
  defaultValue: '127.0.0.1',
);
const _rigPort = int.fromEnvironment(
  'POWERTRAIN_BATTERY_RIG_PORT',
  defaultValue: 35000,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'real TCP session executes exactly one consented MG battery probe',
    () async {
      if (!_rigRequired) {
        markTestSkipped(
          'Start tool/powertrain_battery_rig/simulator.py and set '
          'POWERTRAIN_BATTERY_RIG_REQUIRED=true to collect socket evidence.',
        );
        return;
      }
      expect(_rigHost.trim(), isNotEmpty);
      expect(_rigPort, inInclusiveRange(1, 65535));

      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
      );
      final session = container.read(obdSessionProvider.notifier);
      addTearDown(() async {
        if (container.read(obdSessionProvider).isConnected) {
          await session.disconnect();
        }
        container.dispose();
      });

      final connected = await session.connectForTest(
        WifiTransport(host: _rigHost.trim(), port: _rigPort),
        TransportKind.wifi,
      );
      expect(connected, isTrue);

      await container
          .read(powertrainBatteryExperimentalAccessProvider.notifier)
          .setEnabled(true);
      final snapshot = await PowertrainBatteryCatalogAsset.load();
      final profile = snapshot.catalog.profiles.singleWhere(
        (candidate) => candidate.id == 'mg-zs-ev-au-2021',
      );
      final command = profile.commands.singleWhere(
        (candidate) => candidate.modeAndIdentifier == '22B046',
      );
      final consents = container.read(
        powertrainExperimentalProbeConsentsProvider.notifier,
      );
      final decision = consents.authorize(
        snapshot: snapshot,
        profileId: profile.id,
        commandKey: command.wireKey,
        vehicleYear: 2021,
        connectionGeneration: session.connectionGeneration,
      );
      expect(decision.accepted, isTrue, reason: decision.reason);

      final result = await session.probePowertrainBatteryCommand(
        snapshot: snapshot,
        profileId: profile.id,
        commandKey: command.wireKey,
        vehicleYear: 2021,
      );

      expect(result.passed, isTrue, reason: result.detail);
      expect(result.responder, '789');
      expect(result.rawResponseBytes, [0x62, 0xB0, 0x46, 0x01, 0xF4]);
      expect(result.payloadBytes, [0x01, 0xF4]);
      expect(result.readings.single.value, 50.0);
      expect(
        container.read(powertrainExperimentalProbeConsentsProvider),
        isEmpty,
        reason: 'the wire read must consume its one-use consent',
      );
      await expectLater(
        session.probePowertrainBatteryCommand(
          snapshot: snapshot,
          profileId: profile.id,
          commandKey: command.wireKey,
          vehicleYear: 2021,
        ),
        throwsA(isA<TransportException>()),
      );
    },
  );
}
