/// Wi-Fi TCP transport for IP-based ELM327 adapters.
///
/// These adapters run a soft AP the phone joins, then expose a raw TCP socket.
/// `192.168.0.10:35000` is the near-universal default; a few clones use
/// `192.168.4.1` or port `35000`/`23`, so both are user-editable.
library;

import 'dart:async';
import 'dart:io';

import 'obd_transport.dart';

/// How [WifiTransport] opens its TCP socket.
///
/// Injected by tests to observe the timeout budget the transport hands down;
/// production always uses [Socket.connect].
typedef WifiSocketConnector =
    Future<Socket> Function(String host, int port, Duration timeout);

/// Picks the OS network route the adapter socket must use.
///
/// The adapter's soft AP carries no internet, and Android decides per network
/// what that means. Measured on a Galaxy S24 Ultra rather than reasoned about:
/// an unvalidated Wi-Fi stays the default network only when somebody once
/// answered the system's「無法連上網際網路，是否繼續使用」prompt with yes —
/// the network then carries `acceptUnvalidated` in `dumpsys connectivity`.
/// A hotspot the phone has never joined does not carry it, and the adapter's
/// hotspot is always new. Where the prompt is missed, or Samsung's *Switch to
/// mobile data* hands off, an unbound socket goes out over cellular to an
/// address that only exists on the Wi-Fi.
///
/// A binder closes that hole: it binds the process to the Wi-Fi network for
/// exactly the moment the socket is created, and the lease is released
/// immediately afterward — a bound socket keeps its network for its lifetime,
/// and nothing else in the app should inherit the binding. The implementation
/// lives outside `obd/` because it needs a platform channel; this interface
/// stays pure Dart so the transport remains unit-testable.
abstract interface class WifiRouteBinder {
  /// Routes upcoming socket creation toward the Wi-Fi that can reach [host].
  ///
  /// Throws [WifiRouteException] when no usable Wi-Fi route exists — the
  /// transport reports that *before* any socket I/O, because a connect
  /// attempt over the wrong network does not fail, it hangs.
  Future<WifiRouteLease> bindForHost(String host);
}

/// An acquired route binding that must be restored.
abstract interface class WifiRouteLease {
  /// Restores the process's default network selection.
  Future<void> release();
}

/// The lease for platforms and hosts that need no binding.
final class NoopWifiRouteLease implements WifiRouteLease {
  const NoopWifiRouteLease();

  @override
  Future<void> release() async {}
}

/// A route could not be selected or restored.
final class WifiRouteException implements Exception {
  const WifiRouteException(this.message);

  final String message;

  @override
  String toString() => 'WifiRouteException: $message';
}

class WifiTransport extends BaseObdTransport {
  final String host;
  final int port;
  final Duration connectTimeout;

  /// Selects the network route before the socket exists; null skips binding.
  ///
  /// Android injects a platform-channel binder here. Everywhere else — tests,
  /// macOS, the emulator's loopback rig — sockets already reach the adapter
  /// on the default network and no binder is installed.
  final WifiRouteBinder? routeBinder;

  final WifiSocketConnector _connector;

  Socket? _socket;
  StreamSubscription<List<int>>? _subscription;

  WifiTransport({
    this.host = defaultHost,
    this.port = defaultPort,
    this.connectTimeout = const Duration(seconds: 8),
    this.routeBinder,
    WifiSocketConnector? socketConnector,
  }) : _connector = socketConnector ?? _defaultConnector;

  static const String defaultHost = '192.168.0.10';
  static const int defaultPort = 35000;

  static Future<Socket> _defaultConnector(
    String host,
    int port,
    Duration timeout,
  ) => Socket.connect(host, port, timeout: timeout);

  @override
  TransportKind get kind => TransportKind.wifi;

  @override
  String get displayName => '$host:$port';

  @override
  Map<String, Object> get diagnosticMetadata =>
      Map.unmodifiable({'host': host, 'port': port});

