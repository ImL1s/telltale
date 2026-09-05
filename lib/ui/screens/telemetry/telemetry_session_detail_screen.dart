library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../diagnostics/availability.dart';
import '../../../state/telemetry_sessions.dart';
import '../../../telemetry/session/telemetry_session.dart';
import '../../widgets/panel.dart';
import '../../widgets/telemetry/telemetry_status_copy.dart';
import 'telemetry_export_sheet.dart';

class TelemetrySessionDetailScreen extends ConsumerStatefulWidget {
  const TelemetrySessionDetailScreen({required this.sessionId, super.key});

  final String sessionId;

  @override
  ConsumerState<TelemetrySessionDetailScreen> createState() =>
      _TelemetrySessionDetailScreenState();
}

class _TelemetrySessionDetailScreenState
    extends ConsumerState<TelemetrySessionDetailScreen> {
  Timer? _playbackTimer;
  var _playing = false;
  var _speed = 1;
  var _position = 0.0;

  @override
  void dispose() {
    _playbackTimer?.cancel();
    super.dispose();
  }

  void _resetPlaybackForDeniedAccess() {
    _playbackTimer?.cancel();
    _playbackTimer = null;
    _playing = false;
    _position = 0;
  }

  void _togglePlayback(TelemetrySessionReplay replay) {
    if (_playing) {
      _playbackTimer?.cancel();
      setState(() => _playing = false);
      return;
    }
    if (_position >= 1) _position = 0;
    final durationMs = (replay.elapsedDurationUs / 1000).clamp(1, 1 << 31);
    setState(() => _playing = true);
    _playbackTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      final next = _position + ((_speed * 100) / durationMs);
      if (next >= 1) {
        _playbackTimer?.cancel();
        setState(() {
          _position = 1;
          _playing = false;
        });
      } else {
        setState(() => _position = next);
      }
    });
  }

  void _scrub(double value) {
    _playbackTimer?.cancel();
    setState(() {
      _position = value;
      _playing = false;
    });
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _export() async {
    final box = context.findRenderObject() as RenderBox?;
    final origin = box == null
        ? null
        : box.localToGlobal(Offset.zero) & box.size;
    final format = await showTelemetryExportSheet(context);
    if (format == null || !mounted) return;
    final result = await ref
        .read(telemetrySessionActionsProvider)
        .export(widget.sessionId, format, sharePositionOrigin: origin);
    if (!result.isSuccess &&
        result.failure != TelemetrySessionActionFailure.restartRequired) {
      _snack('匯出未完成：${result.message}');
    }
  }

  Future<void> _delete(TelemetrySessionReplay replay) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('刪除本機紀錄？'),
        content: Text('將刪除 ${replay.startedAtUtc.toLocal()} 的紀錄。此操作無法復原。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('刪除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final result = await ref
        .read(telemetrySessionActionsProvider)
        .delete(widget.sessionId, confirmed: true);
    if (!mounted) return;
    if (result.isSuccess) {
      ref.invalidate(telemetrySessionLibraryProvider);
      Navigator.pop(context);
    } else {
      if (result.failure != TelemetrySessionActionFailure.restartRequired) {
        _snack('刪除未完成：${result.message}');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<TelemetryHistoryAccess>(telemetryHistoryAccessProvider, (
      previous,
      next,
    ) {
      if (previous == TelemetryHistoryAccess.permitted &&
          next != TelemetryHistoryAccess.permitted) {
        _resetPlaybackForDeniedAccess();
      }
    });
    final access = ref.watch(telemetryHistoryAccessProvider);
    if (access != TelemetryHistoryAccess.permitted) {
      return Scaffold(
        appBar: AppBar(title: const Text('紀錄回放')),
        body: Center(child: Text(access.message!)),
      );
    }
    final replay = ref.watch(telemetrySessionReplayProvider(widget.sessionId));
    return Scaffold(
      appBar: AppBar(title: const Text('紀錄回放')),
      body: replay.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => const Center(child: Text('無法載入紀錄')),
        data: (result) {
          final value = result.replay;
          if (value == null) {
            return const Center(child: Text('紀錄損壞或無法讀取'));
          }
          return _ReplayBody(
            replay: value,
            playing: _playing,
            speed: _speed,
            position: _position,
            onTogglePlay: () => _togglePlayback(value),
            onSpeed: (value) => setState(() => _speed = value),
            onPosition: _scrub,
            onExport: () => unawaited(_export()),
            onDelete: () => unawaited(_delete(value)),
          );
        },
      ),
    );
  }
}

class _ReplayBody extends StatelessWidget {
  const _ReplayBody({
    required this.replay,
    required this.playing,
    required this.speed,
    required this.position,
    required this.onTogglePlay,
    required this.onSpeed,
    required this.onPosition,
    required this.onExport,
    required this.onDelete,
  });

  final TelemetrySessionReplay replay;
  final bool playing;
  final int speed;
  final double position;
  final VoidCallback onTogglePlay;
  final ValueChanged<int> onSpeed;
  final ValueChanged<double> onPosition;
  final VoidCallback onExport;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.all(Spacing.lg),
    children: [
      Panel(
        child: Wrap(
          spacing: Spacing.lg,
          runSpacing: Spacing.sm,
          children: [
            Text(telemetrySourceLabel(replay.source)),
            Text('${replay.transport} · ${replay.protocol}'),
            Text('${replay.startedAtUtc.toLocal()}'),
            Text('${replay.signalCount} 項訊號'),
            Text('${replay.valueCount} 筆有效值'),
            Text('${replay.statusCount} 個狀態'),
            Text('${replay.gapCount} 個缺口'),
            Text(telemetryTerminalReasonLabel(replay.terminalReason)),
            const Text('離線抽樣回放'),
          ],
        ),
      ),
      const SizedBox(height: Spacing.md),
      const Text(telemetryReplayDisclaimer),
      const SizedBox(height: Spacing.md),
      Wrap(
        spacing: Spacing.sm,
        runSpacing: Spacing.sm,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          FilledButton.icon(
            onPressed: onTogglePlay,
            icon: Icon(playing ? Icons.pause : Icons.play_arrow),
            label: Text(playing ? '暫停' : '播放'),
          ),
          for (final value in const [1, 4, 16])
            ChoiceChip(
              selected: speed == value,
              onSelected: (_) => onSpeed(value),
              label: Text('${value}x'),
            ),
        ],
      ),
      Slider(
        value: position,
        onChanged: onPosition,
        semanticFormatterCallback: (value) => '回放位置 ${(value * 100).round()}%',
      ),
      for (final lane in replay.lanes) ...[
        _ReplayLanePanel(
          lane: lane,
          position: position,
          durationUs: replay.elapsedDurationUs,
          source: replay.source,
        ),
        const SizedBox(height: Spacing.sm),
      ],
      const SizedBox(height: Spacing.md),
      Wrap(
        spacing: Spacing.md,
        runSpacing: Spacing.sm,
        children: [
          FilledButton.icon(
            onPressed: onExport,
            icon: const Icon(Icons.ios_share),
            label: const Text('匯出'),
          ),
          OutlinedButton.icon(
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline),
            label: const Text('刪除'),
          ),
        ],
      ),
    ],
  );
}

