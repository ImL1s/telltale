/// The polling queue, and the batching that keeps it fed.
///
/// A priority queue rather than a round robin: the gauges a driver is watching
/// need to move, and a temperature that updates every two seconds is still
/// telling the truth. `fastMode` then packs several PIDs into one CAN request
/// where the adapter supports it.
///
/// Ordering, highest first: integer weight, then [PriorityTier] ordinal, then
/// FIFO by enqueue time.
library;

import 'pid.dart';
import 'priority_tier.dart';

/// One queued poll request.
class QueuedRequest implements Comparable<QueuedRequest> {
  final Pid pid;
  final PriorityTier priority;
  final int weight;
  final DateTime enqueuedAt;

  QueuedRequest(this.pid, this.priority, {this.weight = 0, DateTime? enqueuedAt})
      : enqueuedAt = enqueuedAt ?? DateTime.now();

  @override
  int compareTo(QueuedRequest other) {
    if (weight != other.weight) return other.weight.compareTo(weight);
    if (priority.index != other.priority.index) {
      return other.priority.index.compareTo(priority.index);
    }
    return enqueuedAt.compareTo(other.enqueuedAt);
  }

  @override
  String toString() => 'QueuedRequest(${pid.shortName}, ${priority.name}, w=$weight)';
}

/// Throughput statistics surfaced to the UI's connection status strip.
class SchedulerStats {
  final double pidsPerSecond;
  final int corruptionCount;
  final bool fastModeEnabled;
  final Duration interCommandDelay;

  const SchedulerStats({
    required this.pidsPerSecond,
    required this.corruptionCount,
    required this.fastModeEnabled,
    required this.interCommandDelay,
  });
}

class PriorityScheduler {
  /// Kept sorted on insert. A binary-search insert costs O(log n) to locate and
  /// O(n) to shift, which beats re-sorting the whole list per enqueue and is
  /// well within budget for the tens-of-PIDs queues this actually sees.
  final List<QueuedRequest> _queue = [];

  /// Multi-PID batching. Disabled automatically when the ECU starts returning
  /// garbage.
  bool fastModeEnabled = true;

  /// Whether a given PID may share a request with others.
  ///
  /// Session-global permission was too coarse. One verified support block —
  /// `0100` succeeding while `0120` timed out — turned every PID into a batch
  /// candidate, including ones from blocks nothing had confirmed. A
  /// partial-map ECU then answered about the members it implements and omitted
  /// the rest; the short reply tripped the corruption handler and disabled
  /// fast mode for the whole session.
  ///
  /// Batching is a claim that the vehicle will answer about every member, so
  /// it has to be decided per member. Unknown PIDs stay single-request, which
  /// is what keeps useful gauges alive on partial maps and clone adapters.
  bool Function(Pid pid)? isBatchable;

  /// Whether the detected bus supports multi-PID requests at all. Set from the
  /// protocol number once the adapter has actually completed its search.
  bool canBatch = false;

  int corruptionCount = 0;

  /// Throttle between commands, raised on corruption to let the bus settle.
  Duration interCommandDelay = const Duration(milliseconds: 10);

  /// Rolling completion timestamps used to derive PIDs/sec.
  final List<DateTime> _completions = [];

  /// Max PIDs the ELM327 will answer in a single Mode 01 batch. Above this the
  /// reply overruns the adapter's buffer and comes back truncated.
  static const int maxBatchSize = 6;

  int get length => _queue.length;
  bool get isEmpty => _queue.isEmpty;
  bool get isNotEmpty => _queue.isNotEmpty;

  void enqueue(Pid pid, PriorityTier priority, {int weight = 0}) {
    _insertSorted(QueuedRequest(pid, priority, weight: weight));
  }

  void enqueueRequest(QueuedRequest request) => _insertSorted(request);

  void _insertSorted(QueuedRequest item) {
    var low = 0;
    var high = _queue.length;
    while (low < high) {
      final mid = (low + high) >> 1;
      if (item.compareTo(_queue[mid]) < 0) {
        high = mid;
      } else {
        low = mid + 1;
      }
    }
    _queue.insert(low, item);
  }

  QueuedRequest? popNext() => _queue.isEmpty ? null : _queue.removeAt(0);

