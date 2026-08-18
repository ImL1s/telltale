/// The emissions readiness monitors, out of Mode 01 PID 01's B, C and D bytes.
///
/// The engine has been fetching these since the beginning. `_readMilStatus`
/// asks for `0101`, checks the reply is a full six bytes *specifically so that
/// B, C and D are known to have arrived* — and then reads byte A and throws the
/// rest away. This decodes what was already on the wire.
///
/// It closes a loop the app had left open. Every clear warns that 清除會重置排放
/// 就緒狀態 and that the car then needs a full drive cycle before it can pass an
/// emissions test. Until now the app could say that and never show it.
///
/// The distinction that matters, and the reason a naive implementation gets
/// this wrong: a monitor can be **not supported by this vehicle**, which is a
/// formal J1979 state and not a failure. Almost every car reports several as
/// unsupported. Rendering those as "incomplete" would make a perfectly ready
/// vehicle look unready, which is the same class of error as reporting a
/// vehicle clean when it is not — a confident wrong answer, in the other
/// direction.
library;

/// One monitored system, and what this controller says about it.
enum ReadinessState {
  /// Tested and complete. Ready for an emissions test.
  complete,

  /// Supported, and not finished since the last reset. Needs more driving.
  incomplete,

  /// This vehicle does not have this monitor. Not a fault and not a gap.
  unsupported,
}

/// The monitors J1979 defines, in the order an inspector reads them.
enum ReadinessMonitor {
  // The three continuous monitors, from byte B.
  misfire('失火監控', continuous: true),
  fuelSystem('燃油系統監控', continuous: true),
  components('綜合元件監控', continuous: true),

  // The non-continuous monitors, from bytes C and D. Which set applies
  // depends on the ignition type, also carried in byte B.
  catalyst('觸媒轉換器'),
  heatedCatalyst('觸媒加熱'),
  evaporative('蒸發排放系統'),
  secondaryAir('二次空氣噴射'),
  gasolineParticulateFilter('汽油微粒濾清器（GPF）'),
  oxygenSensor('含氧感知器'),
  oxygenSensorHeater('含氧感知器加熱'),
  egr('EGR / VVT 系統'),

  // Compression ignition (diesel) uses the same two bytes for a different set.
  nmhcCatalyst('NMHC 觸媒'),
  noxAftertreatment('NOx / SCR 後處理'),
  boostPressure('增壓壓力'),
  exhaustSensor('排氣感知器'),
  particulateFilter('微粒濾清器');

  const ReadinessMonitor(this.label, {this.continuous = false});

  /// What to call it on screen.
  final String label;

  /// Continuous monitors run whenever the engine does; the rest need a
  /// specific set of conditions — a cold start, a steady cruise — which is why
  /// a car can sit at "incomplete" for days of ordinary driving.
  final bool continuous;
}

/// How this engine is ignited, which decides what bytes C and D mean.
enum IgnitionType {
  /// Petrol. Byte B bit 3 clear.
  spark,

  /// Diesel. Byte B bit 3 set.
  compression,
}

/// One controller's readiness report.
class Readiness {
  const Readiness({
    required this.ignition,
    required this.states,
    this.unnamedSupported = 0,
    this.unnamedOutstanding = 0,
  });

  /// Monitors the vehicle reported as supported that this table has no name
  /// for, finished or not.
  ///
  /// Separate from [unnamedOutstanding] because the two answer opposite
  /// questions. "Is anything unfinished" decides whether the car can be called
  /// ready; "does this controller monitor anything at all" decides whether it
  /// has an opinion worth reporting. Collapsing them made a car that supports
  /// exactly one unnamed monitor, and has completed it, read as a module that
  /// does no emissions monitoring — the over-strict twin of the bug the
  /// counter was added for, in the same commit.
  final int unnamedSupported;

  /// Monitors the vehicle reported as supported and unfinished that this table
  /// has no name for.
  ///
  /// Zero on every car this decoder understands. Non-zero means the vehicle is
  /// using a bit from a revision or a manufacturer this code does not model —
  /// and the only thing that must follow from that is that it cannot be called
  /// ready.
  final int unnamedOutstanding;

  final IgnitionType ignition;

  /// Every monitor this controller described, including the unsupported ones.
  /// Kept rather than filtered, because "this car does not have that monitor"
  /// is an answer somebody comparing against an inspection report needs.
  final Map<ReadinessMonitor, ReadinessState> states;