class _ReplayLanePanel extends StatelessWidget {
  const _ReplayLanePanel({
    required this.lane,
    required this.position,
    required this.durationUs,
    required this.source,
  });

  final TelemetryReplayLane lane;
  final double position;
  final int durationUs;
  final TelemetrySource source;

  @override
  Widget build(BuildContext context) {
    final gaps = lane.primitives.fold<int>(
      0,
      (count, primitive) =>
          count +
          switch (primitive.kind) {
            TelemetryReplayPrimitiveKind.gap =>
              1 + primitive.omittedGapCountBefore,
            TelemetryReplayPrimitiveKind.value =>
              primitive.omittedGapCountBefore,
            TelemetryReplayPrimitiveKind.status => 0,
          },
    );
    final elapsedUs = (durationUs * position).round();
    double? currentValue;
    String? currentQuality;
    String? currentStatus;
    for (final primitive in lane.primitives) {
      if (primitive.elapsedUs > elapsedUs) break;
      if (primitive.kind == TelemetryReplayPrimitiveKind.value) {
        currentValue = primitive.value;
        currentQuality = primitive.quality;
        currentStatus = null;
      } else if (primitive.kind == TelemetryReplayPrimitiveKind.status) {
        currentValue = null;
        currentQuality = null;
        currentStatus = primitive.status;
      } else {
        currentValue = null;
        currentQuality = null;
      }
    }
    final status = _statusFor(
      value: currentValue,
      quality: currentQuality,
      status: currentStatus,
    );
    final valueLabel = currentValue?.toStringAsFixed(1) ?? '--';
    final title = [
      '${lane.name} · $valueLabel ${lane.unit}',
      if (status.badgeText.isNotEmpty) status.badgeText,
    ].join(' · ');
    return Semantics(
      key: ValueKey('telemetry-replay-lane-${lane.pidId}'),
      label:
          '$title，'
          '${lane.primitives.length} 個抽樣節點，$gaps 個中斷',
      child: Panel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: context.texts.titleMedium),
            const SizedBox(height: Spacing.sm),
            SizedBox(
              height: 88,
              width: double.infinity,
              child: CustomPaint(
                painter: _ReplayLanePainter(
                  primitives: lane.primitives,
                  position: position,
                  durationUs: durationUs,
                  color: Theme.of(context).colorScheme.primary,
                  markerColor: Theme.of(context).colorScheme.error,
                ),
              ),
            ),
            const SizedBox(height: Spacing.sm),
            Text('${lane.primitives.length} 個抽樣節點 · $gaps 個中斷'),
          ],
        ),
      ),
    );
  }

  DatumStatus _statusFor({
    required double? value,
    required String? quality,
    required String? status,
  }) {
    final definition = lane.asDefinition();
    if (value != null) {
      return AvailabilityPolicy.forRecordedEvent(
        definition: definition,
        event: TelemetryEvent.value(
          observedAtUtc: DateTime.utc(1970),
          sourceTimestampUtc: DateTime.utc(1970),
          elapsedUs: 0,
          pidId: lane.pidId,
          value: value,
          quality: switch (quality) {
            'outOfReferenceRange' => TelemetryQuality.outOfReferenceRange,
            'tentativeDecode' => TelemetryQuality.tentativeDecode,
            _ => TelemetryQuality.valid,
          },
        ),
        source: source,
      );
    }
    if (status != null) {
      for (final named in TelemetryStatus.values) {
        if (named.wireName == status) {
          return AvailabilityPolicy.forRecordedEvent(
            definition: definition,
            event: TelemetryEvent.status(
              observedAtUtc: DateTime.utc(1970),
              elapsedUs: 0,
              pidId: lane.pidId,
              status: named,
            ),
            source: source,
          );
        }
      }
    }
    return AvailabilityPolicy.forRecordedDefinition(
      definition: definition,
      source: source,
    );
  }
}

