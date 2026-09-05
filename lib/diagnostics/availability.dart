/// USABILITY-R2: availability, evidence, and operation risk are separate.
///
/// Evidence (未驗證 / 已驗證) is a label. It is not a ban on generic OBD,
/// community/experimental bounded reads, user imports, or disclosed estimates.
library;

import '../obd/physics/vehicle_evidence.dart';
import '../obd/physics/vehicle_profile.dart';
import '../obd/pid/pid.dart';
import '../obd/powertrain_battery/powertrain_battery_profile.dart';
import '../obd/telemetry.dart';
import '../state/vehicle_identity.dart';
import '../telemetry/session/telemetry_session.dart';

enum FeatureAvailability { usable, usableWithNotice, rawOnly, unavailable }

enum DatumOrigin { ecuReported, calculated, userEntered, demo }

enum EvidenceKind {
  fieldVerified,
  community,
  experimental,
  userSupplied,
  notTested,
  unknown,
}

enum Compatibility { exact, candidate, userSelected, unknown, knownMismatch }

enum DatumQuality {
  valid,
  tentativeDecode,
  outOfReferenceRange,
  stale,
  invalid,
  partial,
}

enum OperationRisk { display, boundedRead, clear, stateChange, program }

enum EstimateKind { horsepower, fuel }

/// One status object for live UI, recorder, replay, and export.
class DatumStatus {
  const DatumStatus({
    required this.availability,
    required this.origin,
    required this.evidence,
    required this.compatibility,
    required this.quality,
    required this.operationRisk,
    this.reason,
    this.nextStep,
    this.formula,
    this.assumptions,
    this.freshnessLabel,
  });

  final FeatureAvailability availability;
  final DatumOrigin origin;
  final EvidenceKind evidence;
  final Compatibility compatibility;
  final DatumQuality quality;
  final OperationRisk operationRisk;
  final String? reason;
  final String? nextStep;
  final String? formula;
  final String? assumptions;
  final String? freshnessLabel;

  /// Whether this status may be shown as a normal numeric success.
  bool get isNumericSuccess =>
      (availability == FeatureAvailability.usable ||
          availability == FeatureAvailability.usableWithNotice) &&
      quality != DatumQuality.invalid &&
      operationRisk != OperationRisk.stateChange &&
      operationRisk != OperationRisk.program;

  bool get isEstimate => origin == DatumOrigin.calculated;

  bool get isFieldVerified => evidence == EvidenceKind.fieldVerified;

  List<String> get badgeLabels {
    final labels = <String>[];
    switch (origin) {
      case DatumOrigin.calculated:
        labels.add('估算');
      case DatumOrigin.userEntered:
        labels.add('使用者提供');
      case DatumOrigin.demo:
        labels.add('示範');
      case DatumOrigin.ecuReported:
        break;
    }
    switch (evidence) {
      case EvidenceKind.fieldVerified:
        labels.add('已驗證');
      case EvidenceKind.community:
        labels.add('社群解碼');
        labels.add('本車未驗證');
      case EvidenceKind.experimental:
        labels.add('實驗');
        labels.add('本車未驗證');
      case EvidenceKind.userSupplied:
        if (!labels.contains('使用者提供')) labels.add('使用者提供');
      case EvidenceKind.notTested:
      case EvidenceKind.unknown:
        if (origin != DatumOrigin.demo) labels.add('未驗證');
    }
    switch (quality) {
      case DatumQuality.outOfReferenceRange:
        labels.add('異常');
      case DatumQuality.stale:
        labels.add('過期');
      case DatumQuality.partial:
        labels.add('部分');
      case DatumQuality.tentativeDecode:
        labels.add('暫定解碼');
      case DatumQuality.invalid:
        labels.add('無效');
      case DatumQuality.valid:
        break;
    }
    if (freshnessLabel != null &&
        freshnessLabel!.isNotEmpty &&
        !labels.contains(freshnessLabel)) {
      labels.add(freshnessLabel!);
    }
    return labels;
  }