  /// Decodes bytes B, C and D of a `41 01 A B C D` reply.
  ///
  /// Bit layout from J1979. Byte B: bits 0–2 say whether each continuous
  /// monitor is *supported*, bits 4–6 say whether it is *incomplete*, and bit
  /// 3 is the ignition type. Bytes C and D carry support and incompleteness
  /// for the non-continuous monitors, in the same bit order as each other.
  ///
  /// The two halves are deliberately not collapsed. A bit set in D with its
  /// partner clear in C means "incomplete, and not supported" — a
  /// contradiction the vehicle should not report, and one this reads as
  /// unsupported rather than inventing a state from it.
  factory Readiness.decode(int b, int c, int d) {
    final ignition =
        (b & 0x08) != 0 ? IgnitionType.compression : IgnitionType.spark;

    ReadinessState resolve({required bool supported, required bool incomplete}) {
      if (!supported) return ReadinessState.unsupported;
      return incomplete ? ReadinessState.incomplete : ReadinessState.complete;
    }

    final states = <ReadinessMonitor, ReadinessState>{
      ReadinessMonitor.misfire: resolve(
          supported: b & 0x01 != 0, incomplete: b & 0x10 != 0),
      ReadinessMonitor.fuelSystem: resolve(
          supported: b & 0x02 != 0, incomplete: b & 0x20 != 0),
      ReadinessMonitor.components: resolve(
          supported: b & 0x04 != 0, incomplete: b & 0x40 != 0),
    };

    // Bit n of C is support; bit n of D is incompleteness, for the same
    // monitor.
    const spark = <int, ReadinessMonitor>{
      0: ReadinessMonitor.catalyst,
      1: ReadinessMonitor.heatedCatalyst,
      2: ReadinessMonitor.evaporative,
      3: ReadinessMonitor.secondaryAir,
      // Bit 4. **Not** A/C refrigerant, which is the name half the OBD
      // reference tables on the internet give it: it sat as Reserved in J1979
      // for years and was recently defined as the gasoline particulate
      // filter. The distinction is not pedantry — a car new enough to set this
      // bit is a direct-injection petrol engine with a GPF, and none of them
      // has an A/C refrigerant monitor at all, so the wrong label sends
      // somebody reconciling against an inspection report after a system their
      // car does not have.
      //
      // Leaving the bit out entirely, which is what this did first, is how a
      // car that supports it and has not finished it reported *nothing*
      // outstanding. A bit this table does not know is still a bit the vehicle
      // set.
      4: ReadinessMonitor.gasolineParticulateFilter,
      5: ReadinessMonitor.oxygenSensor,
      6: ReadinessMonitor.oxygenSensorHeater,
      7: ReadinessMonitor.egr,
    };
    const compression = <int, ReadinessMonitor>{
      0: ReadinessMonitor.nmhcCatalyst,
      1: ReadinessMonitor.noxAftertreatment,
      3: ReadinessMonitor.boostPressure,
      5: ReadinessMonitor.exhaustSensor,
      6: ReadinessMonitor.particulateFilter,
      7: ReadinessMonitor.egr,
    };

    final map = ignition == IgnitionType.compression ? compression : spark;
    map.forEach((bit, monitor) {
      states[monitor] = resolve(
        supported: c & (1 << bit) != 0,
        incomplete: d & (1 << bit) != 0,
      );
    });

    // Anything the table above does not name.
    //
    // The specific gap was bit 4 of the petrol set, and fixing only that would
    // leave the same shape waiting for the next revision or the next
    // manufacturer: a monitor this code cannot name is dropped, so a car that
    // supports it and has not finished it reports nothing outstanding and the
    // screen says it is ready. That is a false all-clear about an inspection
    // somebody is about to drive to.
    //
    // Counted rather than named, because naming it would be inventing a
    // meaning. What matters is that it cannot silently become "ready".
    //
    // Both halves are counted, and counting only one was a defect of its own.
    // The first version tracked *outstanding* unnamed bits so they could block
    // "ready" — and then a vehicle whose only supported monitor was unnamed
    // and finished had no named monitor complete either, so it read as a
    // module that reports nothing at all. It had reported something: that it
    // was done.
    var unnamedSupported = 0;
    var unnamedOutstanding = 0;
    for (var bit = 0; bit < 8; bit++) {
      if (map.containsKey(bit)) continue;
      if (c & (1 << bit) == 0) continue;
      unnamedSupported++;
      if (d & (1 << bit) != 0) unnamedOutstanding++;
    }

    return Readiness(
      ignition: ignition,
      states: Map.unmodifiable(states),
      unnamedSupported: unnamedSupported,
      unnamedOutstanding: unnamedOutstanding,
    );
  }

  /// Monitors this vehicle has and has not finished.
  List<ReadinessMonitor> get incomplete => [
        for (final e in states.entries)
          if (e.value == ReadinessState.incomplete) e.key,
      ];

  /// Monitors this vehicle has and has finished.
  List<ReadinessMonitor> get complete => [
        for (final e in states.entries)
          if (e.value == ReadinessState.complete) e.key,
      ];

  /// Monitors this vehicle does not have. Ordinary, and not a gap.
  List<ReadinessMonitor> get unsupported => [
        for (final e in states.entries)
          if (e.value == ReadinessState.unsupported) e.key,
      ];

  /// Whether every monitor this vehicle *has* has finished.
  ///
  /// Says nothing about whether the car would pass an inspection — that also
  /// depends on the fault codes and on how many incomplete monitors the local
  /// rules tolerate — so the name is about the monitors and nothing wider.
  bool get allSupportedComplete =>
      supportsAnything && incomplete.isEmpty && unnamedOutstanding == 0;

  /// Whether this controller monitors anything at all, named or not.
  bool get supportsAnything =>
      complete.isNotEmpty || incomplete.isNotEmpty || unnamedSupported > 0;

  /// True when the controller reported no supported monitors at all.
  ///
  /// Not the same as "ready". A reply of all zeroes is what a module that does
  /// not participate in emissions monitoring sends, and reading it as a clean
  /// bill of health would turn silence into an answer — the mistake this
  /// codebase is organised against.
  bool get saysNothing => !supportsAnything;
}
