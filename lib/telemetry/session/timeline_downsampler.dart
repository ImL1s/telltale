library;

import 'dart:math' as math;

sealed class TimelinePrimitive {
  const TimelinePrimitive({required this.elapsedUs});

  final int elapsedUs;
}

final class TimelineValue extends TimelinePrimitive {
  const TimelineValue({
    required super.elapsedUs,
    required this.value,
    this.segmentId = '',
    this.breakBefore = false,
    this.omittedGapCountBefore = 0,
  });

  final double value;
  final String segmentId;
  final bool breakBefore;
  final int omittedGapCountBefore;

  TimelineValue withOmittedGaps(int count) => TimelineValue(
    elapsedUs: elapsedUs,
    value: value,
    segmentId: segmentId,
    breakBefore: breakBefore || count > 0,
    omittedGapCountBefore: omittedGapCountBefore + count,
  );
}

final class TimelineStatus extends TimelinePrimitive {
  const TimelineStatus({required super.elapsedUs, required this.status});

  final String status;
}

final class TimelineGap extends TimelinePrimitive {
  const TimelineGap({
    required super.elapsedUs,
    this.gapId = '',
    this.omittedGapCount = 0,
  });

  final String gapId;
  final int omittedGapCount;

  TimelineGap withOmittedGaps(int count) => TimelineGap(
    elapsedUs: elapsedUs,
    gapId: gapId,
    omittedGapCount: omittedGapCount + count,
  );
}

/// Bounded, streaming min/max downsampler for one signal lane.
///
/// Every primitive is summarized immediately. Once the lane exceeds its output
/// budget, adjacent summaries are merged. Each summary retains first/last,
/// exact value extrema, a status, and an explicit gap marker carrying the exact
/// number of gaps represented by that marker.
final class TimelineDownsampleAccumulator {
  TimelineDownsampleAccumulator({this.maximumPrimitives = 1200}) {
    if (maximumPrimitives < 1) {
      throw ArgumentError.value(maximumPrimitives);
    }
  }

  final int maximumPrimitives;
  final List<_Bucket> _buckets = <_Bucket>[];
  var _sequence = 0;
  var _compacting = false;

  int get retainedBucketCount => _buckets.length;

  void add(TimelinePrimitive primitive) {
    _buckets.add(_Bucket.single(_Indexed(_sequence++, primitive)));
    if (_buckets.length <= maximumPrimitives && !_compacting) return;
    _compacting = true;
    final target = math.max(1, maximumPrimitives ~/ _maximumBucketCandidates);
    while (_buckets.length > target) {
      final index = _smallestAdjacentPairIndex();
      _buckets[index] = _Bucket.merge(_buckets[index], _buckets[index + 1]);
      _buckets.removeAt(index + 1);
    }
  }

  List<TimelinePrimitive> finish() {
    if (!_compacting) {
      return List<TimelinePrimitive>.unmodifiable(
        _buckets.map((bucket) => bucket.first.primitive),
      );
    }

    final indexed = <_Indexed>[];
    var totalGapCount = 0;
    for (final bucket in _buckets) {
      indexed.addAll(bucket.candidates());
      totalGapCount += bucket.gapCount;
    }
    indexed.sort((left, right) => left.sequence.compareTo(right.sequence));
    final unique = <_Indexed>[];
    for (final candidate in indexed) {
      if (unique.isNotEmpty && unique.last.sequence == candidate.sequence) {
        if (_representedGapCount(candidate.primitive) >
            _representedGapCount(unique.last.primitive)) {
          unique[unique.length - 1] = candidate;
        }
      } else {
        unique.add(candidate);
      }
    }

    final selected = unique.length <= maximumPrimitives
        ? unique
        : _selectBounded(unique, maximumPrimitives);
    _restoreOmittedGapPlacement(unique, selected, totalGapCount);
    return List<TimelinePrimitive>.unmodifiable(
      selected.map((item) => item.primitive),
    );
  }

  int _smallestAdjacentPairIndex() {
    var selected = 0;
    var selectedWeight = _buckets[0].weight + _buckets[1].weight;
    for (var index = 1; index < _buckets.length - 1; index++) {
      final weight = _buckets[index].weight + _buckets[index + 1].weight;
      if (weight < selectedWeight) {
        selected = index;
        selectedWeight = weight;
      }
    }
    return selected;
  }
}

const int _maximumBucketCandidates = 7;

int _representedGapCount(TimelinePrimitive primitive) => switch (primitive) {
  TimelineGap gap => gap.omittedGapCount + 1,
  TimelineValue value => value.omittedGapCountBefore,
  TimelineStatus() => 0,
};

