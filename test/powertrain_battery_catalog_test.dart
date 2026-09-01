import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/obd/pid/formula_engine.dart';
import 'package:torque_obd/obd/powertrain_battery/powertrain_battery_catalog.dart';
import 'package:torque_obd/obd/powertrain_battery/powertrain_battery_profile.dart';
import 'package:torque_obd/obd/powertrain_battery/profile_catalog_validator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('bundled powertrain battery catalog', () {
    test('loads a hash-checked large catalog from rootBundle', () async {
      final snapshot = await PowertrainBatteryCatalogAsset.load(rootBundle);
      final profiles = snapshot.catalog.profiles;

      expect(profiles.length, greaterThanOrEqualTo(60));
      expect(snapshot.profileCount, profiles.length);
      expect(snapshot.profileCount, 221);
      expect(snapshot.signalCount, 157);
      expect(snapshot.countsByPowertrain, {
        'BEV': 89,
        'FCEV': 5,
        'HEV': 48,
        'MHEV': 7,
        'PHEV': 69,
        'REEV': 3,
      });
      expect(snapshot.catalogSha256, hasLength(64));
    });

    test(
      'rejects catalog bytes that do not match the checked-in manifest',
      () async {
        final manifest = await rootBundle.loadString(
          PowertrainBatteryCatalogAsset.manifestAsset,
        );
        final catalog = await rootBundle.loadString(
          PowertrainBatteryCatalogAsset.catalogAsset,
        );

        expect(
          () => PowertrainBatteryCatalogAsset.fromStrings(
            manifestJson: manifest,
            catalogJson: '$catalog ',
          ),
          throwsA(isA<PowertrainBatteryCatalogAssetException>()),
        );
      },
    );

    test(
      'all entries validate, are unique, and carry pinned attribution',
      () async {
        final snapshot = await PowertrainBatteryCatalogAsset.load(rootBundle);
        const validator = PowertrainBatteryProfileCatalogValidator();
        final validation = validator.validateCatalog(snapshot.catalog);

        expect(validation.issues, isEmpty);
        expect(
          snapshot.catalog.profiles.map((profile) => profile.id).toSet(),
          hasLength(snapshot.catalog.profiles.length),
        );
        expect(
          snapshot.catalog.profiles
              .map(
                (profile) => (
                  profile.source.name,
                  profile.source.revision,
                  profile.source.path,
                ),
              )
              .toSet(),
          hasLength(60),
        );
        expect(
          snapshot.catalog.profiles
              .map((profile) => (profile.source.name, profile.source.revision))
              .toSet(),
          hasLength(34),
        );
        expect(
          snapshot.catalog.profiles
              .where(
                (profile) =>
                    profile.status == PowertrainProfileStatus.researchOnly,
              )
              .length,
          205,
        );
        expect(
          snapshot.catalog.profiles
              .where(
                (profile) =>
                    profile.status == PowertrainProfileStatus.community,
              )
              .length,
          12,
        );
        expect(
          snapshot.catalog.profiles
              .where(
                (profile) =>
                    profile.status == PowertrainProfileStatus.experimental,
              )
              .length,
          4,
        );
        for (final profile in snapshot.catalog.profiles) {
          expect(
            profile.source.revision,
            matches(RegExp(r'^[0-9a-f]{40,64}$')),
          );
          expect(profile.source.license, isNotEmpty);
          expect(profile.source.path, isNotEmpty);
          expect(profile.source.locator, isNotEmpty);
          expect(profile.limitations, isNotEmpty);
          if (profile.status == PowertrainProfileStatus.researchOnly ||
              profile.status == PowertrainProfileStatus.experimental) {
            expect(validator.validateProfile(profile).canInstall, isFalse);
          }
        }
        final epaProfiles = snapshot.catalog.profiles.where(
          (profile) =>
              profile.source.name ==
              'U.S. EPA FuelEconomy.gov vehicle snapshot',
        );
        expect(epaProfiles, hasLength(119));
        for (final profile in epaProfiles) {
          expect(profile.status, PowertrainProfileStatus.researchOnly);
          expect(profile.commands, isEmpty);
        }
      },
    );

    test(
      'only the cross-corroborated community entries are installable',
      () async {
        final snapshot = await PowertrainBatteryCatalogAsset.load(rootBundle);
        const validator = PowertrainBatteryProfileCatalogValidator();
        final installable = snapshot.catalog.profiles.where(
          (profile) => validator.validateProfile(profile).canInstall,
        );

        expect(installable.map((profile) => profile.id).toSet(), {
          'mg-zs-ev-au-2021',
          'mg-mg4-2022-2026',
          'mg-mg5-ev-2020-2023',
          'byd-atto3-2022-2024-community',
          'hyundai-ioniq5-egmp-2021-2024-community',
          'kia-ev6-egmp-2022-2024-community',
          'hyundai-kona-electric-os-2019-2023-community',
          'kia-niro-ev-de-2019-2022-community',
          'volkswagen-eup-gen2-2020-2023-community',
          'renault-zoe-ph1-2012-2019-community',
          'hyundai-ioniq6-egmp-2022-2024-community',
          'kia-soul-ev-sk3-2020-community',
        });
        final metadataOnlyMappings = snapshot.catalog.profiles.where(
          (profile) => {
            'chevrolet-bolt-ev-2017',
            'chevrolet-bolt-ev-2019-2020',
            'lexus-rx450h-2020-2022',
            'lexus-rx450hl-2020-2022',
          }.contains(profile.id),
        );
        expect(metadataOnlyMappings, hasLength(4));
        for (final profile in metadataOnlyMappings) {
          expect(profile.status, PowertrainProfileStatus.researchOnly);
          expect(validator.validateProfile(profile).canInstall, isFalse);
          expect(profile.commands, isEmpty, reason: profile.id);
        }

        final executableMappings = snapshot.catalog.profiles.where(
          (profile) => {
            'mg-zs-ev-au-2021',
            'lexus-rx450hl-2020-source-vehicle',
          }.contains(profile.id),
        );
        expect(executableMappings, hasLength(2));
        for (final profile in executableMappings) {
          final validation = validator.validateProfile(profile);
          if (profile.id == 'mg-zs-ev-au-2021') {
            // Community: installable because two independent sources agree
            // on every shipped formula, and still probe-eligible for a
            // consented try-before-install read.
            expect(profile.status, PowertrainProfileStatus.community);
            expect(validation.canInstall, isTrue);
            expect(validation.canProbe, isTrue);
            expect(profile.secondarySources, isNotEmpty);
          } else {
            // The Lexus mapping's byte windows found no independent
            // confirmation, so it stays experimental and probe-only.
            expect(profile.status, PowertrainProfileStatus.experimental);
            expect(validation.canInstall, isFalse);
            expect(validation.canProbe, isTrue);
          }
          expect(profile.source.artifactSha256, hasLength(64));
          expect(profile.identityEvidence, isNotNull);
          expect(profile.commands, isNotEmpty, reason: profile.id);
          for (final command in profile.commands) {
            expect(
              PowertrainBatteryProfileCatalogValidator.readOnlyServices,
              contains(command.mode),
            );
            expect(command.requestHeader, matches(RegExp(r'^[0-9A-F]{3}$')));
            expect(
              command.expectedResponder,
              matches(RegExp(r'^[0-9A-F]{3}$')),
            );
            for (final signal in command.signals) {
              expect(
                signal.offset + signal.width,
                lessThanOrEqualTo(command.payloadLength),
              );
              expect(
                FormulaEngine.validate(
                  signal.equation,
                  sampleBytes: List<int>.filled(signal.width, 1),
                ),
                isNull,
                reason: '${profile.id}:${signal.id}',
              );
            }
          }
        }
      },
    );

    test('formulas use the local sliced signal byte window', () async {
      final snapshot = await PowertrainBatteryCatalogAsset.load(rootBundle);
      final byId = {
        for (final profile in snapshot.catalog.profiles) profile.id: profile,
      };

      final lexus = byId['lexus-rx450hl-2020-source-vehicle']!;
      final lexusSignals = {
        for (final command in lexus.commands)
          for (final signal in command.signals) signal.id: signal,
      };
      expect(lexusSignals['mg1_torque']?.equation, '((A*256+B)-32768)/8');
      expect(lexusSignals['battery_temp_4']?.equation, 'A');

      final mg = byId['mg-zs-ev-au-2021']!;
      final mgSignals = {
        for (final command in mg.commands)
          for (final signal in command.signals) signal.id: signal,
      };
      // The cell-index bytes were excluded by the cross-source review; only
      // the corroborated voltage windows ship.
      expect(mgSignals.containsKey('max_cell_number'), isFalse);
      expect(mgSignals['max_cell_voltage']?.equation, '(A*256+B)/1000');
    });

    test(
      'keeps high-risk or uncertain vehicles explicitly non-installable',
      () async {
        final snapshot = await PowertrainBatteryCatalogAsset.load(rootBundle);
        final byId = {
          for (final profile in snapshot.catalog.profiles) profile.id: profile,
        };

        expect(
          snapshot.catalog.profiles
              .where((profile) => profile.powertrain == 'PHEV')
              .every(
                (profile) =>
                    profile.status == PowertrainProfileStatus.researchOnly,
              ),
          isTrue,
        );

        expect(byId['ford-fusion-energi-2013-2020']?.powertrain, 'PHEV');
        expect(
          byId['ford-fusion-energi-2013-2020']?.limitations.join(' '),
          contains('HV battery'),
        );
        expect(byId['kia-niro-hybrid-2023-2026']?.powertrain, 'HEV');
        expect(
          byId['kia-niro-hybrid-2023-2026']?.limitations.join(' '),
          contains('extended diagnostic session'),
        );
        expect(byId['deepal-s05-reev-2024-2026']?.powertrain, 'REEV');
        expect(byId['toyota-mirai-fcev-2016-2026']?.powertrain, 'FCEV');
        expect(
          byId['mg-zs-ev-au-2021']?.status,
          PowertrainProfileStatus.community,
        );
        expect(
          byId['lexus-rx450hl-2020-2022']?.status,
          PowertrainProfileStatus.researchOnly,
        );
        expect(
          byId['lexus-rx450hl-2020-source-vehicle']?.status,
          PowertrainProfileStatus.experimental,
        );
        expect(
          byId['hyundai-ioniq-phev-2017-2022']?.limitations.join(' '),
          contains('fcm1'),
        );
        expect(
          byId['hyundai-ioniq5-72kwh-2021-wican-research']?.source.license,
          'MIT',
        );
        expect(byId['genesis-g90-mhev-us-2023-2026']?.powertrain, 'MHEV');
        expect(
          byId['bmw-x5-xdrive45e-us-2021-2023']?.status,
          PowertrainProfileStatus.researchOnly,
        );
        expect(
          byId['audi-q5-tfsi-e-quattro-phev-us-2022-2023']?.limitations.join(
            ' ',
          ),
          contains('diagnostic'),
        );
        expect(byId['bmw-i8-us-2014-2017']?.powertrain, 'PHEV');
        expect(
          byId['chevrolet-volt-phev-us-2011-2019']?.status,
          PowertrainProfileStatus.researchOnly,
        );
        expect(byId['honda-accord-hybrid-us-2018-2026']?.powertrain, 'HEV');
        expect(byId['ford-f150-lightning-4wd-us-2022-2024']?.powertrain, 'BEV');
        expect(byId['kia-ev9-long-range-awd-us-2024-2026']?.commands, isEmpty);
        expect(
          byId['mg-mg4-2022-2026']?.status,
          PowertrainProfileStatus.community,
        );
        expect(
          byId['mg-mg5-ev-2020-2023']?.status,
          PowertrainProfileStatus.community,
        );
        expect(
          byId['byd-atto3-2022-2024-community']?.status,
          PowertrainProfileStatus.community,
        );
        expect(
          byId['toyota-etnga-bev-2022-2024']?.status,
          PowertrainProfileStatus.experimental,
        );
        expect(byId['fiat-500e-332-2020-2026']?.commands, isEmpty);
        expect(
          byId['mini-cooper-se-2020-2024']?.limitations.join(' '),
          contains('extended addressing'),
        );
        expect(
          byId['nissan-ariya-fwd-63kwh-us-2025-2026']?.limitations.join(' '),
          contains('29-bit'),
        );
        expect(
          byId['toyota-bz4x-us-2023-2025']?.limitations.join(' '),
          contains('toyota-etnga-bev-2022-2024'),
        );
        expect(
          byId['rivian-r1t-at-dual-large-20-us-2024-2026']?.source.license,
          'U.S.-Government-Public-Domain',
        );
        expect(
          byId['epa-50703-bmw-550e-xdrive-sedan-us-2027']?.powertrain,
          'PHEV',
        );
        expect(
          byId['epa-50447-ford-f150-pickup-2wd-hev-us-2026']?.powertrain,
          'HEV',
        );
        expect(
          byId['epa-50595-land-rover-range-rover-sv-mhev-us-2027']?.powertrain,
          'MHEV',
        );
        expect(
          byId['epa-50617-cadillac-lyriq-awd-v-series-19kw-charger-us-2027']
              ?.powertrain,
          'BEV',
        );
        expect(byId['epa-50392-honda-cr-v-e-fcev-us-2026']?.powertrain, 'FCEV');
      },
    );
  });
}
