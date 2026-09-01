/// Production filesystem and live-state wiring for telemetry recording.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../obd/pid/pid_library.dart';
import '../obd/telemetry.dart';
import '../obd/transport/obd_transport.dart';
import '../telemetry/session/telemetry_session.dart';
import '../telemetry/session/telemetry_session_codec.dart';
import '../telemetry/session/telemetry_session_store.dart';
import '../telemetry/session/telemetry_session_writer.dart';
import 'obd_session.dart';
import 'telemetry_recorder.dart';

final class TelemetryConnectionSnapshot {
  const TelemetryConnectionSnapshot({
    required this.connected,
    required this.foreground,
    required this.connectionGeneration,
    required this.foregroundEpoch,
  });

  final bool connected;
  final bool foreground;
  final int connectionGeneration;
  final int foregroundEpoch;
}

enum _SpeedClass { stopped, moving, unknown }

/// Synchronous Start authority fed by every telemetry publication.
///
/// Keeping the safety epoch here means a moving/unknown sample cannot vanish
/// between two async Start checkpoints merely because a later stopped sample
/// replaced it in the UI provider.
final class LiveTelemetryStartEnvironment implements TelemetryStartEnvironment {
  LiveTelemetryStartEnvironment({
    required this.readConnection,
    required this.utcNow,
    required this.elapsedUs,
  });

  final TelemetryConnectionSnapshot Function() readConnection;
  final DateTime Function() utcNow;
  final int Function() elapsedUs;
  TelemetrySnapshot _telemetry = const TelemetrySnapshot();
  _SpeedClass? _speedClass;
  int _safetyEpoch = 0;
  TelemetryStartSafetyInvalidation? _safetyInvalidation;

  void observeTelemetry(TelemetrySnapshot telemetry) {
    _telemetry = telemetry;
    _observeSpeedClass(_classify(telemetry, utcNow().toUtc()));
  }

  /// Revokes Start authority while the upstream provider is loading, failed,
  /// or otherwise has no current authoritative snapshot.
  void revokeTelemetryAuthority() {
    observeTelemetry(const TelemetrySnapshot());
  }

  @override
  TelemetryStartEnvironmentSnapshot snapshot(String checkpoint) {
    final connection = readConnection();
    final now = utcNow().toUtc();
    final elapsed = elapsedUs();
    final reading = _freshSpeed(_telemetry, now);
    _observeSpeedClass(
      reading == null
          ? _SpeedClass.unknown
          : reading.value <= 5
          ? _SpeedClass.stopped
          : _SpeedClass.moving,
    );
    final remaining = reading == null
        ? Duration.zero
        : reading.maxAge - now.difference(reading.timestamp.toUtc());
    final boundedRemainingUs = reading == null
        ? 0
        : min(reading.maxAge.inMicroseconds, max(0, remaining.inMicroseconds));
    return TelemetryStartEnvironmentSnapshot(
      connected: connection.connected,
      foreground: connection.foreground,
      connectionGeneration: connection.connectionGeneration,
      foregroundEpoch: connection.foregroundEpoch,
      safetyEpoch: _safetyEpoch,
      speedKnown: reading != null,
      speedKmh: reading?.value ?? double.nan,
      speedFreshUntilElapsedUs: elapsed + boundedRemainingUs,
      observedElapsedUs: elapsed,
      safetyInvalidation: _safetyInvalidation,
    );
  }

  void _observeSpeedClass(_SpeedClass next) {
    final previous = _speedClass;
    if (previous == _SpeedClass.stopped && next != _SpeedClass.stopped) {
      _safetyEpoch++;
      _safetyInvalidation = next == _SpeedClass.moving
          ? TelemetryStartSafetyInvalidation.moving
          : TelemetryStartSafetyInvalidation.speedUnknown;
    }
    _speedClass = next;
  }

  static _SpeedClass _classify(TelemetrySnapshot telemetry, DateTime now) {
    final reading = _freshSpeed(telemetry, now);
    if (reading == null) return _SpeedClass.unknown;
    return reading.value <= 5 ? _SpeedClass.stopped : _SpeedClass.moving;
  }

