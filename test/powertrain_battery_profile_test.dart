import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/obd/powertrain_battery/powertrain_battery_profile.dart';
import 'package:torque_obd/obd/powertrain_battery/profile_catalog_validator.dart';

Map<String, Object?> _source({
  String revision = '2f485fcbffa2259d9e1db92d14483c1bef55dcca',
}) => {
  'name': 'MG-EV-OBD-PID',
  'url':
      'https://github.com/peternixon/MG-EV-OBD-PID/tree/'
      '2f485fcbffa2259d9e1db92d14483c1bef55dcca',
  'revision': revision,
  'license': 'Apache-2.0',
  'path': 'MG ZS EV/MG ZS EV.csv',
  'locator': 'row: BMS DC Bus Voltage',
};

Map<String, Object?> _command({
  String requestHeader = '781',
  String expectedResponder = '789',
  String mode = '22',
  String identifier = 'B041',
  int payloadLength = 2,
  int signalOffset = 0,
  int signalWidth = 2,
}) => {
  'request_header': requestHeader,
  'expected_responder': expectedResponder,
  'mode': mode,
  'identifier': identifier,
  'payload_length': payloadLength,
  'signals': [
    {
      'id': 'dc_bus_voltage',
      'name': 'DC bus voltage',
      'offset': signalOffset,
      'width': signalWidth,
      'equation': '(A*256+B)*0.25',
      'unit': 'V',
      'min_value': 0.0,
      'max_value': 500.0,
      'semantic_kind': 'packVoltage',
      'recommended': true,
    },
  ],
};

Map<String, Object?> _profile({
  String status = 'ready',
  List<Map<String, Object?>>? commands,
  Map<String, Object?>? source,
}) => {
  'id': 'mg-zs-ev-au-2021',
  'display_name': 'MG ZS EV 2021 battery',
  'description': 'Read-only traction-battery telemetry.',
  'limitations': ['Australian 2021 vehicle source evidence only.'],
  'status': status,
  'evidence': 'sourceBacked',
  'market': 'Australia',
  'make': 'MG',
  'model': 'ZS EV',
  'year_from': 2021,
  'year_to': 2022,
  'variant': 'Excite',
  'powertrain': 'BEV',
  'identity_evidence': {
    'market': 'exact',
    'year': 'exact',
    'model': 'exact',
    'variant': 'exact',
  },
  'source': source ?? _source(),
  'commands': commands ?? [_command()],
};

