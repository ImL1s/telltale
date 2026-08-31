import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/core/theme/app_theme.dart';
import 'package:torque_obd/obd/powertrain_battery/powertrain_battery_catalog.dart';
import 'package:torque_obd/obd/powertrain_battery/powertrain_battery_probe.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/state/powertrain_battery_experiments.dart';
import 'package:torque_obd/state/powertrain_battery_profiles.dart';
import 'package:torque_obd/ui/screens/settings/settings_screen.dart';

import 'support/fake_elm327.dart';

Future<ProviderContainer> _container(
  Map<String, Object> values, {
  PowertrainBatteryExperimentalPersistence? experimentalPersistence,
}) async {
  SharedPreferences.setMockInitialValues(values);
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      if (experimentalPersistence != null)
        powertrainBatteryExperimentalPersistenceProvider.overrideWithValue(
          experimentalPersistence,
        ),
    ],
  );
}

Future<void> _waitForCommand(
  FakeElm327 adapter,
  String command, {
  int afterCount = 0,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 1));
  int count() => adapter.commandLog.where((wire) => wire == command).length;
  while (count() <= afterCount && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  expect(count(), greaterThan(afterCount));
}

FakeElm327 _experimentalAdapter({
  String responder = '789',
  List<int>? response,
}) => FakeElm327(
  protocol: BusProtocol.can11,
  ecus: [
    FakeEcu(
      name: 'ECM',
      requestId: '7E0',
      responseId: '7E8',
      responses: const {
        '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
        '010D': [0x41, 0x0D, 0x3C],
        '015E': [0x41, 0x5E, 0x00, 0x64],
      },
    ),
    FakeEcu(
      name: 'BMS',
      requestId: '781',
      responseId: responder,
      responses: response == null ? const {} : {'22B046': response},
    ),
  ],
);

