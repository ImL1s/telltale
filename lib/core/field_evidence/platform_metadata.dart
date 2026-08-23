import 'dart:io';

import 'package:flutter/services.dart';

const String unknownPlatformMetadata = 'unknown';
const String androidFieldApplicationId = 'com.cbstudio.telltale';

typedef PlatformMetadataLoader = Future<Object?> Function();

final class PlatformMetadata {
  const PlatformMetadata({
    this.applicationId = unknownPlatformMetadata,
    required this.appVersion,
    required this.appBuild,
    required this.platform,
    required this.osVersion,
    required this.manufacturer,
    required this.model,
    required this.sdkInt,
  });

  factory PlatformMetadata.unknown() => const PlatformMetadata(
    applicationId: unknownPlatformMetadata,
    appVersion: unknownPlatformMetadata,
    appBuild: unknownPlatformMetadata,
    platform: unknownPlatformMetadata,
    osVersion: unknownPlatformMetadata,
    manufacturer: unknownPlatformMetadata,
    model: unknownPlatformMetadata,
    sdkInt: unknownPlatformMetadata,
  );

  factory PlatformMetadata.dartIoFallback() {
    try {
      return PlatformMetadata(
        applicationId: unknownPlatformMetadata,
        appVersion: unknownPlatformMetadata,
        appBuild: unknownPlatformMetadata,
        platform: _normalized(Platform.operatingSystem),
        osVersion: _normalized(Platform.operatingSystemVersion),
        manufacturer: unknownPlatformMetadata,
        model: unknownPlatformMetadata,
        sdkInt: unknownPlatformMetadata,
      );
    } on Object {
      return PlatformMetadata.unknown();
    }
  }

  factory PlatformMetadata.fromPlatformMap(Map<String, Object?> values) {
    return PlatformMetadata(
      applicationId: _normalizedApplicationId(values['applicationId']),
      appVersion: _normalized(values['appVersion']),
      appBuild: _normalized(values['appBuild']),
      platform: _normalized(values['platform']),
      osVersion: _normalized(values['osVersion']),
      manufacturer: _normalized(values['manufacturer']),
      model: _normalized(values['model']),
      sdkInt: _normalized(values['sdkInt']),
    );
  }

  final String applicationId;
  final String appVersion;
  final String appBuild;
  final String platform;
  final String osVersion;
  final String manufacturer;
  final String model;
  final String sdkInt;

  bool get isObdTestRigApplication =>
      applicationId == 'com.cbstudio.telltale.rig';

  /// Whether vehicle evidence must be treated as simulated.
  ///
  /// Android normally supplies the exact package ID over the platform
  /// channel. Only the production package is eligible for field evidence.
  /// Every other Android identity fails closed, including missing, partial,
  /// malformed, repackaged, and future flavor IDs: losing field evidence is
  /// safer than allowing an unrecognized build to forge a physical header or
  /// replace real-car evidence. Other platforms do not use Android package
  /// identity as their provenance boundary.
  bool get requiresSimulatedEvidence =>
      platform == 'android' && applicationId != androidFieldApplicationId;

  static String _normalized(Object? value) {
    final text = value?.toString().trim() ?? '';
    return text.isEmpty ? unknownPlatformMetadata : text;
  }

  /// Package identity is a security boundary, not display text. Use trimming
  /// only to recognize an absent value; preserving every nonblank byte makes
  /// padding and control-character alterations non-exact and therefore
  /// simulated on Android.
  static String _normalizedApplicationId(Object? value) {
    final text = value?.toString() ?? '';
    return text.trim().isEmpty ? unknownPlatformMetadata : text;
  }
}

final class PlatformMetadataCache {
  PlatformMetadataCache({
    PlatformMetadata? initialValue,
    this.channel = const MethodChannel(
      'com.cbstudio.telltale/platform_metadata',
    ),
    this.timeout = const Duration(milliseconds: 500),
  }) : _value = initialValue ?? PlatformMetadata.dartIoFallback();

  final MethodChannel channel;
  final Duration timeout;
  PlatformMetadata _value;

  PlatformMetadata get value => _value;

  Future<void> prefetch({PlatformMetadataLoader? loader}) async {
    try {
      final raw =
          await (loader?.call() ??
                  channel.invokeMethod<Object?>('getPlatformMetadata'))
              .timeout(timeout);
      if (raw case final Map<Object?, Object?> values) {
        final normalizedKeys = values.map(
          (key, value) => MapEntry(key.toString(), value),
        );
        // dart:io already established that this process is Android. A
        // successful but empty, partial, or malformed channel reply must not
        // erase that safety-critical context and turn an unknown package into
        // apparently eligible field evidence. Do not carry the application ID
        // forward: the native reply itself must provide the exact field ID.
        if (_value.platform == 'android') {
          normalizedKeys['platform'] = 'android';
        }
        _value = PlatformMetadata.fromPlatformMap(normalizedKeys);
      }
    } on Object {
      // Field evidence must never prevent startup or a vehicle connection.
      // Preserve the synchronous dart:io fallback already held in the cache.
    }
  }
}

final PlatformMetadataCache platformMetadataCache = PlatformMetadataCache();

Future<void> prefetchPlatformMetadata() => platformMetadataCache.prefetch();
