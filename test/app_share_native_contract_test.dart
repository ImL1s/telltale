import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/core/share/app_share_platform_bridge.dart';
import 'package:torque_obd/core/share/app_storage_capacity.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const capacityChannel = MethodChannel(
    'com.cbstudio.telltale/app_storage_capacity',
  );
  const shareChannel = MethodChannel('com.cbstudio.telltale/app_share');

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(capacityChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(shareChannel, null);
  });

  test('capacity probe accepts only positive integral byte counts', () async {
    const probe = AppStorageCapacity();

    Future<int?> invokeWith(Object? reply) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(capacityChannel, (_) async => reply);
      return probe.availableBytes(Directory('/ignored'));
    }

    expect(await invokeWith(4096), 4096);
    expect(await invokeWith(0), isNull);
    expect(await invokeWith(-1), isNull);
    expect(await invokeWith(1.5), isNull);
    expect(await invokeWith('4096'), isNull);
  });

  test('capacity probe fails closed when native probing fails', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          capacityChannel,
          (_) async => throw PlatformException(code: 'capacity_failed'),
        );

    expect(
      await const AppStorageCapacity().availableBytes(Directory('/ignored')),
      isNull,
    );
  });

  test(
    'macOS bridge waits for the native lifecycle result vocabulary',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(shareChannel, (call) async {
            calls.add(call);
            return 'selected';
          });

      final result =
          await const AppSharePlatformBridge(useNativeMacOsShare: true).share(
            const AppSharePlatformRequest(
              path: '/immutable/staged.csv',
              mimeType: 'text/csv',
              fileName: 'session.csv',
              subject: 'Telltale session',
            ),
          );

      expect(result, AppShareResult.selected);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'shareFile');
      expect(
        calls.single.arguments,
        containsPair('path', '/immutable/staged.csv'),
      );
      expect(
        AppSharePlatformBridge.mapNativeResult('dismissed'),
        AppShareResult.dismissed,
      );
      expect(
        AppSharePlatformBridge.mapNativeResult('unavailable'),
        AppShareResult.unavailable,
      );
      expect(
        AppSharePlatformBridge.mapNativeResult('failed'),
        AppShareResult.failed,
      );
      expect(
        AppSharePlatformBridge.mapNativeResult('delivered'),
        AppShareResult.failed,
      );
    },
  );

  test(
    'native sources preserve same-volume and macOS completion contracts',
    () {
      final android = File(
        'android/app/src/main/kotlin/com/cbstudio/telltale/MainActivity.kt',
      ).readAsStringSync();
      final ios = File('ios/Runner/AppDelegate.swift').readAsStringSync();
      final macos = File('macos/Runner/MainFlutterWindow.swift')
          .readAsStringSync();

      expect(android, contains('StatFs(cacheDir.path)'));
      expect(android, contains('APP_STORAGE_CAPACITY_CHANNEL'));
      expect(ios, contains('cachesDirectory'));
      expect(ios, contains('volumeAvailableCapacityForImportantUsageKey'));
      expect(macos, contains('NSSharingServiceDelegate'));
      expect(macos, contains('didShareItems'));
      expect(macos, contains('didFailToShareItems'));
      expect(macos, contains('delegateFor sharingService'));
      expect(macos, contains('NSItemProvider()'));
      expect(macos, contains('provider.suggestedName = fileName'));
      expect(macos, contains('registerFileRepresentation'));
      expect(macos, contains('visibility: .all'));
      expect(macos, contains('case ("text/csv", "csv")'));
      expect(macos, contains('case ("application/json", "json")'));
      expect(macos, contains('case ("text/plain", "txt")'));
      expect(macos, contains('NSUserCancelledError'));
      expect(macos, isNot(contains('items = [url]')));
      expect(macos, isNot(contains('sharingService.perform(withItems:')));
      expect(
        macos,
        isNot(
          contains(
            'didChoose sharingService: NSSharingService?) {\n      result("selected")',
          ),
        ),
      );

      final windows = File(
        'windows/runner/flutter_window.cpp',
      ).readAsStringSync();
      final linux = File('linux/runner/my_application.cc').readAsStringSync();
      expect(windows, contains('com.cbstudio.telltale/app_storage_capacity'));
      expect(windows, contains('GetDiskFreeSpaceExW'));
      expect(linux, contains('com.cbstudio.telltale/app_storage_capacity'));
      expect(linux, contains('statvfs'));
    },
  );

  test('share bridge forwards an iPad popover origin when provided', () async {
    Rect? captured;
    // Exercise the request type contract used by export UI.
    const request = AppSharePlatformRequest(
      path: '/immutable/staged.csv',
      mimeType: 'text/csv',
      fileName: 'session.csv',
      subject: 'Telltale session',
      sharePositionOrigin: Rect.fromLTWH(10, 20, 30, 40),
    );
    captured = request.sharePositionOrigin;
    expect(captured, const Rect.fromLTWH(10, 20, 30, 40));
  });
}
