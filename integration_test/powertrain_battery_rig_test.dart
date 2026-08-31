/// End-to-end phone proof for the experimental, evidence-gated battery probe.
///
/// This test uses the shipped, hash-checked MG catalog entry and its exact
/// Mode 22 B046 command. It exercises the Android device's real TCP stack and
/// the production one-shot consent path, but the peer is a deterministic
/// synthetic ELM327 rig. Passing it is not adapter, vehicle, request-header,
/// scaling, trim, firmware, or market compatibility proof.
///
/// Start `tool/powertrain_battery_rig/simulator.py` on a host reachable from
/// the device, then run:
///
///     flutter test integration_test/powertrain_battery_rig_test.dart \
///       -d <device-id> --flavor rig \
///       --dart-define=TELLTALE_TEST_RIG=true \
///       --dart-define=WIFI_RIG_HOST=<host-ip> \
///       --dart-define=WIFI_RIG_PORT=35000
///
/// Missing or invalid rig configuration fails rather than skipping. The test
/// runs only in the isolated `.rig` package so it cannot clear or inherit the
/// field app's preferences or evidence.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:torque_obd/obd/powertrain_battery/powertrain_battery_catalog.dart';
import 'package:torque_obd/obd/powertrain_battery/powertrain_battery_profile.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/state/powertrain_battery_experiments.dart';
import 'package:torque_obd/state/powertrain_battery_profiles.dart';

import 'rig_support.dart';

const String rigHost = String.fromEnvironment('WIFI_RIG_HOST');
const String rigPortText = String.fromEnvironment(
  'WIFI_RIG_PORT',
  defaultValue: '35000',
);
const String mgProfileId = 'mg-zs-ev-au-2021';
const String mgRawSocIdentifier = 'B046';

Finder fieldWithLabel(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
  description: 'TextField labelled "$label"',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'probe production MG B046 once without installing or persisting a PID',
    (tester) async {
      expect(
        rigHost.trim(),
        isNotEmpty,
        reason: 'WIFI_RIG_HOST must name a host reachable from the device',
      );
      final rigPort = int.tryParse(rigPortText);
      expect(
        rigPort,
        isNotNull,
        reason: 'WIFI_RIG_PORT must be an integer, got "$rigPortText"',
      );
      expect(
        rigPort,
        inInclusiveRange(1, 65535),
        reason: 'WIFI_RIG_PORT must be in the range 1-65535',
      );

      await startCleanRigApp(tester);

      final wifiHeader = await revealText(tester, 'Wi-Fi');
      await tester.tap(wifiHeader);
      await tester.pumpAndSettle();

      await revealText(tester, 'IP 位址');
      final hostField = fieldWithLabel('IP 位址');
      final portField = fieldWithLabel('埠');
      expect(hostField, findsOneWidget);
      expect(portField, findsOneWidget);
      await tester.enterText(hostField, rigHost.trim());
      await tester.enterText(portField, '$rigPort');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      await revealText(tester, '連線');
      final connectButton = find.widgetWithText(FilledButton, '連線');
      expect(connectButton, findsOneWidget);
      await tester.tap(connectButton);
      await tester.pump();

      await requireDashboard(tester);
      await requireLivePolling(tester);

      final container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp)),
        listen: false,
      );
      final session = container.read(obdSessionProvider.notifier);
      final registry = container.read(pidRegistryProvider.notifier);
      final preferences = container.read(sharedPreferencesProvider);

      final snapshot = await PowertrainBatteryCatalogAsset.load();
      final profile = snapshot.catalog.profiles.singleWhere(
        (candidate) => candidate.id == mgProfileId,
      );
      final command = profile.commands.singleWhere(
        (candidate) => candidate.identifier == mgRawSocIdentifier,
      );
      expect(profile.status, PowertrainProfileStatus.experimental);
      expect(registry.installedPowertrainProfileIds, isEmpty);
      expect(registry.profilePids, isEmpty);

      await container
          .read(powertrainBatteryExperimentalAccessProvider.notifier)
          .setEnabled(true);
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
      final rawSoc = result.readings.singleWhere(
        (reading) => reading.signal.id == 'raw_soc',
      );
      expect(rawSoc.value, 50.0);
      expect(rawSoc.rawBytes, [0x01, 0xF4]);

      expect(
        container.read(powertrainExperimentalProbeConsentsProvider),
        isEmpty,
        reason: 'the consent must be consumed before the one-shot wire read',
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

      expect(registry.installedPowertrainProfileIds, isEmpty);
      expect(registry.profilePids, isEmpty);
      expect(
        container
            .read(activePidsProvider)
            .where((pid) => pid.ownerProfileId == profile.id),
        isEmpty,
      );
      expect(
        preferences.getStringList('powertrain_profile_pids_v1') ?? const [],
        isEmpty,
        reason: 'an experimental probe must never persist dashboard PIDs',
      );

      await session.saveTranscriptSnapshotForTest();
      final stored = await waitForStoredTranscript(tester, (value) {
        return value.body.contains(r'>> ATSH 781\r') &&
            value.body.contains(r'>> 22B046\r') &&
            value.body.contains('789');
      });
      expect(
        stored,
        isNotNull,
        reason: 'one-shot battery wire evidence was not persisted',
      );
      expect(stored!.fromRealHardware, isFalse);
      expect(stored.header, contains('# Telltale 無車測試馬具證據 v1'));
      expect(stored.header, contains('不得視為實體轉接器或實車驗證'));
      expect(stored.header, contains('# 連線方式：Wi-Fi'));
      expect(stored.header, contains('# 裝置：${rigHost.trim()}:$rigPort'));
      expect(
        r'>> 22B046\r'.allMatches(stored.body).length,
        1,
        reason: 'consent consumption must prevent an implicit second wire read',
      );

      final pendingDecision = consents.authorize(
        snapshot: snapshot,
        profileId: profile.id,
        commandKey: command.wireKey,
        vehicleYear: 2021,
        connectionGeneration: session.connectionGeneration,
      );
      expect(pendingDecision.accepted, isTrue, reason: pendingDecision.reason);
      expect(
        container.read(powertrainExperimentalProbeConsentsProvider),
        isNotEmpty,
      );

      await session.disconnect();
      await tester.pump();
      expect(container.read(obdSessionProvider).isConnected, isFalse);
      expect(
        container.read(powertrainExperimentalProbeConsentsProvider),
        isEmpty,
        reason: 'pending experimental consent must not survive disconnect',
      );
      expect(registry.installedPowertrainProfileIds, isEmpty);
      expect(registry.profilePids, isEmpty);
    },
  );
}