  static Reading? _freshSpeed(TelemetrySnapshot telemetry, DateTime now) {
    final id = PidLibrary.vehicleSpeed.id;
    if (telemetry.faults.containsKey(id)) return null;
    final reading = telemetry.readings[id];
    if (reading == null ||
        !reading.value.isFinite ||
        reading.timestamp.toUtc().isAfter(now.toUtc()) ||
        reading.isStaleAt(now)) {
      return null;
    }
    return reading;
  }
}

/// Adapts the canonical session store to the root recording controller.
final class FileTelemetryRecorderStorage implements TelemetryRecorderStorage {
  FileTelemetryRecorderStorage(
    this.store, {
    Future<TelemetryAppendSink> Function(File file)? appendSinkForFile,
  }) : _appendSinkForFile =
           appendSinkForFile ??
           ((file) async =>
               FileTelemetryAppendSink(await file.open(mode: FileMode.append)));

  final TelemetrySessionStore store;
  final Future<TelemetryAppendSink> Function(File file) _appendSinkForFile;
  TelemetryQuotaSnapshot? _lastQuota;

  @override
  Future<void> prepareDirectory({
    void Function(String checkpoint)? checkpoint,
  }) async {
    // The store owns and validates its directory. A quota scan is the narrow
    // public operation that creates it without exposing paths to this layer.
    _lastQuota = await store.scanQuota(checkpoint: checkpoint);
    checkpoint?.call('storage.afterDirectoryPreparation');
  }

  @override
  Future<TelemetryStorageQuota> scanQuota({
    void Function(String checkpoint)? checkpoint,
  }) async {
    final quota = await store.scanQuota(checkpoint: checkpoint);
    checkpoint?.call('storage.afterQuotaScan');
    _lastQuota = quota;
    final rejection = quota.groupCount >= TelemetryQuota.groupLimit
        ? TelemetryQuotaRejection.libraryGroupLimit
        : quota.remainingLibraryBytes <= 0
        ? TelemetryQuotaRejection.libraryByteLimit
        : null;
    return TelemetryStorageQuota(
      effectiveSessionLimit: quota.effectiveSessionLimit,
      sessionLimitIsLibraryBound: quota.sessionLimitIsLibraryBound,
      rejection: rejection,
    );
  }