FakeElm327 _lexusExperimentalAdapter() => FakeElm327(
  protocol: BusProtocol.can11,
  ecus: [
    FakeEcu(
      name: 'ECM',
      requestId: '7E0',
      responseId: '7E8',
      responses: {
        '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
        '010D': [0x41, 0x0D, 0x3C],
        '015E': [0x41, 0x5E, 0x00, 0x64],
      },
    ),
    FakeEcu(
      name: 'Hybrid control',
      requestId: '7E2',
      responseId: '7EA',
      responses: {
        '2195': [0x61, 0x95, 20, 21, 22, 23],
      },
    ),
  ],
);

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'consent is one-use and rejects generation, expiry, and clock rollback',
    () async {
      final container = await _container({});
      addTearDown(container.dispose);
      await container
          .read(powertrainBatteryExperimentalAccessProvider.notifier)
          .setEnabled(true);
      final snapshot = await PowertrainBatteryCatalogAsset.load();
      final profile = snapshot.catalog.profiles.singleWhere(
        (profile) => profile.id == 'mg-zs-ev-au-2021',
      );
      final command = profile.commands.singleWhere(
        (command) => command.modeAndIdentifier == '22B046',
      );
      final consents = container.read(
        powertrainExperimentalProbeConsentsProvider.notifier,
      );
      final now = DateTime.utc(2026, 8, 31, 12);

      expect(
        consents
            .authorize(
              snapshot: snapshot,
              profileId: profile.id,
              commandKey: command.wireKey,
              vehicleYear: 2021,
              connectionGeneration: 7,
              now: now,
            )
            .accepted,
        isTrue,
      );
      expect(
        consents.take(
          snapshot: snapshot,
          profileId: profile.id,
          commandKey: command.wireKey,
          vehicleYear: 2021,
          connectionGeneration: 8,
          now: now,
        ),
        isNull,
        reason: 'consent must not cross a connection generation',
      );

      expect(
        consents
            .authorize(
              snapshot: snapshot,
              profileId: profile.id,
              commandKey: command.wireKey,
              vehicleYear: 2021,
              connectionGeneration: 7,
              now: now,
            )
            .accepted,
        isTrue,
      );
      final lease = consents.take(
        snapshot: snapshot,
        profileId: profile.id,
        commandKey: command.wireKey,
        vehicleYear: 2021,
        connectionGeneration: 7,
        now: now,
      );
      expect(lease, isNotNull);
      expect(
        container.read(powertrainExperimentalProbeConsentsProvider),
        isEmpty,
      );
      expect(
        consents.take(
          snapshot: snapshot,
          profileId: profile.id,
          commandKey: command.wireKey,
          vehicleYear: 2021,
          connectionGeneration: 7,
          now: now,
        ),
        isNull,
        reason: 'a lease is consumed before any wire request',
      );
      consents.complete(lease!);

      consents.invalidateForVehicleBoundary();
      consents.authorize(
        snapshot: snapshot,
        profileId: profile.id,
        commandKey: command.wireKey,
        vehicleYear: 2021,
        connectionGeneration: 9,
        now: now,
      );
      expect(
        consents.take(
          snapshot: snapshot,
          profileId: profile.id,
          commandKey: command.wireKey,
          vehicleYear: 2021,
          connectionGeneration: 9,
          now: now.add(PowertrainExperimentalProbeConsents.consentLifetime),
        ),
        isNull,
        reason: 'the exact expiry instant is already closed',
      );

      consents.authorize(
        snapshot: snapshot,
        profileId: profile.id,
        commandKey: command.wireKey,
        vehicleYear: 2021,
        connectionGeneration: 9,
        now: now,
      );
      expect(
        consents.take(
          snapshot: snapshot,
          profileId: profile.id,
          commandKey: command.wireKey,
          vehicleYear: 2021,
          connectionGeneration: 9,
          now: now.subtract(const Duration(seconds: 1)),
        ),
        isNull,
        reason: 'a backwards wall clock must not extend the consent window',
      );
    },
  );

  test(
    'cooldown, single-flight, attempt cap, and quarantine stay fail closed',
    () async {
      final container = await _container({});
      addTearDown(container.dispose);
      await container
          .read(powertrainBatteryExperimentalAccessProvider.notifier)
          .setEnabled(true);
      final snapshot = await PowertrainBatteryCatalogAsset.load();
      final profile = snapshot.catalog.profiles.singleWhere(
        (profile) => profile.id == 'mg-zs-ev-au-2021',
      );
      final command = profile.commands.singleWhere(
        (command) => command.modeAndIdentifier == '22B046',
      );
      final consents = container.read(
        powertrainExperimentalProbeConsentsProvider.notifier,
      );
      final start = DateTime.utc(2026, 8, 31, 13);

      void authorize(DateTime at) {
        expect(
          consents
              .authorize(
                snapshot: snapshot,
                profileId: profile.id,
                commandKey: command.wireKey,
                vehicleYear: 2021,
                connectionGeneration: 12,
                now: at,
              )
              .accepted,
          isTrue,
        );
      }

      PowertrainExperimentalProbeLease? take(DateTime at) => consents.take(
        snapshot: snapshot,
        profileId: profile.id,
        commandKey: command.wireKey,
        vehicleYear: 2021,
        connectionGeneration: 12,
        now: at,
      );

      authorize(start);
      final first = take(start);
      expect(first, isNotNull);
      authorize(start.add(const Duration(seconds: 1)));
      expect(
        take(start.add(const Duration(seconds: 1))),
        isNull,
        reason: 'only one experimental request can be in flight',
      );
      consents.complete(first!);
      expect(
        take(start.add(const Duration(seconds: 4))),
        isNull,
        reason: 'the hard-coded five second cooldown cannot be bypassed',
      );
      final second = take(start.add(const Duration(seconds: 5)));
      expect(second, isNotNull);
      consents.complete(second!);

      authorize(start.add(const Duration(seconds: 10)));
      final third = take(start.add(const Duration(seconds: 10)));
      expect(third, isNotNull);
      consents.complete(third!);

      authorize(start.add(const Duration(seconds: 15)));
      expect(take(start.add(const Duration(seconds: 15))), isNull);
      expect(consents.quarantineReason(profile.id), contains('3 次上限'));
      expect(
        container.read(powertrainExperimentalProbeConsentsProvider),
        isEmpty,
      );
      expect(
        consents
            .authorize(
              snapshot: snapshot,
              profileId: profile.id,
              commandKey: command.wireKey,
              vehicleYear: 2021,
              connectionGeneration: 12,
              now: start.add(const Duration(seconds: 20)),
            )
            .accepted,
        isFalse,
      );

      consents.revokeAll();
      expect(
        consents.quarantineReason(profile.id),
        contains('3 次上限'),
        reason: 'lifecycle and opt-out revocation must not reset per-connection quarantine',
      );
      expect(
        consents
            .authorize(
              snapshot: snapshot,
              profileId: profile.id,
              commandKey: command.wireKey,
              vehicleYear: 2021,
              connectionGeneration: 12,
              now: start.add(const Duration(seconds: 25)),
            )
            .accepted,
        isFalse,
        reason: 'the fourth attempt stays blocked until a vehicle boundary',
      );

      consents.invalidateForVehicleBoundary();
      expect(consents.quarantineReason(profile.id), isNull);
      expect(
        consents
            .authorize(
              snapshot: snapshot,
              profileId: profile.id,
              commandKey: command.wireKey,
              vehicleYear: 2021,
              connectionGeneration: 13,
              now: start.add(const Duration(seconds: 30)),
            )
            .accepted,
        isTrue,
      );
    },
  );

  test(
    'catalog hash and source revision remain bound to the consent',
    () async {
      final container = await _container({});
      addTearDown(container.dispose);
      await container
          .read(powertrainBatteryExperimentalAccessProvider.notifier)
          .setEnabled(true);
      final snapshot = await PowertrainBatteryCatalogAsset.load();
      final catalogJson = await rootBundle.loadString(
        PowertrainBatteryCatalogAsset.catalogAsset,
      );
      final manifestJson = await rootBundle.loadString(
        PowertrainBatteryCatalogAsset.manifestAsset,
      );
      final rehashedCatalog = '$catalogJson\n';
      final rehashedManifest = manifestJson
          .replaceFirst(
            snapshot.catalogSha256,
            '3d79e55b828dfdedf4ca0565a68b0c665e32333145d8029704a02a3ea18939d7',
          )
          .replaceFirst('"size_bytes": 296763', '"size_bytes": 296764');
      final otherSnapshot = PowertrainBatteryCatalogAsset.fromStrings(
        manifestJson: rehashedManifest,
        catalogJson: rehashedCatalog,
      );
      final profile = snapshot.catalog.profiles.singleWhere(
        (profile) => profile.id == 'mg-zs-ev-au-2021',
      );
      final command = profile.commands.singleWhere(
        (command) => command.modeAndIdentifier == '22B046',
      );
      final consents = container.read(
        powertrainExperimentalProbeConsentsProvider.notifier,
      );
      final now = DateTime.utc(2026, 8, 31, 14);
      consents.authorize(
        snapshot: snapshot,
        profileId: profile.id,
        commandKey: command.wireKey,
        vehicleYear: 2021,
        connectionGeneration: 3,
        now: now,
      );

      expect(
        consents.take(
          snapshot: otherSnapshot,
          profileId: profile.id,
          commandKey: command.wireKey,
          vehicleYear: 2021,
          connectionGeneration: 3,
          now: now,
        ),
        isNull,
        reason:
            'even semantically identical bytes need the consented catalog SHA',
      );
    },
  );

  test(
    'transport refusal is one-shot, consumes consent, and does not quarantine',
    () async {
      final container = await _container({
        'powertrain_battery_experiments_enabled_v1': true,
      });
      addTearDown(container.dispose);
      final snapshot = await PowertrainBatteryCatalogAsset.load();
      final profile = snapshot.catalog.profiles.singleWhere(
        (profile) => profile.id == 'mg-zs-ev-au-2021',
      );
      final command = profile.commands.singleWhere(
        (command) => command.modeAndIdentifier == '22B046',
      );
      final adapter = _experimentalAdapter();
      final session = container.read(obdSessionProvider.notifier);
      expect(await session.connectForTest(adapter, TransportKind.demo), isTrue);
      final consents = container.read(
        powertrainExperimentalProbeConsentsProvider.notifier,
      );
      expect(
        consents
            .authorize(
              snapshot: snapshot,
              profileId: profile.id,
              commandKey: command.wireKey,
              vehicleYear: 2021,
              connectionGeneration: session.connectionGeneration,
            )
            .accepted,
        isTrue,
      );
      final before = adapter.commandLog
          .where((wire) => wire == command.modeAndIdentifier)
          .length;

      final result = await session.probePowertrainBatteryCommand(
        snapshot: snapshot,
        profileId: profile.id,
        commandKey: command.wireKey,
        vehicleYear: 2021,
      );

      expect(result.failure, PowertrainBatteryProbeFailure.transport);
      expect(
        adapter.commandLog.where((wire) => wire == command.modeAndIdentifier),
        hasLength(before + 1),
        reason: 'NO DATA is inconclusive and must never trigger auto-retry',
      );
      expect(consents.quarantineReason(profile.id), isNull);
      expect(
        container.read(powertrainExperimentalProbeConsentsProvider),
        isEmpty,
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
      expect(
        adapter.commandLog.where((wire) => wire == command.modeAndIdentifier),
        hasLength(before + 1),
      );
      await session.disconnect();
    },
  );

  test(
    'probe year mismatch revokes stale consent without a wire attempt',
    () async {
      final container = await _container({
        'powertrain_battery_experiments_enabled_v1': true,
      });
      addTearDown(container.dispose);
      final snapshot = await PowertrainBatteryCatalogAsset.load();
      final profile = snapshot.catalog.profiles.singleWhere(
        (profile) => profile.id == 'mg-zs-ev-au-2021',
      );
      final command = profile.commands.singleWhere(
        (command) => command.modeAndIdentifier == '22B046',
      );
      final adapter = _experimentalAdapter(
        response: const [0x62, 0xB0, 0x46, 0x01, 0xF4],
      );
      final session = container.read(obdSessionProvider.notifier);
      expect(await session.connectForTest(adapter, TransportKind.demo), isTrue);
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
      final before = adapter.commandLog
          .where((wire) => wire == command.modeAndIdentifier)
          .length;
      final beforeHeaderCount = adapter.commandLog
          .where((wire) => wire == 'ATSH781' || wire == 'ATSH 781')
          .length;

      await expectLater(
        session.probePowertrainBatteryCommand(
          snapshot: snapshot,
          profileId: profile.id,
          commandKey: command.wireKey,
          vehicleYear: 2020,
        ),
        throwsA(isA<TransportException>()),
      );

      expect(
        adapter.commandLog.where((wire) => wire == command.modeAndIdentifier),
        hasLength(before),
        reason: 'a mismatched vehicle year must fail before the wire request',
      );
      expect(
        adapter.commandLog.where(
          (wire) => wire == 'ATSH781' || wire == 'ATSH 781',
        ),
        hasLength(beforeHeaderCount),
        reason: 'a mismatched vehicle year must fail before header selection',
      );
      expect(
        container.read(powertrainExperimentalProbeConsentsProvider),
        isEmpty,
        reason: 'the stale mismatched consent must be revoked immediately',
      );

      final replacement = consents.authorize(
        snapshot: snapshot,
        profileId: profile.id,
        commandKey: command.wireKey,
        vehicleYear: 2021,
        connectionGeneration: session.connectionGeneration,
      );
      expect(replacement.accepted, isTrue, reason: replacement.reason);
      final result = await session.probePowertrainBatteryCommand(
        snapshot: snapshot,
        profileId: profile.id,
        commandKey: command.wireKey,
        vehicleYear: 2021,
      );
      expect(result.passed, isTrue, reason: result.detail);
      expect(
        adapter.commandLog.where((wire) => wire == command.modeAndIdentifier),
        hasLength(before + 1),
        reason: 'the rejected mismatch must not count as a wire attempt',
      );
      await session.disconnect();
    },
  );

  test(
    'Lexus Mode 21 reaches wire once only through a consumed session consent',
    () async {
      final container = await _container({
        'powertrain_battery_experiments_enabled_v1': true,
      });
      addTearDown(container.dispose);
      final snapshot = await PowertrainBatteryCatalogAsset.load();
      final profile = snapshot.catalog.profiles.singleWhere(
        (profile) => profile.id == 'lexus-rx450hl-2020-source-vehicle',
      );
      final command = profile.commands.singleWhere(
        (command) => command.modeAndIdentifier == '2195',
      );
      final adapter = _lexusExperimentalAdapter();
      final session = container.read(obdSessionProvider.notifier);
      expect(await session.connectForTest(adapter, TransportKind.demo), isTrue);
      final consents = container.read(
        powertrainExperimentalProbeConsentsProvider.notifier,
      );
      expect(
        consents
            .authorize(
              snapshot: snapshot,
              profileId: profile.id,
              commandKey: command.wireKey,
              vehicleYear: 2020,
              connectionGeneration: session.connectionGeneration,
            )
            .accepted,
        isTrue,
      );
      final before = adapter.commandLog
          .where((wire) => wire == command.modeAndIdentifier)
          .length;

      final result = await session.probePowertrainBatteryCommand(
        snapshot: snapshot,
        profileId: profile.id,
        commandKey: command.wireKey,
        vehicleYear: 2020,
      );

      expect(result.passed, isTrue);
      expect(result.responder, '7EA');
      expect(
        adapter.commandLog.where((wire) => wire == command.modeAndIdentifier),
        hasLength(before + 1),
      );
      expect(adapter.commandLog.where((wire) => wire.startsWith('21')), [
        command.modeAndIdentifier,
      ], reason: 'no scan, batch, or additional Mode 21 query is allowed');
      expect(
        container.read(powertrainExperimentalProbeConsentsProvider),
        isEmpty,
      );

      await expectLater(
        session.probePowertrainBatteryCommand(
          snapshot: snapshot,
          profileId: profile.id,
          commandKey: command.wireKey,
          vehicleYear: 2020,
        ),
        throwsA(isA<TransportException>()),
      );
      expect(
        adapter.commandLog.where((wire) => wire == command.modeAndIdentifier),
        hasLength(before + 1),
        reason: 'the consumed consent cannot send a second request',
      );
      await session.disconnect();
    },
  );

  test('wrong responder is quarantined until the vehicle boundary', () async {
    final container = await _container({
      'powertrain_battery_experiments_enabled_v1': true,
    });
    addTearDown(container.dispose);
    final snapshot = await PowertrainBatteryCatalogAsset.load();
    final profile = snapshot.catalog.profiles.singleWhere(
      (profile) => profile.id == 'mg-zs-ev-au-2021',
    );
    final command = profile.commands.singleWhere(
      (command) => command.modeAndIdentifier == '22B046',
    );
    final adapter = _experimentalAdapter(
      responder: '788',
      response: const [0x62, 0xB0, 0x46, 0x01, 0xF4],
    );
    final session = container.read(obdSessionProvider.notifier);
    expect(await session.connectForTest(adapter, TransportKind.demo), isTrue);
    final consents = container.read(
      powertrainExperimentalProbeConsentsProvider.notifier,
    );
    expect(
      consents
          .authorize(
            snapshot: snapshot,
            profileId: profile.id,
            commandKey: command.wireKey,
            vehicleYear: 2021,
            connectionGeneration: session.connectionGeneration,
          )
          .accepted,
      isTrue,
    );

    final result = await session.probePowertrainBatteryCommand(
      snapshot: snapshot,
      profileId: profile.id,
      commandKey: command.wireKey,
      vehicleYear: 2021,
    );

    expect(result.failure, PowertrainBatteryProbeFailure.responderMismatch);
    expect(consents.quarantineReason(profile.id), isNotNull);
    expect(
      consents
          .authorize(
            snapshot: snapshot,
            profileId: profile.id,
            commandKey: command.wireKey,
            vehicleYear: 2021,
            connectionGeneration: session.connectionGeneration,
          )
          .accepted,
      isFalse,
    );
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(
      consents.quarantineReason(profile.id),
      isNotNull,
      reason: 'backgrounding is not a new vehicle boundary',
    );
    expect(
      consents
          .authorize(
            snapshot: snapshot,
            profileId: profile.id,
            commandKey: command.wireKey,
            vehicleYear: 2021,
            connectionGeneration: session.connectionGeneration,
          )
          .accepted,
      isFalse,
    );
    await session.disconnect();
    expect(consents.quarantineReason(profile.id), isNull);
  });

  test('disable revokes synchronously before persistence completes', () async {
    final persistence = Completer<bool>();
    final container = await _container({
      'powertrain_battery_experiments_enabled_v1': true,
    }, experimentalPersistence: (_) => persistence.future);
    addTearDown(container.dispose);
    final snapshot = await PowertrainBatteryCatalogAsset.load();
    final profile = snapshot.catalog.profiles.singleWhere(
      (profile) => profile.id == 'mg-zs-ev-au-2021',
    );
    final command = profile.commands.singleWhere(
      (command) => command.modeAndIdentifier == '22B046',
    );
    final adapter = _experimentalAdapter(
      response: const [0x62, 0xB0, 0x46, 0x01, 0xF4],
    );
    final session = container.read(obdSessionProvider.notifier);
    expect(await session.connectForTest(adapter, TransportKind.demo), isTrue);
    adapter.slowCommands[command.modeAndIdentifier] = const Duration(
      milliseconds: 200,
    );
    final consents = container.read(
      powertrainExperimentalProbeConsentsProvider.notifier,
    );
    consents.authorize(
      snapshot: snapshot,
      profileId: profile.id,
      commandKey: command.wireKey,
      vehicleYear: 2021,
      connectionGeneration: session.connectionGeneration,
    );
    final pending = session.probePowertrainBatteryCommand(
      snapshot: snapshot,
      profileId: profile.id,
      commandKey: command.wireKey,
      vehicleYear: 2021,
    );
    await _waitForCommand(adapter, command.modeAndIdentifier);

    var disableCompleted = false;
    final disabling = container
        .read(powertrainBatteryExperimentalAccessProvider.notifier)
        .setEnabled(false);
    unawaited(disabling.whenComplete(() => disableCompleted = true));

    expect(
      container.read(powertrainBatteryExperimentalAccessProvider),
      isFalse,
      reason: 'disable is a synchronous safety boundary',
    );
    expect(
      container.read(powertrainExperimentalProbeConsentsProvider),
      isEmpty,
      reason: 'the access listener must revoke before persistence returns',
    );
    expect(disableCompleted, isFalse);

    await expectLater(pending, throwsA(isA<TransportException>()));
    expect(disableCompleted, isFalse);
    persistence.complete(true);
    await disabling;
    expect(
      container.read(powertrainExperimentalProbeConsentsProvider),
      isEmpty,
    );
    await session.disconnect();
  });

  test('failed disable persistence remains fail closed', () async {
    final container = await _container({
      'powertrain_battery_experiments_enabled_v1': true,
    }, experimentalPersistence: (_) async => false);
    addTearDown(container.dispose);
    // Instantiate the session so its access listener owns consent revocation.
    container.read(obdSessionProvider);
    final snapshot = await PowertrainBatteryCatalogAsset.load();
    final profile = snapshot.catalog.profiles.singleWhere(
      (profile) => profile.id == 'mg-zs-ev-au-2021',
    );
    final command = profile.commands.singleWhere(
      (command) => command.modeAndIdentifier == '22B046',
    );
    final consents = container.read(
      powertrainExperimentalProbeConsentsProvider.notifier,
    );
    expect(
      consents
          .authorize(
            snapshot: snapshot,
            profileId: profile.id,
            commandKey: command.wireKey,
            vehicleYear: 2021,
            connectionGeneration: 1,
          )
          .accepted,
      isTrue,
    );

    await expectLater(
      container
          .read(powertrainBatteryExperimentalAccessProvider.notifier)
          .setEnabled(false),
      throwsStateError,
    );

    expect(container.read(powertrainBatteryExperimentalAccessProvider), false);
    expect(
      container.read(powertrainExperimentalProbeConsentsProvider),
      isEmpty,
    );
  });

  test('pause discards a slow response and clears consent', () async {
    final container = await _container({
      'powertrain_battery_experiments_enabled_v1': true,
    });
    addTearDown(container.dispose);
    final snapshot = await PowertrainBatteryCatalogAsset.load();
    final profile = snapshot.catalog.profiles.singleWhere(
      (profile) => profile.id == 'mg-zs-ev-au-2021',
    );
    final command = profile.commands.singleWhere(
      (command) => command.modeAndIdentifier == '22B046',
    );
    final adapter = _experimentalAdapter(
      response: const [0x62, 0xB0, 0x46, 0x01, 0xF4],
    );
    adapter.slowCommands[command.modeAndIdentifier] = const Duration(
      milliseconds: 200,
    );
    final session = container.read(obdSessionProvider.notifier);
    expect(await session.connectForTest(adapter, TransportKind.demo), isTrue);
    final consents = container.read(
      powertrainExperimentalProbeConsentsProvider.notifier,
    );
    consents.authorize(
      snapshot: snapshot,
      profileId: profile.id,
      commandKey: command.wireKey,
      vehicleYear: 2021,
      connectionGeneration: session.connectionGeneration,
    );
    final pending = session.probePowertrainBatteryCommand(
      snapshot: snapshot,
      profileId: profile.id,
      commandKey: command.wireKey,
      vehicleYear: 2021,
    );
    await _waitForCommand(adapter, command.modeAndIdentifier);

    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);

    await expectLater(pending, throwsA(isA<TransportException>()));
    expect(
      container.read(powertrainExperimentalProbeConsentsProvider),
      isEmpty,
    );
    binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await session.disconnect();
  });

  test(
    'disconnect and reconnect isolate a slow response by generation',
    () async {
      final container = await _container({
        'powertrain_battery_experiments_enabled_v1': true,
      });
      addTearDown(container.dispose);
      final snapshot = await PowertrainBatteryCatalogAsset.load();
      final profile = snapshot.catalog.profiles.singleWhere(
        (profile) => profile.id == 'mg-zs-ev-au-2021',
      );
      final command = profile.commands.singleWhere(
        (command) => command.modeAndIdentifier == '22B046',
      );
      final firstAdapter = _experimentalAdapter(
        response: const [0x62, 0xB0, 0x46, 0x01, 0xF4],
      );
      firstAdapter.slowCommands[command.modeAndIdentifier] = const Duration(
        milliseconds: 200,
      );
      final session = container.read(obdSessionProvider.notifier);
      expect(
        await session.connectForTest(firstAdapter, TransportKind.demo),
        isTrue,
      );
      final firstGeneration = session.connectionGeneration;
      final consents = container.read(
        powertrainExperimentalProbeConsentsProvider.notifier,
      );
      consents.authorize(
        snapshot: snapshot,
        profileId: profile.id,
        commandKey: command.wireKey,
        vehicleYear: 2021,
        connectionGeneration: firstGeneration,
      );
      final pending = session.probePowertrainBatteryCommand(
        snapshot: snapshot,
        profileId: profile.id,
        commandKey: command.wireKey,
        vehicleYear: 2021,
      );
      final pendingRefusal = expectLater(
        pending,
        throwsA(isA<TransportException>()),
      );
      await _waitForCommand(firstAdapter, command.modeAndIdentifier);

      await session.disconnect();
      expect(
        container.read(powertrainExperimentalProbeConsentsProvider),
        isEmpty,
      );
      final secondAdapter = _experimentalAdapter(
        response: const [0x62, 0xB0, 0x46, 0x01, 0xF4],
      );
      expect(
        await session.connectForTest(secondAdapter, TransportKind.demo),
        isTrue,
      );
      expect(session.connectionGeneration, isNot(firstGeneration));
      await pendingRefusal;
      expect(
        container.read(powertrainExperimentalProbeConsentsProvider),
        isEmpty,
      );
      await session.disconnect();
    },
  );

  test(
    'pause and resume retire a queued probe before it reaches wire',
    () async {
      final container = await _container({
        'powertrain_battery_experiments_enabled_v1': true,
      });
      addTearDown(container.dispose);
      final snapshot = await PowertrainBatteryCatalogAsset.load();
      final profile = snapshot.catalog.profiles.singleWhere(
        (profile) => profile.id == 'mg-zs-ev-au-2021',
      );
      final command = profile.commands.singleWhere(
        (command) => command.modeAndIdentifier == '22B046',
      );
      final adapter = _experimentalAdapter(
        response: const [0x62, 0xB0, 0x46, 0x01, 0xF4],
      );
      final session = container.read(obdSessionProvider.notifier);
      expect(await session.connectForTest(adapter, TransportKind.demo), isTrue);
      await session.engine!.stop();
      adapter.slowCommands['010D'] = const Duration(milliseconds: 300);
      final owner = session.pauseEpoch;
      final speedRequestsBefore = adapter.commandLog
          .where((wire) => wire == '010D')
          .length;
      final blocker = session.engine!.client.sendGlobal('010D', owner: owner);
      await _waitForCommand(adapter, '010D', afterCount: speedRequestsBefore);

      final consents = container.read(
        powertrainExperimentalProbeConsentsProvider.notifier,
      );
      consents.authorize(
        snapshot: snapshot,
        profileId: profile.id,
        commandKey: command.wireKey,
        vehicleYear: 2021,
        connectionGeneration: session.connectionGeneration,
      );
      final pending = session.probePowertrainBatteryCommand(
        snapshot: snapshot,
        profileId: profile.id,
        commandKey: command.wireKey,
        vehicleYear: 2021,
      );
      final pendingRefusal = expectLater(
        pending,
        throwsA(isA<TransportException>()),
      );
      expect(adapter.commandLog, isNot(contains(command.modeAndIdentifier)));

      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);

      await blocker;
      await pendingRefusal;
      expect(
        adapter.commandLog,
        isNot(contains(command.modeAndIdentifier)),
        reason:
            'the retired lifecycle owner must be refused before wire output',
      );
      expect(
        container.read(powertrainExperimentalProbeConsentsProvider),
        isEmpty,
      );
      await session.disconnect();
    },
  );

  test('enable publishes true only after persistence succeeds', () async {
    final persistence = Completer<bool>();
    final container = await _container(
      const {},
      experimentalPersistence: (_) => persistence.future,
    );
    addTearDown(container.dispose);

    final enabling = container
        .read(powertrainBatteryExperimentalAccessProvider.notifier)
        .setEnabled(true);
    expect(container.read(powertrainBatteryExperimentalAccessProvider), false);

    persistence.complete(true);
    await enabling;
    expect(container.read(powertrainBatteryExperimentalAccessProvider), true);
  });

  test(
    'persistence writes stay ordered and relaunch remains disabled',
    () async {
      SharedPreferences.setMockInitialValues(const {});
      final preferences = await SharedPreferences.getInstance();
      final enableGate = Completer<void>();
      final disableGate = Completer<void>();
      final writes = <bool>[];
      Future<bool> persist(bool enabled) async {
        writes.add(enabled);
        await (enabled ? enableGate.future : disableGate.future);
        return preferences.setBool(
          'powertrain_battery_experiments_enabled_v1',
          enabled,
        );
      }

      final container = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(preferences),
          powertrainBatteryExperimentalPersistenceProvider.overrideWithValue(
            persist,
          ),
        ],
      );
      addTearDown(container.dispose);
      final notifier = container.read(
        powertrainBatteryExperimentalAccessProvider.notifier,
      );

      final enabling = notifier.setEnabled(true);
      await Future<void>.delayed(Duration.zero);
      expect(writes, [true]);
      final disabling = notifier.setEnabled(false);
      expect(
        container.read(powertrainBatteryExperimentalAccessProvider),
        false,
      );
      expect(writes, [
        true,
      ], reason: 'the newer disable must wait behind the old durable write');

      enableGate.complete();
      await enabling;
      await Future<void>.delayed(Duration.zero);
      expect(writes, [true, false]);
      expect(
        container.read(powertrainBatteryExperimentalAccessProvider),
        false,
      );
      disableGate.complete();
      await disabling;
      expect(
        preferences.getBool('powertrain_battery_experiments_enabled_v1'),
        false,
      );

      final relaunched = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(preferences)],
      );
      addTearDown(relaunched.dispose);
      expect(
        relaunched.read(powertrainBatteryExperimentalAccessProvider),
        false,
        reason: 'the final durable value must also stay fail closed',
      );
    },
  );

  test(
    'disable and re-enable retire a queued probe before it reaches wire',
    () async {
      final container = await _container({
        'powertrain_battery_experiments_enabled_v1': true,
      });
      addTearDown(container.dispose);
      final snapshot = await PowertrainBatteryCatalogAsset.load();
      final profile = snapshot.catalog.profiles.singleWhere(
        (profile) => profile.id == 'mg-zs-ev-au-2021',
      );
      final command = profile.commands.singleWhere(
        (command) => command.modeAndIdentifier == '22B046',
      );
      final adapter = _experimentalAdapter(
        response: const [0x62, 0xB0, 0x46, 0x01, 0xF4],
      );
      final session = container.read(obdSessionProvider.notifier);
      expect(await session.connectForTest(adapter, TransportKind.demo), isTrue);
      await session.engine!.stop();
      adapter.slowCommands['010D'] = const Duration(milliseconds: 300);
      final speedRequestsBefore = adapter.commandLog
          .where((wire) => wire == '010D')
          .length;
      final blocker = session.engine!.client.sendGlobal(
        '010D',
        owner: session.pauseEpoch,
      );
      await _waitForCommand(adapter, '010D', afterCount: speedRequestsBefore);

      final consents = container.read(
        powertrainExperimentalProbeConsentsProvider.notifier,
      );
      consents.authorize(
        snapshot: snapshot,
        profileId: profile.id,
        commandKey: command.wireKey,
        vehicleYear: 2021,
        connectionGeneration: session.connectionGeneration,
      );
      final pending = session.probePowertrainBatteryCommand(
        snapshot: snapshot,
        profileId: profile.id,
        commandKey: command.wireKey,
        vehicleYear: 2021,
      );
      final refusal = expectLater(pending, throwsA(isA<TransportException>()));

      final access = container.read(
        powertrainBatteryExperimentalAccessProvider.notifier,
      );
      await access.setEnabled(false);
      await access.setEnabled(true);
      await blocker;
      await refusal;
      expect(
        adapter.commandLog,
        isNot(contains(command.modeAndIdentifier)),
        reason: 'an off/on cycle must not revive an already-consumed lease',
      );
      await session.disconnect();
    },
  );

  test('a queued probe cannot cross its consent expiry onto wire', () async {
    final container = await _container({
      'powertrain_battery_experiments_enabled_v1': true,
    });
    addTearDown(container.dispose);
    final snapshot = await PowertrainBatteryCatalogAsset.load();
    final profile = snapshot.catalog.profiles.singleWhere(
      (profile) => profile.id == 'mg-zs-ev-au-2021',
    );
    final command = profile.commands.singleWhere(
      (command) => command.modeAndIdentifier == '22B046',
    );
    final adapter = _experimentalAdapter(
      response: const [0x62, 0xB0, 0x46, 0x01, 0xF4],
    );
    final session = container.read(obdSessionProvider.notifier);
    expect(await session.connectForTest(adapter, TransportKind.demo), isTrue);
    await session.engine!.stop();
    adapter.slowCommands['010D'] = const Duration(milliseconds: 900);
    final speedRequestsBefore = adapter.commandLog
        .where((wire) => wire == '010D')
        .length;
    final blocker = session.engine!.client.sendGlobal(
      '010D',
      owner: session.pauseEpoch,
    );
    await _waitForCommand(adapter, '010D', afterCount: speedRequestsBefore);

    final consents = container.read(
      powertrainExperimentalProbeConsentsProvider.notifier,
    );
    final issuedAt = DateTime.now().toUtc().subtract(
      PowertrainExperimentalProbeConsents.consentLifetime -
          const Duration(milliseconds: 700),
    );
    expect(
      consents
          .authorize(
            snapshot: snapshot,
            profileId: profile.id,
            commandKey: command.wireKey,
            vehicleYear: 2021,
            connectionGeneration: session.connectionGeneration,
            now: issuedAt,
          )
          .accepted,
      isTrue,
    );
    final pending = session.probePowertrainBatteryCommand(
      snapshot: snapshot,
      profileId: profile.id,
      commandKey: command.wireKey,
      vehicleYear: 2021,
    );

    await blocker;
    final result = await pending;
    expect(result.failure, PowertrainBatteryProbeFailure.transport);
    expect(
      adapter.commandLog,
      isNot(contains(command.modeAndIdentifier)),
      reason: 'the transport deadline must be checked again before write',
    );
    await session.disconnect();
  });

  test(
    'lab visibility opt-in defaults closed and persists only the boolean',
    () async {
      final first = await _container({});
      expect(first.read(powertrainBatteryExperimentalAccessProvider), isFalse);

      await first
          .read(powertrainBatteryExperimentalAccessProvider.notifier)
          .setEnabled(true);
      expect(first.read(powertrainBatteryExperimentalAccessProvider), isTrue);
      final prefs = first.read(sharedPreferencesProvider);
      expect(prefs.getKeys(), {
        'powertrain_battery_experiments_enabled_v1',
      }, reason: 'vehicle/profile/command consent must remain memory-only');
      first.dispose();

      final relaunched = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(relaunched.dispose);
      expect(
        relaunched.read(powertrainBatteryExperimentalAccessProvider),
        isTrue,
      );
    },
  );

  testWidgets('settings requires both warnings before enabling the lab', (
    tester,
  ) async {
    final container = await _container({});
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final toggle = find.byKey(const Key('experimental_battery_access_switch'));
    await tester.scrollUntilVisible(
      toggle,
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(find.text('開啟大電池證據實驗室'), findsOneWidget);
    var enable = tester.widget<FilledButton>(
      find.byKey(const Key('enable_experimental_battery_access')),
    );
    expect(enable.onPressed, isNull);

    await tester.tap(find.byKey(const Key('experimental_evidence_ack')));
    await tester.pump();
    enable = tester.widget<FilledButton>(
      find.byKey(const Key('enable_experimental_battery_access')),
    );
    expect(enable.onPressed, isNull);

    await tester.tap(find.byKey(const Key('experimental_wire_ack')));
    await tester.pump();
    enable = tester.widget<FilledButton>(
      find.byKey(const Key('enable_experimental_battery_access')),
    );
    expect(enable.onPressed, isNotNull);
    await tester.tap(
      find.byKey(const Key('enable_experimental_battery_access')),
    );
    await tester.pumpAndSettle();

    expect(container.read(powertrainBatteryExperimentalAccessProvider), isTrue);
  });

  testWidgets('settings reports a failed enable and stays closed', (
    tester,
  ) async {
    final container = await _container(
      const {},
      experimentalPersistence: (_) async => false,
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final toggle = find.byKey(const Key('experimental_battery_access_switch'));
    await tester.scrollUntilVisible(
      toggle,
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('experimental_evidence_ack')));
    await tester.tap(find.byKey(const Key('experimental_wire_ack')));
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('enable_experimental_battery_access')),
    );
    await tester.pumpAndSettle();

    expect(container.read(powertrainBatteryExperimentalAccessProvider), false);
    expect(find.text('無法儲存大電池實驗功能設定，功能維持關閉。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings revokes consent even when disabling cannot persist', (
    tester,
  ) async {
    final container = await _container(const {
      'powertrain_battery_experiments_enabled_v1': true,
    }, experimentalPersistence: (_) async => false);
    addTearDown(container.dispose);
    final consents = container.read(
      powertrainExperimentalProbeConsentsProvider.notifier,
    );
    final snapshot = await tester.runAsync(PowertrainBatteryCatalogAsset.load);
    expect(snapshot, isNotNull);
    final catalogSnapshot = snapshot!;
    final profile = catalogSnapshot.catalog.profiles.singleWhere(
      (profile) => profile.id == 'mg-zs-ev-au-2021',
    );
    final command = profile.commands.singleWhere(
      (command) => command.modeAndIdentifier == '22B046',
    );
    expect(
      consents
          .authorize(
            snapshot: catalogSnapshot,
            profileId: profile.id,
            commandKey: command.wireKey,
            vehicleYear: 2021,
            connectionGeneration: 0,
          )
          .accepted,
      isTrue,
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final toggle = find.byKey(const Key('experimental_battery_access_switch'));
    await tester.scrollUntilVisible(
      toggle,
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(container.read(powertrainBatteryExperimentalAccessProvider), false);
    expect(
      container.read(powertrainExperimentalProbeConsentsProvider),
      isEmpty,
    );
    expect(
      find.text(
        '本次執行已關閉大電池實驗功能，但無法儲存設定；'
        '下次啟動可能再顯示實驗入口，每條查詢仍需重新確認。',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
