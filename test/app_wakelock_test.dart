import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/core/app_wakelock.dart';

void main() {
  test('setAppWakelock no-ops on Linux without calling the plugin', () async {
    var called = false;
    await setAppWakelock(
      true,
      isLinux: true,
      enable: () async {
        called = true;
      },
    );
    expect(called, isFalse);
  });

  test('setAppWakelock enables and disables when supported', () async {
    final calls = <bool>[];
    await setAppWakelock(
      true,
      isLinux: false,
      enable: () async => calls.add(true),
      disable: () async => calls.add(false),
    );
    await setAppWakelock(
      false,
      isLinux: false,
      enable: () async => calls.add(true),
      disable: () async => calls.add(false),
    );
    expect(calls, [true, false]);
  });

  test('setAppWakelock swallows MissingPluginException', () async {
    await setAppWakelock(
      true,
      isLinux: false,
      enable: () async => throw MissingPluginException('wakelock'),
    );
    await setAppWakelock(
      false,
      isLinux: false,
      disable: () async => throw MissingPluginException('wakelock'),
    );
  });
}
