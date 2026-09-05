/// Drives [AvailabilityPolicy] — the shipped USABILITY-R2 decision surface.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/diagnostics/availability.dart';
import 'package:torque_obd/obd/physics/vehicle_profile.dart';
import 'package:torque_obd/obd/pid/pid.dart';
import 'package:torque_obd/obd/pid/pid_csv.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/obd/powertrain_battery/powertrain_battery_profile.dart';
import 'package:torque_obd/obd/telemetry.dart';
import 'package:torque_obd/state/vehicle_identity.dart';

void main() {
  group('該能用的沒有被錯誤阻擋', () {
    test('no VIN, no catalog, unknown year still enters generic OBD', () {
      final status = AvailabilityPolicy.genericObdSession(
        identity: const VehicleIdentity.unavailable(),
      );
      expect(status.availability, FeatureAvailability.usableWithNotice);
      expect(status.isNumericSuccess, isTrue);
      expect(status.evidence, isNot(EvidenceKind.fieldVerified));
      expect(status.nextStep, contains('通用 OBD'));
      expect(status.reason, contains('VIN'));
      expect(status.reason, isNot(contains('型錄無匹配')));
      expect(status.reason, isNot(contains('年式未知')));
      final miss = AvailabilityPolicy.genericObdSession(
        identity: const VehicleIdentity.unavailable(),
        catalogMatched: false,
      );
      expect(miss.reason, contains('型錄無匹配'));
    });

    test('community and experimental bounded-read profiles may install', () {
      expect(
        AvailabilityPolicy.canInstallBoundedReadProfile(
          status: PowertrainProfileStatus.community,
          modeAndIdentifiers: const ['22B046'],
          validatorIssuesEmpty: true,
        ),
        isTrue,
      );
      expect(
        AvailabilityPolicy.canInstallBoundedReadProfile(
          status: PowertrainProfileStatus.experimental,
          modeAndIdentifiers: const ['221F5B'],
          validatorIssuesEmpty: true,
        ),
        isTrue,
      );
      expect(
        AvailabilityPolicy.canInstallBoundedReadProfile(
          status: PowertrainProfileStatus.community,
          modeAndIdentifiers: const ['2161'],
          validatorIssuesEmpty: true,
        ),
        isFalse,
      );
    });

    test('user CSV import is usable and labelled 使用者提供', () {
      const columns =
          'Name,ShortName,ModeAndPID,Equation,Min Value,Max Value,'
          'Units,Header\r\n';
      final result = PidCsv.parse(
        '${columns}User coolant,ECT,0105,A-40,-40,215,C,7E0\r\n',
      );
      expect(result.errors, isEmpty);
      final pid = result.pids.single;
      expect(pid.isCustom, isTrue);
      final status = AvailabilityPolicy.forPid(
        pid: pid,
        reading: Reading(
          pid: pid,
          value: 90,
          rawBytes: const [0x41, 0x05, 0x82],
          timestamp: DateTime.now(),
        ),
      );
      expect(status.isNumericSuccess, isTrue);
      expect(status.origin, DatumOrigin.userEntered);
      expect(status.evidence, EvidenceKind.userSupplied);
      expect(status.badgeLabels, contains('使用者提供'));
    });

    test('one PID fault does not veto sibling readings', () {
      const rpm = PidLibrary.engineRpm;
      const speed = PidLibrary.vehicleSpeed;
      final snapshot = TelemetrySnapshot(
        readings: {
          rpm.id: Reading(
            pid: rpm,
            value: 2000,
            rawBytes: const [],
            timestamp: DateTime.now(),
          ),
        },
        faults: {speed.id: PidFault.noAnswer},
        capturedAt: DateTime.now(),
      );
      final rpmStatus = AvailabilityPolicy.forPid(
        pid: rpm,
        reading: snapshot[rpm.id],
      );
      final speedStatus = AvailabilityPolicy.forPid(
        pid: speed,
        fault: snapshot.faults[speed.id],
      );
      expect(rpmStatus.isNumericSuccess, isTrue);
      expect(snapshot.valueOf(rpm), 2000);
      expect(speedStatus.quality, DatumQuality.partial);
      expect(speedStatus.nextStep, contains('只影響此項'));
    });

    test('estimates are shown as 估算, never 實測', () {
      const profile = VehicleProfile(massKg: 1280, isConfirmed: false);
      final status = AvailabilityPolicy.forEstimate(
        profile: profile,
        value: 145,
        formula: AvailabilityPolicy.horsepowerFormula,
        quantity: '馬力',
      );
      expect(status.isNumericSuccess, isTrue);
      expect(status.origin, DatumOrigin.calculated);
      expect(status.badgeLabels, contains('估算'));
      expect(status.badgeLabels, isNot(contains('已驗證')));
      expect(status.formula, AvailabilityPolicy.horsepowerFormula);
      expect(status.assumptions, anyOf(contains('手動輸入'), contains('通用預設')));
      expect(status.assumptions, contains('1280'));
      expect(status.assumptions, contains('迎風面積'));
      expect(status.assumptions, contains('傳動效率'));
      expect(status.assumptions, isNot(contains('VE ')));
      final fuel = AvailabilityPolicy.forEstimate(
        profile: const VehicleProfile(massKg: 1280, isConfirmed: false),
        value: 4.2,
        formula: AvailabilityPolicy.fuelEstimateFormula,
        quantity: '油耗',
        kind: EstimateKind.fuel,
      );
      expect(fuel.assumptions, contains('AFR'));
      expect(fuel.assumptions, contains('密度'));
      expect(fuel.assumptions, contains('排氣量'));
      expect(fuel.assumptions, contains('VE'));
      expect(fuel.formula, contains('speed-density'));
      expect(fuel.assumptions, isNot(contains('車重')));
      expect(fuel.quality, DatumQuality.valid);
      final fuelOutlier = AvailabilityPolicy.forEstimate(
        profile: profile,
        value: 150,
        formula: AvailabilityPolicy.fuelEstimateFormula,
        quantity: '油耗',
        kind: EstimateKind.fuel,
      );
      expect(fuelOutlier.quality, DatumQuality.outOfReferenceRange);
      expect(fuelOutlier.badgeLabels, contains('異常'));
      final hpInRange = AvailabilityPolicy.forEstimate(
        profile: profile,
        value: 1500,
        formula: AvailabilityPolicy.horsepowerFormula,
        quantity: '馬力',
      );
      expect(hpInRange.quality, DatumQuality.valid);
      final hpOutlier = AvailabilityPolicy.forEstimate(
        profile: profile,
        value: 2500,
        formula: AvailabilityPolicy.horsepowerFormula,
        quantity: '馬力',
      );
      expect(hpOutlier.quality, DatumQuality.outOfReferenceRange);
    });

    test('finite out-of-range coolant is kept as 異常', () {
      const pid = PidLibrary.coolantTemp;
      final status = AvailabilityPolicy.decodedValue(
        structurallyValid: true,
        value: 999,
        min: pid.minValue,
        max: pid.maxValue,
      );
      expect(status.isNumericSuccess, isTrue);
      expect(status.quality, DatumQuality.outOfReferenceRange);
      expect(status.badgeLabels, contains('異常'));
    });

    test('stale badges are not doubled', () {
      const pid = PidLibrary.engineRpm;
      final status = AvailabilityPolicy.forPid(
        pid: pid,
        reading: Reading(
          pid: pid,
          value: 2000,
          rawBytes: const [],
          timestamp: DateTime.now().subtract(const Duration(minutes: 5)),
        ),
        isStale: true,
      );
      expect(status.badgeLabels.where((label) => label == '過期').length, 1);
    });

    test('installed community PID is labelled 社群解碼', () {
      const pid = Pid(
        name: 'SOC',
        shortName: 'SOC',
        modeAndPid: '22B046',
        equation: 'A',
        minValue: 0,
        maxValue: 100,
        units: '%',
        evidenceKind: 'community',
      );
      final status = AvailabilityPolicy.forPid(
        pid: pid,
        reading: Reading(
          pid: pid,
          value: 67,
          rawBytes: const [],
          timestamp: DateTime.now(),
        ),
      );
      expect(status.evidence, EvidenceKind.community);
      expect(status.badgeLabels, contains('社群解碼'));
    });

    test('a missing reading is waiting, not 無效', () {
      const pid = PidLibrary.engineRpm;
      final status = AvailabilityPolicy.forPid(pid: pid);
      expect(status.isNumericSuccess, isFalse);
      expect(status.quality, DatumQuality.partial);
      expect(status.reason, '尚無讀值');
      expect(status.badgeLabels, isNot(contains('無效')));
    });

    test('research-only metadata has no fake numeric reading', () {
      expect(
        AvailabilityPolicy.canInstallBoundedReadProfile(
          status: PowertrainProfileStatus.researchOnly,
          modeAndIdentifiers: const [],
          validatorIssuesEmpty: true,
        ),
        isFalse,
      );
    });
  });

  group('該阻擋的有阻擋', () {
    test('NaN, Infinity, and a structurally bad packet are not numbers', () {
      for (final value in [
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        final status = AvailabilityPolicy.decodedValue(
          structurallyValid: true,
          value: value,
          min: 0,
          max: 100,
        );
        expect(status.isNumericSuccess, isFalse, reason: '$value');
        expect(status.quality, DatumQuality.invalid);
        expect(status.availability, FeatureAvailability.rawOnly);
      }
      final bad = AvailabilityPolicy.decodedValue(
        structurallyValid: false,
        value: 67,
        min: 0,
        max: 100,
      );
      expect(bad.isNumericSuccess, isFalse);
      expect(bad.reason, contains('壞封包'));
    });

    test('Mode 21 experimental is not a gauge poll and does not install', () {
      expect(PollableServices.isPollable('2161'), isFalse);
      expect(
        AvailabilityPolicy.canInstallBoundedReadProfile(
          status: PowertrainProfileStatus.experimental,
          modeAndIdentifiers: const ['2161'],
          validatorIssuesEmpty: true,
        ),
        isFalse,
      );
      expect(AvailabilityPolicy.allowSend(modeAndPid: '2161'), isFalse);
      expect(
        AvailabilityPolicy.allowSend(
          modeAndPid: '2161',
          gate: const OperationGate(oneShotConsent: true),
        ),
        isTrue,
      );
    });

    test('clear, actuate, and program send nothing without their gates', () {
      expect(AvailabilityPolicy.allowSend(modeAndPid: '04'), isFalse);
      expect(AvailabilityPolicy.allowSend(modeAndPid: '2F011203'), isFalse);
      expect(AvailabilityPolicy.allowSend(modeAndPid: '2E1234'), isFalse);
      expect(AvailabilityPolicy.allowSend(modeAndPid: '310112'), isFalse);
      expect(AvailabilityPolicy.allowSend(modeAndPid: '1101'), isFalse);
      expect(
        AvailabilityPolicy.allowSend(
          modeAndPid: '04',
          gate: const OperationGate(
            clearSnapshotReady: true,
            clearConfirmed: true,
          ),
        ),
        isTrue,
      );
      expect(
        AvailabilityPolicy.riskFor('04'),
        isNot(AvailabilityPolicy.riskFor('010C')),
      );
    });

    test('evidence never upgrades a write to allowed', () {
      expect(AvailabilityPolicy.allowSend(modeAndPid: '2F011203'), isFalse);
      expect(PollableServices.isPollable('2F011203'), isFalse);
    });

    test('validator issues still block install', () {
      expect(
        AvailabilityPolicy.canInstallBoundedReadProfile(
          status: PowertrainProfileStatus.community,
          modeAndIdentifiers: const ['22B046'],
          validatorIssuesEmpty: false,
        ),
        isFalse,
      );
    });
  });
}
