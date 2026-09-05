import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/obd/pid/pid.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/pid/priority_tier.dart';
import 'package:torque_obd/obd/powertrain_battery/powertrain_battery_profile.dart';
import 'package:torque_obd/obd/powertrain_battery/profile_pid_installer.dart';
import 'package:torque_obd/state/pid_mutation_lock.dart';
import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/state/powertrain_battery_profiles.dart';

import 'support/powertrain_snapshot_fixture.dart';

const _legacyProfilePidsKey = 'powertrain_profile_pids_v1';
const _installsKey = 'powertrain_profile_installs_v1';
const _profileId = 'injected-ready-profile';

Map<String, Object?> _primarySource({bool pinnedArtifact = true}) => {
  'name': 'primary source',
  'url': 'https://example.invalid/source',
  'revision': '2f485fcbffa2259d9e1db92d14483c1bef55dcca',
  'license': 'Apache-2.0',
  'path': 'profile.csv',
  'locator': '22B046',
  if (pinnedArtifact)
    'artifact_sha256':
        'f20ee02b2710def73c008fb54f086172a4e3323a751e8392efd1f0e3d9de0923',
};

List<Map<String, Object?>> _corroboration() => [
  {
    'name': 'independent corroboration',
    'url': 'https://example.invalid/other',
    'revision': 'a' * 40,
    'license': 'MIT',
    'path': 'poller.cpp',
    'locator': 'poll table rows for 22B046',
    'artifact_sha256': 'c' * 64,
  },
];

Map<String, Object?> _profileJson({
  String status = 'community',
  List<Map<String, Object?>>? secondarySources,
  Map<String, Object?>? source,
}) => {
  'id': _profileId,
  'display_name': 'Injected profile',
  'description': 'Structurally valid installable fixture.',
  'limitations': ['No Telltale physical-vehicle validation.'],
  'status': status,
  'evidence': 'sourceBacked',
  'market': 'Australia',
  'make': 'MG',
  'model': 'ZS EV',
  'year_from': 2021,
  'year_to': 2021,
  'variant': '44.5 kWh',
  'powertrain': 'BEV',
  'identity_evidence': {
    'market': 'exact',
    'year': 'exact',
    'model': 'exact',
    'variant': 'exact',
  },
  'source': source ?? _primarySource(),
  'secondary_sources': secondarySources ?? _corroboration(),
  'commands': [
    {
      'request_header': '781',
      'expected_responder': '789',
      'mode': '22',
      'identifier': 'B046',
      'payload_length': 4,
      'signals': [
        {
          'id': 'raw-soc',
          'name': 'BMS raw state of charge',
          'offset': 0,
          'width': 2,
          'equation': '(A*256+B)/10',
          'unit': '%',
          'min_value': 0,
          'max_value': 100,
          'semantic_kind': 'stateOfCharge',
          'recommended': true,
        },
        // Deliberately offset into the payload: the equation letters must
        // stay window-relative, or a shifted read produces a plausible wrong
        // number instead of an error.
        {
          'id': 'pack-temp',
          'name': 'Pack temperature',
          'offset': 2,
          'width': 2,
          'equation': '(A*256+B)/4-40',
          'unit': 'C',
          'min_value': -40,
          'max_value': 80,
          'semantic_kind': 'batteryTemperature',
          'recommended': false,
        },
      ],
    },
  ],
};

PowertrainBatteryProfile _profileOf(Map<String, Object?> json) =>
    PowertrainBatteryProfile.fromJson(json);

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
  ownerProfileId: _profileId,
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

/// A preferences fake whose writes can be made to fail, because the real
/// mock cannot express a failed write and the rollback paths deserve tests.
final class _FlakyPrefs implements SharedPreferences {
  _FlakyPrefs(this.inner);

  final SharedPreferences inner;
  bool failWrites = false;

  /// When non-empty, only writes to these keys fail — modelling the case
  /// where one preferences write lands and another does not.
  Set<String> failKeys = const {};

  bool _fails(String key) => failWrites || failKeys.contains(key);

  @override
  Future<bool> setStringList(String key, List<String> value) async =>
      _fails(key) ? false : inner.setStringList(key, value);

