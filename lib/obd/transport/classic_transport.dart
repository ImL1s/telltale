/// Bluetooth Classic RFCOMM / SPP transport (tier 1).
///
/// This is what the cheap ELM327 dongles use. Android in practice: iOS exposes
/// RFCOMM only to MFi-registered accessories, so the connection wizard hides
/// this option there rather than offering a link that cannot work.
///
/// ## The three-tier connection cascade
///
/// 1. **Secure, by UUID.** What a well-behaved adapter answers.
/// 2. **Insecure, by UUID.** Rescues devices whose SDP record is present but
///    which refuse an authenticated handshake — the most common clone failure.
/// 3. **Insecure, on RFCOMM channel 1.** Skips service discovery entirely.
///
/// The third tier exists because both UUID paths perform an SDP lookup and
/// fail outright when the device publishes no usable SPP record. Cheap ELM327
/// clones frequently listen on channel 1 and advertise nothing: they are
/// discoverable, they pair normally, and they cannot be connected to by UUID
/// at all.
///
/// Upstream `flutter_classic_bluetooth` 0.1.8 has no such path — it calls
/// `createRfcommSocketToServiceRecord` and its insecure twin and nothing else,
/// which was verified by reading its Android source. `connect(channel:)` was
/// added in a fork and the dependency is pinned to that commit; see
/// `pubspec.yaml`.
///
/// Each tier begins only after the previous one has genuinely *terminated*,
/// timeouts included. That is a property of the pinned fork rather than of
/// this file: `connect(timeout:)` calls `cancelConnect` before throwing, which
/// closes the socket and releases the native call blocked in
/// `BluetoothSocket.connect()`. Without that a timeout would leave a socket
/// racing the next tier for an adapter that accepts one link — which is why
/// this used to abort instead, at the cost of never reaching tier 3.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_classic_bluetooth/flutter_classic_bluetooth.dart';

import 'obd_transport.dart';

class ClassicTransport extends BaseObdTransport {
  ClassicTransport({required this.address, required this.name, this.onAttempt});

  final String address;
  final String name;

  /// Reports which tier is being tried, so the screen can say what it is
  /// waiting on.
  ///
  /// Each tier waits up to twelve seconds, and all three can run. Between the
  /// tap and any visible change there was nothing at all — up to
  /// thirty-six seconds of a blank progress bar in a windscreen mount, which
  /// reads as a frozen app and produces a force-quit rather than a wait.
  final void Function(String tier)? onAttempt;

  /// Shared plugin handle. The API is instance-based, but the underlying
  /// platform channel is a singleton, so one instance for the app is correct.
  static final FlutterClassicBluetooth _btc = FlutterClassicBluetooth();

  BtcConnection? _connection;
  StreamSubscription<List<int>>? _inputSub;

  /// Set once the caller has given up on this transport, and never cleared.
  ///
  /// One-way because a transport instance belongs to exactly one attempt — the
  /// session builds a fresh `ClassicTransport` per tap — so there is no second
  /// connection that could legitimately want the flag back, and nothing has to
  /// reason about when to reset it.
  bool _aborted = false;

  /// How a tier opens its socket. Test seam only.
  ///
  /// The cascade is the one piece of this app whose behaviour is defined by
  /// what it does *not* do next, and there was no way to observe that: `_btc`
  /// is a static handle onto a platform channel, so every rule about tier
  /// ordering and stopping was unpinned. It was deleted once during a mutation
  /// check and nothing went red — the deletion reached a commit whose own
  /// message described the behaviour it had just removed. A seam this thin is
  /// a smaller price than that.
  @visibleForTesting
  Future<BtcConnection> Function({
    required String address,
    String uuid,
    bool secure,
    Duration? timeout,
    int? channel,
  })? openTierForTest;

  @override
  TransportKind get kind => TransportKind.bluetoothClassic;

  @override
  String get displayName => name.isEmpty ? address : name;

  @override
  Map<String, Object> get diagnosticMetadata => Map.unmodifiable({
        'deviceIdentifier': address,
        'deviceName': name,
        'paired': true,
      });

  /// Bonded devices. An ELM327 must be paired in system settings before it will
  /// accept an RFCOMM connection, so these are the only ones worth offering.
  static Future<List<DiscoveredDevice>> pairedDevices() async {
    final devices = await _btc.getPairedDevices();
    return devices
        .map(
          (d) => DiscoveredDevice(
            id: d.address,
            name: (d.name?.isNotEmpty ?? false) ? d.name! : d.address,
            kind: TransportKind.bluetoothClassic,
            rssi: d.rssi,
            isPaired: true,
          ),
        )
        .toList();
  }

