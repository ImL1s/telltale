library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../core/hash/fnv1a64.dart';
import '../core/share/app_share_cache.dart';
import '../core/share/app_share_platform_bridge.dart';
import '../core/share/share_lease_ledger.dart';
import 'artifact_operation_gate.dart';

enum ShareConnectionClass { disconnected, connected }

enum SharePermitCause { recorder, connection, moving, speedUnknown, foreground }

enum AppShareCrashCut {
  sourceVerified,
  handedOffLeaseVerified,
  platformInvoked,
}

final class AppShareCrashCutSnapshot {
  const AppShareCrashCutSnapshot({
    required this.cut,
    required this.id,
    required this.sourceKind,
    required this.sourceFileName,
    required this.ledgerFileName,
    required this.ledgerState,
    required this.bytes,
    required this.fingerprint,
    required this.result,
  });

  final AppShareCrashCut cut;
  final String id;
  final ShareSourceKind sourceKind;
  final String sourceFileName;
  final String ledgerFileName;
  final ShareLeaseState ledgerState;
  final int bytes;
  final String fingerprint;
  final String? result;
}

abstract interface class AppShareCrashCutProbe {
  /// Returns null when this cut is not selected, preserving the production
  /// path without introducing an await.
  Future<void>? pauseAt(AppShareCrashCutSnapshot snapshot);
}

class SharePreparationPermit {
  const SharePreparationPermit({
    required this.recorderEpoch,
    required this.foregroundEpoch,
    required this.connectionEpoch,
    required this.safetyEpoch,
    required this.connectionClass,
  });
  final int recorderEpoch;
  final int foregroundEpoch;
  final int connectionEpoch;
  final int safetyEpoch;
  final ShareConnectionClass connectionClass;
}

class SharePermitValidation {
  const SharePermitValidation.valid() : cause = null;
  const SharePermitValidation.invalid(this.cause);
  final SharePermitCause? cause;
  bool get isValid => cause == null;
}

abstract interface class AppSharePolicy {
  SharePreparationPermit? freeze();
  SharePermitValidation validate(SharePreparationPermit permit);
}

final class PreparedAppShareSource {
  const PreparedAppShareSource({
    required this.streamFactory,
    this.knownByteLength,
    this.dispose,
  });

  final Stream<List<int>> Function() streamFactory;
  final int? knownByteLength;
  final Future<void> Function()? dispose;
}

class AppShareRequest {
  AppShareRequest({
    required this.sourceKind,
    required this.subject,
    required Stream<List<int>> Function() streamFactory,
    int? knownByteLength,
  }) : prepareSource = (() => PreparedAppShareSource(
         streamFactory: streamFactory,
         knownByteLength: knownByteLength,
       ));

  const AppShareRequest.lazy({
    required this.sourceKind,
    required this.subject,
    required this.prepareSource,
  });

  final ShareSourceKind sourceKind;
  final String subject;
  final FutureOr<PreparedAppShareSource?> Function() prepareSource;
}

enum ShareError {
  shareBusy,
  artifactBusy,
  policyDenied,
  shareSafetyChangedRecorder,
  shareSafetyChangedConnection,
  shareSafetyChangedMoving,
  shareSafetyChangedSpeedUnknown,
  shareSafetyChangedForeground,
  shareSizeLimit,
  shareStagingBusy,
  shareCleanupRequired,
  shareSpaceUnknown,
  shareNoSpace,
  storageFailure,
}

enum AppShareInitializationOutcome {
  ready,
  policyDenied,
  artifactBusy,
  blocked,
}

class AppShareOutcome {
  const AppShareOutcome({this.result, this.error});
  final AppShareResult? result;
  final ShareError? error;
}

extension AppShareOutcomeMessage on AppShareOutcome {
  String? get userFacingError => switch (error) {
    null => null,
    ShareError.shareBusy || ShareError.artifactBusy => '另一個檔案作業尚未完成。',
    ShareError.policyDenied => '目前的連線或行車狀態不允許匯出。',
    ShareError.shareSafetyChangedRecorder ||
    ShareError.shareSafetyChangedConnection ||
    ShareError.shareSafetyChangedMoving ||
    ShareError.shareSafetyChangedSpeedUnknown ||
    ShareError.shareSafetyChangedForeground => '準備匯出期間狀態已改變，未開啟分享。',
    ShareError.shareSizeLimit => '匯出檔超過 32 MiB 上限。',
    ShareError.shareStagingBusy => '先前的分享檔仍在保留期內，請稍後再試。',
    ShareError.shareCleanupRequired => '分享暫存區需要在重新啟動後檢查。',
    ShareError.shareSpaceUnknown => '無法確認分享檔所需的可用空間。',
    ShareError.shareNoSpace => '儲存空間不足，無法準備分享檔。',
    ShareError.storageFailure => '準備或記錄分享結果時發生儲存錯誤。',
  };
}

