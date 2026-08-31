import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';
import 'package:torque_obd/core/share/app_share_platform_bridge.dart';

void main() {
  test('platform vocabulary never claims delivery', () {
    expect(
      AppSharePlatformBridge.mapStatus(ShareResultStatus.success),
      AppShareResult.selected,
    );
    expect(
      AppSharePlatformBridge.mapStatus(ShareResultStatus.dismissed),
      AppShareResult.dismissed,
    );
    expect(
      AppSharePlatformBridge.mapStatus(ShareResultStatus.unavailable),
      AppShareResult.unavailable,
    );
    expect(
      AppShareResult.values.map((v) => v.name),
      isNot(contains('delivered')),
    );
  });

  test('no feature bypasses the app-wide platform bridge', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      if (source.contains('SharePlus.instance.share') &&
          !entity.path.endsWith('app_share_platform_bridge.dart')) {
        offenders.add(entity.path);
      }
    }
    expect(offenders, isEmpty);
  });
}