  @override
  Future<void> connect() async {
    if (_socket != null) return;
    final stopwatch = Stopwatch()..start();

    // Bind first, so the socket below is created on the Wi-Fi even when
    // Android has made cellular the default. A route refusal is reported
    // before any socket I/O: connecting over the wrong network does not
    // fail, it hangs for the full timeout and then blames the adapter.
    WifiRouteLease? lease;
    try {
      lease = await routeBinder?.bindForHost(host);
    } on WifiRouteException catch (e) {
      // The binder's own message names which of the distinct failures this
      // was — no Wi-Fi network, a refused bind, a stalled platform thread —
      // because「請先連上熱點」is the right remedy for only the first one.
      throw TransportException(
        'Wi-Fi 路由設定失敗：${e.message}。無法連往 $host:$port。'
        '若手機尚未連上轉接器的 Wi-Fi 熱點，請先連上再重試。',
        e,
      );
    }

    final Socket socket;
    try {
      // One budget covers binding and connecting; a slow bind may not grant
      // the socket a fresh full timeout on top.
      final remaining = connectTimeout - stopwatch.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('路由綁定用盡了連線時限', connectTimeout);
      }
      socket = await _connector(host, port, remaining);
    } on SocketException catch (e) {
      await _releaseQuietly(lease);
      throw TransportException(
        '無法連線到 $host:$port。請確認手機已連上轉接器的 Wi-Fi 熱點；'
        '第一次連上時系統若問「無法連上網際網路，是否繼續使用」，要選繼續使用。'
        '仍然失敗就關閉行動數據再試一次。',
        e,
      );
    } on TimeoutException catch (e) {
      // Socket.connect reports its own timeout as a SocketException, but a
      // TimeoutException can still arrive from an outer await — or from the
      // budget check above.
      await _releaseQuietly(lease);
      throw TransportException('連線 $host:$port 逾時。', e);
    } on Object {
      // Socket.connect throws nothing beyond the two shapes above, but the
      // connector is injectable and the process-wide route binding must not
      // outlive the attempt no matter what shape the failure takes.
      await _releaseQuietly(lease);
      rethrow;
    }

    // Restore the route before the connection is offered to anyone. A failed
    // restore leaves every later socket in the process bound to the adapter's
    // dead-end network, so the safe outcome is no connection at all.
    try {
      await lease?.release();
    } on Object catch (e) {
      socket.destroy();
      throw TransportException(
        '連線已建立，但無法恢復系統網路路由，已中斷 $host:$port 的連線。'
        '請重新開啟 App 後再試一次。',
        e,
      );
    }

    // ELM327 traffic is a chat of tiny frames; Nagle would batch them and add
    // up to 40ms of latency to every single PID read.
    socket.setOption(SocketOption.tcpNoDelay, true);
    _socket = socket;
    _subscription = socket.listen(
      emitBytes,
      onError: (Object _) => _handleDrop(),
      onDone: _handleDrop,
      cancelOnError: false,
    );
    setConnected(true);
  }

  /// Best-effort restore on a connect path that already failed.
  ///
  /// The connect failure is the story the caller needs; a restore failure on
  /// that same path has nothing further to protect and must not replace it.
  Future<void> _releaseQuietly(WifiRouteLease? lease) async {
    if (lease == null) return;
    try {
      await lease.release();
    } on Object {
      // Reported failure already covers this attempt.
    }
  }

  void _handleDrop() {
    // Cancel here as well as in disconnect(): a peer-initiated close leaves the
    // subscription attached to a dead socket otherwise.
    unawaited(_subscription?.cancel());
    _subscription = null;
    setConnected(false);
    _socket = null;
  }

  @override
  Future<void> disconnect() async {
    await _subscription?.cancel();
    _subscription = null;
    try {
      await _socket?.close();
    } on SocketException {
      // The peer already went away; nothing left to close cleanly.
    }
    _socket?.destroy();
    _socket = null;
    setConnected(false);
  }

  @override
  Future<void> write(List<int> data) async {
    final socket = _socket;
    if (socket == null) {
      throw const WriteRefusedException('Wi-Fi 連線尚未建立。');
    }
    socket.add(data);
    await socket.flush();
  }
}