  @override
  Future<bool> remove(String key) async =>
      _fails(key) ? false : inner.remove(key);

  @override
  List<String>? getStringList(String key) => inner.getStringList(key);

  @override
  bool containsKey(String key) => inner.containsKey(key);

  @override
  Set<String> getKeys() => inner.getKeys();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused in this test: $invocation');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('installer gates', () {
    test('research-only profiles cannot become runtime PIDs', () {
      final json = _profileJson(status: 'researchOnly')
        ..['commands'] = <Object?>[];
      expect(
        () => PowertrainProfilePidInstaller.build(_profileOf(json)),
        throwsA(isA<PowertrainProfileInstallException>()),
      );
    });

    test('experimental Mode 22 profiles become unverified runtime PIDs', () {
      final pids = PowertrainProfilePidInstaller.build(
        _profileOf(_profileJson(status: 'experimental')),
      );
      expect(pids, isNotEmpty);
    });

    test('community without independent corroboration cannot install', () {
      expect(
        () => PowertrainProfilePidInstaller.build(
          _profileOf(_profileJson(secondarySources: [])),
        ),
        throwsA(
          isA<PowertrainProfileInstallException>().having(
            (error) => error.message,
            'message',
            contains('missing_secondary_source'),
          ),
        ),
      );
    });

    test('community without a pinned source artifact hash cannot install', () {
      expect(
        () => PowertrainProfilePidInstaller.build(
          _profileOf(
            _profileJson(source: _primarySource(pinnedArtifact: false)),
          ),
        ),
        throwsA(
          isA<PowertrainProfileInstallException>().having(
            (error) => error.message,
            'message',
            contains('missing_source_artifact_hash'),
          ),
        ),
      );
    });

    test('a renamed copy of the primary is not corroboration', () {
      final clonedPrimary = _primarySource()
        ..['name'] = 'a different name'
        ..['license'] = 'MIT';
      expect(
        () => PowertrainProfilePidInstaller.build(
          _profileOf(_profileJson(secondarySources: [clonedPrimary])),
        ),
        throwsA(
          isA<PowertrainProfileInstallException>().having(
            (error) => error.message,
            'message',
            contains('duplicate_corroborating_source'),
          ),
        ),
      );
    });

