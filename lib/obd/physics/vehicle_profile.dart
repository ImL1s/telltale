/// Vehicle parameters the physics engine needs.
library;

import 'vehicle_evidence.dart';

enum FuelType {
  gasoline('汽油', 14.7, 740),
  diesel('柴油', 14.5, 835),
  lpg('液化石油氣 (LPG)', 15.6, 540),
  ethanolE85('E85 酒精汽油', 9.8, 782);

  const FuelType(this.label, this.stoichAfr, this.densityGPerL);
  final String label;
  final double stoichAfr;
  final double densityGPerL;
}

enum Drivetrain {
  fwd('前輪驅動', 0.85),
  rwd('後輪驅動', 0.85),
  awd('四輪驅動', 0.80);

  const Drivetrain(this.label, this.efficiency);
  final String label;
  final double efficiency;
}

class VehicleProfile {
  static const int schemaVersion = 2;
  static const double minDisplacementL = 0.6;
  // The bundled U.S. EPA passenger-car catalog contains factory 8.4 L
  // configurations. Keeping the former 8.0 L ceiling made exact official
  // records impossible to represent and silently pushed them back to a guess.
  static const double maxDisplacementL = 8.5;
  static const double minMassKg = 600;
  static const double maxMassKg = 3500;
  static const double minVolumetricEfficiency = 50;
  static const double maxVolumetricEfficiency = 130;
  static const double minDragCoefficient = 0.15;
  static const double maxDragCoefficient = 0.60;
  static const double minFrontalAreaM2 = 1.4;
  static const double maxFrontalAreaM2 = 4.0;
  static const double minRollingResistance = 0.006;
  static const double maxRollingResistance = 0.030;

  const VehicleProfile({
    this.displacementL = 2.0,
    this.massKg = 1500,
    this.volumetricEfficiency = 85,
    this.fuelType = FuelType.gasoline,
    this.drivetrain = Drivetrain.fwd,
    this.dragCoefficient = 0.30,
    this.frontalAreaM2 = 2.2,
    this.rollingResistance = 0.015,
    bool isConfirmed = false,
  }) : _displacementOrigin = VehicleFieldOrigin.genericDefault,
       _massOrigin = VehicleFieldOrigin.genericDefault,
       _volumetricEfficiencyOrigin = VehicleFieldOrigin.genericDefault,
       _fuelTypeOrigin = VehicleFieldOrigin.genericDefault,
       _drivetrainOrigin = VehicleFieldOrigin.genericDefault,
       _dragCoefficientOrigin = VehicleFieldOrigin.genericDefault,
       _frontalAreaOrigin = VehicleFieldOrigin.genericDefault,
       _rollingResistanceOrigin = VehicleFieldOrigin.genericDefault,
       _displacementResolution = isConfirmed
           ? EvidenceResolution.userConfirmedSession
           : EvidenceResolution.unknown,
       _massResolution = isConfirmed
           ? EvidenceResolution.userConfirmedSession
           : EvidenceResolution.unknown,
       _volumetricEfficiencyResolution = isConfirmed
           ? EvidenceResolution.userConfirmedSession
           : EvidenceResolution.unknown,
       _fuelTypeResolution = isConfirmed
           ? EvidenceResolution.userConfirmedSession
           : EvidenceResolution.unknown,
       _drivetrainResolution = isConfirmed
           ? EvidenceResolution.userConfirmedSession
           : EvidenceResolution.unknown,
       _dragCoefficientResolution = isConfirmed
           ? EvidenceResolution.userConfirmedSession
           : EvidenceResolution.unknown,
       _frontalAreaResolution = isConfirmed
           ? EvidenceResolution.userConfirmedSession
           : EvidenceResolution.unknown,
       _rollingResistanceResolution = isConfirmed
           ? EvidenceResolution.userConfirmedSession
           : EvidenceResolution.unknown,
       _displacementEvidence = null,
       _massEvidence = null,
       _volumetricEfficiencyEvidence = null,
       _fuelTypeEvidence = null,
       _drivetrainEvidence = null,
       _dragCoefficientEvidence = null,
       _frontalAreaEvidence = null,
       _rollingResistanceEvidence = null,
       _confirmationRequested = isConfirmed;