class AppShareCoordinator {
  AppShareCoordinator({
    required this.rootDirectory,
    required this.policy,
    required this.artifactGate,
    required this.platform,
    required this.idSource,
    required this.nowUtc,
    required this.availableBytes,
    this.crashCutProbe,
    Future<void> Function(Directory, ShareLeaseRecord)? allocatedCleanup,
  }) : allocatedCleanup = allocatedCleanup ?? _cleanupAllocated;

  final Future<Directory> Function() rootDirectory;
  final AppSharePolicy policy;
  final ArtifactOperationGate artifactGate;
  final AppSharePlatform platform;
  final String Function() idSource;
  final DateTime Function() nowUtc;
  final Future<int?> Function(Directory) availableBytes;
  final AppShareCrashCutProbe? crashCutProbe;
  final Future<void> Function(Directory, ShareLeaseRecord) allocatedCleanup;
  bool _busy = false;
  AppShareInitializationOutcome? _startupOutcome;
  Future<AppShareInitializationOutcome>? _initializationFuture;
  static const _sourceLimit = 32 * 1024 * 1024;
  static const _idAllocationAttempts = 8;

  /// Reconstructs the crash-safe staging cache before routed UI can admit a
  /// Share. Indeterminate cleanup retains root ownership for this process.
  Future<AppShareInitializationOutcome> initialize() {
    final settled = _startupOutcome;
    if (settled != null) return Future.value(settled);
    final active = _initializationFuture;
    if (active != null) return active;
    final operation = _initialize();
    _initializationFuture = operation;
    return operation.whenComplete(() {
      if (identical(_initializationFuture, operation)) {
        _initializationFuture = null;
      }
    });
  }

  Future<AppShareInitializationOutcome> _initialize() async {
    if (_busy) return AppShareInitializationOutcome.artifactBusy;
    _busy = true;
    final artifact = artifactGate.tryAcquire(
      'share-startup',
      ArtifactOperation.recovery,
    );
    if (!artifact.acquired) {
      _busy = false;
      return AppShareInitializationOutcome.artifactBusy;
    }
    final permit = policy.freeze();
    if (permit == null) {
      artifactGate.release(artifact.token!);
      _busy = false;
      return AppShareInitializationOutcome.policyDenied;
    }
    try {
      final root = await rootDirectory();
      _check(permit);
      await AppShareCache(root)
          .reconstructAndClean(nowUtc(), checkpoint: () => _check(permit));
      _check(permit);
      _startupOutcome = AppShareInitializationOutcome.ready;
      artifactGate.release(artifact.token!);
      _busy = false;
      return _startupOutcome!;
    } on Object {
      // Cleanup may already have crossed a durable boundary. Only a fresh
      // process may reconstruct after an indeterminate startup operation.
      _startupOutcome = AppShareInitializationOutcome.blocked;
      return _startupOutcome!;
    }
  }

  /// Synchronous command admission. Startup is completed before routes are
  /// exposed, so Share never waits for reconstruction while a caller-owned
  /// source or descriptor is already open.
  Future<AppShareOutcome> share(AppShareRequest request) {
    final startup = _startupOutcome;
    if (startup != AppShareInitializationOutcome.ready) {
      return Future.value(
        AppShareOutcome(
          error: startup == AppShareInitializationOutcome.policyDenied
              ? ShareError.policyDenied
              : ShareError.shareCleanupRequired,
        ),
      );
    }

    // Command order is deliberate and contains no await: current policy,
    // share mutex, global artifact gate, then the operation permit freeze.
    if (policy.freeze() == null) {
      return Future.value(
        const AppShareOutcome(error: ShareError.policyDenied),
      );
    }
    if (_busy) {
      return Future.value(const AppShareOutcome(error: ShareError.shareBusy));
    }
    _busy = true;
    final owner = 'share-${idSource()}';
    final artifact = artifactGate.tryAcquire(
      owner,
      _operationFor(request.sourceKind),
    );
    final token = artifact.token;
    if (token == null) {
      _busy = false;
      return Future.value(
        const AppShareOutcome(error: ShareError.artifactBusy),
      );
    }
    final permit = policy.freeze();
    if (permit == null) {
      artifactGate.release(token);
      _busy = false;
      return Future.value(
        const AppShareOutcome(error: ShareError.policyDenied),
      );
    }
    return _shareAdmitted(
      request: request,
      owner: owner,
      artifactToken: token,
      permit: permit,
    );
  }

