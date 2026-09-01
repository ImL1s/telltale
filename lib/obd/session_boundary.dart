enum ObdSessionBoundaryReason { userDisconnect, linkLoss, sessionReplacement }

/// Synchronous notice that the named connection generation can accept no more
/// recording events.
class ObdSessionBoundary {
  const ObdSessionBoundary({
    required this.generation,
    required this.observedAtUtc,
    required this.reason,
  });

  final int generation;
  final DateTime observedAtUtc;
  final ObdSessionBoundaryReason reason;
}
