import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/core/share/app_share_platform_bridge.dart';
import 'package:torque_obd/core/share/share_lease_ledger.dart';
import 'package:torque_obd/state/app_share_coordinator.dart';
import 'package:torque_obd/state/artifact_operation_gate.dart';

void main() {
  test(
    'null probe preserves the synchronous validation-to-platform tail',
    () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final outcome = await fixture.coordinator.share(_request());
      expect(outcome.result, AppShareResult.selected);
      expect(fixture.trace.last, 'platform.share');
      expect(fixture.trace[fixture.trace.length - 2], 'policy.validate');
    },
  );

  for (final cut in AppShareCrashCut.values) {
    test(
      '$cut exposes durable state while both ownership gates stay held',
      () async {
        final probe = _HoldingProbe(cut);
        final fixture = await _Fixture.create(probe: probe);
        addTearDown(fixture.dispose);
        final operation = fixture.coordinator.share(_request());
        final snapshot = await probe.ready.future;
        expect(snapshot.cut, cut);
        expect(
          fixture.platform.calls,
          cut == AppShareCrashCut.platformInvoked ? 1 : 0,
        );
        expect(fixture.gate.snapshot.isIdle, isFalse);
        expect(
          (await fixture.coordinator.share(_request())).error,
          ShareError.shareBusy,
        );
        expect(
          fixture.gate
              .tryAcquire('cross-feature', ArtifactOperation.delete)
              .token,
          isNull,
        );
        final record = await ShareLeaseLedger(fixture.root).read(snapshot.id);
        expect(record!.state, snapshot.ledgerState);
        expect(
          File('${fixture.root.path}/${snapshot.sourceFileName}').lengthSync(),
          snapshot.bytes,
        );
        probe.release.complete();
        expect((await operation).result, AppShareResult.selected);
        expect(fixture.trace.last, 'platform.share');
        expect(fixture.trace[fixture.trace.length - 2], 'policy.validate');
      },
    );
  }

  for (final cut in const [
    AppShareCrashCut.sourceVerified,
    AppShareCrashCut.handedOffLeaseVerified,
  ]) {
    test('revocation while $cut is paused invokes no platform', () async {
      final probe = _HoldingProbe(cut);
      final fixture = await _Fixture.create(probe: probe);
      addTearDown(fixture.dispose);
      final operation = fixture.coordinator.share(_request());
      await probe.ready.future;
      fixture.policy.valid = false;
      probe.release.complete();
      final outcome = await operation;
      expect(fixture.platform.calls, 0);
      expect(outcome.error, ShareError.shareSafetyChangedForeground);
      final entries = fixture.root.listSync();
      if (cut == AppShareCrashCut.sourceVerified) {
        expect(entries, isEmpty);
      } else {
        final record = await ShareLeaseLedger(fixture.root)
            .read('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
        expect(record!.state, ShareLeaseState.handedOffLease);
        expect(record.result, 'notInvokedSafetyChanged.foreground');
      }
    });
  }

  test('throwing source probe follows allocated cleanup containment', () async {
    final fixture = await _Fixture.create(
      probe: const _ThrowingProbe(AppShareCrashCut.sourceVerified),
    );
    addTearDown(fixture.dispose);
    expect(
      (await fixture.coordinator.share(_request())).error,
      ShareError.storageFailure,
    );
    expect(fixture.platform.calls, 0);
    expect(fixture.root.listSync(), isEmpty);
    expect(fixture.gate.snapshot.isIdle, isTrue);
  });

  test('throwing handed-off probe retains the valid pending lease', () async {
    final fixture = await _Fixture.create(
      probe: const _ThrowingProbe(AppShareCrashCut.handedOffLeaseVerified),
    );
    addTearDown(fixture.dispose);
    expect(
      (await fixture.coordinator.share(_request())).error,
      ShareError.storageFailure,
    );
    expect(fixture.platform.calls, 0);
    final record = await ShareLeaseLedger(fixture.root)
        .read('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
    expect(record!.state, ShareLeaseState.handedOffLease);
    expect(record.result, 'pending');
  });

  test(
    'platform-invoked probe runs after call and before result await',
    () async {
      final probe = _HoldingProbe(AppShareCrashCut.platformInvoked);
      final fixture = await _Fixture.create(probe: probe);
      addTearDown(fixture.dispose);
      final operation = fixture.coordinator.share(_request());
      final snapshot = await probe.ready.future;
      expect(snapshot.ledgerState, ShareLeaseState.handedOffLease);
      expect(snapshot.result, 'pending');
      expect(fixture.platform.calls, 1);
      expect(fixture.gate.snapshot.isIdle, isFalse);
      var completed = false;
      unawaited(operation.whenComplete(() => completed = true));
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      probe.release.complete();
      expect((await operation).result, AppShareResult.selected);
    },
  );

  test(
    'throwing platform-invoked probe retains pending lease after one call',
    () async {
      final fixture = await _Fixture.create(
        probe: const _ThrowingProbe(AppShareCrashCut.platformInvoked),
      );
      addTearDown(fixture.dispose);
      expect(
        (await fixture.coordinator.share(_request())).error,
        ShareError.storageFailure,
      );
      expect(fixture.platform.calls, 1);
      final record = await ShareLeaseLedger(fixture.root)
          .read('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa');
      expect(record!.state, ShareLeaseState.handedOffLease);
      expect(record.result, 'pending');
    },
  );

  test(
    'final validation reaches platform before its scheduled microtask',
    () async {
      final root = Directory.systemTemp.createTempSync('share-tail-event-loop');
      addTearDown(() => root.deleteSync(recursive: true));
      final policy = _TailPolicy();
      final platform = _TailPlatform(policy);
      final probe = _ArmingHandoffProbe(policy);
      final coordinator = AppShareCoordinator(
        rootDirectory: () async => root,
        policy: policy,
        artifactGate: ArtifactOperationGate(),
        platform: platform,
        idSource: () => 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        nowUtc: () => DateTime.utc(2026),
        availableBytes: (_) async => 64 * 1024 * 1024,
        crashCutProbe: probe,
      );
      expect(
        await coordinator.initialize(),
        AppShareInitializationOutcome.ready,
      );
      expect(
        (await coordinator.share(_request())).result,
        AppShareResult.selected,
      );
      expect(platform.calls, 1);
      await Future<void>.delayed(Duration.zero);
      expect(policy.finalValidationMicrotaskRan, isTrue);
    },
  );
}

AppShareRequest _request() => AppShareRequest(
  sourceKind: ShareSourceKind.pidCsv,
  subject: 'probe',
  streamFactory: () => Stream.value([1, 2, 3, 4]),
);

final class _HoldingProbe implements AppShareCrashCutProbe {
  _HoldingProbe(this.cut);
  final AppShareCrashCut cut;
  final ready = Completer<AppShareCrashCutSnapshot>();
  final release = Completer<void>();

  @override
  Future<void>? pauseAt(AppShareCrashCutSnapshot snapshot) {
    if (snapshot.cut != cut) return null;
    ready.complete(snapshot);
    return release.future;
  }
}

final class _ThrowingProbe implements AppShareCrashCutProbe {
  const _ThrowingProbe(this.cut);
  final AppShareCrashCut cut;
  @override
  Future<void>? pauseAt(AppShareCrashCutSnapshot snapshot) =>
      snapshot.cut == cut
      ? Future<void>.error(StateError('crash probe failed'))
      : null;
}

final class _ArmingHandoffProbe implements AppShareCrashCutProbe {
  _ArmingHandoffProbe(this.policy);
  final _TailPolicy policy;
  @override
  Future<void>? pauseAt(AppShareCrashCutSnapshot snapshot) {
    if (snapshot.cut != AppShareCrashCut.handedOffLeaseVerified) return null;
    policy.armFinalValidation = true;
    return Future<void>.value();
  }
}

final class _Fixture {
  _Fixture(
    this.root,
    this.policy,
    this.platform,
    this.gate,
    this.coordinator,
    this.trace,
  );
  final Directory root;
  final _Policy policy;
  final _Platform platform;
  final ArtifactOperationGate gate;
  final AppShareCoordinator coordinator;
  final List<String> trace;

  static Future<_Fixture> create({AppShareCrashCutProbe? probe}) async {
    final root = Directory.systemTemp.createTempSync('share-crash-probe');
    final trace = <String>[];
    final policy = _Policy(trace);
    final platform = _Platform(trace);
    final gate = ArtifactOperationGate();
    final coordinator = AppShareCoordinator(
      rootDirectory: () async => root,
      policy: policy,
      artifactGate: gate,
      platform: platform,
      idSource: () => 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      nowUtc: () => DateTime.utc(2026),
      availableBytes: (_) async => 64 * 1024 * 1024,
      crashCutProbe: probe,
    );
    expect(await coordinator.initialize(), AppShareInitializationOutcome.ready);
    trace.clear();
    return _Fixture(root, policy, platform, gate, coordinator, trace);
  }

  void dispose() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

final class _Policy implements AppSharePolicy {
  _Policy(this.trace);
  final List<String> trace;
  bool valid = true;
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
    trace.add('policy.validate');
    return valid
        ? const SharePermitValidation.valid()
        : const SharePermitValidation.invalid(SharePermitCause.foreground);
  }
}

final class _Platform implements AppSharePlatform {
  _Platform(this.trace);
  final List<String> trace;
  int calls = 0;
  @override
  Future<AppShareResult> share(AppSharePlatformRequest request) async {
    trace.add('platform.share');
    calls++;
    return AppShareResult.selected;
  }
}

final class _TailPolicy implements AppSharePolicy {
  bool armFinalValidation = false;
  bool finalValidationMicrotaskRan = false;
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
    if (armFinalValidation) {
      armFinalValidation = false;
      scheduleMicrotask(() => finalValidationMicrotaskRan = true);
    }
    return const SharePermitValidation.valid();
  }
}

final class _TailPlatform implements AppSharePlatform {
  _TailPlatform(this.policy);
  final _TailPolicy policy;
  int calls = 0;
  @override
  Future<AppShareResult> share(AppSharePlatformRequest request) {
    expect(policy.finalValidationMicrotaskRan, isFalse);
    calls++;
    return Future.value(AppShareResult.selected);
  }
}