  // `discover()` used to live here: it started an inquiry and mapped the
  // results, but nothing ever called it. The connection wizard lists
  // `pairedDevices()` only, because Android will not let an app bond from
  // inside a normal activity — pairing happens in system settings. Keeping an
  // unused scanner around implied a "find an unpaired adapter" feature that
  // does not exist, so it is gone and the wizard says where to pair instead.

  static Future<void> stopDiscovery() => _btc.stopDiscovery();

  static Future<bool> isAdapterEnabled() => _btc.isEnabled();

  @override
  Future<void> connect() async {
    _connection = await _connectWithRetry();

    _inputSub = _connection!.input.listen(
      emitBytes,
      onError: (Object _) => setConnected(false),
      onDone: () => setConnected(false),
      cancelOnError: false,
    );
    setConnected(true);
  }

  /// Walks the three tiers in order, never running two at once.
  ///
  /// A timeout now *advances* the cascade. It used to end it, on the grounds
  /// that the plugin's `timeout` was a Dart-side `Future.timeout` which left
  /// the native socket blocked inside `BluetoothSocket.connect()` — so moving
  /// on would race two sockets for an adapter that accepts one link. That was
  /// true, and it is not any more: the pinned fork's `connect(timeout:)` calls
  /// `cancelConnect` before throwing, which closes the socket and releases the
  /// blocked native call. The tier really has terminated.
  ///
  /// Keeping the abort after that change was actively harmful. A secure SDP
  /// lookup does not always fail fast — against some stacks it simply hangs to
  /// the 12-second deadline — and on those devices the user only ever saw
  /// "connection timed out, wait a few seconds", while tier 3 (channel 1, no
  /// SDP at all) was never tried. Tier 3 is the entire reason this app runs a
  /// forked plugin.
  Future<BtcConnection> _connectWithRetry() async {
    Object? firstFailure;
    Object? firstTimeout;
    // What each tier actually said.
    //
    // Three attempts were collapsed into one sentence with a timeout
    // outranking everything, so the tier that carries the real diagnosis —
    // "this Android build does not expose createRfcommSocket(int)", or a
    // clone that refused the direct channel — never reached the screen. The
    // precedence is right: "never answered" is the case where waiting helps.
    // Discarding the other two is not.
    final tierNotes = <String>[];

    for (final attempt in _attempts) {
      // Checked at the tier boundary, which is the only place the cascade can
      // be stopped from outside.
      //
      // `BluetoothSocket.connect()` has no interrupt, and the plugin's own
      // cancellation needs an `attemptId` it mints inside `connect()` and does
      // not hand back — so a tier that has already started runs to its own
      // 12-second deadline whatever happens. What was wrong was continuing
      // *past* that: somebody who tapped a pair of headphones in the bonded
      // list, saw 加密 SPP 連線, and tapped 取消 still waited out all three
      // tiers — up to 36 seconds during which the next tap did nothing at all,
      // with no error and no explanation. Stopping here caps the abandoned
      // attempt at the tier already in flight.
      if (_aborted) throw const TransportException('連線已取消。');
      onAttempt?.call(_describeAttempt(attempt));
      try {
        final opened = await (openTierForTest ?? _btc.connect)(
          address: address,
          uuid: BtcUuid.spp,
          secure: attempt.secure,
          channel: attempt.channel,
          timeout: _attemptTimeout,
        );
        // Checked again on the way out, because a tier can *succeed* into a
        // cancellation.
        //
        // The check above only stops the next tier from starting. Cancelling
        // during a connect that then completes — the commonest way an SDP
        // lookup ends, milliseconds after the user gave up — handed back a
        // live socket, which was installed, marked connected, and handshaken
        // against a device the user had walked away from. It also holds the
        // adapter, which is the one resource the next attempt needs.
        if (_aborted) {
          try {
            await opened.close();
          } on Object {
            // Already gone; the throw below is the outcome that matters.
          }
          throw const TransportException('連線已取消。');
        }
        return opened;
      } on BtcTimeoutException catch (e) {
        // The plugin's own type, and it is NOT a `dart:async`
        // `TimeoutException` — `BtcTimeoutException extends BtcException
        // implements Exception`. Distinguishing them mattered when a timeout
        // aborted the cascade; now that the fork cancels the native connect,
        // both simply mean this tier is over.
        firstTimeout ??= e;
        firstFailure ??= e;
        tierNotes.add(_describeTier(attempt, e));
      } on TimeoutException catch (e) {
        firstTimeout ??= e;
        firstFailure ??= e;
        tierNotes.add(_describeTier(attempt, e));
      } on Exception catch (e) {
        // This tier is genuinely over, so nothing is left holding the device
        // and the next one is safe to start.
        firstFailure ??= e;
        tierNotes.add(_describeTier(attempt, e));
      }
    }

    // A tier that timed out is worth saying so about: it is the difference
    // between "this device refused us" and "this device never answered", and
    // the second is the one where waiting and retrying actually helps.
    //
    // Every tier is in here, including the ones that timed out. They used to
    // be dropped — only the `on Exception` branch recorded a note — so the
    // appendix was empty in precisely the case it was written for: a stack
    // where all three tiers hang to their deadline. The screen then said
    // "timed out" with no indication that three different things had been
    // tried, which is the difference between a wrong password and a wrong
    // building.
    final detail = tierNotes.isEmpty ? '' : '\n（其他嘗試：${tierNotes.join('；')}）';
    if (firstTimeout != null) throw _timedOut(firstTimeout, detail);

    throw TransportException(
      '無法連線到 $displayName。請先在系統藍牙設定完成配對，'
      '並確認轉接器已插上 OBD 埠且電門已開啟。$detail',
      firstFailure,
    );
  }

