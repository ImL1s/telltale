import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/core/field_evidence/platform_metadata.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('PlatformMetadata', () {
    test('normalizes absent and blank values to literal unknown', () {
      final metadata = PlatformMetadata.fromPlatformMap(<String, Object?>{
        'applicationId': 'com.cbstudio.telltale.rig',
        'appVersion': '  ',
        'appBuild': null,
        'platform': 'android',
        'osVersion': '',
        'manufacturer': 'Google',
        'model': null,
        'sdkInt': 35,
      });

      expect(metadata.applicationId, 'com.cbstudio.telltale.rig');
      expect(metadata.isObdTestRigApplication, isTrue);
      expect(metadata.appVersion, 'unknown');
      expect(metadata.appBuild, 'unknown');
      expect(metadata.platform, 'android');
      expect(metadata.osVersion, 'unknown');
      expect(metadata.manufacturer, 'Google');
      expect(metadata.model, 'unknown');
      expect(metadata.sdkInt, '35');
    });

    test('only the exact Android field package is field eligible', () {
      const identities = <String, bool>{
        androidFieldApplicationId: false,
        'com.cbstudio.telltale.rig': true,
        unknownPlatformMetadata: true,
        '': true,
        'com.cbstudio.telltale.': true,
        'com.cbstudio.telltale.debug': true,
        'com.cbstudio.telltale.evil': true,
        'COM.CBSTUDIO.TELLTALE': true,
        'com.cbstudio.telltale\nforged': true,
        ' com.cbstudio.telltale': true,
        'com.cbstudio.telltale ': true,
        'com.cbstudio.telltale\n': true,
        'com.cbstudio.telltale\t': true,
      };

      for (final MapEntry(key: applicationId, value: expected)
          in identities.entries) {
        final metadata = PlatformMetadata(
          applicationId: applicationId,
          appVersion: 'unknown',
          appBuild: 'unknown',
          platform: 'android',
          osVersion: 'Android 16',
          manufacturer: 'unknown',
          model: 'unknown',
          sdkInt: 'unknown',
        );

        expect(
          metadata.requiresSimulatedEvidence,
          expected,
          reason: 'classification for applicationId=$applicationId',
        );
      }
    });

    test('unknown non-Android package provenance is not called a rig', () {
      const metadata = PlatformMetadata(
        appVersion: 'unknown',
        appBuild: 'unknown',
        platform: 'macos',
        osVersion: 'unknown',
        manufacturer: 'unknown',
        model: 'unknown',
        sdkInt: 'unknown',
      );

      expect(metadata.requiresSimulatedEvidence, isFalse);
    });

    test('cache exposes a synchronous value before prefetch completes', () {
      const initial = PlatformMetadata(
        appVersion: 'unknown',
        appBuild: 'unknown',
        platform: 'android',
        osVersion: 'unknown',
        manufacturer: 'unknown',
        model: 'unknown',
        sdkInt: 'unknown',
      );
      final cache = PlatformMetadataCache(initialValue: initial);

      expect(cache.value, same(initial));
    });

    test(
      'prefetch replaces the cached value from the platform channel',
      () async {
        final cache = PlatformMetadataCache(
          initialValue: PlatformMetadata.unknown(),
          channel: const MethodChannel('test/platform_metadata'),
          timeout: const Duration(milliseconds: 500),
        );

        await cache.prefetch(
          loader: () async => <String, Object?>{
            'applicationId': 'com.cbstudio.telltale',
            'appVersion': '1.2.3',
            'appBuild': '42',
            'platform': 'android',
            'osVersion': '15',
            'manufacturer': 'Google',
            'model': 'Pixel 9',
            'sdkInt': 35,
          },
        );

        expect(cache.value.applicationId, 'com.cbstudio.telltale');
        expect(cache.value.isObdTestRigApplication, isFalse);
        expect(cache.value.requiresSimulatedEvidence, isFalse);
        expect(cache.value.appVersion, '1.2.3');
        expect(cache.value.appBuild, '42');
        expect(cache.value.platform, 'android');
        expect(cache.value.osVersion, '15');
        expect(cache.value.manufacturer, 'Google');
        expect(cache.value.model, 'Pixel 9');
        expect(cache.value.sdkInt, '35');
      },
    );

    test('empty native metadata preserves known Android provenance', () async {
      final cache = PlatformMetadataCache(
        initialValue: _androidFallback(),
        timeout: const Duration(milliseconds: 500),
      );

      await cache.prefetch(loader: () async => <String, Object?>{});

      expect(cache.value.platform, 'android');
      expect(cache.value.applicationId, unknownPlatformMetadata);
      expect(cache.value.requiresSimulatedEvidence, isTrue);
    });

    test(
      'applicationId-only malformed or unexpected replies fail closed',
      () async {
        for (final applicationId in <Object?>[
          null,
          '  ',
          'com.cbstudio.telltale.',
          'com.example.repackaged',
          ' $androidFieldApplicationId',
          '$androidFieldApplicationId ',
          '$androidFieldApplicationId\n',
          '$androidFieldApplicationId\t',
        ]) {
          final cache = PlatformMetadataCache(
            initialValue: _androidFallback(),
            timeout: const Duration(milliseconds: 500),
          );

          await cache.prefetch(
            loader: () async => <String, Object?>{
              'applicationId': applicationId,
            },
          );

          expect(cache.value.platform, 'android');
          expect(
            cache.value.requiresSimulatedEvidence,
            isTrue,
            reason: 'classification for applicationId=$applicationId',
          );
        }
      },
    );

    test(
      'partial native metadata preserves known Android provenance',
      () async {
        final cache = PlatformMetadataCache(
          initialValue: _androidFallback(),
          timeout: const Duration(milliseconds: 500),
        );

        await cache.prefetch(
          loader: () async => <String, Object?>{
            'appVersion': '1.2.3',
            'model': 'Pixel 9',
          },
        );

        expect(cache.value.platform, 'android');
        expect(cache.value.applicationId, unknownPlatformMetadata);
        expect(cache.value.appVersion, '1.2.3');
        expect(cache.value.model, 'Pixel 9');
        expect(cache.value.requiresSimulatedEvidence, isTrue);
      },
    );

    test(
      'empty metadata does not classify a non-Android fallback as rig',
      () async {
        const fallback = PlatformMetadata(
          appVersion: 'unknown',
          appBuild: 'unknown',
          platform: 'macos',
          osVersion: 'macOS',
          manufacturer: 'Apple',
          model: 'Mac',
          sdkInt: 'unknown',
        );
        final cache = PlatformMetadataCache(
          initialValue: fallback,
          timeout: const Duration(milliseconds: 500),
        );

        await cache.prefetch(loader: () async => <String, Object?>{});

        expect(cache.value.platform, unknownPlatformMetadata);
        expect(cache.value.requiresSimulatedEvidence, isFalse);
      },
    );

    test('prefetch retains fallback on channel failure', () async {
      const fallback = PlatformMetadata(
        appVersion: 'unknown',
        appBuild: 'unknown',
        platform: 'android',
        osVersion: 'Android 15',
        manufacturer: 'unknown',
        model: 'unknown',
        sdkInt: 'unknown',
      );
      final cache = PlatformMetadataCache(
        initialValue: fallback,
        timeout: const Duration(milliseconds: 500),
      );

      await cache.prefetch(loader: () async => throw MissingPluginException());

      expect(cache.value, same(fallback));
      expect(cache.value.requiresSimulatedEvidence, isTrue);
    });

    test('prefetch times out and retains fallback', () async {
      const fallback = PlatformMetadata(
        appVersion: 'unknown',
        appBuild: 'unknown',
        platform: 'android',
        osVersion: 'unknown',
        manufacturer: 'unknown',
        model: 'unknown',
        sdkInt: 'unknown',
      );
      final cache = PlatformMetadataCache(
        initialValue: fallback,
        timeout: const Duration(milliseconds: 1),
      );

      await cache.prefetch(
        loader: () => Future<Object?>.delayed(
          const Duration(milliseconds: 50),
          () => <String, Object?>{'appVersion': 'late'},
        ),
      );

      expect(cache.value, same(fallback));
      expect(cache.value.requiresSimulatedEvidence, isTrue);
    });
  });
}

PlatformMetadata _androidFallback() => const PlatformMetadata(
  appVersion: unknownPlatformMetadata,
  appBuild: unknownPlatformMetadata,
  platform: 'android',
  osVersion: 'Android 16',
  manufacturer: unknownPlatformMetadata,
  model: unknownPlatformMetadata,
  sdkInt: unknownPlatformMetadata,
);