  String get badgeText => badgeLabels.join(' · ');

  Map<String, String> get exportFields => {
    'availability': availability.name,
    'origin': origin.name,
    'evidence': evidence.name,
    'compatibility': compatibility.name,
    'quality': quality.name,
    'operation_risk': operationRisk.name,
    if (reason != null && reason!.isNotEmpty) 'reason': reason!,
    if (formula != null && formula!.isNotEmpty) 'formula': formula!,
    if (assumptions != null && assumptions!.isNotEmpty)
      'assumptions': assumptions!,
  };
}

/// Preconditions that are *not* evidence. Unverified data cannot skip these.
class OperationGate {
  const OperationGate({
    this.clearSnapshotReady = false,
    this.clearConfirmed = false,
    this.oneShotConsent = false,
    this.programRecipeAuthorized = false,
  });

  final bool clearSnapshotReady;
  final bool clearConfirmed;
  final bool oneShotConsent;
  final bool programRecipeAuthorized;
}

/// Shared USABILITY-R2 decisions. UI, recorder, and exporters must call this
/// rather than inventing a second `supported` bool.
abstract final class AvailabilityPolicy {
  static const horsepowerFormula =
      'wheelWatts = (m·a + ½ρ·Cd·A·v² + Crr·m·g)·v; '
      'engineHp = wheelHp / drivetrainEfficiency';

  static const fuelEstimateFormula =
      'L/h = (MAF g/s) / (AFR × fuel density g/L) × 3600; '
      'L/100km = (L/h) / speed_kmh × 100';

  /// Generic OBD is available without a catalog match, VIN, or year.
  static DatumStatus genericObdSession({
    required VehicleIdentity identity,
    bool? catalogMatched,
    int? modelYear,
    bool fieldVerified = false,
  }) {
    final missingVin = identity.vin == null;
    final gaps = <String>[
      if (missingVin) 'VIN 未讀到',
      if (modelYear == null && catalogMatched != null) '年式未知',
      if (catalogMatched == false) '型錄無匹配',
    ];
    return DatumStatus(
      availability: FeatureAvailability.usableWithNotice,
      origin: DatumOrigin.ecuReported,
      evidence: fieldVerified
          ? EvidenceKind.fieldVerified
          : EvidenceKind.notTested,
      compatibility: catalogMatched == true
          ? Compatibility.exact
          : Compatibility.unknown,
      quality: DatumQuality.valid,
      operationRisk: OperationRisk.boundedRead,
      reason: gaps.isEmpty ? null : gaps.join(' · '),
      nextStep: '可繼續通用 OBD，或手動選車、補參數',
    );
  }

  /// A structurally valid finite value, including out-of-range outliers.
  static DatumStatus decodedValue({
    required bool structurallyValid,
    required double? value,
    double? min,
    double? max,
    DatumOrigin origin = DatumOrigin.ecuReported,
    EvidenceKind evidence = EvidenceKind.notTested,
    Compatibility compatibility = Compatibility.unknown,
    OperationRisk operationRisk = OperationRisk.boundedRead,
    bool isStale = false,
    String? freshnessLabel,
  }) {
    if (!structurallyValid) {
      return DatumStatus(
        availability: FeatureAvailability.rawOnly,
        origin: origin,
        evidence: evidence,
        compatibility: compatibility,
        quality: DatumQuality.invalid,
        operationRisk: operationRisk,
        reason: '壞封包，只可查看原文',
        nextStep: '可看 raw / error，不可當成正常數值',
      );
    }
    if (value == null || !value.isFinite) {
      return DatumStatus(
        availability: FeatureAvailability.rawOnly,
        origin: origin,
        evidence: evidence,
        compatibility: compatibility,
        quality: DatumQuality.invalid,
        operationRisk: operationRisk,
        reason: '非有限數值',
        nextStep: '可看 raw / error，不可當成正常數值',
      );
    }
    final outOfRange =
        min != null && max != null && (value < min || value > max);
    return DatumStatus(
      availability: FeatureAvailability.usableWithNotice,
      origin: origin,
      evidence: evidence,
      compatibility: compatibility,
      quality: isStale
          ? DatumQuality.stale
          : outOfRange
          ? DatumQuality.outOfReferenceRange
          : DatumQuality.valid,
      operationRisk: operationRisk,
      reason: outOfRange ? '超出一般參考範圍，已保留' : null,
      freshnessLabel: freshnessLabel,
    );
  }