  /// What this tier is trying, in the words a person would use.
  static String _describeAttempt(({bool secure, int? channel}) attempt) =>
      attempt.channel != null
          ? '直接連通道 ${attempt.channel}（最後一種方式，最多 12 秒）'
          : attempt.secure
              ? '加密 SPP 連線（最多 12 秒）'
              : '未加密 SPP 連線（最多 12 秒）';

  /// One tier's outcome, short enough to sit inside a connection error.
  static String _describeTier(
    ({bool secure, int? channel}) attempt,
    Object error,
  ) {
    final what = attempt.channel != null
        ? '直接連通道 ${attempt.channel}'
        : attempt.secure
            ? '加密 SPP'
            : '未加密 SPP';
    final why = error is BtcException ? error.message : error.toString();
    return '$what：$why';
  }

  /// Reported when every tier was tried and at least one timed out.
  ///
  /// Kept distinct from an outright refusal because the advice differs: an
  /// adapter that never answered may well answer in a few seconds, where one
  /// that refused will keep refusing.
  TransportException _timedOut(Object cause, [String detail = '']) =>
      TransportException(
        '連線到 $displayName 逾時。轉接器可能仍在回應中 — '
        '請等幾秒再試一次，不要立刻重試。$detail',
        cause,
      );

  /// The cascade, in order. `channel` null means "look the service up by UUID".
  ///
  /// Tier 3 (`channel: 1`) is only meaningful on Android. Product code never
  /// constructs [ClassicTransport] on Windows/Linux (those hosts use
  /// [SerialTransport]); macOS keeps the Classic card gated off.
  static const List<({bool secure, int? channel})> _attempts = [
    (secure: true, channel: null),
    (secure: false, channel: null),
    // No SDP lookup at all — for clones that listen on channel 1 and publish
    // nothing. This is the tier upstream does not have.
    (secure: false, channel: 1),
  ];

  /// Long enough for a slow SDP lookup, short enough that a wedged stack does
  /// not look like a frozen app.
  static const Duration _attemptTimeout = Duration(seconds: 12);

  @override
  Future<void> disconnect() async {
    // Doubles as the cascade's abort signal.
    //
    // The session's cancel path already reaches here — 取消 disposes the
    // client, and `Elm327Client.dispose()` disconnects its transport — so the
    // signal needs no new wiring, and every other way an attempt is abandoned
    // (a superseded connect, a lifecycle teardown) arrives by the same door.
    _aborted = true;
    await _inputSub?.cancel();
    _inputSub = null;
    try {
      await _connection?.close();
    } on Exception {
      // Socket already torn down by the remote end.
    }
    _connection = null;
    setConnected(false);
  }

  @override
  Future<void> write(List<int> data) async {
    final connection = _connection;
    if (connection == null) {
      throw const WriteRefusedException('藍牙連線尚未建立。');
    }
    await connection.output.writeBytes(data);
  }
}
