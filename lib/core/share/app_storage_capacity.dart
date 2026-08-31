library;

import 'dart:io';

import 'package:flutter/services.dart';

/// Fail-closed probe for the bytes currently available on the volume that
/// owns the application's cache directory.
class AppStorageCapacity {
  const AppStorageCapacity();

  static const _channel = MethodChannel(
    'com.cbstudio.telltale/app_storage_capacity',
  );

  Future<int?> availableBytes(Directory _) async {
    try {
      final value = await _channel.invokeMethod<Object?>('getAvailableBytes');
      return value is int && value > 0 ? value : null;
    } on Object {
      return null;
    }
  }
}