  factory VehicleProfile.sourced({
    SourcedField<double>? displacementL,
    SourcedField<double>? massKg,
    SourcedField<double>? volumetricEfficiency,
    SourcedField<FuelType>? fuelType,
    SourcedField<Drivetrain>? drivetrain,
    SourcedField<double>? dragCoefficient,
    SourcedField<double>? frontalAreaM2,
    SourcedField<double>? rollingResistance,
    bool isConfirmed = false,
  }) {
    final profile = VehicleProfile._internal(
      displacementL: displacementL ?? _generic(2.0),
      massKg: massKg ?? _generic(1500.0),
      volumetricEfficiency: volumetricEfficiency ?? _generic(85.0),
      fuelType: fuelType ?? _generic(FuelType.gasoline),
      drivetrain: drivetrain ?? _generic(Drivetrain.fwd),
      dragCoefficient: dragCoefficient ?? _generic(0.30),
      frontalAreaM2: frontalAreaM2 ?? _generic(2.2),
      rollingResistance: rollingResistance ?? _generic(0.015),
      isConfirmed: false,
    );
    return isConfirmed ? profile._withSessionConfirmation(true) : profile;
  }

  VehicleProfile._internal({
    required SourcedField<double> displacementL,
    required SourcedField<double> massKg,
    required SourcedField<double> volumetricEfficiency,
    required SourcedField<FuelType> fuelType,
    required SourcedField<Drivetrain> drivetrain,
    required SourcedField<double> dragCoefficient,
    required SourcedField<double> frontalAreaM2,
    required SourcedField<double> rollingResistance,
    required bool isConfirmed,
  }) : displacementL = displacementL.value,
       massKg = massKg.value,
       volumetricEfficiency = volumetricEfficiency.value,
       fuelType = fuelType.value,
       drivetrain = drivetrain.value,
       dragCoefficient = dragCoefficient.value,
       frontalAreaM2 = frontalAreaM2.value,
       rollingResistance = rollingResistance.value,
       _displacementOrigin = displacementL.origin,
       _massOrigin = massKg.origin,
       _volumetricEfficiencyOrigin = volumetricEfficiency.origin,
       _fuelTypeOrigin = fuelType.origin,
       _drivetrainOrigin = drivetrain.origin,
       _dragCoefficientOrigin = dragCoefficient.origin,
       _frontalAreaOrigin = frontalAreaM2.origin,
       _rollingResistanceOrigin = rollingResistance.origin,
       _displacementResolution = displacementL.resolution,
       _massResolution = massKg.resolution,
       _volumetricEfficiencyResolution = volumetricEfficiency.resolution,
       _fuelTypeResolution = fuelType.resolution,
       _drivetrainResolution = drivetrain.resolution,
       _dragCoefficientResolution = dragCoefficient.resolution,
       _frontalAreaResolution = frontalAreaM2.resolution,
       _rollingResistanceResolution = rollingResistance.resolution,
       _displacementEvidence = displacementL.evidence,
       _massEvidence = massKg.evidence,
       _volumetricEfficiencyEvidence = volumetricEfficiency.evidence,
       _fuelTypeEvidence = fuelType.evidence,
       _drivetrainEvidence = drivetrain.evidence,
       _dragCoefficientEvidence = dragCoefficient.evidence,
       _frontalAreaEvidence = frontalAreaM2.evidence,
       _rollingResistanceEvidence = rollingResistance.evidence,
       _confirmationRequested = isConfirmed;

  final double displacementL;
  final double massKg;
  final double volumetricEfficiency;
  final FuelType fuelType;
  final Drivetrain drivetrain;
  final double dragCoefficient;
  final double frontalAreaM2;
  final double rollingResistance;