class _ReplayLanePainter extends CustomPainter {
  const _ReplayLanePainter({
    required this.primitives,
    required this.position,
    required this.durationUs,
    required this.color,
    required this.markerColor,
  });

  final List<TelemetryReplayPrimitive> primitives;
  final double position;
  final int durationUs;
  final Color color;
  final Color markerColor;

  @override
  void paint(Canvas canvas, Size size) {
    final values = primitives
        .where(
          (primitive) =>
              primitive.kind == TelemetryReplayPrimitiveKind.value &&
              primitive.value != null,
        )
        .toList(growable: false);
    if (values.isEmpty || durationUs <= 0) return;
    var minimum = values.first.value!;
    var maximum = minimum;
    for (final primitive in values.skip(1)) {
      final value = primitive.value!;
      if (value < minimum) minimum = value;
      if (value > maximum) maximum = value;
    }
    final range = maximum == minimum ? 1.0 : maximum - minimum;
    final path = Path();
    var mustMove = true;
    for (final primitive in primitives) {
      final x = (primitive.elapsedUs / durationUs).clamp(0.0, 1.0) * size.width;
      if (primitive.kind != TelemetryReplayPrimitiveKind.value) {
        mustMove = true;
        canvas.drawLine(
          Offset(x, 0),
          Offset(x, size.height),
          Paint()
            ..color = markerColor.withValues(alpha: 0.55)
            ..strokeWidth = 1,
        );
        continue;
      }
      final value = primitive.value;
      if (value == null) continue;
      if (primitive.breakBefore || primitive.omittedGapCountBefore > 0) {
        mustMove = true;
      }
      final y = size.height - (((value - minimum) / range) * size.height);
      if (mustMove) {
        path.moveTo(x, y);
        mustMove = false;
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
    final cursorX = position.clamp(0.0, 1.0) * size.width;
    canvas.drawLine(
      Offset(cursorX, 0),
      Offset(cursorX, size.height),
      Paint()
        ..color = color.withValues(alpha: 0.7)
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_ReplayLanePainter oldDelegate) =>
      oldDelegate.position != position ||
      oldDelegate.primitives != primitives ||
      oldDelegate.durationUs != durationUs ||
      oldDelegate.color != color ||
      oldDelegate.markerColor != markerColor;
}