  @override
  Future<TelemetryStagingWriter> createExclusive(
    TelemetrySessionHeader Function(String sessionId) headerForId, {
    required TelemetryStorageQuota quota,
    void Function(String checkpoint)? checkpoint,
  }) async {
    final probeHeader = headerForId('00000000000000000000000000000000');
    final minimalValueBytes = _minimalValueLineBytes(probeHeader);
    if (TelemetrySessionCodec.encodeHeaderLine(probeHeader).length +
            TelemetryQuota.footerReserveBytes +
            minimalValueBytes >
        quota.effectiveSessionLimit) {
      throw const TelemetryStorageCreateException(
        TelemetryStorageCreateFailure.noRoomForValue,
      );
    }
    final scanned = _lastQuota;
    if (scanned == null ||
        scanned.effectiveSessionLimit != quota.effectiveSessionLimit ||
        scanned.sessionLimitIsLibraryBound !=
            quota.sessionLimitIsLibraryBound) {
      if (quota.effectiveSessionLimit <= 0) {
        throw const TelemetryStorageCreateException(
          TelemetryStorageCreateFailure.noRoomForValue,
        );
      }
      throw const TelemetryStorageCreateException(
        TelemetryStorageCreateFailure.staleQuota,
      );
    }

    TelemetrySessionHeader? durableHeader;
    List<int>? durableHeaderLine;
    final created = await store.createStaging(
      headerLineForId: (id) {
        final header = headerForId(id);
        final line = TelemetrySessionCodec.encodeHeaderLine(header);
        durableHeader = header;
        durableHeaderLine = line;
        return line;
      },
      minimalValueLineBytes: minimalValueBytes,
      checkpoint: checkpoint,
    );
    if (created.outcome != TelemetryCreateOutcome.created) {
      throw TelemetryStorageCreateException(switch (created.outcome) {
        TelemetryCreateOutcome.invalidHeader =>
          TelemetryStorageCreateFailure.invalidHeader,
        TelemetryCreateOutcome.noRoomForValue =>
          TelemetryStorageCreateFailure.noRoomForValue,
        TelemetryCreateOutcome.idCollision =>
          TelemetryStorageCreateFailure.idCollision,
        TelemetryCreateOutcome.libraryGroupLimit ||
        TelemetryCreateOutcome.libraryByteLimit =>
          TelemetryStorageCreateFailure.staleQuota,
        TelemetryCreateOutcome.uncontainedFailure =>
          TelemetryStorageCreateFailure.uncontainedFailure,
        _ => TelemetryStorageCreateFailure.storageFailure,
      });
    }
    try {
      checkpoint?.call('storage.afterCreateStaging');
    } on Object catch (error, stackTrace) {
      final cleanup = await store.deleteStaging(created.sessionId!);
      if (cleanup != TelemetryDeleteOutcome.deleted &&
          cleanup != TelemetryDeleteOutcome.notFound) {
        throw const TelemetryStorageCreateException(
          TelemetryStorageCreateFailure.uncontainedFailure,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    final file = created.file!;
    final header = durableHeader;
    final headerLine = durableHeaderLine;
    if (header == null ||
        headerLine == null ||
        header.sessionId != created.sessionId) {
      final cleanup = await store.deleteStaging(created.sessionId!);
      throw TelemetryStorageCreateException(
        cleanup == TelemetryDeleteOutcome.deleted ||
                cleanup == TelemetryDeleteOutcome.notFound
            ? TelemetryStorageCreateFailure.storageFailure
            : TelemetryStorageCreateFailure.uncontainedFailure,
      );
    }
    try {
      checkpoint?.call('storage.beforeAppendReopen');
    } on Object catch (error, stackTrace) {
      final cleanup = await store.deleteStaging(created.sessionId!);
      if (cleanup != TelemetryDeleteOutcome.deleted &&
          cleanup != TelemetryDeleteOutcome.notFound) {
        throw const TelemetryStorageCreateException(
          TelemetryStorageCreateFailure.uncontainedFailure,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }

    late final TelemetryAppendSink sink;
    try {
      sink = await _appendSinkForFile(file);
    } on Object {
      final cleanup = await store.deleteStaging(created.sessionId!);
      if (cleanup == TelemetryDeleteOutcome.deleted ||
          cleanup == TelemetryDeleteOutcome.notFound) {
        throw const TelemetryStorageCreateException(
          TelemetryStorageCreateFailure.storageFailure,
        );
      }
      throw const TelemetryStorageCreateException(
        TelemetryStorageCreateFailure.uncontainedFailure,
      );
    }
    try {
      checkpoint?.call('storage.afterAppendReopen');
    } on Object catch (error, stackTrace) {
      try {
        await sink.close();
      } on Object {
        throw const TelemetryStorageCreateException(
          TelemetryStorageCreateFailure.uncontainedFailure,
        );
      }
      final cleanup = await store.deleteStaging(created.sessionId!);
      if (cleanup != TelemetryDeleteOutcome.deleted &&
          cleanup != TelemetryDeleteOutcome.notFound) {
        throw const TelemetryStorageCreateException(
          TelemetryStorageCreateFailure.uncontainedFailure,
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    final writer = TelemetrySessionWriter(
      sink: sink,
      bytesAlreadyWritten: headerLine.length,
      effectiveSessionLimit: created.effectiveSessionLimit!,
      sessionLimitIsLibraryBound: created.sessionLimitIsLibraryBound!,
    );
    return _FileTelemetryStagingWriter(
      store: store,
      sessionId: created.sessionId!,
      staging: file,
      header: header,
      headerLine: headerLine,
      writer: writer,
    );
  }

  static int _minimalValueLineBytes(TelemetrySessionHeader header) {
    var minimum = TelemetrySessionCodec.maximumEventOrFooterLineBytes + 1;
    for (final signal in header.signals) {
      final timestamp = header.startedAtUtc;
      final length = TelemetrySessionCodec.encodeEventLine(
        TelemetryEvent.value(
          observedAtUtc: timestamp,
          sourceTimestampUtc: timestamp,
          elapsedUs: 0,
          pidId: signal.definition.id,
          value: 0,
        ),
      ).length;
      minimum = min(minimum, length);
    }
    return minimum;
  }
}

final class _FileTelemetryStagingWriter
    implements TelemetryStagingWriter, TelemetryAppendFailureNotifier {
  _FileTelemetryStagingWriter({
    required this.store,
    required this.sessionId,
    required this.staging,
    required this.header,
    required List<int> headerLine,
    required this.writer,
  }) : _headerLine = List<int>.unmodifiable(headerLine) {
    _partialCheckpoint = Timer.periodic(
      TelemetrySessionWriter.partialCheckpointInterval,
      (_) => unawaited(_checkpointPartial()),
    );
  }

  final TelemetrySessionStore store;
  final String sessionId;
  final File staging;
  @override
  final TelemetrySessionHeader header;
  final List<int> _headerLine;
  final TelemetrySessionWriter writer;
  bool _headerAccepted = false;
  Timer? _partialCheckpoint;
  bool _partialCheckpointBusy = false;

  void _stopPartialCheckpoint() {
    _partialCheckpoint?.cancel();
    _partialCheckpoint = null;
  }

  Future<void> _checkpointPartial() async {
    if (_partialCheckpointBusy) return;
    _partialCheckpointBusy = true;
    try {
      await writer.checkpointPartial();
    } on Object {
      // Append-failure handler already closes acceptance.
    } finally {
      _partialCheckpointBusy = false;
    }
  }

  @override
  int get bytesBeforeFooter => writer.bytesBeforeFooter;

  @override
  void setAppendFailureHandler(void Function()? handler) {
    writer.setAppendFailureHandler(handler);
  }

  @override
  Future<void> appendHeader(List<int> line) async {
    if (_headerAccepted || !_sameBytes(line, _headerLine)) {
      throw const TelemetryStorageCreateException(
        TelemetryStorageCreateFailure.invalidHeader,
      );
    }
    // TelemetrySessionStore atomically created and flushed this exact header.
    // Accept the controller callback, but never append a duplicate line.
    _headerAccepted = true;
  }

  @override
  Future<void> flushHeader() => writer.sink.flush();

  @override
  TelemetryAppendResult tryAppendEvent(List<int> line) {
    if (!_headerAccepted) return TelemetryAppendResult.closed;
    return writer.tryAppendLine(line);
  }

  @override
  Future<TelemetryCloseResult> closeForAbort() async {
    _stopPartialCheckpoint();
    try {
      await writer.closeForAbort();
      return TelemetryCloseResult.closed;
    } on Object {
      return TelemetryCloseResult.failed;
    }
  }

  @override
  Future<TelemetryCleanupResult> deleteZeroValue() async {
    final result = await store.deleteStaging(sessionId);
    return switch (result) {
      TelemetryDeleteOutcome.deleted => TelemetryCleanupResult.deleted,
      TelemetryDeleteOutcome.notFound => TelemetryCleanupResult.contained,
      _ => TelemetryCleanupResult.failed,
    };
  }

  @override
  Future<TelemetryFinalizeResult> finalizeAndInstall(
    TelemetrySessionFooter footer,
  ) async {
    _stopPartialCheckpoint();
    try {
      if (footer.bytesBeforeFooter != writer.bytesBeforeFooter) {
        return TelemetryFinalizeResult.uncontainedFailure;
      }
      await writer.finalize(
        footerLine: TelemetrySessionCodec.encodeFooterLine(footer),
      );
      final installed = await store.install(sessionId);
      if (installed == TelemetryInstallOutcome.installed) {
        return TelemetryFinalizeResult.installed;
      }
    } on Object {
      // The staging artifact is intentionally preserved for strict recovery.
    }
    return writer.closeSucceeded &&
            await store.stagingIsStableRegularFile(sessionId)
        ? TelemetryFinalizeResult.preservedFailure
        : TelemetryFinalizeResult.uncontainedFailure;
  }

  static bool _sameBytes(List<int> first, List<int> second) {
    if (first.length != second.length) return false;
    for (var index = 0; index < first.length; index++) {
      if (first[index] != second[index]) return false;
    }
    return true;
  }
}

TelemetrySource telemetrySourceForConnection({
  required TransportKind transport,
  required bool requiresSimulatedEvidence,
}) => deriveTelemetrySource(
  transport: transport,
  requiresSimulatedEvidence: requiresSimulatedEvidence,
);

final class TelemetryConnectionEvidence {
  const TelemetryConnectionEvidence({
    required this.source,
    required this.transport,
    required this.protocol,
  });

  final TelemetrySource source;
  final TransportKind transport;
  final String protocol;
}

final telemetrySessionStoreProvider = Provider<TelemetrySessionStore>(
  (ref) => TelemetrySessionStore(),
);

final _telemetryClockProvider = Provider<_TelemetryClock>(
  (ref) => _TelemetryClock(),
);

final liveTelemetryStartEnvironmentProvider =
    Provider<LiveTelemetryStartEnvironment>((ref) {
      final clock = ref.read(_telemetryClockProvider);
      final environment = LiveTelemetryStartEnvironment(
        readConnection: () {
          final state = ref.read(obdSessionProvider);
          final session = ref.read(obdSessionProvider.notifier);
          return TelemetryConnectionSnapshot(
            connected: state.isConnected,
            foreground: session.isForeground,
            connectionGeneration: session.generation,
            foregroundEpoch: session.pauseEpoch,
          );
        },
        utcNow: clock.utcNow,
        elapsedUs: clock.elapsedUs,
      );
      final initial = ref.read(telemetryProvider);
      final initialValue = authoritativeTelemetryValue(initial);
      if (initialValue != null) {
        environment.observeTelemetry(initialValue);
      } else {
        environment.revokeTelemetryAuthority();
      }
      ref.listen(telemetryProvider, (_, next) {
        final value = authoritativeTelemetryValue(next);
        if (value != null) {
          environment.observeTelemetry(value);
        } else {
          environment.revokeTelemetryAuthority();
        }
      });
      return environment;
    });

final productionTelemetryRecorderRuntimeProvider =
    Provider<TelemetryRecorderRuntime>((ref) {
      final clock = ref.watch(_telemetryClockProvider);
      return TelemetryRecorderRuntime(
        environment: ref.watch(liveTelemetryStartEnvironmentProvider),
        storage: FileTelemetryRecorderStorage(
          ref.watch(telemetrySessionStoreProvider),
        ),
        utcNow: clock.utcNow,
        elapsedUs: clock.elapsedUs,
      );
    });

final currentTelemetryConnectionEvidenceProvider =
    Provider<TelemetryConnectionEvidence?>((ref) {
      final state = ref.watch(obdSessionProvider);
      if (!state.isConnected || state.kind == null || state.protocol.isEmpty) {
        return null;
      }
      final session = ref.read(obdSessionProvider.notifier);
      return TelemetryConnectionEvidence(
        source: telemetrySourceForConnection(
          transport: state.kind!,
          requiresSimulatedEvidence: session.requiresSimulatedEvidence,
        ),
        transport: state.kind!,
        protocol: state.protocol,
      );
    });

final class _TelemetryClock {
  _TelemetryClock() : _stopwatch = Stopwatch()..start();

  final Stopwatch _stopwatch;

  DateTime utcNow() => DateTime.now().toUtc();
  int elapsedUs() => _stopwatch.elapsedMicroseconds;
}
