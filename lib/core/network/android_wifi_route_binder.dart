/// Android implementation of [WifiRouteBinder], over a platform channel.
///
/// Lives outside `lib/obd/` on purpose: the engine stays pure Dart, and this
/// file is the one place the Wi-Fi transport touches Flutter. The Kotlin side
/// (`MainActivity.bindWifiRoute`) binds the process to a connected Wi-Fi
/// network — validated or not, because an ELM327 soft AP never validates —
/// for exactly the moment the socket is created.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../obd/transport/wifi_transport.dart';

final class AndroidWifiRouteBinder implements WifiRouteBinder {
  AndroidWifiRouteBinder({
    this.channel = const MethodChannel('com.cbstudio.telltale/wifi_route'),
    this.callTimeout = const Duration(seconds: 3),
  });

  final MethodChannel channel;

  /// Both channel calls are synchronous binder IPC on the native side; a call
  /// that outlives this is stuck, and the connect budget should not wait for
  /// it.
  final Duration callTimeout;

  @override
  Future<WifiRouteLease> bindForHost(String host) async {
    // Loopback never crosses a radio, and every rig this project drives an
    // emulator with reaches its ELM327 through `adb reverse` on loopback.
    // Whether a process bound to a Wi-Fi `Network` still routes loopback
    // correctly is exactly the kind of thing that differs per OS build, so
    // it is not gambled on.
    if (_isLoopback(host)) return const NoopWifiRouteLease();
    try {
      // Only a numeric literal crosses the channel: the native side hands it
      // to InetAddress.getByName to prefer the Wi-Fi whose link subnet
      // contains the adapter, and that call must never become a DNS lookup
      // on the platform thread. A hostname just loses the preference.
      final literal = InternetAddress.tryParse(host.trim()) == null
          ? null
          : host.trim();
      await channel
          .invokeMethod<void>('bind', <String, Object?>{'host': literal})
          .timeout(callTimeout);
    } on MissingPluginException {
      // Two sources share this exception: a Dart build running against a
      // native host without the channel handler, and a method-name skew
      // (an old APK's handler answering `notImplemented` to a newer Dart).
      // Either way the unbound socket is the long-standing behavior that
      // works whenever the Wi-Fi is still the default network, so degrade
      // to it rather than turning a possibly working connection into a
      // refusal. This is a deliberate fail-open, locked in by test.
      return const NoopWifiRouteLease();
    } on PlatformException catch (e) {
      // These messages reach the screen inside the transport's sentence, so
      // the known refusals get a sentence a person can act on; the raw
      // native detail still rides along for the transcript via `toString`.
      throw WifiRouteException(switch (e.code) {
        'no_wifi_network' => '手機目前沒有連上任何 Wi-Fi 網路',
        'ambiguous_wifi_network' =>
          '手機同時連著多個同樣可能的 Wi-Fi，無法判斷哪一個通往轉接器；'
              '請先關閉另一個 Wi-Fi 連線（${e.message}）',
        'bind_refused' => '系統拒絕綁定 Wi-Fi 網路路由（${e.message}）',
        _ => e.message ?? '無法綁定 Wi-Fi 網路路由（${e.code}）',
      });
    } on TimeoutException {
      // `Future.timeout` abandons the reply but cannot cancel the queued
      // native call: a platform thread stalled past the timeout will still
      // run the bind afterwards, leaving the process bound with no lease to
      // remember it. Channel messages execute in order on the platform
      // thread, so a trailing release is guaranteed to land *after* that
      // late bind and undo it — and if the bind never ran, unbinding is a
      // no-op. Fire and forget: this path already reports its failure.
      unawaited(
        channel.invokeMethod<void>('release').then(
          (_) {},
          onError: (Object _) {},
        ),
      );
      throw const WifiRouteException('綁定 Wi-Fi 網路路由逾時（系統暫時沒有回應）');
    }
    return _AndroidWifiRouteLease(channel, callTimeout);
  }

  static bool _isLoopback(String host) {
    final normalized = host.trim().toLowerCase();
    if (normalized == 'localhost') return true;
    // An IPv4-mapped IPv6 literal parses as IPv6 and is not `isLoopback`
    // even when the embedded IPv4 is 127/8; unwrap it before judging.
    final unwrapped = normalized.startsWith('::ffff:')
        ? normalized.substring(7)
        : normalized;
    return InternetAddress.tryParse(unwrapped)?.isLoopback ?? false;
  }
}

final class _AndroidWifiRouteLease implements WifiRouteLease {
  _AndroidWifiRouteLease(this._channel, this._timeout);

  final MethodChannel _channel;
  final Duration _timeout;
  bool _released = false;

  @override
  Future<void> release() async {
    // The transport releases once per connect path, but a success path and a
    // failure path must both be free to call this without double-restoring.
    if (_released) return;
    _released = true;
    try {
      await _channel.invokeMethod<void>('release').timeout(_timeout);
    } on MissingPluginException {
      // bind succeeded over this same channel, so the handler exists; if it
      // vanished mid-session the process is being torn down anyway.
    } on PlatformException catch (e) {
      throw WifiRouteException(
        e.message ?? '無法恢復系統網路路由（${e.code}）',
      );
    } on TimeoutException {
      // Unlike an abandoned bind, an abandoned release needs no compensation:
      // the queued call still unbinds when the platform thread recovers. The
      // transport still refuses this connection and asks for an app restart,
      // because nothing here can know when — or whether — that recovery
      // happens, and "eventually correct" is not a state to hand a session.
      throw const WifiRouteException('恢復系統網路路由逾時');
    }
  }
}