  static DatumStatus forPid({
    required Pid pid,
    Reading? reading,
    PidFault? fault,
    bool isStale = false,
    bool fieldVerified = false,
    PowertrainProfileStatus? catalogStatus,
    bool demo = false,
  }) {
    final origin = demo
        ? DatumOrigin.demo
        : pid.isCustom
        ? DatumOrigin.userEntered
        : DatumOrigin.ecuReported;
    final resolvedCatalog = catalogStatus ?? _statusFromKind(pid.evidenceKind);
    final evidence = fieldVerified
        ? EvidenceKind.fieldVerified
        : pid.isCustom
        ? EvidenceKind.userSupplied
        : switch (resolvedCatalog) {
            PowertrainProfileStatus.community => EvidenceKind.community,
            PowertrainProfileStatus.experimental => EvidenceKind.experimental,
            PowertrainProfileStatus.ready => EvidenceKind.notTested,
            PowertrainProfileStatus.researchOnly => EvidenceKind.notTested,
            null => EvidenceKind.notTested,
          };

    if (fault == PidFault.refusedUnsafeService) {
      return DatumStatus(
        availability: FeatureAvailability.unavailable,
        origin: origin,
        evidence: evidence,
        compatibility: Compatibility.unknown,
        quality: DatumQuality.invalid,
        operationRisk: riskFor(pid.modeAndPid),
        reason: '此服務不是唯讀查詢，已停止發送',
      );
    }
    if (reading == null) {
      return DatumStatus(
        availability: FeatureAvailability.unavailable,
        origin: origin,
        evidence: evidence,
        compatibility: Compatibility.unknown,
        quality: DatumQuality.partial,
        operationRisk: OperationRisk.boundedRead,
        reason: switch (fault) {
          PidFault.unsupported => '此車輛不支援這個 PID',
          PidFault.noAnswer => '無回應，稍後重試',
          PidFault.busError => '匯流排錯誤',
          PidFault.formulaError => '公式錯誤',
          PidFault.headerNotOnThisBus => '標頭不符本車匯流排',
          PidFault.refusedUnsafeService => '此服務不是唯讀查詢',
          null => '尚無讀值',
        },
        nextStep: '失敗只影響此項，其他讀值照用',
      );
    }

    return decodedValue(
      structurallyValid: true,
      value: reading.value,
      min: pid.minValue,
      max: pid.maxValue,
      origin: origin,
      evidence: evidence,
      isStale: isStale,
      freshnessLabel: isStale ? null : '剛更新',
    );
  }

  static DatumStatus forEstimate({
    required VehicleProfile profile,
    required double? value,
    required String formula,
    String quantity = '估算',
    EstimateKind kind = EstimateKind.horsepower,
  }) {
    final assumptions = _estimateAssumptions(profile, kind);
    if (value == null || !value.isFinite) {
      return DatumStatus(
        availability: FeatureAvailability.unavailable,
        origin: DatumOrigin.calculated,
        evidence: EvidenceKind.notTested,
        compatibility: Compatibility.unknown,
        quality: DatumQuality.partial,
        operationRisk: OperationRisk.display,
        reason: '$quantity缺少必要輸入',
        nextStep: '只影響此估算，其他讀值照用',
        formula: formula,
        assumptions: assumptions,
      );
    }
    final outOfRange = value < 0 || value > 2000;
    return DatumStatus(
      availability: FeatureAvailability.usableWithNotice,
      origin: DatumOrigin.calculated,
      evidence: EvidenceKind.notTested,
      compatibility: Compatibility.userSelected,
      quality: outOfRange
          ? DatumQuality.outOfReferenceRange
          : DatumQuality.valid,
      operationRisk: OperationRisk.display,
      formula: formula,
      assumptions: assumptions,
      reason: profile.isConfirmed ? null : '假設尚未確認，仍可估算',
      freshnessLabel: '剛更新',
    );
  }