  Future<AppShareOutcome> _shareAdmitted({
    required AppShareRequest request,
    required String owner,
    required ArtifactOperationToken artifactToken,
    required SharePreparationPermit permit,
  }) async {
    var handedOff = false;
    var releaseOwnership = true;
    ShareLeaseRecord? record;
    Directory? ownedRoot;
    PreparedAppShareSource? prepared;
    late AppShareOutcome outcome;

    try {
      outcome = await (() async {
        final root = await rootDirectory();
        ownedRoot = root;
        _check(permit);
        final List<ShareLeaseRecord> existing;
        try {
          existing = await AppShareCache(root)
              .reconstructAndClean(nowUtc(), checkpoint: () => _check(permit));
        } on FileSystemException {
          return const AppShareOutcome(error: ShareError.shareCleanupRequired);
        }
        _check(permit);
        if (existing.length >= AppShareCache.maxSources) {
          return const AppShareOutcome(error: ShareError.shareStagingBusy);
        }

        final pendingSource = request.prepareSource();
        prepared = pendingSource is Future<PreparedAppShareSource?>
            ? await pendingSource
            : pendingSource;
        _check(permit);
        final sourceView = prepared;
        if (sourceView == null) {
          return const AppShareOutcome(error: ShareError.storageFailure);
        }

        var count = sourceView.knownByteLength ?? 0;
        if (count < 0 || count > _sourceLimit) {
          return const AppShareOutcome(error: ShareError.shareSizeLimit);
        }
        if (sourceView.knownByteLength == null) {
          count = await _countSource(sourceView, permit);
          _check(permit);
        }
        final free = await availableBytes(root);
        _check(permit);
        if (free == null) {
          return const AppShareOutcome(error: ShareError.shareSpaceUnknown);
        }
        if (free < count + 8 * 1024 * 1024 + 8192) {
          return const AppShareOutcome(error: ShareError.shareNoSpace);
        }
        if (existing.fold<int>(0, (sum, item) => sum + (item.bytes ?? 0)) +
                count >
            AppShareCache.maxBytes) {
          return const AppShareOutcome(error: ShareError.shareStagingBusy);
        }

        final ledger = ShareLeaseLedger(root);
        ShareLeaseRecord? allocated;
        for (var attempt = 0; attempt < _idAllocationAttempts; attempt++) {
          final id = attempt == 0
              ? owner.substring('share-'.length)
              : idSource();
          _check(permit);
          if (await AppShareCache(root)
              .containsGroup(id, checkpoint: () => _check(permit))) {
            continue;
          }
          final candidate = ShareLeaseRecord.allocated(
            id: id,
            sourceKind: request.sourceKind,
            createdAtUtc: nowUtc(),
          );
          record = candidate;
          try {
            await ledger.install(candidate, checkpoint: () => _check(permit));
            allocated = candidate;
            break;
          } on ShareLeaseCollisionException {
            // A competing allocation won after the full-group preflight.
            // Never adopt or clean a group this operation did not create.
            record = null;
          }
        }
        if (allocated == null) {
          return const AppShareOutcome(error: ShareError.shareStagingBusy);
        }
        record = allocated;
        _check(permit);
        final source = File('${root.path}/${record!.sourceFileName}');
        _check(permit);
        final sourceType = await FileSystemEntity.type(
          source.path,
          followLinks: false,
        );
        _check(permit);
        if (sourceType != FileSystemEntityType.notFound) {
          throw const FileSystemException('share source collision');
        }
        await source.create(exclusive: true);
        _check(permit);
        final sink = await source.open(mode: FileMode.writeOnly);
        _check(permit);
        final written = await _writeSource(
          sink: sink,
          source: sourceView,
          permit: permit,
        );
        _check(permit);
        final verifiedFingerprint = await _verifyWrittenSource(
          source,
          expectedBytes: count,
          checkpoint: () => _check(permit),
        );
        _check(permit);
        if (written.bytes != count ||
            written.fingerprint != verifiedFingerprint) {
          throw const FileSystemException('share source verification failed');
        }
        _check(permit);
        final sourceVerifiedPause = crashCutProbe?.pauseAt(
          AppShareCrashCutSnapshot(
            cut: AppShareCrashCut.sourceVerified,
            id: record!.id,
            sourceKind: record!.sourceKind,
            sourceFileName: record!.sourceFileName,
            ledgerFileName: record!.ledgerFileName,
            ledgerState: ShareLeaseState.allocated,
            bytes: written.bytes,
            fingerprint: written.fingerprint,
            result: null,
          ),
        );
        if (sourceVerifiedPause != null) {
          await sourceVerifiedPause;
          _check(permit);
        }
        final handedOffRecord = record!.handedOff(
          bytes: written.bytes,
          fingerprint: written.fingerprint,
          atUtc: nowUtc(),
        );
        _check(permit);
        final allocatedRecord = record!;
        // Publish the candidate before the awaited atomic transition. If the
        // checkpoint revokes immediately after rename, recovery must preserve
        // the durable handed-off lease rather than delete it as allocated.
        record = handedOffRecord;
        await ledger.transition(
          expected: allocatedRecord,
          next: handedOffRecord,
          checkpoint: () => _check(permit),
        );
        handedOff = true;
        final handedOffPause = crashCutProbe?.pauseAt(
          AppShareCrashCutSnapshot(
            cut: AppShareCrashCut.handedOffLeaseVerified,
            id: record!.id,
            sourceKind: record!.sourceKind,
            sourceFileName: record!.sourceFileName,
            ledgerFileName: record!.ledgerFileName,
            ledgerState: ShareLeaseState.handedOffLease,
            bytes: record!.bytes!,
            fingerprint: record!.fingerprint!,
            result: record!.result,
          ),
        );
        if (handedOffPause != null) {
          await handedOffPause;
        }

        // No await or event-loop yield may appear between this final current
        // policy validation and the native/platform invocation.
        _check(permit);
        final platformFuture = platform.share(
          AppSharePlatformRequest(
            path: source.path,
            mimeType: request.sourceKind.mimeType,
            fileName: 'telltale-${record!.id}.${request.sourceKind.extension}',
            subject: request.subject,
          ),
        );
        // This instrumentation cut is deliberately after the synchronous
        // platform invocation and before awaiting its result. A null probe
        // adds no await or event-loop yield to the production path.
        final platformInvokedPause = crashCutProbe?.pauseAt(
          AppShareCrashCutSnapshot(
            cut: AppShareCrashCut.platformInvoked,
            id: record!.id,
            sourceKind: record!.sourceKind,
            sourceFileName: record!.sourceFileName,
            ledgerFileName: record!.ledgerFileName,
            ledgerState: ShareLeaseState.handedOffLease,
            bytes: record!.bytes!,
            fingerprint: record!.fingerprint!,
            result: record!.result,
          ),
        );
        if (platformInvokedPause != null) {
          await platformInvokedPause;
        }
        final result = await platformFuture;
        try {
          await ledger.transition(
            expected: record!,
            next: record!.withResult(result.name, nowUtc()),
          );
        } on ShareResourceUncontainedException {
          rethrow;
        } on Object {
          return const AppShareOutcome(error: ShareError.storageFailure);
        }
        return AppShareOutcome(result: result);
      })();
    } on ShareResourceUncontainedException {
      releaseOwnership = false;
      outcome = const AppShareOutcome(error: ShareError.shareCleanupRequired);
    } on _SharePermitException catch (error) {
      try {
        if (!handedOff && record?.state == ShareLeaseState.handedOffLease) {
          handedOff = await _isDurableHandoff(record!);
        }
        if (!handedOff && record != null) {
          await allocatedCleanup(ownedRoot ?? await rootDirectory(), record!);
        } else if (handedOff && record != null) {
          try {
            await ShareLeaseLedger(ownedRoot ?? await rootDirectory())
                .transition(
                  expected: record!,
                  next: record!.withResult(
                    'notInvokedSafetyChanged.${error.cause.name}',
                    nowUtc(),
                  ),
                );
          } on ShareResourceUncontainedException {
            rethrow;
          } on Object {
            // The immutable pending handed-off lease is reconstructable.
          }
        }
        outcome = AppShareOutcome(error: _errorFor(error.cause));
      } on Object {
        releaseOwnership = false;
        outcome = const AppShareOutcome(error: ShareError.shareCleanupRequired);
      }
    } on _ShareLimitException {
      try {
        if (!handedOff && record != null) {
          await allocatedCleanup(ownedRoot ?? await rootDirectory(), record!);
        }
        outcome = const AppShareOutcome(error: ShareError.shareSizeLimit);
      } on Object {
        releaseOwnership = false;
        outcome = const AppShareOutcome(error: ShareError.shareCleanupRequired);
      }
    } on Object {
      try {
        if (!handedOff && record?.state == ShareLeaseState.handedOffLease) {
          handedOff = await _isDurableHandoff(record!);
        }
        if (!handedOff && record != null) {
          await allocatedCleanup(ownedRoot ?? await rootDirectory(), record!);
        }
        outcome = const AppShareOutcome(error: ShareError.storageFailure);
      } on Object {
        // Cleanup or descriptor containment was not positively proven. Keep
        // both in-memory ownership tokens for fresh-root reconstruction.
        releaseOwnership = false;
        outcome = const AppShareOutcome(error: ShareError.shareCleanupRequired);
      }
    }

    final dispose = prepared?.dispose;
    if (dispose != null) {
      try {
        await dispose();
      } on Object {
        releaseOwnership = false;
        outcome = const AppShareOutcome(error: ShareError.shareCleanupRequired);
      }
    }
    if (releaseOwnership) {
      artifactGate.release(artifactToken);
      _busy = false;
    }
    return outcome;
  }