  /// Drains up to [maxBatchSize] requests that can legally share one frame:
  /// Mode 01 PIDs on the same header as the head of the queue.
  ///
  /// When fastMode is off this returns exactly one request, so the caller's
  /// loop shape is identical in both modes.
  List<QueuedRequest> popBatch() {
    if (_queue.isEmpty) return const [];
    final head = _queue.removeAt(0);
    if (!fastModeEnabled || !canBatch || !head.pid.isMode01) return [head];
    if (!(isBatchable?.call(head.pid) ?? true)) return [head];

    final batch = [head];
    final seen = {head.pid.modeAndPid};
    var i = 0;
    while (i < _queue.length && batch.length < maxBatchSize) {
      final candidate = _queue[i];
      final fitsBatch = candidate.pid.isMode01 &&
          candidate.pid.header == head.pid.header &&
          !seen.contains(candidate.pid.modeAndPid) &&
          (isBatchable?.call(candidate.pid) ?? true);
      if (fitsBatch) {
        seen.add(candidate.pid.modeAndPid);
        batch.add(_queue.removeAt(i));
      } else {
        i++;
      }
    }
    return batch;
  }

  /// Drops queued work for PIDs that are no longer active.
  ///
  /// The queue outlives a definition change: a request built from a variant
  /// the user has just removed stays in it, gets transmitted, costs a cycle on
  /// the vehicle's bus, and produces a reading for a gauge that no longer
  /// exists. Keeping the requests whose ids survive means an ordinary edit
  /// does not restart the whole schedule.
  void retireQueuedRequests(Map<String, Pid> active) {
    // Dropping by id was not enough, and the reason is the ordinary case:
    // editing a formula leaves the id alone. The queued request then survives
    // retirement still carrying the *old* `Pid` object, is dequeued after the
    // swap so the engine's generation check passes, and evaluates raw `0x0A`
    // with `A*10` — publishing 100 for a gauge whose only surviving definition
    // says 10.
    //
    // So survivors are re-pointed at the current definition rather than merely
    // kept. The schedule is preserved, which matters: clearing the queue on
    // every edit would restart the whole rotation.
    //
    // Only the queue. The completions window is a throughput measure —
    // timestamps of recent replies — and describes the link, not any one
    // definition.
    for (var i = _queue.length - 1; i >= 0; i--) {
      final current = active[_queue[i].pid.id];
      if (current == null) {
        _queue.removeAt(i);
      } else if (!identical(current, _queue[i].pid)) {
        final old = _queue[i];
        _queue[i] = QueuedRequest(
          current,
          old.priority,
          weight: old.weight,
          enqueuedAt: old.enqueuedAt,
        );
      }
    }
  }

  void clear() {
    _queue.clear();
    _completions.clear();
  }

  /// Builds the wire command for [requests].
  ///
  /// A batch of Mode 01 PIDs collapses into one frame — `010C`, `0105`, `010D`
  /// become `010C050D` — which is what lifts throughput from ~15 to 60-100
  /// PIDs/sec on CAN vehicles.
  String buildCommand(List<QueuedRequest> requests) {
    if (requests.isEmpty) return '';
    if (!fastModeEnabled || !canBatch || requests.length == 1) {
      return requests.first.pid.modeAndPid;
    }

    final suffixes = <String>[];
    for (final request in requests) {
      final code = request.pid.modeAndPid;
      if (request.pid.isMode01 && request.pid.header == requests.first.pid.header) {
        suffixes.add(code.substring(2));
      }
    }
    if (suffixes.isEmpty) return requests.first.pid.modeAndPid;
    return '01${suffixes.join()}';
  }

  /// Called when a reply came back garbled or the adapter reported BUFFER FULL.
  /// Drops to single-PID mode and backs the throttle off.
  void handleCorruptionEvent() {
    corruptionCount++;
    fastModeEnabled = false;
    interCommandDelay = const Duration(milliseconds: 100);
  }

  /// Restores full-rate polling — used when the user reconnects or explicitly
  /// re-enables fastMode in settings.
  void resetThrottle() {
    fastModeEnabled = true;
    corruptionCount = 0;
    interCommandDelay = const Duration(milliseconds: 10);
  }

  /// Records that [count] PIDs finished, for the throughput readout.
  void recordCompletions(int count) {
    final now = DateTime.now();
    for (var i = 0; i < count; i++) {
      _completions.add(now);
    }
    final cutoff = now.subtract(const Duration(seconds: 1));
    _completions.removeWhere((t) => t.isBefore(cutoff));
  }

  SchedulerStats get stats {
    // Pruned on read, not only on write.
    //
    // The window was trimmed inside `recordCompletions`, which is never called
    // once the bus stops answering — so the throughput pill froze at whatever
    // it last read. A dead link went on advertising 80 PIDs/s, which is the
    // most reassuring possible thing to show a driver whose adapter has come
    // unplugged.
    final cutoff = DateTime.now().subtract(const Duration(seconds: 1));
    _completions.removeWhere((t) => t.isBefore(cutoff));

    return SchedulerStats(
        pidsPerSecond: _completions.length.toDouble(),
        corruptionCount: corruptionCount,
        fastModeEnabled: fastModeEnabled,
        interCommandDelay: interCommandDelay,
      );
  }
}