  static String _estimateAssumptions(VehicleProfile profile, EstimateKind kind) {
    return switch (kind) {
      EstimateKind.horsepower =>
        '${_fieldNote('車重', '${profile.massKg.toStringAsFixed(0)} kg', profile.massField.origin)}；'
        '${_fieldNote('Cd', profile.dragCoefficient.toStringAsFixed(2), profile.dragCoefficientField.origin)}；'
        '${_fieldNote('迎風面積', '${profile.frontalAreaM2.toStringAsFixed(1)} m²', profile.frontalAreaField.origin)}；'
        '${_fieldNote('滾動阻力', profile.rollingResistance.toStringAsFixed(3), profile.rollingResistanceField.origin)}；'
        '${_fieldNote('傳動效率', '${(profile.drivetrainEfficiency * 100).toStringAsFixed(0)}% ${profile.drivetrain.label}', profile.drivetrainField.origin)}',
      EstimateKind.fuel =>
        '${_fieldNote('燃料', profile.fuelType.label, profile.fuelTypeField.origin)}；'
        'AFR ${profile.stoichAfr.toStringAsFixed(1)}；'
        '密度 ${profile.fuelDensityGPerL.toStringAsFixed(0)} g/L',
    };
  }

  static String _fieldNote(
    String label,
    String value,
    VehicleFieldOrigin origin,
  ) => '$label $value（${_originLabel(origin)}）';

  static String? serviceByte(String modeAndPid) {
    final value = PollableServices.normalise(modeAndPid);
    if (value.length < 2 || value.length.isOdd) return null;
    if (!RegExp(r'^[0-9A-F]+$').hasMatch(value)) return null;
    return value.substring(0, 2);
  }

  static OperationRisk riskFor(String modeAndPid) {
    final service = serviceByte(modeAndPid);
    if (service == null) return OperationRisk.program;
    if (PollableServices.isPollable(modeAndPid)) {
      return OperationRisk.boundedRead;
    }
    switch (service) {
      case '03':
      case '07':
      case '0A':
      case '09':
      case '21':
        return OperationRisk.boundedRead;
      case '04':
      case '14':
        return OperationRisk.clear;
      case '2F':
      case '31':
        return OperationRisk.stateChange;
      default:
        return OperationRisk.program;
    }
  }

  /// Send decision. Evidence / 未驗證 never authorizes a write.
  static bool allowSend({
    required String modeAndPid,
    OperationGate gate = const OperationGate(),
  }) {
    switch (riskFor(modeAndPid)) {
      case OperationRisk.display:
        return true;
      case OperationRisk.boundedRead:
        if (PollableServices.isPollable(modeAndPid)) return true;
        final service = serviceByte(modeAndPid);
        if (service == '21') return gate.oneShotConsent;
        if (service == '03' ||
            service == '07' ||
            service == '0A' ||
            service == '09') {
          return true;
        }
        return false;
      case OperationRisk.clear:
        return gate.clearSnapshotReady && gate.clearConfirmed;
      case OperationRisk.stateChange:
      case OperationRisk.program:
        return gate.programRecipeAuthorized;
    }
  }

  static bool canInstallBoundedReadProfile({
    required PowertrainProfileStatus status,
    required Iterable<String> modeAndIdentifiers,
    required bool validatorIssuesEmpty,
  }) {
    if (!validatorIssuesEmpty) return false;
    final commands = modeAndIdentifiers.toList(growable: false);
    if (commands.isEmpty) return false;
    switch (status) {
      case PowertrainProfileStatus.ready:
      case PowertrainProfileStatus.community:
      case PowertrainProfileStatus.experimental:
        return commands.every(PollableServices.isPollable);
      case PowertrainProfileStatus.researchOnly:
        return false;
    }
  }

