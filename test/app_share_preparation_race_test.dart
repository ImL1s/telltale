import 'dart:io';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/core/hash/fnv1a64.dart';
import 'package:torque_obd/core/share/app_share_platform_bridge.dart';
import 'package:torque_obd/core/share/share_lease_ledger.dart';
import 'package:torque_obd/state/app_share_coordinator.dart';
import 'package:torque_obd/state/artifact_operation_gate.dart';

void main() {
  test(
    'permit is checked after awaited chunks and stale speed invokes no share',
    () async {
      final dir = Directory.systemTemp.createTempSync('share-race');
      addTearDown(() => dir.deleteSync(recursive: true));
      final policy = _RevokingPolicy();
      final platform = _NoPlatform();
      final coordinator = AppShareCoordinator(
        rootDirectory: () async => dir,
        policy: policy,
        artifactGate: ArtifactOperationGate(),
        platform: platform,
        idSource: () => 'fedcba9876543210fedcba9876543210',
        nowUtc: () => DateTime.utc(2026),
        availableBytes: (_) async => 64 * 1024 * 1024,
      );
      expect(
        await coordinator.initialize(),
        AppShareInitializationOutcome.ready,
      );
      final outcome = await coordinator.share(
        AppShareRequest(
          sourceKind: ShareSourceKind.rawTranscript,
          subject: 'raw',
          streamFactory: () async* {
            yield [1];
            yield [2];
          },
        ),
      );
      expect(outcome.error, ShareError.shareSafetyChangedSpeedUnknown);
      expect(platform.calls, 0);
    },
  );

  test('failed allocated cleanup retains both ownership gates', () async {
    final dir = Directory.systemTemp.createTempSync('share-cleanup-fail');
    addTearDown(() => dir.deleteSync(recursive: true));
    final gate = ArtifactOperationGate();
    const id = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    final coordinator = AppShareCoordinator(
      rootDirectory: () async => dir,
      policy: _RevokeAfterAllocated(File('${dir.path}/$id.lease.json')),
      artifactGate: gate,
      platform: _NoPlatform(),
      idSource: () => id,
      nowUtc: () => DateTime.utc(2026),
      availableBytes: (_) async => 64 * 1024 * 1024,
      allocatedCleanup: (directory, record) async =>
          throw const FileSystemException('busy'),
    );
    expect(await coordinator.initialize(), AppShareInitializationOutcome.ready);
    final request = AppShareRequest(
      sourceKind: ShareSourceKind.pidCsv,
      subject: 'x',
      streamFactory: () => Stream.value([1]),
    );
    expect(
      (await coordinator.share(request)).error,
      ShareError.shareCleanupRequired,
    );
    expect(gate.snapshot.isIdle, isFalse);
    expect((await coordinator.share(request)).error, ShareError.shareBusy);
  });

  test(
    'racy growth beyond 32 MiB cleans allocated residue before release',
    () async {
      final dir = Directory.systemTemp.createTempSync('share-limit');
      addTearDown(() => dir.deleteSync(recursive: true));
      var openings = 0;
      final gate = ArtifactOperationGate();
      final coordinator = AppShareCoordinator(
        rootDirectory: () async => dir,
        policy: _AlwaysPolicy(),
        artifactGate: gate,
        platform: _NoPlatform(),
        idSource: () => 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        nowUtc: () => DateTime.utc(2026),
        availableBytes: (_) async => 80 * 1024 * 1024,
      );
      expect(
        await coordinator.initialize(),
        AppShareInitializationOutcome.ready,
      );
      final outcome = await coordinator.share(
        AppShareRequest(
          sourceKind: ShareSourceKind.pidCsv,
          subject: 'x',
          streamFactory: () async* {
            openings++;
            if (openings == 1) {
              yield [1];
            } else {
              for (var i = 0; i < 513; i++) {
                yield List<int>.filled(64 * 1024, 1);
              }
            }
          },
        ),
      );
      expect(outcome.error, ShareError.shareSizeLimit);
      expect(gate.snapshot.isIdle, isTrue);
      expect(dir.listSync(), isEmpty);
    },
  );

  test('exact 32 MiB is admitted and verified from disk', () async {
    final dir = Directory.systemTemp.createTempSync('share-exact-limit');
    addTearDown(() => dir.deleteSync(recursive: true));
    const limit = 32 * 1024 * 1024;
    final platform = _NoPlatform();
    final coordinator = AppShareCoordinator(
      rootDirectory: () async => dir,
      policy: _AlwaysPolicy(),
      artifactGate: ArtifactOperationGate(),
      platform: platform,
      idSource: () => 'cdcdcdcdcdcdcdcdcdcdcdcdcdcdcdcd',
      nowUtc: () => DateTime.utc(2026),
      availableBytes: (_) async => 80 * 1024 * 1024,
    );
    expect(await coordinator.initialize(), AppShareInitializationOutcome.ready);
    final outcome = await coordinator.share(
      AppShareRequest(
        sourceKind: ShareSourceKind.telemetryJson,
        subject: 'exact',
        knownByteLength: limit,
        streamFactory: () async* {
          final chunk = List<int>.filled(64 * 1024, 0x61);
          for (var i = 0; i < 512; i++) {
            yield chunk;
          }
        },
      ),
    );
    expect(outcome.result, AppShareResult.selected);
    expect(platform.calls, 1);
  });

  test('source group collision invokes no platform and is preserved', () async {
    final dir = Directory.systemTemp.createTempSync('share-source-collision');
    addTearDown(() => dir.deleteSync(recursive: true));
    const id = 'dededededededededededededededede';
    final platform = _NoPlatform();
    final coordinator = AppShareCoordinator(
      rootDirectory: () async => dir,
      policy: _AlwaysPolicy(),
      artifactGate: ArtifactOperationGate(),
      platform: platform,
      idSource: () => id,
      nowUtc: () => DateTime.utc(2026),
      availableBytes: (_) async => 80 * 1024 * 1024,
    );
    expect(await coordinator.initialize(), AppShareInitializationOutcome.ready);
    var passes = 0;
    final outcome = await coordinator.share(
      AppShareRequest(
        sourceKind: ShareSourceKind.pidCsv,
        subject: 'collision',
        streamFactory: () async* {
          passes++;
          if (passes == 1) {
            File('${dir.path}/$id.csv.share').writeAsBytesSync([9]);
          }
          yield [1];
        },
      ),
    );
    expect(outcome.error, ShareError.shareStagingBusy);
    expect(platform.calls, 0);
    expect(File('${dir.path}/$id.csv.share').readAsBytesSync(), [9]);
  });

  test('never-completing platform keeps cross-feature ownership', () async {
    final dir = Directory.systemTemp.createTempSync('share-never-result');
    addTearDown(() => dir.deleteSync(recursive: true));
    final platform = _NeverPlatform();
    final gate = ArtifactOperationGate();
    final coordinator = AppShareCoordinator(
      rootDirectory: () async => dir,
      policy: _AlwaysPolicy(),
      artifactGate: gate,
      platform: platform,
      idSource: () => 'efefefefefefefefefefefefefefefef',
      nowUtc: () => DateTime.utc(2026),
      availableBytes: (_) async => 80 * 1024 * 1024,
    );
    expect(await coordinator.initialize(), AppShareInitializationOutcome.ready);
    final first = coordinator.share(
      AppShareRequest(
        sourceKind: ShareSourceKind.rawTranscript,
        subject: 'never',
        streamFactory: () => Stream.value([1]),
      ),
    );
    await platform.invoked.future;
    expect(gate.snapshot.isIdle, isFalse);
    expect(
      (await coordinator.share(
        AppShareRequest(
          sourceKind: ShareSourceKind.pidCsv,
          subject: 'blocked',
          streamFactory: () => Stream.value([2]),
        ),
      )).error,
      ShareError.shareBusy,
    );
    platform.result.complete(AppShareResult.dismissed);
    expect((await first).result, AppShareResult.dismissed);
    expect(gate.snapshot.isIdle, isTrue);
  });

  test(
    'revocation after handed-off rename reconstructs and releases safely',
    () async {
      final dir = Directory.systemTemp.createTempSync('share-post-rename');
      addTearDown(() => dir.deleteSync(recursive: true));
      const id = 'acacacacacacacacacacacacacacacac';
      final platform = _NoPlatform();
      final gate = ArtifactOperationGate();
      final coordinator = AppShareCoordinator(
        rootDirectory: () async => dir,
        policy: _RevokeOnDurableHandoff(File('${dir.path}/$id.lease.json')),
        artifactGate: gate,
        platform: platform,
        idSource: () => id,
        nowUtc: () => DateTime.utc(2026),
        availableBytes: (_) async => 80 * 1024 * 1024,
      );
      expect(
        await coordinator.initialize(),
        AppShareInitializationOutcome.ready,
      );
      final outcome = await coordinator.share(
        AppShareRequest(
          sourceKind: ShareSourceKind.pidCsv,
          subject: 'post rename',
          streamFactory: () => Stream.value([1, 2, 3]),
        ),
      );
      expect(outcome.error, ShareError.shareSafetyChangedForeground);
      expect(platform.calls, 0);
      expect(gate.snapshot.isIdle, isTrue);
      final restored = await ShareLeaseLedger(dir).read(id);
      expect(restored!.state, ShareLeaseState.handedOffLease);
      expect(restored.result, startsWith('notInvokedSafetyChanged'));
    },
  );

  test(
    'repeated injected ID preserves handed-off group byte-for-byte',
    () async {
      final dir = Directory.systemTemp.createTempSync('share-id-collision');
      addTearDown(() => dir.deleteSync(recursive: true));
      const id = '45454545454545454545454545454545';
      final bytes = [1, 2, 3];
      final hash = Fnv1a64()..add(bytes);
      final record =
          ShareLeaseRecord.allocated(
            id: id,
            sourceKind: ShareSourceKind.pidCsv,
            createdAtUtc: DateTime.utc(2026),
          ).handedOff(
            bytes: bytes.length,
            fingerprint: hash.fingerprint,
            atUtc: DateTime.utc(2026, 1, 1, 0, 1),
          );
      await ShareLeaseLedger(dir).install(record);
      File('${dir.path}/${record.sourceFileName}').writeAsBytesSync(bytes);
      final before = <String, List<int>>{
        for (final file in dir.listSync().whereType<File>())
          file.path.split(Platform.pathSeparator).last: file.readAsBytesSync(),
      };
      final platform = _NoPlatform();
      var ids = 0;
      final coordinator = AppShareCoordinator(
        rootDirectory: () async => dir,
        policy: _AlwaysPolicy(),
        artifactGate: ArtifactOperationGate(),
        platform: platform,
        idSource: () {
          ids++;
          return id;
        },
        nowUtc: () => DateTime.utc(2026, 1, 1, 0, 2),
        availableBytes: (_) async => 80 * 1024 * 1024,
      );
      expect(
        await coordinator.initialize(),
        AppShareInitializationOutcome.ready,
      );

      final outcome = await coordinator.share(
        AppShareRequest(
          sourceKind: ShareSourceKind.telemetryJson,
          subject: 'collision',
          streamFactory: () => Stream.value([9]),
        ),
      );

      expect(outcome.error, ShareError.shareStagingBusy);
      expect(ids, 8);
      expect(platform.calls, 0);
      final after = <String, List<int>>{
        for (final file in dir.listSync().whereType<File>())
          file.path.split(Platform.pathSeparator).last: file.readAsBytesSync(),
      };
      expect(after, before);
    },
  );

  test(
    'lazy source is not opened before synchronous artifact admission',
    () async {
      final dir = Directory.systemTemp.createTempSync('share-lazy-admission');
      addTearDown(() => dir.deleteSync(recursive: true));
      final gate = ArtifactOperationGate();
      final coordinator = AppShareCoordinator(
        rootDirectory: () async => dir,
        policy: _AlwaysPolicy(),
        artifactGate: gate,
        platform: _NoPlatform(),
        idSource: () => '56565656565656565656565656565656',
        nowUtc: () => DateTime.utc(2026),
        availableBytes: (_) async => 80 * 1024 * 1024,
      );
      expect(
        await coordinator.initialize(),
        AppShareInitializationOutcome.ready,
      );
      final blocker = gate.tryAcquire('other', ArtifactOperation.record);
      var preparations = 0;

      final outcome = await coordinator.share(
        AppShareRequest.lazy(
          sourceKind: ShareSourceKind.recoveredTranscript,
          subject: 'lazy',
          prepareSource: () {
            preparations++;
            return PreparedAppShareSource(
              streamFactory: () => Stream.value([1]),
              knownByteLength: 1,
            );
          },
        ),
      );

      expect(outcome.error, ShareError.artifactBusy);
      expect(preparations, 0);
      gate.release(blocker.token!);
    },
  );

  test(
    'iterator cancel failure retains Share and artifact ownership',
    () async {
      final dir = Directory.systemTemp.createTempSync('share-cancel-fail');
      addTearDown(() => dir.deleteSync(recursive: true));
      final gate = ArtifactOperationGate();
      final policy = _TogglePolicy();
      final coordinator = AppShareCoordinator(
        rootDirectory: () async => dir,
        policy: policy,
        artifactGate: gate,
        platform: _NoPlatform(),
        idSource: () => '67676767676767676767676767676767',
        nowUtc: () => DateTime.utc(2026),
        availableBytes: (_) async => 80 * 1024 * 1024,
      );
      expect(
        await coordinator.initialize(),
        AppShareInitializationOutcome.ready,
      );
      late StreamController<List<int>> stream;
      stream = StreamController<List<int>>(
        onListen: () {
          policy.revoked = true;
          stream.add([1]);
        },
        onCancel: () => Future<void>.error(StateError('cancel failed')),
      );

      final outcome = await coordinator.share(
        AppShareRequest(
          sourceKind: ShareSourceKind.pidCsv,
          subject: 'cancel failure',
          streamFactory: () => stream.stream,
        ),
      );

      expect(outcome.error, ShareError.shareCleanupRequired);
      expect(gate.snapshot.isIdle, isFalse);
      expect(
        (await coordinator.share(
          AppShareRequest(
            sourceKind: ShareSourceKind.pidCsv,
            subject: 'blocked',
            streamFactory: () => Stream.value([2]),
          ),
        )).error,
        ShareError.shareBusy,
      );
    },
  );

  test(
    'never-completing iterator cancel keeps ownership until it settles',
    () async {
      final dir = Directory.systemTemp.createTempSync('share-cancel-never');
      addTearDown(() => dir.deleteSync(recursive: true));
      final gate = ArtifactOperationGate();
      final policy = _TogglePolicy();
      final cancelStarted = Completer<void>();
      final cancelResult = Completer<void>();
      final coordinator = AppShareCoordinator(
        rootDirectory: () async => dir,
        policy: policy,
        artifactGate: gate,
        platform: _NoPlatform(),
        idSource: () => '78787878787878787878787878787878',
        nowUtc: () => DateTime.utc(2026),
        availableBytes: (_) async => 80 * 1024 * 1024,
      );
      expect(
        await coordinator.initialize(),
        AppShareInitializationOutcome.ready,
      );
      late StreamController<List<int>> stream;
      stream = StreamController<List<int>>(
        onListen: () {
          policy.revoked = true;
          stream.add([1]);
        },
        onCancel: () {
          cancelStarted.complete();
          return cancelResult.future;
        },
      );

      final first = coordinator.share(
        AppShareRequest(
          sourceKind: ShareSourceKind.pidCsv,
          subject: 'cancel never',
          streamFactory: () => stream.stream,
        ),
      );
      await cancelStarted.future;
      expect(gate.snapshot.isIdle, isFalse);
      expect(
        (await coordinator.share(
          AppShareRequest(
            sourceKind: ShareSourceKind.pidCsv,
            subject: 'blocked',
            streamFactory: () => Stream.value([2]),
          ),
        )).error,
        ShareError.shareBusy,
      );
      cancelResult.complete();
      expect((await first).error, ShareError.shareSafetyChangedSpeedUnknown);
      expect(gate.snapshot.isIdle, isTrue);
    },
  );

  test(
    'prepared source dispose failure retains ownership for fresh root',
    () async {
      final dir = Directory.systemTemp.createTempSync('share-dispose-fail');
      addTearDown(() => dir.deleteSync(recursive: true));
      final gate = ArtifactOperationGate();
      final coordinator = AppShareCoordinator(
        rootDirectory: () async => dir,
        policy: _AlwaysPolicy(),
        artifactGate: gate,
        platform: _NoPlatform(),
        idSource: () => '89898989898989898989898989898989',
        nowUtc: () => DateTime.utc(2026),
        availableBytes: (_) async => 80 * 1024 * 1024,
      );
      expect(
        await coordinator.initialize(),
        AppShareInitializationOutcome.ready,
      );

      final outcome = await coordinator.share(
        AppShareRequest.lazy(
          sourceKind: ShareSourceKind.recoveredTranscript,
          subject: 'dispose failure',
          prepareSource: () => PreparedAppShareSource(
            streamFactory: () => Stream.value([1]),
            knownByteLength: 1,
            dispose: () => Future<void>.error(StateError('close failed')),
          ),
        ),
      );

      expect(outcome.error, ShareError.shareCleanupRequired);
      expect(gate.snapshot.isIdle, isFalse);
    },
  );
}