  void _check(SharePreparationPermit permit) {
    final validation = policy.validate(permit);
    if (!validation.isValid) throw _SharePermitException(validation.cause!);
  }

  static ShareError _errorFor(SharePermitCause cause) => switch (cause) {
    SharePermitCause.recorder => ShareError.shareSafetyChangedRecorder,
    SharePermitCause.connection => ShareError.shareSafetyChangedConnection,
    SharePermitCause.moving => ShareError.shareSafetyChangedMoving,
    SharePermitCause.speedUnknown => ShareError.shareSafetyChangedSpeedUnknown,
    SharePermitCause.foreground => ShareError.shareSafetyChangedForeground,
  };

  static ArtifactOperation _operationFor(ShareSourceKind kind) =>
      switch (kind) {
        ShareSourceKind.rawTranscript => ArtifactOperation.rawTranscriptShare,
        ShareSourceKind.recoveredTranscript =>
          ArtifactOperation.recoveredTranscriptShare,
        ShareSourceKind.pidCsv => ArtifactOperation.pidCsvShare,
        ShareSourceKind.telemetryCsv ||
        ShareSourceKind.telemetryJson => ArtifactOperation.export,
      };

  static Future<void> _cleanupAllocated(
    Directory root,
    ShareLeaseRecord record,
  ) async {
    await AppShareCache(
      root,
    ).reconstructAndClean(DateTime.fromMillisecondsSinceEpoch(0, isUtc: true));
    for (final path in [
      '${root.path}/${record.sourceFileName}',
      '${root.path}/${record.ledgerFileName}',
      '${root.path}/${record.ledgerFileName}.tmp',
    ]) {
      if (await FileSystemEntity.type(path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const FileSystemException('allocated cleanup not contained');
      }
    }
  }

  static Future<String> _verifyWrittenSource(
    File source, {
    required int expectedBytes,
    required void Function() checkpoint,
  }) async {
    final type = await FileSystemEntity.type(source.path, followLinks: false);
    checkpoint();
    if (type != FileSystemEntityType.file) {
      throw const FileSystemException('share source is not a regular file');
    }
    final hash = Fnv1a64();
    var bytes = 0;
    await for (final chunk in source.openRead()) {
      checkpoint();
      bytes += chunk.length;
      if (bytes > _sourceLimit) throw const _ShareLimitException();
      hash.add(chunk);
    }
    checkpoint();
    if (bytes != expectedBytes) {
      throw const FileSystemException('share source byte count mismatch');
    }
    return hash.fingerprint;
  }

  Future<int> _countSource(
    PreparedAppShareSource source,
    SharePreparationPermit permit,
  ) async {
    final iterator = StreamIterator<List<int>>(source.streamFactory());
    Object? operationError;
    StackTrace? operationStack;
    var count = 0;
    try {
      while (await iterator.moveNext()) {
        _check(permit);
        count += iterator.current.length;
        if (count > _sourceLimit) throw const _ShareLimitException();
      }
      _check(permit);
    } on Object catch (error, stack) {
      operationError = error;
      operationStack = stack;
    }
    try {
      await iterator.cancel();
    } on Object {
      throw const ShareResourceUncontainedException(
        'share count iterator did not cancel',
      );
    }
    if (operationError != null) {
      Error.throwWithStackTrace(operationError, operationStack!);
    }
    _check(permit);
    return count;
  }

  Future<_WrittenShareSource> _writeSource({
    required RandomAccessFile sink,
    required PreparedAppShareSource source,
    required SharePreparationPermit permit,
  }) async {
    final iterator = StreamIterator<List<int>>(source.streamFactory());
    final hash = Fnv1a64();
    Object? operationError;
    StackTrace? operationStack;
    var written = 0;
    try {
      while (await iterator.moveNext()) {
        _check(permit);
        final chunk = iterator.current;
        written += chunk.length;
        if (written > _sourceLimit) throw const _ShareLimitException();
        hash.add(chunk);
        await sink.writeFrom(chunk);
        _check(permit);
        await sink.flush();
        _check(permit);
      }
      await sink.flush();
      _check(permit);
    } on Object catch (error, stack) {
      operationError = error;
      operationStack = stack;
    }

    var iteratorContained = true;
    try {
      await iterator.cancel();
    } on Object {
      iteratorContained = false;
    }
    var sinkContained = true;
    try {
      await sink.close();
    } on Object {
      sinkContained = false;
    }
    if (!iteratorContained || !sinkContained) {
      throw const ShareResourceUncontainedException(
        'share source iterator or file handle did not close',
      );
    }
    if (operationError != null) {
      Error.throwWithStackTrace(operationError, operationStack!);
    }
    _check(permit);
    return _WrittenShareSource(bytes: written, fingerprint: hash.fingerprint);
  }

  Future<bool> _isDurableHandoff(ShareLeaseRecord expected) async {
    try {
      final root = await rootDirectory();
      final restored = await ShareLeaseLedger(root).read(expected.id);
      return restored?.state == ShareLeaseState.handedOffLease &&
          jsonEncode(restored!.toJson()) == jsonEncode(expected.toJson());
    } on ShareResourceUncontainedException {
      rethrow;
    } on Object {
      return false;
    }
  }
}

final class _WrittenShareSource {
  const _WrittenShareSource({required this.bytes, required this.fingerprint});