  final VehicleFieldOrigin _displacementOrigin;
  final VehicleFieldOrigin _massOrigin;
  final VehicleFieldOrigin _volumetricEfficiencyOrigin;
  final VehicleFieldOrigin _fuelTypeOrigin;
  final VehicleFieldOrigin _drivetrainOrigin;
  final VehicleFieldOrigin _dragCoefficientOrigin;
  final VehicleFieldOrigin _frontalAreaOrigin;
  final VehicleFieldOrigin _rollingResistanceOrigin;
  final EvidenceResolution _displacementResolution;
  final EvidenceResolution _massResolution;
  final EvidenceResolution _volumetricEfficiencyResolution;
  final EvidenceResolution _fuelTypeResolution;
  final EvidenceResolution _drivetrainResolution;
  final EvidenceResolution _dragCoefficientResolution;
  final EvidenceResolution _frontalAreaResolution;
  final EvidenceResolution _rollingResistanceResolution;
  final EvidenceRef? _displacementEvidence;
  final EvidenceRef? _massEvidence;
  final EvidenceRef? _volumetricEfficiencyEvidence;
  final EvidenceRef? _fuelTypeEvidence;
  final EvidenceRef? _drivetrainEvidence;
  final EvidenceRef? _dragCoefficientEvidence;
  final EvidenceRef? _frontalAreaEvidence;
  final EvidenceRef? _rollingResistanceEvidence;
  final bool _confirmationRequested;

  SourcedField<double> get displacementField => _field(
    displacementL,
    _displacementOrigin,
    _displacementResolution,
    _displacementEvidence,
  );
  SourcedField<double> get massField =>
      _field(massKg, _massOrigin, _massResolution, _massEvidence);
  SourcedField<double> get volumetricEfficiencyField => _field(
    volumetricEfficiency,
    _volumetricEfficiencyOrigin,
    _volumetricEfficiencyResolution,
    _volumetricEfficiencyEvidence,
  );
  SourcedField<FuelType> get fuelTypeField =>
      _field(fuelType, _fuelTypeOrigin, _fuelTypeResolution, _fuelTypeEvidence);
  SourcedField<Drivetrain> get drivetrainField => _field(
    drivetrain,
    _drivetrainOrigin,
    _drivetrainResolution,
    _drivetrainEvidence,
  );
  SourcedField<double> get dragCoefficientField => _field(
    dragCoefficient,
    _dragCoefficientOrigin,
    _dragCoefficientResolution,
    _dragCoefficientEvidence,
  );
  SourcedField<double> get frontalAreaField => _field(
    frontalAreaM2,
    _frontalAreaOrigin,
    _frontalAreaResolution,
    _frontalAreaEvidence,
  );
  SourcedField<double> get rollingResistanceField => _field(
    rollingResistance,
    _rollingResistanceOrigin,
    _rollingResistanceResolution,
    _rollingResistanceEvidence,
  );
  List<SourcedField<Object?>> get inputFields => [
    _widen(displacementField),
    _widen(massField),
    _widen(volumetricEfficiencyField),
    _widen(fuelTypeField),
    _widen(drivetrainField),
    _widen(dragCoefficientField),
    _widen(frontalAreaField),
    _widen(rollingResistanceField),
  ];
  Map<String, SourcedField<Object?>> get inputFieldMap => Map.unmodifiable({
    'displacementL': _widen(displacementField),
    'massKg': _widen(massField),
    'volumetricEfficiency': _widen(volumetricEfficiencyField),
    'fuelType': _widen(fuelTypeField),
    'drivetrain': _widen(drivetrainField),
    'dragCoefficient': _widen(dragCoefficientField),
    'frontalAreaM2': _widen(frontalAreaField),
    'rollingResistance': _widen(rollingResistanceField),
  });

  double get drivetrainEfficiency => drivetrain.efficiency;
  double get stoichAfr => fuelType.stoichAfr;
  double get fuelDensityGPerL => fuelType.densityGPerL;
  bool get isConfirmed =>
      _confirmationRequested && hasValidAssumptions && hasResolvedAssumptions;

  bool get hasResolvedAssumptions => inputFields.every(
    (field) =>
        field.resolution == EvidenceResolution.userConfirmedSession ||
        field.isVerifiedExact,
  );

