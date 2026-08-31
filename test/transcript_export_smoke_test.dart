/// Desktop hosts must survive a broken share sheet after bytes are prepared.
///
/// The production path goes through [AppShareEntryController] /
/// [AppShareCoordinator]. A platform that returns [AppShareResult.failed]
/// (Linux xdg/`url_launcher`, missing share target, etc.) must not throw; the
/// staged source file must exist; and callers must see [ShareError.shareHandoffFailed]
/// so the UI does not pretend the picker confirmed.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:torque_obd/core/share/app_share_platform_bridge.dart';
import 'package:torque_obd/obd/transcript.dart';
import 'package:torque_obd/state/app_share_coordinator.dart';
import 'package:torque_obd/state/app_share_entry_controller.dart';
import 'package:torque_obd/state/artifact_operation_gate.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('raw transcript share prepares bytes then survives platform failure', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final root = await Directory.systemTemp.createTemp('telltale-export-');
    addTearDown(() => root.delete(recursive: true));

    final platform = _FailingPlatform();
    final coordinator = AppShareCoordinator(
      rootDirectory: () async => root,
      policy: const _AllowPolicy(),
      artifactGate: ArtifactOperationGate(),
      platform: platform,
      idSource: () => 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      nowUtc: () => DateTime.utc(2026, 9, 1),
      availableBytes: (_) async => 64 * 1024 * 1024,
    );
    expect(await coordinator.initialize(), AppShareInitializationOutcome.ready);

    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    final session = container.read(obdSessionProvider.notifier);
    expect(await session.connectDemo(), isTrue);
    final record = session.exportableRecord;
    expect(record, isNotNull);

    final outcome = await AppShareEntryController(coordinator).shareRawTranscript(
      transcript: record!.transcript,
      header: record.header,
      withHex: false,
      subjectAt: DateTime.utc(2026, 9, 1, 12),
    );

    expect(outcome.error, ShareError.shareHandoffFailed);
    expect(outcome.result, AppShareResult.failed);
    expect(
      outcome.userFacingError,
      '檔案已準備完成，但系統分享介面無法開啟。',
    );
    expect(platform.calls, 1);
    expect(platform.lastPath, isNotNull);
    expect(File(platform.lastPath!).existsSync(), isTrue);
    expect(File(platform.lastPath!).lengthSync(), greaterThan(0));
    expect(platform.lastMime, 'text/plain');

    await session.disconnect();
  });

  test('session without transcript has nothing to export', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    final session = container.read(obdSessionProvider.notifier);
    expect(session.exportableRecord, isNull);
    expect(session.hasTranscript, isFalse);
  });

  test('empty transcript share still stages a header-only file', () async {
    final root = await Directory.systemTemp.createTemp('telltale-export-empty-');
    addTearDown(() => root.delete(recursive: true));
    final platform = _FailingPlatform();
    final coordinator = AppShareCoordinator(
      rootDirectory: () async => root,
      policy: const _AllowPolicy(),
      artifactGate: ArtifactOperationGate(),
      platform: platform,
      idSource: () => 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      nowUtc: () => DateTime.utc(2026, 9, 1),
      availableBytes: (_) async => 64 * 1024 * 1024,
    );
    expect(await coordinator.initialize(), AppShareInitializationOutcome.ready);

    final outcome = await AppShareEntryController(coordinator).shareRawTranscript(
      transcript: ObdTranscript(),
      header: 'Header\n',
      withHex: false,
      subjectAt: DateTime.utc(2026, 9, 1, 12),
    );

    expect(outcome.result, AppShareResult.failed);
    expect(outcome.error, ShareError.shareHandoffFailed);
    expect(platform.calls, 1);
    expect(File(platform.lastPath!).readAsStringSync(), contains('Header'));
  });
}

final class _FailingPlatform implements AppSharePlatform {
  int calls = 0;
  String? lastPath;
  String? lastMime;

  @override
  Future<AppShareResult> share(AppSharePlatformRequest request) async {
    calls += 1;
    lastPath = request.path;
    lastMime = request.mimeType;
    return AppShareResult.failed;
  }
}

final class _AllowPolicy implements AppSharePolicy {
  const _AllowPolicy();

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
