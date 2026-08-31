import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/core/licenses/powertrain_battery_licenses.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bundles attribution, Apache 2.0, CC BY-SA, and MIT terms', () async {
    final text = await loadPowertrainBatteryLicenseText();

    expect(text, contains('Powertrain battery catalog third-party notices'));
    expect(text, contains('Apache License'));
    expect(text, contains('Version 2.0, January 2004'));
    expect(text, contains('TERMS AND CONDITIONS FOR USE, REPRODUCTION'));
    expect(text, contains('CC BY-SA 4.0'));
    expect(text, contains('https://creativecommons.org/licenses/by-sa/4.0/'));
    expect(text, contains('MIT License'));
    expect(text, contains('Copyright (c) 2026 Akin Yavuz'));
    expect(text, contains('2f485fcbffa2259d9e1db92d14483c1bef55dcca'));
    expect(text, contains('c45a018b60b3341d2d8bfb22cf0491c4e878165a'));
    expect(text, contains('f93d7a0afb1cfb8aff9681a7db33db46d55804a2'));
  });
}
