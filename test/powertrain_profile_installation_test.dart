import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/obd/pid/pid.dart';
import 'package:torque_obd/obd/powertrain_battery/powertrain_battery_profile.dart';
import 'package:torque_obd/obd/powertrain_battery/profile_pid_installer.dart';
import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/state/powertrain_battery_profiles.dart';

const _profileStorageKey = 'powertrain_profile_pids_v1';

PowertrainBatteryProfile _profile(PowertrainProfileStatus status) =>
    PowertrainBatteryProfile(
      id: 'injected-ready-profile',
      displayName: 'Injected profile',
      description: 'Structurally valid but not trusted for installation.',
      limitations: const ['No Telltale physical-vehicle validation.'],
      status: status,
      evidence: PowertrainProfileEvidence.sourceBacked,
      market: 'Australia',
      make: 'MG',
      model: 'ZS EV',
      yearFrom: 2021,
      yearTo: 2021,
      variant: '44.5 kWh',
      powertrain: 'BEV',
      source: const PowertrainBatterySource(
        name: 'test source',
        url: 'https://example.invalid/source',
        revision: '2f485fcbffa2259d9e1db92d14483c1bef55dcca',
        license: 'Apache-2.0',
        path: 'profile.csv',
        locator: '22B046',
      ),
      identityEvidence: const PowertrainBatteryIdentityEvidence(
        market: PowertrainIdentityEvidenceLevel.exact,
        year: PowertrainIdentityEvidenceLevel.exact,
        model: PowertrainIdentityEvidenceLevel.exact,
        variant: PowertrainIdentityEvidenceLevel.exact,
      ),
      commands: [
        PowertrainBatteryCommand(
          requestHeader: '781',
          expectedResponder: '789',
          mode: '22',
          identifier: 'B046',
          payloadLength: 2,
          signals: const [
            PowertrainBatterySignal(
              id: 'raw-soc',
              name: 'BMS raw state of charge',
              offset: 0,
              width: 2,
              equation: '(A*256+B)/10',
              unit: '%',
              minValue: 0,
              maxValue: 100,
              semanticKind: 'traction_battery_soc',
              recommended: true,
            ),
          ],
        ),
      ],
    );

const _injectedProfilePid = Pid(
  name: 'Injected SOC',
  shortName: 'SOC',
  modeAndPid: '22B046',
  equation: '(A*256+B)/10',
  minValue: 0,
  maxValue: 100,
  units: '%',
  header: '781',
  isCustom: false,
  ownerProfileId: 'injected-ready-profile',
  sourceSignalId: 'raw-soc',
  sourceRevision: '2f485fcbffa2259d9e1db92d14483c1bef55dcca',
  expectedResponseId: '789',
  dataOffsetBytes: 0,
  dataLengthBytes: 2,
  responseDataLengthBytes: 2,
);

Future<(ProviderContainer, SharedPreferences)> _container(
  Map<String, Object> initial,
) async {
  SharedPreferences.setMockInitialValues(initial);
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
  return (container, prefs);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ready and community profiles cannot become runtime PIDs', () {
    for (final status in [
      PowertrainProfileStatus.ready,
      PowertrainProfileStatus.community,
    ]) {
      expect(
        () => PowertrainProfilePidInstaller.build(_profile(status)),
        throwsA(
          isA<PowertrainProfileInstallException>().having(
            (error) => error.message,
            'message',
            contains('installation is unavailable'),
          ),
        ),
        reason: status.name,
      );
    }
  });

  test(
    'ready and community profiles cannot receive session authorization',
    () async {
      final (container, prefs) = await _container({});
      addTearDown(container.dispose);
      final authorizations = container.read(
        powertrainProfileAuthorizationsProvider.notifier,
      );

      for (final status in [
        PowertrainProfileStatus.ready,
        PowertrainProfileStatus.community,
      ]) {
        final result = authorizations.authorize(
          _profile(status),
          vehicleYear: 2021,
          connectionGeneration: 41,
        );
        expect(result.issues, isEmpty, reason: status.name);
        expect(result.canInstall, isFalse, reason: status.name);
        expect(
          container.read(powertrainProfileAuthorizationsProvider),
          isEmpty,
        );
        expect(authorizations.isAuthorized('injected-ready-profile'), isFalse);
      }

      expect(
        prefs.getKeys().where((key) => key.contains('authorization')),
        isEmpty,
      );
    },
  );

  test('injected persisted profile PIDs are ignored and erased', () async {
    final (container, prefs) = await _container({
      _profileStorageKey: [jsonEncode(_injectedProfilePid.toJson())],
    });
    addTearDown(container.dispose);

    final registry = container.read(pidRegistryProvider.notifier);
    expect(registry.profilePids, isEmpty);
    expect(
      container.read(pidRegistryProvider),
      isNot(contains(_injectedProfilePid)),
    );

    await Future<void>.delayed(Duration.zero);
    expect(prefs.containsKey(_profileStorageKey), isFalse);
  });

  test(
    'registry installation rejects without mutating state or storage',
    () async {
      final (container, prefs) = await _container({});
      addTearDown(container.dispose);
      final registry = container.read(pidRegistryProvider.notifier);
      final before = container.read(pidRegistryProvider);

      await expectLater(
        registry.installPowertrainProfile(
          _profile(PowertrainProfileStatus.ready),
        ),
        throwsA(isA<PowertrainProfileInstallException>()),
      );

      expect(container.read(pidRegistryProvider), same(before));
      expect(registry.profilePids, isEmpty);
      expect(prefs.containsKey(_profileStorageKey), isFalse);
    },
  );

  test(
    'forged authorization cannot put a profile PID in production polling',
    () {
      const ordinary = Pid(
        name: 'RPM',
        shortName: 'RPM',
        modeAndPid: '010C',
        equation: '((A*256)+B)/4',
        minValue: 0,
        maxValue: 8000,
        units: 'rpm',
      );
      const forged = {
        'injected-ready-profile': PowertrainProfileAuthorization(
          vehicleYear: 2021,
          sourceRevision: '2f485fcbffa2259d9e1db92d14483c1bef55dcca',
          connectionGeneration: 7,
        ),
      };

      expect(
        filterAuthorizedPowertrainPids(
          const [ordinary, _injectedProfilePid],
          forged,
          connectionGeneration: 7,
        ),
        const [ordinary],
      );
      expect(
        filterAuthorizedPowertrainPids(
          const [_injectedProfilePid],
          forged,
          connectionGeneration: 7,
        ),
        isEmpty,
      );
    },
  );
}
