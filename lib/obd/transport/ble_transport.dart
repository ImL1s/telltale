/// Bluetooth LE transport — the second of the four links, and the one
/// whose hardware lies most.
///
/// BLE ELM327 clones do not agree on a UUID. The three families in the wild are
/// Nordic UART, the `FFF0` family and the `FFE0` family, and a few use
/// something else entirely. Rather than hard-code one, [_findUartPair] scores
/// the known UUIDs first and then falls back to *any* characteristic pair that
/// can write and notify — which is the only property that actually matters.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:universal_ble/universal_ble.dart';

import 'obd_transport.dart';

/// A BLE peripheral, reduced to its identity plus optional scan evidence.
///
/// The UI and session layers used to pass the BLE package's own device object
/// around, which meant a package swap reached into three files and the widget
/// tree imported a transport dependency to name a callback parameter. A BLE
/// peripheral is addressed purely by its platform id — a MAC on Android, a
/// service UUID on Apple — so (id, name) remains the handle's identity. RSSI
/// is only evidence carried forward from the scan that found it.
///
/// [id] is what the OS reports, verbatim. Do not normalise its case: the
/// platform reports the same adapter differently on Android and Windows, and
/// the BLE layer matches ids case-insensitively while keying its own state by
/// a canonical form. Storing it verbatim is what lets a remembered adapter
/// reconnect without a scan.
class BleAdapterHandle {
  const BleAdapterHandle({required this.id, required this.name, this.rssi});

  final String id;
  final String name;

  /// RSSI from the scan advertisement that produced this handle, if any.
  ///
  /// Reconnecting from a remembered identifier does not perform a scan and
  /// therefore leaves this null rather than inventing a current signal value.
  final int? rssi;

  @override
  bool operator ==(Object other) =>
      other is BleAdapterHandle && other.id == id && other.name == name;

  @override
  int get hashCode => Object.hash(id, name);

  @override
  String toString() => 'BleAdapterHandle($id, $name)';
}

class BleTransport extends BaseObdTransport {
  BleTransport(this.handle);

  final BleAdapterHandle handle;

  BleDevice get _device => BleDevice(deviceId: handle.id, name: handle.name);

  BleCharacteristic? _write;
  BleCharacteristic? _notify;
  StreamSubscription<Uint8List>? _valueSub;
  StreamSubscription<bool>? _stateSub;
  String _mtuRequestOutcome = 'notAttempted';
  String? _selectedServiceUuid;
  String? _selectedWriteCharacteristicUuid;
  String? _selectedNotifyCharacteristicUuid;
  String? _subscriptionKind;

  static const int requestedMtu = 185;

  /// Known UART service/characteristic families, best-known first.
  ///
  /// These are written as full 128-bit lower-case UUIDs because that is the
  /// form `BleService` normalises its own `uuid` to, so [_findUartPair] can
  /// compare them directly. A 16-bit shorthand here would never match and the
  /// preference ordering would silently degrade to "whatever the adapter
  /// listed first" — which still connects, so nothing would ever report it.
  static final List<String> _preferredServices = [
    '6e400001-b5a3-f393-e0a9-e50e24dcca9e', // Nordic UART
    '0000fff0-0000-1000-8000-00805f9b34fb',
    '0000ffe0-0000-1000-8000-00805f9b34fb',
    '000018f0-0000-1000-8000-00805f9b34fb',
  ];

  @override
  TransportKind get kind => TransportKind.bluetoothLe;

  @override
  String get displayName => handle.name.isEmpty ? handle.id : handle.name;

  @override
  Map<String, Object> get diagnosticMetadata => Map.unmodifiable({
    'deviceIdentifier': handle.id,
    'deviceName': handle.name,
    'scanRssiDbm': ?handle.rssi,
    'requestedMtu': requestedMtu,
    'mtuRequestOutcome': _mtuRequestOutcome,
    'selectedServiceUuid': ?_selectedServiceUuid,
    'selectedWriteCharacteristicUuid': ?_selectedWriteCharacteristicUuid,
    'selectedNotifyCharacteristicUuid': ?_selectedNotifyCharacteristicUuid,
    'subscriptionKind': ?_subscriptionKind,
  });

  static Future<void> stopScan() => UniversalBle.stopScan();