  bool get hasValidAssumptions =>
      _inRange(displacementL, minDisplacementL, maxDisplacementL) &&
      _inRange(massKg, minMassKg, maxMassKg) &&
      _inRange(
        volumetricEfficiency,
        minVolumetricEfficiency,
        maxVolumetricEfficiency,
      ) &&
      _inRange(dragCoefficient, minDragCoefficient, maxDragCoefficient) &&
      _inRange(frontalAreaM2, minFrontalAreaM2, maxFrontalAreaM2) &&
      _inRange(rollingResistance, minRollingResistance, maxRollingResistance);

  VehicleProfile copyWith({
    double? displacementL,
    double? massKg,
    double? volumetricEfficiency,
    FuelType? fuelType,
    Drivetrain? drivetrain,
    double? dragCoefficient,
    double? frontalAreaM2,
    double? rollingResistance,
    bool? isConfirmed,
  }) {
    final changed =
        displacementL != null ||
        massKg != null ||
        volumetricEfficiency != null ||
        fuelType != null ||
        drivetrain != null ||
        dragCoefficient != null ||
        frontalAreaM2 != null ||
        rollingResistance != null;
    final copied = VehicleProfile._internal(
      displacementL: displacementL == null
          ? displacementField
          : _user(displacementL),
      massKg: massKg == null ? massField : _user(massKg),
      volumetricEfficiency: volumetricEfficiency == null
          ? volumetricEfficiencyField
          : _user(volumetricEfficiency),
      fuelType: fuelType == null ? fuelTypeField : _user(fuelType),
      drivetrain: drivetrain == null ? drivetrainField : _user(drivetrain),
      dragCoefficient: dragCoefficient == null
          ? dragCoefficientField
          : _user(dragCoefficient),
      frontalAreaM2: frontalAreaM2 == null
          ? frontalAreaField
          : _user(frontalAreaM2),
      rollingResistance: rollingResistance == null
          ? rollingResistanceField
          : _user(rollingResistance),
      isConfirmed: changed ? false : (isConfirmed ?? this.isConfirmed),
    );
    if (changed) return copied._withSessionConfirmation(false);
    if (isConfirmed != null) {
      return copied._withSessionConfirmation(isConfirmed);
    }
    return copied;
  }

  VehicleProfile confirmAssumptions() => _withSessionConfirmation(true);
  VehicleProfile unconfirmed() => _withSessionConfirmation(false);

  /// Carries editable values across a process or vehicle boundary without
  /// carrying trust for the vehicle on the other side. A later catalog
  /// selection can establish fresh exact evidence for the current car.
  VehicleProfile untrustedAfterVehicleBoundary() => VehicleProfile._internal(
    displacementL: _persistedField(displacementField),
    massKg: _persistedField(massField),
    volumetricEfficiency: _persistedField(volumetricEfficiencyField),
    fuelType: _persistedField(fuelTypeField),
    drivetrain: _persistedField(drivetrainField),
    dragCoefficient: _persistedField(dragCoefficientField),
    frontalAreaM2: _persistedField(frontalAreaField),
    rollingResistance: _persistedField(rollingResistanceField),
    isConfirmed: false,
  );

  VehicleProfile _withSessionConfirmation(bool confirmed) =>
      VehicleProfile._internal(
        displacementL: _sessionField(displacementField, confirmed),
        massKg: _sessionField(massField, confirmed),
        volumetricEfficiency: _sessionField(
          volumetricEfficiencyField,
          confirmed,
        ),
        fuelType: _sessionField(fuelTypeField, confirmed),
        drivetrain: _sessionField(drivetrainField, confirmed),
        dragCoefficient: _sessionField(dragCoefficientField, confirmed),
        frontalAreaM2: _sessionField(frontalAreaField, confirmed),
        rollingResistance: _sessionField(rollingResistanceField, confirmed),
        isConfirmed: confirmed,
      );

