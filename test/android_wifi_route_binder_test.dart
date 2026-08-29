import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/core/network/android_wifi_route_binder.dart';
import 'package:torque_obd/obd/transport/wifi_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.cbstudio.telltale/wifi_route');

  void mockNative(Future<Object?> Function(MethodCall call)? handler) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, handler);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
  }

  test('bind and release cross the channel in order, once each', () async {
    final calls = <String>[];
    mockNative((call) async {
      calls.add(call.method);
      return null;
    });

    final lease = await AndroidWifiRouteBinder().bindForHost('192.168.0.10');
    expect(calls, const ['bind']);

    await lease.release();
    await lease.release();
    expect(calls, const ['bind', 'release'], reason: 'release is idempotent');
  });

  test('loopback hosts get a noop lease without touching the channel', () async {
    mockNative((call) async {
      fail('loopback must not reach the native side (got ${call.method})');
    });

    final binder = AndroidWifiRouteBinder();
    const hosts = [
      '127.0.0.1',
      '127.0.0.53',
      'localhost',
      'LOCALHOST',
      '::1',
      '::ffff:127.0.0.1',
    ];
    for (final host in hosts) {
      final lease = await binder.bindForHost(host);
      expect(lease, isA<NoopWifiRouteLease>(), reason: host);
      await lease.release();
    }
  });

  test('an ambiguous multi-Wi-Fi refusal gets an actionable sentence', () async {
    // Binding deterministically to a coin-flip candidate would time out the
    // same way on every retry with the adapter taking the blame; the native
    // side refuses instead, and the person must be told what to change.
    mockNative((call) async {
      throw PlatformException(
        code: 'ambiguous_wifi_network',
        message: '2 Wi-Fi networks are equally plausible routes',
      );
    });

    await expectLater(
      AndroidWifiRouteBinder().bindForHost('192.168.0.10'),
      throwsA(
        isA<WifiRouteException>().having(
          (error) => error.message,
          'message',
          allOf(contains('關閉另一個 Wi-Fi'), contains('2 Wi-Fi networks')),
        ),
      ),
    );
  });

  test('a known platform refusal is translated for the screen', () async {
    // Native detail is English transcript prose, but the binder's message
    // lands inside the transport's user-facing sentence — the known codes
    // must arrive as something a person standing at a car can act on.
    mockNative((call) async {
      throw PlatformException(
        code: 'no_wifi_network',
        message: 'ConnectivityManager reports no TRANSPORT_WIFI network',
      );
    });

    await expectLater(
      AndroidWifiRouteBinder().bindForHost('192.168.0.10'),
      throwsA(
        isA<WifiRouteException>().having(
          (error) => error.message,
          'message',
          contains('沒有連上任何 Wi-Fi'),
        ),
      ),
    );
  });

  test('an unknown platform refusal still surfaces its native detail', () async {
    mockNative((call) async {
      throw PlatformException(
        code: 'unexpected_code',
        message: 'something novel from a future native side',
      );
    });

    await expectLater(
      AndroidWifiRouteBinder().bindForHost('192.168.0.10'),
      throwsA(
        isA<WifiRouteException>().having(
          (error) => error.message,
          'message',
          contains('something novel'),
        ),
      ),
    );
  });

  test('a missing native handler degrades to the unbound socket', () async {
    // No mock handler installed: invokeMethod throws MissingPluginException,
    // which is a Dart build running against a native host without the
    // handler. Refusing the connection would turn a possibly working unbound
    // socket into a hard failure, so the binder steps aside instead.
    final lease = await AndroidWifiRouteBinder().bindForHost('192.168.0.10');
    expect(lease, isA<NoopWifiRouteLease>());
  });

  test('a release refusal surfaces as a route exception', () async {
    mockNative((call) async {
      if (call.method == 'release') {
        throw PlatformException(
          code: 'release_refused',
          message: 'bindProcessToNetwork(null) returned false',
        );
      }
      return null;
    });

    final lease = await AndroidWifiRouteBinder().bindForHost('192.168.0.10');
    await expectLater(
      lease.release(),
      throwsA(
        isA<WifiRouteException>().having(
          (error) => error.message,
          'message',
          contains('bindProcessToNetwork(null)'),
        ),
      ),
    );
  });

  test('a hung native call is cut off by the call timeout', () async {
    // The native side is one synchronous binder IPC; a call that outlives the
    // timeout is stuck, and the connect budget must not wait for it.
    final hung = Completer<Object?>();
    addTearDown(() => hung.complete(null));
    final calls = <String>[];
    mockNative((call) {
      calls.add(call.method);
      if (call.method == 'bind') return hung.future;
      return Future<Object?>.value();
    });

    await expectLater(
      AndroidWifiRouteBinder(
        callTimeout: const Duration(milliseconds: 50),
      ).bindForHost('192.168.0.10'),
      throwsA(
        isA<WifiRouteException>().having(
          (error) => error.message,
          'message',
          contains('逾時'),
        ),
      ),
    );

    // `Future.timeout` cannot cancel the queued native bind, and a platform
    // thread stalled past the timeout will still run it later — binding the
    // process with no lease left to remember it. Channel messages execute in
    // order, so the compensating release is guaranteed to land after that
    // late bind. Its absence here is the orphaned-binding regression.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(calls, const ['bind', 'release'],
        reason: 'an abandoned bind must be followed by exactly one '
            'compensating release');
  });

  test('a numeric host crosses the channel; a hostname does not', () async {
    // The native side prefers the Wi-Fi whose link subnet contains the
    // adapter, and feeds this value to InetAddress.getByName — which must
    // never become a DNS lookup on the platform thread.
    final hosts = <Object?>[];
    mockNative((call) async {
      if (call.method == 'bind') {
        hosts.add((call.arguments as Map<Object?, Object?>)['host']);
      }
      return null;
    });

    final binder = AndroidWifiRouteBinder();
    await binder.bindForHost('192.168.0.10');
    await binder.bindForHost('my-adapter.example');
    expect(hosts, const ['192.168.0.10', null]);
  });
}
