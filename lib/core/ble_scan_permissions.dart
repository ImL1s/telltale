/// The one version-aware Bluetooth permission rule, shared by every shell.
///
/// Extracted from the connect screen so the wear shell cannot grow a weaker
/// copy. The trap this encodes: `permission_handler` reports a request for a
/// permission the OS does not define as **granted**, so on Android 11 and
/// below the modern `BLUETOOTH_SCAN`/`BLUETOOTH_CONNECT` requests succeed
/// vacuously while BLE scanning is actually gated behind location — skipping
/// the location request makes the scan return an empty list with no error,
/// which looks exactly like "no adapters nearby".
library;

import 'dart:io';

import 'package:flutter_classic_bluetooth/flutter_classic_bluetooth.dart'
    show FlutterClassicBluetooth;
import 'package:permission_handler/permission_handler.dart';

enum BlePermissionOutcome { granted, denied, permanentlyDenied }

final class BlePermissionResult {
  const BlePermissionResult(this.outcome, {this.deniedLabel});

  final BlePermissionOutcome outcome;

  /// Which permission was actually refused, so a message can name it —
  /// 「藍牙」 on Android 12+, 「位置」 below.
  final String? deniedLabel;

  bool get granted => outcome == BlePermissionOutcome.granted;
}

/// The first Android release with `BLUETOOTH_SCAN` / `BLUETOOTH_CONNECT`.
const int _androidS = 31;

/// Acquires exactly the permissions the next action needs, and no others.
Future<BlePermissionResult> ensureBluetoothPermissions({
  required bool forScanning,
}) async {
  if (!Platform.isAndroid) {
    return const BlePermissionResult(BlePermissionOutcome.granted);
  }

  final sdk = await FlutterClassicBluetooth().androidSdkInt();
  // Unknown means an Android where the plugin could not answer; assume the
  // modern behaviour rather than asking for location on a device that
  // declares `neverForLocation`.
  final modern = sdk == null || sdk >= _androidS;

  if (modern) {
    final results = await <Permission>[
      Permission.bluetoothConnect,
      if (forScanning) Permission.bluetoothScan,
    ].request();
    if (results.values.every((status) => status.isGranted)) {
      return const BlePermissionResult(BlePermissionOutcome.granted);
    }
    // The user said no. Location is a different permission for a different
    // purpose and cannot substitute for this one.
    return BlePermissionResult(
      results.values.any((status) => status.isPermanentlyDenied)
          ? BlePermissionOutcome.permanentlyDenied
          : BlePermissionOutcome.denied,
      deniedLabel: '藍牙',
    );
  }

  // Android 11 or below: `BLUETOOTH` and `BLUETOOTH_ADMIN` are install-time,
  // so a bonded adapter needs nothing further.
  if (!forScanning) {
    return const BlePermissionResult(BlePermissionOutcome.granted);
  }

  // Only discovery is gated on location here, and declaring it in the
  // manifest is not enough — it is a runtime permission like any other.
  final location = await Permission.locationWhenInUse.request();
  if (location.isGranted || location.isLimited) {
    return const BlePermissionResult(BlePermissionOutcome.granted);
  }
  return BlePermissionResult(
    location.isPermanentlyDenied
        ? BlePermissionOutcome.permanentlyDenied
        : BlePermissionOutcome.denied,
    deniedLabel: '位置',
  );
}
