import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/telemetry/session/timeline_downsampler.dart';

void main() {
  test('under-cap input remains unchanged', () {
    final input = List<TimelinePrimitive>.generate(
      20,
      (index) => TimelineValue(elapsedUs: index, value: index.toDouble()),
    );
    expect(downsampleTimeline(input), input);
  });

  test('over-cap output counts every primitive and preserves omitted gaps', () {
    final input = <TimelinePrimitive>[];
    for (var index = 0; index < 3000; index++) {
      input.add(TimelineValue(elapsedUs: index * 10, value: index.toDouble()));
      if (index % 7 == 0) {
        input
          ..add(TimelineStatus(elapsedUs: index * 10 + 1, status: 'stale'))
          ..add(TimelineGap(elapsedUs: index * 10 + 2));
      }
    }
    final output = downsampleTimeline(input);
    expect(output.length, lessThanOrEqualTo(1200));
    expect(output.whereType<TimelineValue>(), isNotEmpty);
    expect(
      output.whereType<TimelineGap>().any((gap) => gap.omittedGapCount > 0) ||
          output.whereType<TimelineValue>().any(
            (value) => value.breakBefore && value.omittedGapCountBefore > 0,
          ),
      isTrue,
    );
    for (var index = 1; index < output.length; index++) {
      expect(
        output[index].elapsedUs,
        greaterThanOrEqualTo(output[index - 1].elapsedUs),
      );
    }
  });

  test('incremental min/max buckets retain a one-sample spike', () {
    final accumulator = TimelineDownsampleAccumulator(maximumPrimitives: 24);
    for (var index = 0; index < 10000; index++) {
      accumulator.add(
        TimelineValue(
          elapsedUs: index,
          value: index == 4321
              ? 9999
              : index.isEven
              ? 1
              : -1,
          segmentId: 'segment-0',
        ),
      );
    }

    final output = accumulator.finish();
    expect(output, hasLength(lessThanOrEqualTo(24)));
    expect(accumulator.retainedBucketCount, lessThanOrEqualTo(4));
    expect(
      output.whereType<TimelineValue>().map((value) => value.value),
      contains(9999),
    );
    expect(output.first.elapsedUs, 0);
    expect(output.last.elapsedUs, 9999);
  });

  test('convenience path has exact parity with incremental accumulation', () {
    final input = List<TimelinePrimitive>.generate(
      4000,
      (index) => TimelineValue(
        elapsedUs: index * 2,
        value: (index % 31).toDouble(),
        segmentId: 'segment-0',
      ),
    );
    final accumulator = TimelineDownsampleAccumulator();
    for (final primitive in input) {
      accumulator.add(primitive);
    }

    final incremental = accumulator.finish();
    final convenience = downsampleTimeline(input);
    expect(convenience.length, incremental.length);
    for (var index = 0; index < convenience.length; index++) {
      expect(convenience[index].elapsedUs, incremental[index].elapsedUs);
      expect(
        (convenience[index] as TimelineValue).value,
        (incremental[index] as TimelineValue).value,
      );
    }
  });

  test('gap identity and exact omitted gap count survive compaction', () {
    final accumulator = TimelineDownsampleAccumulator(maximumPrimitives: 18);
    var totalGaps = 0;
    for (var index = 0; index < 2000; index++) {
      if (index % 13 == 0) {
        accumulator.add(
          TimelineGap(elapsedUs: index * 3, gapId: 'gap-$totalGaps'),
        );
        totalGaps++;
      }
      accumulator.add(
        TimelineValue(
          elapsedUs: index * 3 + 1,
          value: index.toDouble(),
          segmentId: 'segment-$totalGaps',
        ),
      );
    }

    final output = accumulator.finish();
    final representedGaps = output.whereType<TimelineGap>().fold<int>(
      0,
      (sum, gap) => sum + 1 + gap.omittedGapCount,
    );
    final valueOmissions = output.whereType<TimelineValue>().fold<int>(
      0,
      (sum, value) => sum + value.omittedGapCountBefore,
    );
    expect(representedGaps + valueOmissions, totalGaps);
    expect(
      output.whereType<TimelineGap>().every((gap) => gap.gapId.isNotEmpty),
      isTrue,
    );
    expect(
      output.whereType<TimelineValue>().every(
        (value) => value.segmentId.isNotEmpty,
      ),
      isTrue,
    );
  });

  test('multiple omitted gap clusters retain temporal placement', () {
    final input = <TimelinePrimitive>[];
    for (var index = 0; index < 600; index++) {
      if (index == 100 || index == 300 || index == 500) {
        input.add(TimelineGap(elapsedUs: index * 1000, gapId: 'gap-$index'));
      }
      input.add(
        TimelineValue(
          elapsedUs: index * 1000 + 1,
          value: index.toDouble(),
          segmentId: 'segment-${index ~/ 200}',
        ),
      );
    }

    final output = downsampleTimeline(input, maximumPrimitives: 4);
    final positionedBreaks = output.where((primitive) {
      if (primitive is TimelineGap) return true;
      return primitive is TimelineValue &&
          (primitive.breakBefore || primitive.omittedGapCountBefore > 0);
    }).toList();
    final represented = positionedBreaks.fold<int>(0, (sum, primitive) {
      if (primitive is TimelineGap) {
        return sum + primitive.omittedGapCount + 1;
      }
      return sum + (primitive as TimelineValue).omittedGapCountBefore;
    });

    expect(represented, 3);
    expect(
      positionedBreaks.length,
      greaterThanOrEqualTo(2),
      reason: 'separated omitted gaps must not all be attached at one point',
    );
    expect(positionedBreaks.first.elapsedUs, greaterThan(50000));
    expect(positionedBreaks.last.elapsedUs, greaterThan(350000));
  });

  test('four independent lanes remain bounded in aggregate', () {
    final lanes = List.generate(
      4,
      (_) => TimelineDownsampleAccumulator(maximumPrimitives: 1200),
    );
    for (var index = 0; index < 20000; index++) {
      for (var lane = 0; lane < lanes.length; lane++) {
        lanes[lane].add(
          TimelineValue(
            elapsedUs: index,
            value: lane == 3 && index == 19001 ? 100000 : index.toDouble(),
            segmentId: 'lane-$lane',
          ),
        );
      }
    }
    final outputs = lanes.map((lane) => lane.finish()).toList();
    expect(outputs.every((output) => output.length <= 1200), isTrue);
    expect(
      outputs.fold<int>(0, (sum, output) => sum + output.length.toInt()),
      lessThanOrEqualTo(4800),
    );
    expect(
      outputs.last.whereType<TimelineValue>().map((value) => value.value),
      contains(100000),
    );
  });
}
