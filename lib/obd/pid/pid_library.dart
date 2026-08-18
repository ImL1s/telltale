/// Built-in SAE J1979 Mode 01 PID definitions.
///
/// Every formula and range here was cross-checked against the SAE J1979
/// standard values rather than taken from the reverse-engineering spec alone —
/// see `SPEC_DEVIATIONS.md`. Where the spec and the standard agreed, the shared
/// value is used; nothing in this table is spec-only.
library;

import 'pid.dart';
import 'priority_tier.dart';

/// The percentage formula J1979 uses everywhere: a single byte spanning 0-100%.
const String _pct = 'A*100/255';

/// Two-byte big-endian raw value.
const String _word = '(A*256)+B';

abstract final class PidLibrary {
  // ---------------------------------------------------------------- core ----

  static const engineRpm = Pid(
    name: 'Engine RPM',
    shortName: 'RPM',
    modeAndPid: '010C',
    equation: '($_word)/4',
    minValue: 0,
    maxValue: 8000,
    units: 'rpm',
    priority: PriorityTier.high,
    redlineFrom: 6500,
  );

  static const vehicleSpeed = Pid(
    name: 'Vehicle Speed',
    shortName: 'Speed',
    modeAndPid: '010D',
    equation: 'A',
    minValue: 0,
    maxValue: 240,
    units: 'km/h',
    priority: PriorityTier.high,
  );

  static const coolantTemp = Pid(
    name: 'Engine Coolant Temperature',
    shortName: 'Coolant',
    modeAndPid: '0105',
    equation: 'A-40',
    minValue: -40,
    maxValue: 215,
    units: '°C',
    priority: PriorityTier.medium,
    redlineFrom: 110,
  );

  static const intakeAirTemp = Pid(
    name: 'Intake Air Temperature',
    shortName: 'IAT',
    modeAndPid: '010F',
    equation: 'A-40',
    minValue: -40,
    maxValue: 215,
    units: '°C',
    priority: PriorityTier.medium,
  );

  static const engineLoad = Pid(
    name: 'Calculated Engine Load',
    shortName: 'Load',
    modeAndPid: '0104',
    equation: _pct,
    minValue: 0,
    maxValue: 100,
    units: '%',
    priority: PriorityTier.high,
  );

  static const throttlePosition = Pid(
    name: 'Throttle Position',
    shortName: 'Throttle',
    modeAndPid: '0111',
    equation: _pct,
    minValue: 0,
    maxValue: 100,
    units: '%',
    priority: PriorityTier.high,
  );

  static const manifoldPressure = Pid(
    name: 'Intake Manifold Absolute Pressure',
    shortName: 'MAP',
    modeAndPid: '010B',
    equation: 'A',
    minValue: 0,
    maxValue: 255,
    units: 'kPa',
    priority: PriorityTier.high,
  );

  static const mafRate = Pid(
    name: 'MAF Air Flow Rate',
    shortName: 'MAF',
    modeAndPid: '0110',
    equation: '($_word)/100',
    minValue: 0,
    maxValue: 400,
    units: 'g/s',
    priority: PriorityTier.high,
  );

  static const timingAdvance = Pid(
    name: 'Timing Advance',
    shortName: 'Timing',
    modeAndPid: '010E',
    equation: '(A/2)-64',
    minValue: -64,
    maxValue: 64,
    units: '°',
    priority: PriorityTier.medium,
  );

  // ------------------------------------------------------------ secondary ----

  static const fuelPressure = Pid(
    name: 'Fuel Pressure',
    shortName: 'Fuel Press',
    modeAndPid: '010A',
    equation: 'A*3',
    minValue: 0,
    maxValue: 765,
    units: 'kPa',
    priority: PriorityTier.low,
  );

  static const fuelLevel = Pid(
    name: 'Fuel Tank Level',
    shortName: 'Fuel',
    modeAndPid: '012F',
    equation: _pct,
    minValue: 0,
    maxValue: 100,
    units: '%',
    priority: PriorityTier.low,
  );

  static const barometricPressure = Pid(
    name: 'Barometric Pressure',
    shortName: 'Baro',
    modeAndPid: '0133',
    equation: 'A',
    minValue: 0,
    maxValue: 255,
    units: 'kPa',
    priority: PriorityTier.low,
  );