  Map<String, dynamic> toJson() => {
    'schemaVersion': schemaVersion,
    'displacementL': displacementL,
    'massKg': massKg,
    'volumetricEfficiency': volumetricEfficiency,
    'fuelType': fuelType.name,
    'drivetrain': drivetrain.name,
    'dragCoefficient': dragCoefficient,
    'frontalAreaM2': frontalAreaM2,
    'rollingResistance': rollingResistance,
    'fields': {
      'displacementL': displacementField.toJson(displacementL),
      'massKg': massField.toJson(massKg),
      'volumetricEfficiency': volumetricEfficiencyField.toJson(
        volumetricEfficiency,
      ),
      'fuelType': fuelTypeField.toJson(fuelType.name),
      'drivetrain': drivetrainField.toJson(drivetrain.name),
      'dragCoefficient': dragCoefficientField.toJson(dragCoefficient),
      'frontalAreaM2': frontalAreaField.toJson(frontalAreaM2),
      'rollingResistance': rollingResistanceField.toJson(rollingResistance),
    },
    'isConfirmed': isConfirmed,
  };

  factory VehicleProfile.fromJson(Map<String, dynamic> json) {
    final displacement = _boundedNumber(
      json['displacementL'],
      fallback: 2.0,
      min: minDisplacementL,
      max: maxDisplacementL,
    );
    final mass = _boundedNumber(
      json['massKg'],
      fallback: 1500,
      min: minMassKg,
      max: maxMassKg,
    );
    final ve = _boundedNumber(
      json['volumetricEfficiency'],
      fallback: 85,
      min: minVolumetricEfficiency,
      max: maxVolumetricEfficiency,
    );
    final drag = _boundedNumber(
      json['dragCoefficient'],
      fallback: 0.30,
      min: minDragCoefficient,
      max: maxDragCoefficient,
    );
    final area = _boundedNumber(
      json['frontalAreaM2'],
      fallback: 2.2,
      min: minFrontalAreaM2,
      max: maxFrontalAreaM2,
    );
    final rolling = _boundedNumber(
      json['rollingResistance'],
      fallback: 0.015,
      min: minRollingResistance,
      max: maxRollingResistance,
    );
    final fuel = FuelType.values.firstWhere(
      (value) => value.name == json['fuelType'],
      orElse: () => FuelType.gasoline,
    );
    final drive = Drivetrain.values.firstWhere(
      (value) => value.name == json['drivetrain'],
      orElse: () => Drivetrain.fwd,
    );
    final rawFields = json['fields'];
    var fieldsValid =
        json['schemaVersion'] == schemaVersion &&
        rawFields is Map<String, dynamic>;

    SourcedField<T> readField<T>(String key, T value, Object encoded) {
      if (!fieldsValid) return _generic(value);
      final raw = rawFields[key];
      if (raw is! Map<String, dynamic> || raw['value'] != encoded) {
        fieldsValid = false;
        return _generic(value);
      }
      final origin = VehicleFieldOrigin.values.firstWhere(
        (candidate) => candidate.name == raw['origin'],
        orElse: () => VehicleFieldOrigin.genericDefault,
      );
      final resolution = EvidenceResolution.values.firstWhere(
        (candidate) => candidate.name == raw['resolution'],
        orElse: () => EvidenceResolution.unknown,
      );
      final evidence = EvidenceRef.tryFromJson(raw['evidence']);
      if ((resolution == EvidenceResolution.verifiedExact) !=
              (evidence != null) ||
          resolution == EvidenceResolution.verifiedExact &&
              origin != VehicleFieldOrigin.officialRegistry &&
              origin != VehicleFieldOrigin.manufacturerPublication) {
        fieldsValid = false;
        return _generic(value);
      }
      return SourcedField(
        value: value,
        origin: origin,
        resolution: resolution,
        evidence: evidence,
      );
    }

    final sourced = <Object>[
      readField('displacementL', displacement, displacement),
      readField('massKg', mass, mass),
      readField('volumetricEfficiency', ve, ve),
      readField('fuelType', fuel, fuel.name),
      readField('drivetrain', drive, drive.name),
      readField('dragCoefficient', drag, drag),
      readField('frontalAreaM2', area, area),
      readField('rollingResistance', rolling, rolling),
    ];
    final rawValuesValid =
        _isValidRawNumber(
          json['displacementL'],
          minDisplacementL,
          maxDisplacementL,
        ) &&
        _isValidRawNumber(json['massKg'], minMassKg, maxMassKg) &&
        _isValidRawNumber(
          json['volumetricEfficiency'],
          minVolumetricEfficiency,
          maxVolumetricEfficiency,
        ) &&
        _isValidRawNumber(
          json['dragCoefficient'],
          minDragCoefficient,
          maxDragCoefficient,
        ) &&
        _isValidRawNumber(
          json['frontalAreaM2'],
          minFrontalAreaM2,
          maxFrontalAreaM2,
        ) &&
        _isValidRawNumber(
          json['rollingResistance'],
          minRollingResistance,
          maxRollingResistance,
        ) &&
        json['fuelType'] == fuel.name &&
        json['drivetrain'] == drive.name;
    if (!fieldsValid) {
      return VehicleProfile(
        displacementL: displacement,
        massKg: mass,
        volumetricEfficiency: ve,
        fuelType: fuel,
        drivetrain: drive,
        dragCoefficient: drag,
        frontalAreaM2: area,
        rollingResistance: rolling,
      );
    }
    return VehicleProfile._internal(
      displacementL: sourced[0] as SourcedField<double>,
      massKg: sourced[1] as SourcedField<double>,
      volumetricEfficiency: sourced[2] as SourcedField<double>,
      fuelType: sourced[3] as SourcedField<FuelType>,
      drivetrain: sourced[4] as SourcedField<Drivetrain>,
      dragCoefficient: sourced[5] as SourcedField<double>,
      frontalAreaM2: sourced[6] as SourcedField<double>,
      rollingResistance: sourced[7] as SourcedField<double>,
      isConfirmed: json['isConfirmed'] == true && rawValuesValid,
    );
  }