  /// Maps radio / BlueZ / permission failures to copy the connect screen can
  /// show. Raw `TimeoutException` / D-Bus strings are not actionable at a car.
  static String userFacingScanFailure(Object error) {
    if (error is BleRadioUnavailableException) {
      return error.message;
    }
    final text = '$error';
    final lower = text.toLowerCase();
    if (error is TimeoutException ||
        lower.contains('timeout') ||
        lower.contains('poweredoff') ||
        lower.contains('powered off')) {
      return '藍牙未開啟或尚未就緒。請先在系統設定開啟藍牙後再搜尋。';
    }
    if (lower.contains('unauthorized') ||
        lower.contains('permission') ||
        lower.contains('denied')) {
      return '需要藍牙權限才能搜尋。請到系統設定允許此 App 使用藍牙。';
    }
    if (lower.contains('unsupported') ||
        lower.contains('not available') ||
        lower.contains('missingpluginexception')) {
      return '這台主機沒有可用的藍牙 LE 實作。';
    }
    if (lower.contains('org.bluez') ||
        lower.contains('bluez') ||
        lower.contains('dbus') ||
        lower.contains('failed to connect to socket')) {
      return '找不到可用的 BlueZ／D-Bus 藍牙服務。'
          '請確認系統已安裝並啟動 bluetooth 服務後再試。';
    }
    return 'BLE 搜尋失敗：$error';
  }

  /// Current radio state, used before starting a scan so powered-off hosts
  /// fail immediately with a clear reason instead of waiting on a stream.
  static Future<AvailabilityState> bluetoothAvailability() =>
      UniversalBle.getBluetoothAvailabilityState();

  /// The name to show for a scanned peripheral.
  ///
  /// `BleDevice.name` has already had every non-ASCII character stripped by the
  /// BLE package's own constructor, so an adapter advertising a Chinese or
  /// Japanese name arrives here as an empty string. `rawName` is the untouched
  /// advertisement. Falling through to the address is the last resort: plenty
  /// of cheap ELM327 clones advertise nothing at all, and dropping those from
  /// the list leaves the user staring at a scan that cannot see hardware
  /// sitting a foot away. An address is less friendly than a name and
  /// infinitely more useful than an absence.
  static String _displayNameFor(BleDevice device) {
    final ascii = device.name ?? '';
    if (ascii.isNotEmpty) return ascii;
    final raw = device.rawName?.trim() ?? '';
    if (raw.isNotEmpty) return raw;
    return '未命名裝置 (${device.deviceId})';
  }

  /// Scan results as plain records, so the UI layer can list devices without
  /// importing BLE package types.
  ///
  /// The stream **closes** when the scan ends. The underlying scan stream is a
  /// long-lived broadcast stream that stays open after the radio stops, so
  /// awaiting it directly leaves the caller believing a scan is still running
  /// forever — which is how a "Scanning…" button ends up disabled for the life
  /// of the screen.
  ///
  /// Each advertisement arrives as its own event, including repeats from an
  /// adapter already seen, so a consumer must upsert by id rather than append.
  ///
  /// Only the newest scan generation may call the global `stopScan` — an
  /// older cancelled startup that loses the race after `startScan` must not
  /// tear down a newer screen's radio session.
  static int _scanGeneration = 0;

  static Stream<(String, String, int?)> scanEntries({
    Duration timeout = const Duration(seconds: 12),
  }) {
    final generation = ++_scanGeneration;
    final controller = StreamController<(String, String, int?)>();
    StreamSubscription<BleDevice>? resultsSub;
    Timer? deadline;
    var cancelled = false;

    Future<void> close() async {
      cancelled = true;
      deadline?.cancel();
      await resultsSub?.cancel();
      if (generation == _scanGeneration) {
        try {
          final scanning = await UniversalBle.isScanning();
          // A newer scan may have started while isScanning awaited — only the
          // current generation may issue the global stop.
          if (generation == _scanGeneration && scanning) {
            await UniversalBle.stopScan();
          }
        } on Object {
          // Radio already stopped or turned off; nothing to unwind.
        }
      }
      if (!controller.isClosed) await controller.close();
    }

    controller.onCancel = close;

    Future<void> start() async {
      try {
        final current = await UniversalBle.getBluetoothAvailabilityState();
        // User may have cancelled while availability was awaited — do not arm a
        // global radio scan that close() can no longer associate with this start.
        if (cancelled || controller.isClosed) return;
        if (current != AvailabilityState.poweredOn) {
          throw BleRadioUnavailableException(current);
        }

        resultsSub = UniversalBle.scanStream.listen((device) {
          if (cancelled || controller.isClosed) return;
          controller.add((
            device.deviceId,
            _displayNameFor(device),
            device.rssi,
          ));
        }, onError: (Object error, StackTrace stack) {
          if (!cancelled && !controller.isClosed) {
            controller.addError(
              BleRadioUnavailableException.fromScanError(error),
              stack,
            );
          }
        });

        if (cancelled || controller.isClosed) {
          await resultsSub?.cancel();
          resultsSub = null;
          return;
        }

        await UniversalBle.startScan();
        if (cancelled || controller.isClosed) {
          await close();
          return;
        }
        // The scan itself takes no duration — unlike the previous package,
        // there is no plugin-side timer to stop the radio and no "is scanning"
        // stream to observe it stopping. This deadline is the only thing that
        // ends the scan, so it must be armed unconditionally.
        deadline = Timer(timeout, () => unawaited(close()));
      } on Object catch (e) {
        if (!cancelled && !controller.isClosed) {
          controller.addError(
            e is BleRadioUnavailableException
                ? e
                : BleRadioUnavailableException.fromScanError(e),
          );
        }
        await close();
      }
    }

    controller.onListen = () => unawaited(start());
    return controller.stream;
  }

