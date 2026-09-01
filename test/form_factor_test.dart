/// FormFactor.prefetch answers only from the platform and fails to "phone".
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/core/form_factor.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.cbstudio.telltale/form_factor');

  void mock(Future<Object?> Function(MethodCall call)? handler) {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, handler);
  }

  tearDown(() {
    mock(null);
    FormFactor.debugIsWatch = false;
  });

  test('a platform that says watch is a watch', () async {
    mock((call) async => true);
    await FormFactor.prefetch();
    expect(FormFactor.isWatch, isTrue);
  });

  test('a platform that says phone is a phone', () async {
    mock((call) async => false);
    await FormFactor.prefetch();
    expect(FormFactor.isWatch, isFalse);
  });

  test('a null answer means phone — the safe default everywhere', () async {
    mock((call) async => null);
    FormFactor.debugIsWatch = true; // prove prefetch overwrites, not keeps
    await FormFactor.prefetch();
    expect(FormFactor.isWatch, isFalse);
  });

  test('a channel error means phone, never a crash', () async {
    mock((call) async => throw PlatformException(code: 'boom'));
    FormFactor.debugIsWatch = true;
    await FormFactor.prefetch();
    expect(FormFactor.isWatch, isFalse);
  });

  test('an unregistered channel (iOS, tests) means phone', () async {
    FormFactor.debugIsWatch = true;
    await FormFactor.prefetch();
    expect(FormFactor.isWatch, isFalse);
  });
}
