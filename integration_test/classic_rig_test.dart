/// App-level Bluetooth Classic simulation.
///
/// Android emulators do not expose RFCOMM hardware, so this test replaces only
/// the plugin's platform channels with a deterministic paired adapter and
/// bridges its serial bytes to the built-in Demo ECU. It exercises the shipped
/// connection wizard, paired-device selection, secure-SPP tier, byte stream,
/// ELM327 handshake, polling, and evidence labelling. Generic lifecycle
/// recovery is exercised by the Demo/Wi-Fi rigs and unit tests; this test stays
/// focused on the Classic plugin boundary that those transports do not use. It
/// deliberately does not claim Android BluetoothSocket or radio proof.
///
/// Run with an Android device or emulator attached (set ANDROID_SERIAL when
/// more than one device is connected):
///
///     flutter test integration_test/classic_rig_test.dart -d <device-id> \
///       --flavor rig --dart-define=TELLTALE_TEST_RIG=true
library;

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:torque_obd/obd/transport/demo_transport.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/obd_session.dart';

import 'rig_support.dart';

const String _address = '00:11:22:33:44:55';
const String _name = 'Simulated Classic ELM327';
const int _connectionId = 701;
const MethodChannel _methods = MethodChannel(
  'flutter_classic_bluetooth/methods',
);
const MethodChannel _permissions = MethodChannel(
  'flutter.baseflow.com/permissions/methods',
);
const EventChannel _data = EventChannel(
  'flutter_classic_bluetooth/connection/$_connectionId',
);
const EventChannel _state = EventChannel(
  'flutter_classic_bluetooth/connection_state/$_connectionId',
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('select, connect, poll and record through simulated RFCOMM', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final demo = DemoTransport();
    final methodCalls = <MethodCall>[];
    final writes = <String>[];
    final pending = <Uint8List>[];
    MockStreamHandlerEventSink? dataSink;

    final demoSub = demo.incoming.listen((bytes) {
      final chunk = Uint8List.fromList(bytes);
      final sink = dataSink;
      if (sink == null) {
        pending.add(chunk);
      } else {
        sink.success(chunk);
      }
    });

    messenger.setMockStreamHandler(
      _data,
      MockStreamHandler.inline(
        onListen: (_, sink) {
          dataSink = sink;
          for (final chunk in pending) {
            sink.success(chunk);
          }
          pending.clear();
        },
        onCancel: (_) {
          dataSink = null;
        },
      ),
    );
    messenger.setMockStreamHandler(
      _state,
      MockStreamHandler.inline(onListen: (_, _) {}),
    );
    messenger.setMockMethodCallHandler(_methods, (call) async {
      methodCalls.add(call);
      switch (call.method) {
        case 'androidSdkInt':
          return 36;
        case 'isEnabled':
          return true;
        case 'stopDiscovery':
          return null;
        case 'getPairedDevices':
          return [
            {
              'address': _address,
              'name': _name,
              'type': 'classic',
              'bondState': 'bonded',
              'uuids': const <String>[],
            },
          ];
        case 'connect':
          await demo.connect();
          return {'id': _connectionId};
        case 'write':
          final arguments = call.arguments as Map<Object?, Object?>;
          expect(arguments['id'], _connectionId);
          final bytes = (arguments['data'] as Uint8List).toList();
          writes.add(String.fromCharCodes(bytes));
          await demo.write(bytes);
          return null;
        case 'disconnect':
          await demo.disconnect();
          return null;
        case 'cancelConnect':
          return false;
        default:
          fail('unexpected Classic platform call: ${call.method}');
      }
    });
    messenger.setMockMethodCallHandler(_permissions, (call) async {
      if (call.method != 'requestPermissions') {
        fail('unexpected permission platform call: ${call.method}');
      }
      final requested = (call.arguments as List<Object?>).cast<int>();
      return {for (final permission in requested) permission: 1};
    });

    addTearDown(() async {
      messenger.setMockMethodCallHandler(_methods, null);
      messenger.setMockMethodCallHandler(_permissions, null);
      messenger.setMockStreamHandler(_data, null);
      messenger.setMockStreamHandler(_state, null);
      await demoSub.cancel();
      await demo.disconnect();
    });

    await startCleanRigApp(tester);

    final classicHeader = await revealText(tester, 'Bluetooth Classic');
    await tester.tap(classicHeader);
    await tester.pump();
    final paired = await pumpUntil(
      tester,
      () => find.text(_name).evaluate().isNotEmpty,
      timeout: const Duration(seconds: 10),
    );
    expect(paired, isTrue, reason: 'the paired Classic adapter was not listed');

    final adapter = await revealText(tester, _name);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -120));
    await tester.pump();
    await tester.tap(adapter);
    await tester.pump();

    await requireDashboard(tester);
    await requireLivePolling(tester);
    await completeTelemetryRigJourney(
      tester,
      expectedTransport: TransportKind.bluetoothClassic,
    );

    final connectCalls = methodCalls.where((call) => call.method == 'connect');
    expect(connectCalls, hasLength(1));
    final connectArguments =
        connectCalls.single.arguments as Map<Object?, Object?>;
    expect(connectArguments['address'], _address);
    expect(connectArguments['secure'], isTrue);
    expect(connectArguments, isNot(contains('channel')));
    expect(methodCalls.where((call) => call.method == 'write'), isNotEmpty);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp)),
      listen: false,
    );
    final session = container.read(obdSessionProvider.notifier);
    expect(
      session.engine?.isRunning,
      isTrue,
      reason: 'the Classic polling engine stopped before evidence was saved',
    );
    await session.saveTranscriptSnapshotForTest();
    final stored = await waitForStoredTranscript(
      tester,
      (value) => value.body.contains(r'>> 0100\r'),
    );
    expect(stored, isNotNull, reason: 'Classic evidence was not persisted');
    expect(stored!.fromRealHardware, isFalse);
    expect(stored.header, contains('# Telltale 無車測試馬具證據 v1'));
    expect(stored.header, contains('不得視為實體轉接器或實車驗證'));
    expect(stored.header, contains('# 連線方式：Bluetooth Classic'));
    expect(stored.header, contains('# 裝置：$_name'));
    expect(stored.header, contains('# 連線資訊.deviceIdentifier：$_address'));
    expect(stored.header, contains('# 連線資訊.paired：true'));
    expect(stored.body, contains(r'>> ATZ\r'));
    expect(stored.body, contains(r'>> 0100\r'));
    expect(stored.body, contains('  << '));
    expect(writes, contains('ATZ\r'));
  });
}