  final int bytes;
  final String fingerprint;
}

class _SharePermitException implements Exception {
  const _SharePermitException(this.cause);
  final SharePermitCause cause;
}

class _ShareLimitException implements Exception {
  const _ShareLimitException();
}

class _DeniedSharePolicy implements AppSharePolicy {
  const _DeniedSharePolicy();
  @override
  SharePreparationPermit? freeze() => null;
  @override
  SharePermitValidation validate(SharePreparationPermit permit) =>
      const SharePermitValidation.invalid(SharePermitCause.connection);
}

/// Root wiring seam. app.dart must override policy and capacity with the live
/// recorder/connection/speed/lifecycle authority before enabling file Share.
final appSharePolicyProvider = Provider<AppSharePolicy>(
  (ref) => const _DeniedSharePolicy(),
);

final appShareAvailableBytesProvider =
    Provider<Future<int?> Function(Directory)>(
      (ref) =>
          (_) async => null,
    );

/// Platform boundary for the final hand-off. Production keeps the native
/// bridge; isolated rig builds may override this with a capture-only sink so
/// integration tests can inspect the exact immutable bytes without opening an
/// Android chooser or pretending that an external delivery occurred.
final appSharePlatformProvider = Provider<AppSharePlatform>(
  (ref) => const AppSharePlatformBridge(),
);

final appShareCoordinatorProvider = Provider<AppShareCoordinator>((ref) {
  final random = Random.secure();
  String id() => List<int>.generate(
    16,
    (_) => random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return AppShareCoordinator(
    rootDirectory: () async => Directory(
      '${(await getApplicationCacheDirectory()).path}/telltale-app-shares',
    ),
    policy: ref.watch(appSharePolicyProvider),
    artifactGate: ref.watch(artifactOperationGateProvider),
    platform: ref.watch(appSharePlatformProvider),
    idSource: id,
    nowUtc: () => DateTime.now().toUtc(),
    availableBytes: ref.watch(appShareAvailableBytesProvider),
  );
});