  static DatumStatus forRecordedEvent({
    required TelemetrySignalDefinition definition,
    required TelemetryEvent event,
    TelemetrySource? source,
  }) {
    final derived = definition.variant.startsWith('derived-');
    final origin = derived
        ? DatumOrigin.calculated
        : source == TelemetrySource.demo
        ? DatumOrigin.demo
        : definition.isCustom
        ? DatumOrigin.userEntered
        : DatumOrigin.ecuReported;
    final evidence = definition.isCustom
        ? EvidenceKind.userSupplied
        : switch (definition.evidenceKind) {
            'community' => EvidenceKind.community,
            'experimental' => EvidenceKind.experimental,
            'fieldVerified' => EvidenceKind.fieldVerified,
            'userSupplied' => EvidenceKind.userSupplied,
            _ => EvidenceKind.notTested,
          };
    final compatibility = derived
        ? Compatibility.userSelected
        : definition.isCustom
        ? Compatibility.userSelected
        : switch (definition.evidenceKind) {
            'community' || 'experimental' => Compatibility.candidate,
            _ => Compatibility.unknown,
          };
    if (event.kind == TelemetryEventKind.status) {
      return DatumStatus(
        availability: FeatureAvailability.unavailable,
        origin: origin,
        evidence: evidence,
        compatibility: compatibility,
        quality: DatumQuality.partial,
        operationRisk: derived
            ? OperationRisk.display
            : riskFor(definition.request),
        reason: event.status?.wireName,
        nextStep: '失敗只影響此項，其他讀值照用',
      );
    }
    final status = decodedValue(
      structurallyValid: true,
      value: event.value,
      min: definition.minimum,
      max: definition.maximum,
      origin: origin,
      evidence: evidence,
      compatibility: compatibility,
      operationRisk: derived
          ? OperationRisk.display
          : OperationRisk.boundedRead,
      freshnessLabel: null,
    ).letQuality(
      event.quality == TelemetryQuality.outOfReferenceRange
          ? DatumQuality.outOfReferenceRange
          : event.quality == TelemetryQuality.tentativeDecode
          ? DatumQuality.tentativeDecode
          : null,
    );
    if (!derived) return status;
    return DatumStatus(
      availability: status.availability,
      origin: status.origin,
      evidence: status.evidence,
      compatibility: status.compatibility,
      quality: status.quality,
      operationRisk: status.operationRisk,
      reason: status.reason ?? '假設尚未確認，仍可估算',
      nextStep: status.nextStep,
      formula: definition.equation,
      assumptions: '估算使用記錄當下的車輛設定',
      freshnessLabel: status.freshnessLabel,
    );
  }

  static PowertrainProfileStatus? _statusFromKind(String? kind) {
    if (kind == null) return null;
    for (final status in PowertrainProfileStatus.values) {
      if (status.name == kind) return status;
    }
    return null;
  }

  static String _originLabel(VehicleFieldOrigin origin) => switch (origin) {
    VehicleFieldOrigin.genericDefault => '通用預設',
    VehicleFieldOrigin.userEntered => '手動輸入',
    VehicleFieldOrigin.officialRegistry => '官方型錄',
    VehicleFieldOrigin.manufacturerPublication => '原廠資料',
    VehicleFieldOrigin.scientificModel => '模型係數',
  };
}

extension on DatumStatus {
  DatumStatus letQuality(DatumQuality? quality) {
    if (quality == null || quality == this.quality) return this;
    return DatumStatus(
      availability: availability,
      origin: origin,
      evidence: evidence,
      compatibility: compatibility,
      quality: quality,
      operationRisk: operationRisk,
      reason: quality == DatumQuality.outOfReferenceRange
          ? '超出一般參考範圍，已保留'
          : reason,
      nextStep: nextStep,
      formula: formula,
      assumptions: assumptions,
      freshnessLabel: freshnessLabel,
    );
  }
}