  static const controlModuleVoltage = Pid(
    name: 'Control Module Voltage',
    shortName: 'Voltage',
    modeAndPid: '0142',
    equation: '($_word)/1000',
    minValue: 0,
    maxValue: 18,
    units: 'V',
    priority: PriorityTier.medium,
  );

  static const ambientAirTemp = Pid(
    name: 'Ambient Air Temperature',
    shortName: 'Ambient',
    modeAndPid: '0146',
    equation: 'A-40',
    minValue: -40,
    maxValue: 215,
    units: '°C',
    priority: PriorityTier.low,
  );

  static const engineOilTemp = Pid(
    name: 'Engine Oil Temperature',
    shortName: 'Oil Temp',
    modeAndPid: '015C',
    equation: 'A-40',
    minValue: -40,
    maxValue: 210,
    units: '°C',
    priority: PriorityTier.medium,
    redlineFrom: 130,
  );

  static const engineFuelRate = Pid(
    name: 'Engine Fuel Rate',
    shortName: 'Fuel Rate',
    modeAndPid: '015E',
    equation: '($_word)/20',
    minValue: 0,
    maxValue: 60,
    units: 'L/h',
    priority: PriorityTier.medium,
  );

  static const shortFuelTrimB1 = Pid(
    name: 'Short Term Fuel Trim — Bank 1',
    shortName: 'STFT B1',
    modeAndPid: '0106',
    equation: '(A*100/128)-100',
    minValue: -100,
    maxValue: 100,
    units: '%',
    priority: PriorityTier.medium,
  );

  static const longFuelTrimB1 = Pid(
    name: 'Long Term Fuel Trim — Bank 1',
    shortName: 'LTFT B1',
    modeAndPid: '0107',
    equation: '(A*100/128)-100',
    minValue: -100,
    maxValue: 100,
    units: '%',
    priority: PriorityTier.low,
  );

  static const runTime = Pid(
    name: 'Run Time Since Engine Start',
    shortName: 'Run Time',
    modeAndPid: '011F',
    equation: _word,
    minValue: 0,
    maxValue: 65535,
    units: 's',
    priority: PriorityTier.low,
  );

  static const distanceWithMil = Pid(
    name: 'Distance Travelled With MIL On',
    shortName: 'MIL Dist',
    modeAndPid: '0121',
    equation: _word,
    minValue: 0,
    maxValue: 65535,
    units: 'km',
    priority: PriorityTier.veryLow,
  );

  static const absoluteLoad = Pid(
    name: 'Absolute Load Value',
    shortName: 'Abs Load',
    modeAndPid: '0143',
    equation: '($_word)*100/255',
    minValue: 0,
    maxValue: 300,
    units: '%',
    priority: PriorityTier.low,
  );

  static const commandedEgr = Pid(
    name: 'Commanded EGR',
    shortName: 'EGR',
    modeAndPid: '012C',
    equation: _pct,
    minValue: 0,
    maxValue: 100,
    units: '%',
    priority: PriorityTier.low,
  );

  static const relativeThrottle = Pid(
    name: 'Relative Throttle Position',
    shortName: 'Rel Thr',
    modeAndPid: '0145',
    equation: _pct,
    minValue: 0,
    maxValue: 100,
    units: '%',
    priority: PriorityTier.low,
  );

  // -------------------------------------------------------------- derived ----
  // These have no PID of their own. They are expressed with `VAL{...}` against
  // other PIDs, which is exactly what the formula engine's external-reference
  // support exists for, and they demonstrate it in the shipped set.

  /// Manifold pressure above ambient. Negative under vacuum, positive on boost.
  static const boostPressure = Pid(
    name: 'Turbo Boost (MAP − Baro)',
    shortName: 'Boost',
    modeAndPid: '010B',
    equation: 'A-VAL{0133}',
    minValue: -100,
    maxValue: 200,
    units: 'kPa',
    priority: PriorityTier.high,
    redlineFrom: 150,
    // Shares PID 010B with manifoldPressure but is a different gauge; without
    // its own variant tag the two would collide on `id`.
    variant: 'boost',
  );

  /// Vehicle speed rendered in mph for users who prefer imperial.
  static const speedMph = Pid(
    name: 'Vehicle Speed (mph)',
    shortName: 'Speed',
    modeAndPid: '010D',
    equation: 'A*0.621371',
    minValue: 0,
    maxValue: 150,
    units: 'mph',
    priority: PriorityTier.high,
    variant: 'mph',
  );