class _RevokingPolicy implements AppSharePolicy {
  int validations = 0;
  @override
  SharePreparationPermit? freeze() => const SharePreparationPermit(
    recorderEpoch: 1,
    foregroundEpoch: 1,
    connectionEpoch: 1,
    safetyEpoch: 1,
    connectionClass: ShareConnectionClass.connected,
  );
  @override
  SharePermitValidation validate(SharePreparationPermit permit) =>
      ++validations < 6
      ? const SharePermitValidation.valid()
      : const SharePermitValidation.invalid(SharePermitCause.speedUnknown);
}

class _RevokeAfterAllocated implements AppSharePolicy {
  _RevokeAfterAllocated(this.ledger);

  final File ledger;

  @override
  SharePreparationPermit? freeze() => const SharePreparationPermit(
    recorderEpoch: 1,
    foregroundEpoch: 1,
    connectionEpoch: 1,
    safetyEpoch: 1,
    connectionClass: ShareConnectionClass.disconnected,
  );

  @override
  SharePermitValidation validate(SharePreparationPermit permit) {
    if (ledger.existsSync() &&
        ledger.readAsStringSync().contains('allocated')) {
      return const SharePermitValidation.invalid(SharePermitCause.foreground);
    }
    return const SharePermitValidation.valid();
  }
}