  static SourcedField<T> _field<T>(
    T value,
    VehicleFieldOrigin origin,
    EvidenceResolution resolution,
    EvidenceRef? evidence,
  ) => SourcedField(
    value: value,
    origin: origin,
    resolution: resolution,
    evidence: evidence,
  );
  static SourcedField<Object?> _widen<T>(SourcedField<T> field) => SourcedField(
    value: field.value,
    origin: field.origin,
    resolution: field.resolution,
    evidence: field.evidence,
  );
  static SourcedField<T> _generic<T>(T value) =>
      SourcedField(value: value, origin: VehicleFieldOrigin.genericDefault);
  static SourcedField<T> _user<T>(T value) =>
      SourcedField(value: value, origin: VehicleFieldOrigin.userEntered);
  static SourcedField<T> _sessionField<T>(
    SourcedField<T> field,
    bool confirmed,
  ) {
    if (field.isVerifiedExact ||
        field.resolution == EvidenceResolution.ambiguous ||
        field.resolution == EvidenceResolution.conflict) {
      return field;
    }
    return SourcedField(
      value: field.value,
      origin: field.origin,
      resolution: confirmed
          ? EvidenceResolution.userConfirmedSession
          : EvidenceResolution.unknown,
    );
  }

  static SourcedField<T> _persistedField<T>(SourcedField<T> field) {
    if (field.isVerifiedExact) {
      return SourcedField(
        value: field.value,
        origin: field.origin,
        resolution: EvidenceResolution.unknown,
      );
    }
    return _sessionField(field, false);
  }

  static bool _inRange(double value, double min, double max) =>
      value.isFinite && value >= min && value <= max;
  static bool _isValidRawNumber(Object? raw, double min, double max) =>
      raw is num && _inRange(raw.toDouble(), min, max);
  static double _boundedNumber(
    Object? raw, {
    required double fallback,
    required double min,
    required double max,
  }) {
    if (raw is! num) return fallback;
    final value = raw.toDouble();
    if (!value.isFinite) return fallback;
    return value.clamp(min, max).toDouble();
  }
}
