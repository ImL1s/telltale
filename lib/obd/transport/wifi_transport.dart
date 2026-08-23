/// Wi-Fi TCP transport for IP-based ELM327 adapters.
///
/// These adapters run a soft AP the phone joins, then expose a raw TCP socket.
/// `192.168.0.10:35000` is the near-universal default; a few clones use
/// `192.168.4.1` or port `35000`/`23`, so both are user-editable.
library;

import 'dart:async';
import 'dart:io';

import 'obd_transport.dart';

class WifiTransport extends BaseObdTransport {
  final String host;
  final int port;
  final Duration connectTimeout;

  Socket? _socket;
  StreamSubscription<List<int>>? _subscription;

  WifiTransport({
    this.host = defaultHost,
    this.port = defaultPort,
    this.connectTimeout = const Duration(seconds: 8),
  });

  static const String defaultHost = '192.168.0.10';
  static const int defaultPort = 35000;

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
    try {
      // An ordinary socket on the default network, and on Android that is the
      // single most common way a Wi-Fi adapter fails in the field.
      //
      // The adapter's soft-AP carries no internet, and Android decides what to
      // do about that per network. Measured on a Galaxy S24 Ultra rather than
      // reasoned about: with the validation probe pointed at an unroutable
      // address so the Wi-Fi was judged to have no internet, and cellular data
      // live and pingable, the **Wi-Fi remained the default network** and this
      // connect succeeded — a full session, gauges, fault codes and freeze
      // frame, over the air to a third-party ELM327.
      //
      // What made it work is visible in `dumpsys connectivity`: that network
      // carried `acceptUnvalidated`, because somebody had once answered the
      // system's "no internet, keep using?" prompt with yes. A hotspot the
      // phone has never joined does not carry it, and the adapter's hotspot is
      // always new. So the decisive moment is that prompt, not mobile data —
      // and the guidance says so.
      //
      // Where the prompt is missed or suppressed, Samsung's *Switch to mobile
      // data* under Intelligent Wi-Fi will hand off to cellular on a network it
      // judges unusable, and an unvalidated network that is not the default
      // leaves an unbound socket going out over cellular to an address that
      // only exists on the Wi-Fi. Both end the same way, which is why the
      // message names the remedy rather than the mechanism.
      //
      // The complete fix in code is binding the socket to the Wi-Fi network
      // (`bindProcessToNetwork`, or a per-socket bind), which needs a platform
      // channel or a connectivity plugin — a dependency decision rather than a
      // fix, so it is written down here rather than taken.
      final socket = await Socket.connect(host, port, timeout: connectTimeout);
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
    } on SocketException catch (e) {
      throw TransportException(
        '無法連線到 $host:$port。請確認手機已連上轉接器的 Wi-Fi 熱點；'
        '第一次連上時系統若問「無法連上網際網路，是否繼續使用」，要選繼續使用。'
        '仍然失敗就關閉行動數據再試一次。',
        e,
      );
    } on TimeoutException catch (e) {
      // Socket.connect reports its own timeout as a SocketException, but a
      // TimeoutException can still arrive from an outer await.
      throw TransportException('連線 $host:$port 逾時。', e);
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
