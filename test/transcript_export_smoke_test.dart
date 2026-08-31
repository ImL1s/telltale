/// Transcript export must write a real file and survive a broken share sheet.
///
/// Desktop (especially Linux xdg/`url_launcher`) can fail the share step while
/// the bytes are still the useful artifact. The path must return an error
/// string rather than throw, and the file must exist before share is invoked.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/ui/widgets/transcript_export.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('export writes bytes then reports a share failure without crash', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final dir = await Directory.systemTemp.createTemp('telltale-export-');
    addTearDown(() => dir.delete(recursive: true));

    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    final session = container.read(obdSessionProvider.notifier);
    expect(await session.connectDemo(), isTrue);
    expect(session.hasTranscript, isTrue);

    ShareParams? seen;
    final error = await exportSessionTranscript(
      session,
      withHex: false,
      temporaryDirectory: () async => dir,
      share: (params) async {
        seen = params;
        throw StateError('share sheet unavailable');
      },
    );

    expect(error, contains('匯出失敗'));
    expect(seen, isNotNull);
    expect(seen!.files, isNotNull);
    expect(seen!.files, isNotEmpty);
    final path = seen!.files!.single.path;
    expect(File(path).existsSync(), isTrue);
    expect(File(path).lengthSync(), greaterThan(0));
    expect(seen!.files!.single.mimeType, 'text/plain');

    await session.disconnect();
  });

  test('export without a session says so instead of throwing', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    final error = await exportSessionTranscript(
      container.read(obdSessionProvider.notifier),
      withHex: false,
    );
    expect(error, '沒有可匯出的紀錄。');
  });
}