  @override
  Future<void> connect() async {
    _mtuRequestOutcome = 'notAttempted';
    _selectedServiceUuid = null;
    _selectedWriteCharacteristicUuid = null;
    _selectedNotifyCharacteristicUuid = null;
    _subscriptionKind = null;
    final device = _device;
    try {
      await device.connect(timeout: const Duration(seconds: 15));
    } on UniversalBleException catch (e) {
      throw TransportException('無法連線到 $displayName。請確認轉接器已通電且在範圍內。', e);
    }

    // Everything past this point owns a live BLE link, and setup can fail at
    // any of four awaits — a transient GATT 133 on discovery, a characteristic
    // whose flags do not permit notification, a stack that drops the link
    // mid-setup. Only the "no serial endpoint" branch used to give the link
    // back, so the other failures threw while the OS still held the connection
    // and a notification subscription was live: the retry then failed with
    // "already connected", and bytes arrived into a transport the app believed
    // was disconnected.
    var committed = false;
    try {
      _stateSub = device.connectionStream.listen((isConnected) {
        if (!isConnected) setConnected(false);
      });

      // A larger MTU lets a whole multi-PID reply land in one notification
      // rather than split across several. Android honours it; on Apple the OS
      // negotiates its own and this is at best a no-op.
      //
      // Best-effort on purpose. The previous package took the MTU as a connect
      // argument, so a stack that refused it failed the connection; here it is
      // a separate request and a refusal costs throughput, not the link. A
      // transport that works slowly beats one that does not open.
      try {
        await device.requestMtu(requestedMtu);
        _mtuRequestOutcome = 'succeeded';
      } on Object {
        _mtuRequestOutcome = 'failed';
        // Negotiation refused or unsupported on this platform. The default
        // 23-byte MTU still carries every ELM327 reply, just in more frames.
      }

      final services = await device.discoverServices();
      final pair = _findUartPair(services);
      if (pair == null) {
        throw TransportException('$displayName 沒有可用的序列埠特徵值，可能不是 ELM327 轉接器。');
      }
      _write = pair.$1;
      _notify = pair.$2;
      _selectedServiceUuid = _write!.metaData?.serviceId;
      _selectedWriteCharacteristicUuid = _write!.uuid;
      _selectedNotifyCharacteristicUuid = _notify!.uuid;

      // Listener first, CCCD second. `onValueReceived` is a live stream, not
      // a replay buffer, and some BLE UART clones emit a ready banner or
      // whatever they had buffered the instant notifications are enabled — so
      // subscribing after the await drops those bytes. Losing the first frame
      // of a session is the kind of fault that shows up as an unexplained
      // handshake failure on one particular adapter.
      _valueSub = _notify!.onValueReceived.listen(emitBytes);
      try {
        // Notify and indicate are different CCCD writes and, in this package,
        // different calls that each throw when the characteristic lacks the
        // matching property. `_findUartPair` deliberately accepts either, so
        // asking blindly for notifications breaks every indicate-only clone —
        // a whole family of adapters that would otherwise have worked.
        final usesNotifications = _notify!.properties.contains(
          CharacteristicProperty.notify,
        );
        _subscriptionKind = usesNotifications ? 'notification' : 'indication';
        final subscription = usesNotifications
            ? _notify!.notifications
            : _notify!.indications;
        await subscription.subscribe();
      } on Object {
        // The subscription is live but useless; `_releaseLink` in the `finally`
        // below would tidy it, and doing it here keeps the failure local.
        await _valueSub?.cancel();
        _valueSub = null;
        rethrow;
      }

      setConnected(true);
      committed = true;
    } finally {
      if (!committed) await _releaseLink();
    }
  }

