/// How often a PID is worth asking for.
///
/// A dashboard cannot poll everything at once — one ELM327 exchange is one
/// question — so engine speed has to arrive more often than coolant
/// temperature, and the scheduler needs an order to work from.
///
/// Declaration order is load-bearing: [PriorityTier.index] IS the ordinal the
/// scheduler compares, so `high` must remain last.
library;

enum PriorityTier {
  /// One-time PID support discovery.
  veryLow('Very Low'),

  /// Trip logging — ambient temp, VIN, odometer-ish signals.
  low('Low'),

  /// Secondary gauges — coolant, IAT, MAP.
  medium('Medium'),

  /// Real-time primary gauges — RPM, speed, boost.
  high('High');

  const PriorityTier(this.label);

  /// Human-readable name for settings UI.
  final String label;

  static PriorityTier fromName(String? name) {
    if (name == null) return PriorityTier.medium;
    for (final tier in PriorityTier.values) {
      if (tier.name == name) return tier;
    }
    return PriorityTier.medium;
  }

  /// Target refresh interval the scheduler aims for per tier.
  Duration get targetInterval => switch (this) {
        PriorityTier.high => const Duration(milliseconds: 60),
        PriorityTier.medium => const Duration(milliseconds: 250),
        PriorityTier.low => const Duration(seconds: 2),
        PriorityTier.veryLow => const Duration(seconds: 30),
      };
}