void _restoreOmittedGapPlacement(
  List<_Indexed> candidates,
  List<_Indexed> selected,
  int totalGapCount,
) {
  if (totalGapCount > 0 &&
      !selected.any(
        (item) =>
            item.primitive is TimelineGap || item.primitive is TimelineValue,
      )) {
    final gapCandidate = candidates.firstWhere(
      (item) => _representedGapCount(item.primitive) > 0,
    );
    selected[selected.length - 1] = gapCandidate;
    selected.sort((left, right) => left.sequence.compareTo(right.sequence));
  }
  final selectedSequences = selected.map((item) => item.sequence).toSet();
  for (final candidate in candidates) {
    final count = _representedGapCount(candidate.primitive);
    if (count == 0 || selectedSequences.contains(candidate.sequence)) continue;
    var target = selected.indexWhere(
      (item) =>
          item.sequence >= candidate.sequence &&
          (item.primitive is TimelineGap || item.primitive is TimelineValue),
    );
    if (target < 0) {
      target = selected.lastIndexWhere(
        (item) =>
            item.primitive is TimelineGap || item.primitive is TimelineValue,
      );
    }
    if (target < 0) continue;
    final destination = selected[target];
    selected[target] = _Indexed(
      destination.sequence,
      switch (destination.primitive) {
        TimelineGap gap => gap.withOmittedGaps(count),
        TimelineValue value => value.withOmittedGaps(count),
        TimelineStatus status => status,
      },
    );
  }
  assert(
    selected.fold<int>(
          0,
          (sum, item) => sum + _representedGapCount(item.primitive),
        ) ==
        totalGapCount,
  );
}

List<_Indexed> _selectBounded(List<_Indexed> input, int maximum) {
  if (maximum == 1) return <_Indexed>[input.first];
  final selectedIndexes = <int>{0, input.length - 1};
  final slots = maximum - selectedIndexes.length;
  for (var slot = 1; slot <= slots; slot++) {
    selectedIndexes.add(((slot * (input.length - 1)) / (slots + 1)).round());
  }
  final ordered = selectedIndexes.toList()..sort();
  return <_Indexed>[for (final index in ordered) input[index]];
}

final class _Indexed {
  const _Indexed(this.sequence, this.primitive);

  final int sequence;
  final TimelinePrimitive primitive;
}

final class _Bucket {
  const _Bucket({
    required this.first,
    required this.last,
    required this.minimum,
    required this.maximum,
    required this.status,
    required this.firstGap,
    required this.lastGap,
    required this.gapCount,
    required this.weight,
  });

  factory _Bucket.single(_Indexed value) {
    final primitive = value.primitive;
    return _Bucket(
      first: value,
      last: value,
      minimum: primitive is TimelineValue ? value : null,
      maximum: primitive is TimelineValue ? value : null,
      status: primitive is TimelineStatus ? value : null,
      firstGap: primitive is TimelineGap ? value : null,
      lastGap: primitive is TimelineGap ? value : null,
      gapCount: primitive is TimelineGap ? primitive.omittedGapCount + 1 : 0,
      weight: 1,
    );
  }

  factory _Bucket.merge(_Bucket left, _Bucket right) => _Bucket(
    first: left.first,
    last: right.last,
    minimum: _minimum(left.minimum, right.minimum),
    maximum: _maximum(left.maximum, right.maximum),
    status: left.status ?? right.status,
    firstGap: left.firstGap ?? right.firstGap,
    lastGap: right.lastGap ?? left.lastGap,
    gapCount: left.gapCount + right.gapCount,
    weight: left.weight + right.weight,
  );

  final _Indexed first;
  final _Indexed last;
  final _Indexed? minimum;
  final _Indexed? maximum;
  final _Indexed? status;
  final _Indexed? firstGap;
  final _Indexed? lastGap;
  final int gapCount;
  final int weight;

  Iterable<_Indexed> candidates() sync* {
    yield first;
    if (minimum != null) yield minimum!;
    if (maximum != null) yield maximum!;
    if (status != null) yield status!;
    final firstIndexedGap = firstGap;
    final lastIndexedGap = lastGap;
    if (firstIndexedGap != null) {
      final firstPrimitive = firstIndexedGap.primitive as TimelineGap;
      final firstCount = firstPrimitive.omittedGapCount + 1;
      if (lastIndexedGap == null ||
          lastIndexedGap.sequence == firstIndexedGap.sequence) {
        yield _Indexed(
          firstIndexedGap.sequence,
          firstPrimitive.withOmittedGaps(gapCount - firstCount),
        );
      } else {
        yield firstIndexedGap;
        final lastPrimitive = lastIndexedGap.primitive as TimelineGap;
        final lastCount = lastPrimitive.omittedGapCount + 1;
        yield _Indexed(
          lastIndexedGap.sequence,
          lastPrimitive.withOmittedGaps(gapCount - firstCount - lastCount),
        );
      }
    }
    yield last;
  }
}

_Indexed? _minimum(_Indexed? left, _Indexed? right) {
  if (left == null) return right;
  if (right == null) return left;
  final leftValue = (left.primitive as TimelineValue).value;
  final rightValue = (right.primitive as TimelineValue).value;
  return rightValue < leftValue ? right : left;
}

_Indexed? _maximum(_Indexed? left, _Indexed? right) {
  if (left == null) return right;
  if (right == null) return left;
  final leftValue = (left.primitive as TimelineValue).value;
  final rightValue = (right.primitive as TimelineValue).value;
  return rightValue > leftValue ? right : left;
}

List<TimelinePrimitive> downsampleTimeline(
  List<TimelinePrimitive> input, {
  int maximumPrimitives = 1200,
}) {
  final accumulator = TimelineDownsampleAccumulator(
    maximumPrimitives: maximumPrimitives,
  );
  for (final primitive in input) {
    accumulator.add(primitive);
  }
  return accumulator.finish();
}