  // ---------------------------------------------------------------- sets ----

  /// Every built-in definition, in display order.
  static const List<Pid> all = [
    engineRpm,
    vehicleSpeed,
    engineLoad,
    throttlePosition,
    coolantTemp,
    intakeAirTemp,
    manifoldPressure,
    mafRate,
    timingAdvance,
    engineOilTemp,
    controlModuleVoltage,
    engineFuelRate,
    shortFuelTrimB1,
    longFuelTrimB1,
    fuelLevel,
    fuelPressure,
    barometricPressure,
    ambientAirTemp,
    absoluteLoad,
    commandedEgr,
    relativeThrottle,
    runTime,
    distanceWithMil,

    // Derived definitions, which the comment above them has always claimed
    // were shipped. They were not in this list, so `VAL{}` had no worked
    // example anywhere a user could reach — and the built-in boost gauge could
    // not have worked in any case until formula dependencies started being
    // scheduled.
    boostPressure,
    speedMph,
  ];

  /// Sensible starting dashboard: the six signals a driver actually watches.
  static const List<Pid> defaultDashboard = [
    engineRpm,
    vehicleSpeed,
    coolantTemp,
    engineLoad,
    throttlePosition,
    intakeAirTemp,
  ];

  /// Signals the physics engine needs to derive MAF, fuel flow and horsepower
  /// when the vehicle has no MAF sensor of its own.
  static const List<Pid> physicsInputs = [
    engineRpm,
    vehicleSpeed,
    manifoldPressure,
    intakeAirTemp,
    mafRate,
    // The ECU's own fuel rate, preferred over the stoichiometric estimate
    // wherever the vehicle reports it. Vehicles that do not implement it
    // answer `NO DATA` and the PID retires itself after a few attempts, so
    // asking costs nothing lasting and the payoff is a figure that accounts
    // for the mixture actually being run.
    engineFuelRate,
  ];

  static Pid? byModeAndPid(String modeAndPid) {
    final key = modeAndPid.toUpperCase().trim();
    for (final pid in all) {
      if (pid.modeAndPid == key) return pid;
    }
    return null;
  }

  /// The `01 00` / `01 20` / `01 40` support-discovery requests. Each returns a
  /// 32-bit mask whose bits mark which PIDs in the following block the ECU
  /// answers, and whose lowest bit marks whether the next block exists.
  static const List<String> supportQueries = ['0100', '0120', '0140', '0160'];

  /// The support query whose mask describes [modeAndPid], if any.
  ///
  /// Each mask covers the 32 PIDs *after* its base, so `0120` describes `0121`
  /// through `0140`. A PID outside every published block — or one that is not
  /// Mode 01 — has no mask, and nothing may be concluded about it from one.
  static String? supportBlockFor(String modeAndPid) {
    final hex = modeAndPid.toUpperCase();
    if (!hex.startsWith('01') || hex.length != 4) return null;
    final pid = int.tryParse(hex.substring(2), radix: 16);
    if (pid == null || pid == 0) return null;
    for (final query in supportQueries.reversed) {
      final base = int.parse(query.substring(2), radix: 16);
      if (pid > base && pid <= base + 0x20) return query;
    }
    return null;
  }

  /// Decodes a support bitmask into the PIDs it reports as available.
  ///
  /// [baseQuery] is the query that produced [maskBytes], e.g. `0120` means bit
  /// 31 of the mask corresponds to PID `0121`.
  static Set<String> decodeSupportMask(String baseQuery, List<int> maskBytes) {
    if (maskBytes.length < 4) return const {};
    final base = int.tryParse(baseQuery.substring(2), radix: 16);
    if (base == null) return const {};

    final mask = (maskBytes[0] << 24) | (maskBytes[1] << 16) | (maskBytes[2] << 8) | maskBytes[3];
    final supported = <String>{};
    for (var bit = 0; bit < 32; bit++) {
      // Bit 31 is the first PID after the base, bit 0 the 32nd.
      if ((mask & (1 << (31 - bit))) != 0) {
        final pidNumber = base + bit + 1;
        supported.add('01${pidNumber.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return supported;
  }
}