void main() {
  group('powertrain battery profile parser', () {
    test('parses exact vehicle, source, request, and signal metadata', () {
      final catalog = PowertrainBatteryCatalog.fromJsonString(
        jsonEncode({
          'schema_version': 2,
          'profiles': [
            _profile(),
            _profile(status: 'community')..['id'] = 'mg-zs-ev-community',
            _profile(status: 'experimental')..['id'] = 'mg-zs-ev-experimental',
            _profile(status: 'researchOnly')
              ..['id'] = 'ioniq-phev-research'
              ..['commands'] = <Object?>[],
          ],
        }),
      );

      expect(catalog.schemaVersion, 2);
      expect(catalog.profiles, hasLength(4));
      expect(
        catalog.profiles.map((profile) => profile.status),
        PowertrainProfileStatus.values,
      );

      final profile = catalog.profiles.first;
      expect(profile.market, 'Australia');
      expect(profile.make, 'MG');
      expect(profile.model, 'ZS EV');
      expect(profile.yearFrom, 2021);
      expect(profile.yearTo, 2022);
      expect(profile.appliesToYear(2020), isFalse);
      expect(profile.appliesToYear(2021), isTrue);
      expect(profile.appliesToYear(2022), isTrue);
      expect(profile.appliesToYear(2023), isFalse);
      expect(profile.variant, 'Excite');
      expect(profile.powertrain, 'BEV');
      expect(profile.displayName, 'MG ZS EV 2021 battery');
      expect(profile.description, isNotEmpty);
      expect(profile.limitations, hasLength(1));
      expect(profile.evidence, PowertrainProfileEvidence.sourceBacked);
      expect(profile.source.revision, hasLength(40));
      expect(profile.source.license, 'Apache-2.0');
      expect(profile.source.path, 'MG ZS EV/MG ZS EV.csv');
      expect(profile.source.locator, 'row: BMS DC Bus Voltage');

      final command = profile.commands.single;
      expect(command.requestHeader, '781');
      expect(command.expectedResponder, '789');
      expect(command.mode, '22');
      expect(command.identifier, 'B041');
      expect(command.payloadLength, 2);

      final signal = command.signals.single;
      expect(signal.offset, 0);
      expect(signal.width, 2);
      expect(signal.equation, '(A*256+B)*0.25');
      expect(signal.minValue, 0);
      expect(signal.maxValue, 500);
      expect(signal.semanticKind, 'packVoltage');
      expect(signal.recommended, isTrue);
    });

    test('rejects unknown schema versions and malformed enum values', () {
      expect(
        () => PowertrainBatteryCatalog.fromJsonString(
          jsonEncode({'schema_version': 1, 'profiles': <Object?>[]}),
        ),
        throwsA(isA<PowertrainBatteryProfileFormatException>()),
      );
      expect(
        () => PowertrainBatteryProfile.fromJson(_profile(status: 'verified')),
        throwsA(isA<PowertrainBatteryProfileFormatException>()),
      );
    });
  });

  group('powertrain battery catalog validator', () {
    const validator = PowertrainBatteryProfileCatalogValidator();

    test('ready and community status never grants installation', () {
      for (final status in ['ready', 'community']) {
        final result = validator.validateProfile(
          PowertrainBatteryProfile.fromJson(_profile(status: status)),
        );
        expect(result.issues, isEmpty, reason: status);
        expect(result.canInstall, isFalse, reason: status);
      }

      final research = validator.validateProfile(
        PowertrainBatteryProfile.fromJson(
          _profile(status: 'researchOnly')..['commands'] = <Object?>[],
        ),
      );
      expect(research.issues, isEmpty);
      expect(research.canInstall, isFalse);
      expect(research.canProbe, isFalse);

      final experimentalJson = _profile(status: 'experimental')
        ..['source'] = {..._source(), 'artifact_sha256': 'b' * 64}
        ..['identity_evidence'] = {
          'market': 'sourcePartial',
          'year': 'exact',
          'model': 'exact',
          'variant': 'unknown',
        };
      final experimental = validator.validateProfile(
        PowertrainBatteryProfile.fromJson(experimentalJson),
      );
      expect(experimental.issues, isEmpty);
      expect(experimental.canInstall, isFalse);
      expect(experimental.canProbe, isTrue);
    });

    test('validates inclusive model-year ranges', () {
      for (final years in [
        (from: 1885, to: 2020),
        (from: 2022, to: 2021),
        (from: 2020, to: 2101),
      ]) {
        final json = _profile()
          ..['year_from'] = years.from
          ..['year_to'] = years.to;
        final result = validator.validateProfile(
          PowertrainBatteryProfile.fromJson(json),
        );
        expect(result.canInstall, isFalse);
        expect(
          result.issues.map((issue) => issue.code),
          contains('invalid_vehicle_year_range'),
        );
      }

      final exactYear = _profile()
        ..['year_from'] = 2021
        ..['year_to'] = 2021;
      expect(
        validator
            .validateProfile(PowertrainBatteryProfile.fromJson(exactYear))
            .issues,
        isEmpty,
      );

      final ranged = PowertrainBatteryProfile.fromJson(_profile());
      expect(
        validator
            .validateProfile(ranged, vehicleYear: 2020)
            .issues
            .map((issue) => issue.code),
        contains('vehicle_year_out_of_range'),
      );
      expect(
        validator.validateProfile(ranged, vehicleYear: 2021).issues,
        isEmpty,
      );
      expect(
        validator.validateProfile(ranged, vehicleYear: 2022).issues,
        isEmpty,
      );
      expect(
        validator
            .validateProfile(ranged, vehicleYear: 2023)
            .issues
            .map((issue) => issue.code),
        contains('vehicle_year_out_of_range'),
      );
    });

    test('research-only profiles are never installable', () {
      final profile = PowertrainBatteryProfile.fromJson(
        _profile(status: 'researchOnly')..['commands'] = <Object?>[],
      );

      final result = validator.validateProfile(profile);

      expect(result.issues, isEmpty);
      expect(result.canInstall, isFalse);
    });

    test('allows only source-attributed read-only diagnostic services', () {
      for (final allowed in ['21', '22']) {
        final identifier = allowed == '22' ? 'B041' : '5B';
        final profile = PowertrainBatteryProfile.fromJson(
          _profile(
            commands: [_command(mode: allowed, identifier: identifier)],
          ),
        );
        final result = validator.validateProfile(profile);
        expect(result.issues, isEmpty, reason: allowed);
        expect(result.canInstall, isFalse, reason: allowed);
      }

      for (final denied in [
        '01',
        '02',
        '09',
        '10',
        '11',
        '14',
        '27',
        '28',
        '2E',
        '2F',
        '31',
      ]) {
        final profile = PowertrainBatteryProfile.fromJson(
          _profile(commands: [_command(mode: denied)]),
        );
        final result = validator.validateProfile(profile);
        expect(result.canInstall, isFalse, reason: denied);
        expect(
          result.issues.map((issue) => issue.code),
          contains('unsafe_service'),
          reason: denied,
        );
      }
    });

    test('requires exact identity evidence for ready/community metadata', () {
      final missing = _profile()..remove('identity_evidence');
      final missingResult = validator.validateProfile(
        PowertrainBatteryProfile.fromJson(missing),
      );
      expect(missingResult.canInstall, isFalse);
      expect(
        missingResult.issues.map((issue) => issue.code),
        contains('missing_identity_evidence'),
      );

      for (final field in ['market', 'year', 'model', 'variant']) {
        final json = _profile();
        final evidence = json['identity_evidence']! as Map<String, Object?>;
        evidence[field] = 'sourcePartial';
        final result = validator.validateProfile(
          PowertrainBatteryProfile.fromJson(json),
        );

        expect(result.canInstall, isFalse, reason: field);
        expect(
          result.issues,
          contains(
            isA<PowertrainBatteryProfileIssue>()
                .having(
                  (issue) => issue.code,
                  'code',
                  'insufficient_identity_evidence',
                )
                .having(
                  (issue) => issue.path,
                  'path',
                  'identity_evidence.$field',
                ),
          ),
          reason: field,
        );
      }
    });

    test('rejects placeholder identity prose despite structured evidence', () {
      for (final identity in [
        ('market', 'source-unspecified'),
        ('market', 'unknown'),
        ('variant', 'unspecified'),
        ('variant', 'all variants'),
        ('variant', 'TBD trim'),
        ('variant', 'not specified by source'),
        ('make', 'not reported'),
        ('powertrain', 'Powertrain TBD'),
      ]) {
        final json = _profile()..[identity.$1] = identity.$2;
        final result = validator.validateProfile(
          PowertrainBatteryProfile.fromJson(json),
        );

        expect(result.canInstall, isFalse, reason: identity.toString());
        expect(
          result.issues.map((issue) => issue.code),
          contains('inexact_vehicle_identity'),
          reason: identity.toString(),
        );
      }

      final researchOnly = PowertrainBatteryProfile.fromJson(
        _profile(status: 'researchOnly')
          ..['market'] = 'source-unspecified'
          ..['variant'] = 'source-unspecified'
          ..['commands'] = <Object?>[],
      );
      expect(validator.validateProfile(researchOnly).issues, isEmpty);
      expect(validator.validateProfile(researchOnly).canInstall, isFalse);
    });

    test('requires exact request and responder CAN identifiers', () {
      for (final command in [
        _command(requestHeader: ''),
        _command(expectedResponder: ''),
        _command(requestHeader: '7E'),
        _command(expectedResponder: '7E80'),
        _command(requestHeader: '18DA10F1', expectedResponder: '18DAF1100'),
      ]) {
        final result = validator.validateProfile(
          PowertrainBatteryProfile.fromJson(_profile(commands: [command])),
        );
        expect(result.canInstall, isFalse);
        expect(
          result.issues.map((issue) => issue.code),
          contains('invalid_can_id'),
        );
      }

      final extended = validator.validateProfile(
        PowertrainBatteryProfile.fromJson(
          _profile(
            commands: [
              _command(
                requestHeader: '18DA10F1',
                expectedResponder: '18DAF110',
              ),
            ],
          ),
        ),
      );
      expect(extended.issues, isEmpty);
      expect(extended.canInstall, isFalse);
    });

    test('rejects signal slices outside the declared payload', () {
      final result = validator.validateProfile(
        PowertrainBatteryProfile.fromJson(
          _profile(
            commands: [
              _command(payloadLength: 2, signalOffset: 1, signalWidth: 2),
            ],
          ),
        ),
      );

      expect(result.canInstall, isFalse);
      expect(
        result.issues.map((issue) => issue.code),
        contains('signal_out_of_bounds'),
      );
    });

    test('requires finite, increasing signal presentation bounds', () {
      for (final bounds in [
        (min: 100.0, max: 100.0),
        (min: 101.0, max: 100.0),
        (min: double.nan, max: 100.0),
        (min: 0.0, max: double.infinity),
      ]) {
        final command = _command();
        final signal =
            (command['signals']! as List<Object?>).single
                as Map<String, Object?>;
        signal['min_value'] = bounds.min;
        signal['max_value'] = bounds.max;
        final result = validator.validateProfile(
          PowertrainBatteryProfile.fromJson(_profile(commands: [command])),
        );
        expect(result.canInstall, isFalse);
        expect(
          result.issues.map((issue) => issue.code),
          contains('invalid_signal_range'),
        );
      }
    });

    test('rejects invalid formulas and byte references outside the signal', () {
      for (final formula in ['A+', 'C']) {
        final command = _command(signalWidth: 2);
        final signal =
            (command['signals']! as List<Object?>).single
                as Map<String, Object?>;
        signal['equation'] = formula;
        final result = validator.validateProfile(
          PowertrainBatteryProfile.fromJson(_profile(commands: [command])),
        );

        expect(result.canInstall, isFalse, reason: formula);
        expect(
          result.issues.map((issue) => issue.code),
          contains('invalid_equation'),
          reason: formula,
        );
      }

      final oversized = validator.validateProfile(
        PowertrainBatteryProfile.fromJson(
          _profile(commands: [_command(payloadLength: 15, signalWidth: 15)]),
        ),
      );
      expect(oversized.canInstall, isFalse);
      expect(
        oversized.issues.map((issue) => issue.code),
        contains('signal_too_wide'),
      );
    });

    test('requires immutable source revision and an explicit license', () {
      for (final source in [
        _source(revision: 'main'),
        _source(revision: 'latest'),
        _source(revision: ''),
        {..._source(), 'license': ''},
      ]) {
        final result = validator.validateProfile(
          PowertrainBatteryProfile.fromJson(_profile(source: source)),
        );
        expect(result.canInstall, isFalse);
        expect(
          result.issues.map((issue) => issue.code),
          anyOf(contains('mutable_source'), contains('missing_license')),
        );
      }
    });

    test('catalog validation rejects duplicate profile and signal ids', () {
      final duplicateProfile = PowertrainBatteryCatalog.fromJson({
        'schema_version': 2,
        'profiles': [_profile(), _profile()],
      });
      expect(
        validator
            .validateCatalog(duplicateProfile)
            .issues
            .map((issue) => issue.code),
        contains('duplicate_profile_id'),
      );

      final duplicateSignalCommand = _command();
      duplicateSignalCommand['signals'] = [
        ...(duplicateSignalCommand['signals']! as List<Object?>),
        ...(duplicateSignalCommand['signals']! as List<Object?>),
      ];
      final result = validator.validateProfile(
        PowertrainBatteryProfile.fromJson(
          _profile(commands: [duplicateSignalCommand]),
        ),
      );
      expect(result.canInstall, isFalse);
      expect(
        result.issues.map((issue) => issue.code),
        contains('duplicate_signal_id'),
      );
    });
  });
}