  /// Hands the BLE link and everything attached to it back to the OS.
  ///
  /// Best-effort throughout: this runs while something has already gone wrong,
  /// and a secondary failure here would replace the diagnosis the caller is
  /// about to throw with a less useful one.
  Future<void> _releaseLink() async {
    await _valueSub?.cancel();
    _valueSub = null;
    await _stateSub?.cancel();
    _stateSub = null;
    try {
      await _notify?.unsubscribe();
    } on Object {
      // The characteristic may already be gone with the link.
    }
    _write = null;
    _notify = null;
    try {
      await _device.disconnect();
    } on Object {
      // Already disconnected, which is the state we wanted anyway.
    }
  }

  /// Returns a (write, notify) characteristic pair, or null if the device has
  /// no usable serial endpoint.
  (BleCharacteristic, BleCharacteristic)? _findUartPair(
    List<BleService> services,
  ) {
    // Two explicit passes rather than a sort: Dart's List.sort is not stable,
    // so for a device whose services are all unknown the "equal" comparisons
    // would leave the pick to an arbitrary ordering that can differ between
    // connections to the same adapter.
    final ordered = <BleService>[
      for (final uuid in _preferredServices)
        ...services.where((s) => s.uuid.toLowerCase() == uuid),
      ...services.where(
        (s) => !_preferredServices.contains(s.uuid.toLowerCase()),
      ),
    ];

    for (final service in ordered) {
      BleCharacteristic? writable;
      BleCharacteristic? notifiable;
      for (final c in service.characteristics) {
        final p = c.properties;
        if (writable == null &&
            (p.contains(CharacteristicProperty.write) ||
                p.contains(CharacteristicProperty.writeWithoutResponse))) {
          writable = c;
        }
        if (notifiable == null &&
            (p.contains(CharacteristicProperty.notify) ||
                p.contains(CharacteristicProperty.indicate))) {
          notifiable = c;
        }
      }
      if (writable != null && notifiable != null) return (writable, notifiable);
    }
    return null;
  }

  @override
  Future<void> disconnect() async {
    await _valueSub?.cancel();
    _valueSub = null;
    await _stateSub?.cancel();
    _stateSub = null;
    try {
      await _device.disconnect();
    } on Object {
      // Already gone — the state listener has reported it.
    }
    _write = null;
    _notify = null;
    setConnected(false);
  }

  @override
  Future<void> write(List<int> data) async {
    final characteristic = _write;
    if (characteristic == null) {
      throw const WriteRefusedException('BLE 連線尚未建立。');
    }
    // Write-without-response avoids an ACK round-trip per command, which
    // roughly doubles achievable PIDs/sec on chatty adapters.
    final withoutResponse = characteristic.properties.contains(
      CharacteristicProperty.writeWithoutResponse,
    );
    await characteristic.write(data, withResponse: !withoutResponse);
  }
}

/// BLE radio is not in a state that can scan or connect.
///
/// Distinct from an empty scan result: the radio itself refused the work, so
/// the connect screen should not show the "no adapters found" checklist.
final class BleRadioUnavailableException implements Exception {
  BleRadioUnavailableException(AvailabilityState state)
    : state = state,
      cause = null,
      message = _messageFor(state);

  BleRadioUnavailableException.fromScanError(Object error)
    : state = null,
      cause = error,
      message = BleTransport.userFacingScanFailure(error);

  final AvailabilityState? state;
  final Object? cause;
  final String message;

  static String _messageFor(AvailabilityState state) {
    return switch (state) {
      AvailabilityState.poweredOff =>
        '藍牙未開啟。請先在系統設定開啟藍牙後再搜尋。',
      AvailabilityState.unauthorized =>
        '需要藍牙權限才能搜尋。請到系統設定允許此 App 使用藍牙。',
      AvailabilityState.unsupported => '這台主機不支援藍牙 LE。',
      AvailabilityState.unknown ||
      AvailabilityState.resetting ||
      AvailabilityState.poweredOn =>
        '藍牙目前無法使用（$state）。請稍後再試。',
    };
  }

  @override
  String toString() => message;
}