class _AlwaysPolicy implements AppSharePolicy {
  @override
  SharePreparationPermit? freeze() => const SharePreparationPermit(
    recorderEpoch: 1,
    foregroundEpoch: 1,
    connectionEpoch: 1,
    safetyEpoch: 1,
    connectionClass: ShareConnectionClass.disconnected,
  );
  @override
  SharePermitValidation validate(SharePreparationPermit permit) =>
      const SharePermitValidation.valid();
}

class _TogglePolicy implements AppSharePolicy {
  bool revoked = false;

  @override
  SharePreparationPermit? freeze() => const SharePreparationPermit(
    recorderEpoch: 1,
    foregroundEpoch: 1,
    connectionEpoch: 1,
    safetyEpoch: 1,
    connectionClass: ShareConnectionClass.connected,
  );

  @override
  SharePermitValidation validate(SharePreparationPermit permit) => revoked
      ? const SharePermitValidation.invalid(SharePermitCause.speedUnknown)
      : const SharePermitValidation.valid();
}

class _NoPlatform implements AppSharePlatform {
  int calls = 0;
  @override
  Future<AppShareResult> share(AppSharePlatformRequest request) async {
    calls++;
    return AppShareResult.selected;
  }
}

class _NeverPlatform implements AppSharePlatform {
  final invoked = Completer<void>();
  final result = Completer<AppShareResult>();

  @override
  Future<AppShareResult> share(AppSharePlatformRequest request) {
    invoked.complete();
    return result.future;
  }
}

class _RevokeOnDurableHandoff implements AppSharePolicy {
  _RevokeOnDurableHandoff(this.ledger);
  final File ledger;

  @override
  SharePreparationPermit? freeze() => const SharePreparationPermit(
    recorderEpoch: 1,
    foregroundEpoch: 1,
    connectionEpoch: 1,
    safetyEpoch: 1,
    connectionClass: ShareConnectionClass.disconnected,
  );

  @override
  SharePermitValidation validate(SharePreparationPermit permit) {
    if (ledger.existsSync() &&
        ledger.readAsStringSync().contains('handedOffLease')) {
      return const SharePermitValidation.invalid(SharePermitCause.foreground);
    }
    return const SharePermitValidation.valid();
  }
}