    test('a valid community profile builds window-relative PIDs', () {
      final pids = PowertrainProfilePidInstaller.build(
        _profileOf(_profileJson()),
      );

      expect(pids, hasLength(2));
      final soc = pids.singleWhere((pid) => pid.sourceSignalId == 'raw-soc');
      final temp = pids.singleWhere((pid) => pid.sourceSignalId == 'pack-temp');

      expect(soc.modeAndPid, '22B046');
      expect(soc.header, '781');
      expect(soc.expectedResponseId, '789');
      expect(soc.equation, '(A*256+B)/10');
      expect(soc.dataOffsetBytes, 0);
      expect(soc.dataLengthBytes, 2);
      expect(soc.responseDataLengthBytes, 4);
      expect(soc.priority, PriorityTier.medium);
      expect(soc.shortName, 'SOC');

      // The offset signal keeps its window-relative letters: `A` is byte 2 of
      // the payload, and only `dataOffsetBytes` says so.
      expect(temp.equation, '(A*256+B)/4-40');
      expect(temp.dataOffsetBytes, 2);
      expect(temp.dataLengthBytes, 2);
      expect(temp.priority, PriorityTier.low);

      expect(soc.id, isNot(temp.id));
      expect(soc.isCustom, isFalse);
    });
  });

  group('registry persistence', () {
    test('install resolves from the verified snapshot and persists '
        'references, never formulas', () async {
      final (container, prefs) = await _container({});
      addTearDown(container.dispose);
      final registry = container.read(pidRegistryProvider.notifier);
      final snapshot = snapshotOfProfiles([_profileJson()]);

      await registry.installPowertrainProfile(
        snapshot,
        _profileId,
        vehicleYear: 2021,
      );

      expect(registry.profilePids, hasLength(2));
      expect(registry.installedPowertrainProfileIds, {_profileId});
      expect(registry.installedVehicleYear(_profileId), 2021);

      final stored = prefs.getStringList(_installsKey);
      expect(stored, isNotNull);
      expect(stored, hasLength(1));
      final decoded = jsonDecode(stored!.single) as Map<String, dynamic>;
      expect(decoded, {'profile_id': _profileId, 'vehicle_year': 2021});
      // The formula must never round-trip through mutable preferences.
      expect(stored.single, isNot(contains('A*256')));
      expect(prefs.containsKey(_legacyProfilePidsKey), isFalse);
    });

    test('a profile id outside the verified snapshot cannot install', () async {
      final (container, prefs) = await _container({});
      addTearDown(container.dispose);
      final registry = container.read(pidRegistryProvider.notifier);
      final snapshot = snapshotOfProfiles([_profileJson()]);

      await expectLater(
        registry.installPowertrainProfile(
          snapshot,
          'self-declared-profile',
          vehicleYear: 2021,
        ),
        throwsA(
          isA<PowertrainProfileInstallException>().having(
            (error) => error.message,
            'message',
            contains('not in the verified catalog'),
          ),
        ),
      );
      expect(registry.profilePids, isEmpty);
      expect(prefs.containsKey(_installsKey), isFalse);
    });

    test('install refuses a year outside the documented range', () async {
      final (container, prefs) = await _container({});
      addTearDown(container.dispose);
      final registry = container.read(pidRegistryProvider.notifier);
      final snapshot = snapshotOfProfiles([_profileJson()]);

      await expectLater(
        registry.installPowertrainProfile(
          snapshot,
          _profileId,
          vehicleYear: 2023,
        ),
        throwsA(isA<PowertrainProfileInstallException>()),
      );
      expect(registry.profilePids, isEmpty);
      expect(prefs.containsKey(_installsKey), isFalse);
    });

    test(
      'recording lock refuses install and uninstall without writes',
      () async {
        final (container, prefs) = await _container({});
        addTearDown(container.dispose);
        final registry = container.read(pidRegistryProvider.notifier);
        final snapshot = snapshotOfProfiles([_profileJson()]);
        final token = container
            .read(pidMutationLockProvider)
            .tryAcquire('recording')!;

        expect(
          await registry.installPowertrainProfile(
            snapshot,
            _profileId,
            vehicleYear: 2021,
          ),
          const PidMutationOutcome.locked(),
        );
        expect(registry.profilePids, isEmpty);
        expect(prefs.containsKey(_installsKey), isFalse);

        expect(
          await registry.uninstallPowertrainProfile(_profileId),
          const PidMutationOutcome.locked(),
        );
        container.read(pidMutationLockProvider).release(token);
      },
    );

    test(
      'restore under a recording lock does not rewrite definitions',
      () async {
        final snapshot = snapshotOfProfiles([_profileJson()]);
        final (container, prefs) = await _container({
          _installsKey: [
            jsonEncode({'profile_id': _profileId, 'vehicle_year': 2021}),
          ],
        });
        addTearDown(container.dispose);
        final registry = container.read(pidRegistryProvider.notifier);
        final token = container
            .read(pidMutationLockProvider)
            .tryAcquire('recording')!;

        await registry.restoreInstalledProfiles(snapshot.catalog);

        expect(registry.powertrainRestoreSettled, isFalse);
        expect(registry.profilePids, isEmpty);
        expect(prefs.getStringList(_installsKey), [
          jsonEncode({'profile_id': _profileId, 'vehicle_year': 2021}),
        ]);
        container.read(pidMutationLockProvider).release(token);
      },
    );

    test(
      'install after a skipped restore settles so Start can proceed',
      () async {
        final snapshot = snapshotOfProfiles([_profileJson()]);
        final (container, _) = await _container({});
        addTearDown(container.dispose);
        final registry = container.read(pidRegistryProvider.notifier);
        final token = container
            .read(pidMutationLockProvider)
            .tryAcquire('recording')!;

        await registry.restoreInstalledProfiles(snapshot.catalog);
        expect(registry.powertrainRestoreSettled, isFalse);
        container.read(pidMutationLockProvider).release(token);

        expect(
          await registry.installPowertrainProfile(
            snapshot,
            _profileId,
            vehicleYear: 2021,
          ),
          const PidMutationOutcome.applied(),
        );
        expect(registry.powertrainRestoreSettled, isTrue);
        expect(registry.pidDefinitionsReadyForRecording, isTrue);
      },
    );

    test('uninstall removes PIDs and the stored reference', () async {
      final (container, prefs) = await _container({});
      addTearDown(container.dispose);
      final registry = container.read(pidRegistryProvider.notifier);
      final snapshot = snapshotOfProfiles([_profileJson()]);
      await registry.installPowertrainProfile(
        snapshot,
        _profileId,
        vehicleYear: 2021,
      );

      await registry.uninstallPowertrainProfile(_profileId);

      expect(registry.profilePids, isEmpty);
      expect(prefs.containsKey(_installsKey), isFalse);
    });

    test('restore rebuilds installed PIDs from the verified catalog', () async {
      final (container, _) = await _container({
        _installsKey: [
          jsonEncode({'profile_id': _profileId, 'vehicle_year': 2021}),
        ],
      });
      addTearDown(container.dispose);
      final registry = container.read(pidRegistryProvider.notifier);
      expect(registry.profilePids, isEmpty);

      await registry.restoreInstalledProfiles(
        snapshotOfProfiles([_profileJson()]).catalog,
      );

      expect(registry.profilePids, hasLength(2));
      expect(registry.installedVehicleYear(_profileId), 2021);
    });

    test('restore drops a reference the catalog no longer honors', () async {
      final (container, prefs) = await _container({
        _installsKey: [
          jsonEncode({'profile_id': _profileId, 'vehicle_year': 2021}),
          jsonEncode({'profile_id': 'gone-profile', 'vehicle_year': 2020}),
        ],
      });
      addTearDown(container.dispose);
      final registry = container.read(pidRegistryProvider.notifier);

      // The surviving profile has been downgraded below installable.
      await registry.restoreInstalledProfiles(
        snapshotOfProfiles([
          _profileJson(status: 'researchOnly')..['commands'] = <Object?>[],
        ]).catalog,
      );

      expect(registry.profilePids, isEmpty);
      expect(prefs.containsKey(_installsKey), isFalse);
    });

    test('a pending profile keeps its dashboard slot until restore', () async {
      // The dashboard layout is read before the catalog restore rebuilds
      // profile PIDs. The gauge is invisible while its definition is absent,
      // but its slot must survive — resolving straight into state used to
      // erase the user's battery gauges from the layout on every restart.
      final profilePidId = _injectedProfilePid.id;
      final (container, prefs) = await _container({
        _installsKey: [
          jsonEncode({'profile_id': _profileId, 'vehicle_year': 2021}),
        ],
        'active_pid_ids_v1': [profilePidId, '7E0:010C'],
      });
      addTearDown(container.dispose);

      final active = container.read(activePidsProvider);
      expect(active.map((pid) => pid.id), isNot(contains(profilePidId)));

      await container
          .read(pidRegistryProvider.notifier)
          .restoreInstalledProfiles(
            snapshotOfProfiles([_profileJson()]).catalog,
          );

      final restored = container.read(activePidsProvider);
      expect(restored.first.id, profilePidId);
      // The persisted layout was never rewritten by the pending state.
      expect(prefs.getStringList('active_pid_ids_v1'), contains(profilePidId));
    });

    test(
      'a persistence failure rolls the install and uninstall back',
      () async {
        SharedPreferences.setMockInitialValues({});
        final real = await SharedPreferences.getInstance();
        final prefs = _FlakyPrefs(real);
        final container = ProviderContainer(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        );
        addTearDown(container.dispose);
        final registry = container.read(pidRegistryProvider.notifier);
        final snapshot = snapshotOfProfiles([_profileJson()]);

        prefs.failWrites = true;
        await expectLater(
          registry.installPowertrainProfile(
            snapshot,
            _profileId,
            vehicleYear: 2021,
          ),
          throwsA(
            isA<PowertrainProfileInstallException>().having(
              (error) => error.message,
              'message',
              contains('persisted'),
            ),
          ),
        );
        // The UI must not be told an install happened that a reboot loses.
        expect(registry.profilePids, isEmpty);
        expect(registry.installedVehicleYear(_profileId), isNull);
        expect(real.containsKey(_installsKey), isFalse);

        prefs.failWrites = false;
        await registry.installPowertrainProfile(
          snapshot,
          _profileId,
          vehicleYear: 2021,
        );
        prefs.failWrites = true;
        await expectLater(
          registry.uninstallPowertrainProfile(_profileId),
          throwsA(isA<PowertrainProfileInstallException>()),
        );
        // An uninstall storage failure must not leave a half-uninstalled
        // state that resurrects on restart.
        expect(registry.profilePids, hasLength(2));
        expect(registry.installedVehicleYear(_profileId), 2021);
      },
    );

    test('a failed uninstall cannot prune the dashboard layout', () async {
      SharedPreferences.setMockInitialValues({});
      final real = await SharedPreferences.getInstance();
      final prefs = _FlakyPrefs(real);
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      final registry = container.read(pidRegistryProvider.notifier);
      final active = container.read(activePidsProvider.notifier);
      final snapshot = snapshotOfProfiles([_profileJson()]);

      await registry.restoreInstalledProfiles(snapshot.catalog);
      await registry.installPowertrainProfile(
        snapshot,
        _profileId,
        vehicleYear: 2021,
      );
      final gauge = registry.profilePids.first;
      await active.add(gauge);

      // Only the install-reference write fails; the layout write would have
      // succeeded. The uninstall must fail *before* anything observable
      // changes, or the reconciliation prunes the user's slot and persists
      // the loss even though the uninstall reports failure.
      prefs.failKeys = {_installsKey};
      await expectLater(
        registry.uninstallPowertrainProfile(_profileId),
        throwsA(isA<PowertrainProfileInstallException>()),
      );
      expect(container.read(activePidsProvider), contains(gauge));
      expect(real.getStringList('active_pid_ids_v1'), contains(gauge.id));
      expect(registry.profilePids, hasLength(2));

      // Clearing the fault lets the same uninstall complete and prune.
      prefs.failKeys = const {};
      await registry.uninstallPowertrainProfile(_profileId);
      expect(container.read(activePidsProvider), isNot(contains(gauge)));
      expect(
        real.getStringList('active_pid_ids_v1'),
        isNot(contains(gauge.id)),
      );
    });

    test('a restore that settled before the first dashboard read still '
        'prunes ghosts', () async {
      final profilePidId = _injectedProfilePid.id;
      final (container, prefs) = await _container({
        _installsKey: [
          jsonEncode({'profile_id': _profileId, 'vehicle_year': 2021}),
        ],
        'active_pid_ids_v1': [profilePidId],
      });
      addTearDown(container.dispose);

      // The restore settles with the profile withdrawn from the catalog —
      // and only then is the dashboard provider first created, so no
      // registry notification will ever fire for it. The build itself must
      // apply the settled reconciliation.
      await container
          .read(pidRegistryProvider.notifier)
          .restoreInstalledProfiles(snapshotOfProfiles(const []).catalog);

      expect(
        container.read(activePidsProvider).map((pid) => pid.id),
        PidLibrary.defaultDashboard.map((pid) => pid.id),
      );
      expect(
        prefs.getStringList('active_pid_ids_v1'),
        isNot(contains(profilePidId)),
      );
    });

    test('a settled restore prunes withdrawn slots and restores the '
        'default layout', () async {
      final profilePidId = _injectedProfilePid.id;
      final (container, prefs) = await _container({
        _installsKey: [
          jsonEncode({'profile_id': _profileId, 'vehicle_year': 2021}),
        ],
        'active_pid_ids_v1': [profilePidId],
      });
      addTearDown(container.dispose);

      // Pending: the slot survives the pre-restore window.
      expect(container.read(activePidsProvider), isEmpty);
      expect(prefs.getStringList('active_pid_ids_v1'), contains(profilePidId));

      // The catalog no longer carries the profile: the restore settles, the
      // reference is dropped, and a dashboard that held only battery gauges
      // falls back to the shipped layout instead of staying blank forever.
      await container
          .read(pidRegistryProvider.notifier)
          .restoreInstalledProfiles(snapshotOfProfiles(const []).catalog);

      expect(
        container.read(activePidsProvider).map((pid) => pid.id),
        PidLibrary.defaultDashboard.map((pid) => pid.id),
      );
      expect(
        prefs.getStringList('active_pid_ids_v1'),
        isNot(contains(profilePidId)),
      );
    });

    test('uninstall prunes the dashboard slot and a reinstall does not '
        'resurrect it', () async {
      final (container, prefs) = await _container({});
      addTearDown(container.dispose);
      final registry = container.read(pidRegistryProvider.notifier);
      final active = container.read(activePidsProvider.notifier);
      final snapshot = snapshotOfProfiles([_profileJson()]);

      // Mirrors production ordering: the startup restore settles first.
      await registry.restoreInstalledProfiles(snapshot.catalog);
      await registry.installPowertrainProfile(
        snapshot,
        _profileId,
        vehicleYear: 2021,
      );
      final gauge = registry.profilePids.first;
      await active.add(gauge);
      expect(container.read(activePidsProvider), contains(gauge));

      await registry.uninstallPowertrainProfile(_profileId);
      expect(
        prefs.getStringList('active_pid_ids_v1'),
        isNot(contains(gauge.id)),
        reason:
            'an explicit uninstall is a deletion and must outlive the '
            'session',
      );

      await registry.installPowertrainProfile(
        snapshot,
        _profileId,
        vehicleYear: 2021,
      );
      expect(
        container.read(activePidsProvider).map((pid) => pid.id),
        isNot(contains(gauge.id)),
        reason:
            'reinstalling must not resurrect gauges the user did not '
            'put back',
      );
    });

    test(
      'pending profile slots keep their position through user edits',
      () async {
        final profilePidId = _injectedProfilePid.id;
        const rpm = PidLibrary.engineRpm;
        const speed = PidLibrary.vehicleSpeed;
        final (container, prefs) = await _container({
          _installsKey: [
            jsonEncode({'profile_id': _profileId, 'vehicle_year': 2021}),
          ],
          'active_pid_ids_v1': [profilePidId, rpm.id, speed.id],
        });
        addTearDown(container.dispose);
        final active = container.read(activePidsProvider.notifier);

        // Only the two built-ins are visible while the profile is pending.
        expect(container.read(activePidsProvider).map((pid) => pid.id), [
          rpm.id,
          speed.id,
        ]);

        // Reordering the visible pair must not eat the invisible slot.
        await active.reorder(0, 1);
        expect(prefs.getStringList('active_pid_ids_v1'), [
          profilePidId,
          speed.id,
          rpm.id,
        ]);

        // When the restore finally resolves the profile, the gauge comes back
        // in its original slot, ahead of the reordered pair.
        await container
            .read(pidRegistryProvider.notifier)
            .restoreInstalledProfiles(
              snapshotOfProfiles([_profileJson()]).catalog,
            );
        final resolved = container.read(activePidsProvider);
        expect(resolved.first.id, profilePidId);
        expect(resolved.map((pid) => pid.id).skip(1), [speed.id, rpm.id]);
      },
    );

    test('injected persisted profile PIDs are ignored and erased', () async {
      final (container, prefs) = await _container({
        _legacyProfilePidsKey: [jsonEncode(_injectedProfilePid.toJson())],
      });
      addTearDown(container.dispose);

      final registry = container.read(pidRegistryProvider.notifier);
      expect(registry.profilePids, isEmpty);
      expect(
        container.read(pidRegistryProvider),
        isNot(contains(_injectedProfilePid)),
      );

      await Future<void>.delayed(Duration.zero);
      expect(prefs.containsKey(_legacyProfilePidsKey), isFalse);
    });
  });

  group('session authorization', () {
    test('authorize grants only from the verified snapshot', () async {
      final (container, prefs) = await _container({});
      addTearDown(container.dispose);
      final authorizations = container.read(
        powertrainProfileAuthorizationsProvider.notifier,
      );
      final snapshot = snapshotOfProfiles([_profileJson()]);

      final granted = authorizations.authorize(
        snapshot: snapshot,
        profileId: _profileId,
        vehicleYear: 2021,
        connectionGeneration: 41,
      );
      expect(granted, isNotNull);
      expect(granted!.issues, isEmpty);
      expect(granted.canInstall, isTrue);
      expect(authorizations.isAuthorized(_profileId), isTrue);

      // A profile id the snapshot does not contain grants nothing — and
      // revokes what the id previously held.
      final missing = authorizations.authorize(
        snapshot: snapshot,
        profileId: 'self-declared-profile',
        vehicleYear: 2021,
        connectionGeneration: 41,
      );
      expect(missing, isNull);
      expect(authorizations.isAuthorized('self-declared-profile'), isFalse);

      // Authorizations are session-only; nothing may reach storage.
      expect(
        prefs.getKeys().where((key) => key.contains('authorization')),
        isEmpty,
      );

      authorizations.invalidateForVehicleBoundary();
      expect(authorizations.isAuthorized(_profileId), isFalse);
    });

    test('a failed re-authorization revokes the standing grant', () async {
      final (container, _) = await _container({});
      addTearDown(container.dispose);
      final authorizations = container.read(
        powertrainProfileAuthorizationsProvider.notifier,
      );
      final community = snapshotOfProfiles([_profileJson()]);
      final downgraded = snapshotOfProfiles([
        _profileJson(status: 'researchOnly')..['commands'] = <Object?>[],
      ]);

      authorizations.authorize(
        snapshot: community,
        profileId: _profileId,
        vehicleYear: 2021,
        connectionGeneration: 41,
      );
      expect(authorizations.isAuthorized(_profileId), isTrue);

      final refused = authorizations.authorize(
        snapshot: downgraded,
        profileId: _profileId,
        vehicleYear: 2021,
        connectionGeneration: 41,
      );
      expect(refused!.canInstall, isFalse);
      expect(
        authorizations.isAuthorized(_profileId),
        isFalse,
        reason:
            'a profile the validator no longer accepts must not keep '
            'polling on the strength of an earlier answer',
      );
    });

    test('wrong year cannot be authorized', () async {
      final (container, _) = await _container({});
      addTearDown(container.dispose);
      final authorizations = container.read(
        powertrainProfileAuthorizationsProvider.notifier,
      );

      final result = authorizations.authorize(
        snapshot: snapshotOfProfiles([_profileJson()]),
        profileId: _profileId,
        vehicleYear: 2024,
        connectionGeneration: 41,
      );
      expect(result!.canInstall, isFalse);
      expect(authorizations.isAuthorized(_profileId), isFalse);
    });

    test('filter passes a profile PID only under a live matching grant', () {
      const ordinary = Pid(
        name: 'RPM',
        shortName: 'RPM',
        modeAndPid: '010C',
        equation: '((A*256)+B)/4',
        minValue: 0,
        maxValue: 8000,
        units: 'rpm',
      );
      const grant = {
        _profileId: PowertrainProfileAuthorization(
          vehicleYear: 2021,
          sourceRevision: '2f485fcbffa2259d9e1db92d14483c1bef55dcca',
          connectionGeneration: 7,
        ),
      };

      // Matching generation and revision: the profile PID polls.
      expect(
        filterAuthorizedPowertrainPids(
          const [ordinary, _injectedProfilePid],
          grant,
          connectionGeneration: 7,
        ),
        const [ordinary, _injectedProfilePid],
      );
      // A stale generation is a different connection — possibly a different
      // vehicle — and authorizes nothing.
      expect(
        filterAuthorizedPowertrainPids(
          const [_injectedProfilePid],
          grant,
          connectionGeneration: 8,
        ),
        isEmpty,
      );
      // A revision mismatch means the catalog changed under the install.
      const staleGrant = {
        _profileId: PowertrainProfileAuthorization(
          vehicleYear: 2021,
          sourceRevision: 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          connectionGeneration: 7,
        ),
      };
      expect(
        filterAuthorizedPowertrainPids(
          const [_injectedProfilePid],
          staleGrant,
          connectionGeneration: 7,
        ),
        isEmpty,
      );
      // No grant at all.
      expect(
        filterAuthorizedPowertrainPids(
          const [_injectedProfilePid],
          const {},
          connectionGeneration: 7,
        ),
        isEmpty,
      );
    });
  });
}
