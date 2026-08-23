/// The recording has to survive the failure it was made for.
///
/// A refusal audit found that the diagnostic kit could not be reached in the
/// one situation it exists for: every connect failure runs a teardown, the
/// teardown discarded the client, the export read the transcript off the
/// client — so the session whose bytes somebody actually needed was the session
/// whose bytes were deleted, by the code written to keep them.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/obd/physics/vehicle_profile.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_registry.dart';
import 'package:torque_obd/state/settings.dart';

import 'support/fake_elm327.dart';

Future<ProviderContainer> _container() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a handshake that fails still leaves its bytes behind', () async {
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);

    // An adapter that answers the reset and then refuses the protocol search,
    // which is a critical step: the connection fails and everything is torn
    // down.
    final transport = FakeElm327(
      protocol: BusProtocol.can11,
      ecus: const [],
      faults: const AdapterFaults(forcedReplies: {'ATSP0': '?'}),
    );

    final ok = await session.connectForTest(transport, TransportKind.wifi);
    expect(ok, isFalse, reason: 'the fixture must fail to connect');

    expect(
      session.client,
      isNull,
      reason: 'the session is gone, as it should be',
    );
    expect(
      session.hasTranscript,
      isTrue,
      reason: 'and the bytes are not — this is the entire point',
    );

    final text = session.exportableTranscript!.render(
      header: session.exportableTranscriptHeader,
    );
    expect(text, contains('# Telltale 實車證據 v1'));
    expect(text, contains('# 隱私提醒：'));
    expect(text, contains('# 工作階段：'));
    expect(text, contains('# App：'));
    expect(text, contains('# 車輛設定：'));
    expect(
      text,
      contains('ATZ'),
      reason: 'the handshake that failed is what somebody needs to read',
    );
    expect(text, contains('ATSP0'));
    expect(
      text,
      contains(r'\r'),
      reason: 'and it is the raw bytes, not a tidied summary',
    );
    expect(
      text,
      contains('# 連線方式：Wi-Fi'),
      reason:
          'a record with no idea what produced it is most of the way to '
          'useless, and the header is rendered while the client still exists',
    );
  });

  test('adapter-controlled identity text cannot forge evidence headers', () async {
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    const forgedLine = '# FORGED: PASS';

    expect(
      await session.connectForTest(
        FakeElm327(
          protocol: BusProtocol.can11,
          identity: 'ELM327 v2.1\n$forgedLine\x1B',
          deviceDescription: 'owner\n$forgedLine\x01',
          ecus: [
            FakeEcu(
              name: 'ECM',
              requestId: '7E0',
              responseId: '7E8',
              responses: const {
                '0100': [0x41, 0x00, 0xBE, 0x1F, 0xA8, 0x13],
              },
            ),
          ],
        ),
        TransportKind.wifi,
      ),
      isTrue,
    );

    final header = session.exportableTranscriptHeader;
    expect(header, contains(r'\n# FORGED: PASS'));
    expect(header, contains(r'\x1B'));
    expect(header, contains(r'\x01'));
    expect(header.split('\n'), isNot(contains(forgedLine)));
    expect(header, isNot(contains('\x01')));
    expect(header, isNot(contains('\x1B')));
  });

  test(
    'a second attempt does not erase the first attempt evidence early',
    () async {
      // The failing attempt is kept until something replaces it.
      final container = await _container();
      addTearDown(container.dispose);
      final session = container.read(obdSessionProvider.notifier);

      await session.connectForTest(
        FakeElm327(
          protocol: BusProtocol.can11,
          ecus: const [],
          faults: const AdapterFaults(forcedReplies: {'ATSP0': '?'}),
        ),
        TransportKind.wifi,
      );
      expect(session.hasTranscript, isTrue);

      final first = session.exportableTranscript!.render();
      expect(first, contains('ATSP0'));
    },
  );

  test('a transport that never connected still leaves a record', () async {
    // The failure with the least to say for itself, and therefore the one
    // where an empty export is worst: a Wi-Fi socket refused, a Bluetooth
    // cascade that timed out. Not one OBD byte exists, so a record that began
    // at the handshake began after everything that happened. It begins at the
    // tap now.
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);

    final ok = await session.connectForTest(
      _DeadTransport(),
      TransportKind.wifi,
    );
    expect(ok, isFalse);
    expect(
      session.hasTranscript,
      isTrue,
      reason: 'the attempt happened, so there is something to say about it',
    );

    final text = session.exportableTranscript!.render();
    expect(text, contains('開始連線'));
    expect(
      text,
      contains('連線失敗'),
      reason: 'and what it failed with, which is the whole point',
    );
  });

  test(
    'attempt metadata is frozen and survives a transport-level failure',
    () async {
      final container = await _container();
      addTearDown(container.dispose);
      final session = container.read(obdSessionProvider.notifier);

      await session.connectForTest(_DeadTransport(), TransportKind.wifi);
      final firstHeader = session.exportableTranscriptHeader;
      expect(firstHeader, contains('# 連線資訊.host：10.255.255.1'));
      expect(firstHeader, contains('# 連線資訊.port：35000'));
      expect(firstHeader, contains('# 車輛設定：2 L · 1500 kg · VE 85%'));

      await container
          .read(vehicleProfileProvider.notifier)
          .update(
            const VehicleProfile(
              displacementL: 5,
              massKg: 2500,
              volumetricEfficiency: 110,
            ),
          );

      expect(session.exportableTranscriptHeader, firstHeader);
      expect(session.exportableTranscriptHeader, isNot(contains('5 L')));
    },
  );

  test('R28-N6: the heading always describes the transcript it sits on', () async {
    // Cursor round 28. `exportTranscript` read the transcript, awaited the
    // temporary directory, and only then read the header — so a connection
    // begun in that gap gave it the new session's adapter, protocol and bus
    // over the old session's bytes. A record whose heading describes a
    // different car is worse than no record at all, because nothing in it
    // looks wrong.
    //
    // The two are read together now, and this is the test for the pairing
    // rather than for either half.
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);

    await session.connectForTest(_DeadTransport(), TransportKind.wifi);
    final record = session.exportableRecord;
    expect(record, isNotNull);

    // The cross-check, rather than two independent assertions: the transcript
    // opens by naming the device the attempt was aimed at, and the heading has
    // to name the same one. Anything that lets them drift shows up here.
    final opening = record!.transcript.render().split('\n').first;
    expect(opening, contains('開始連線'));
    final device = _DeadTransport().displayName;
    expect(opening, contains(device));
    expect(
      record.header,
      contains(device),
      reason:
          'the heading describes the bytes underneath it or it is worse '
          'than no heading — nothing in a mislabelled record looks wrong',
    );

    // The race itself — a connection begun between the export's two reads —
    // is closed by construction rather than by this test: there is one read
    // now, so there is no interval to lose. Mutating that back is not
    // something an assertion here can catch, which is why the accessor returns
    // a pair instead of the two getters being kept in step by hand.
  });

  test('nothing attempted means nothing to export, and it says so', () async {
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);
    expect(session.hasTranscript, isFalse);
    expect(session.exportableTranscript, isNull);
  });

  test('a live session exports the live transcript, not a stale one', () async {
    final container = await _container();
    addTearDown(container.dispose);
    final session = container.read(obdSessionProvider.notifier);

    await session.connectForTest(
      FakeElm327(
        protocol: BusProtocol.can11,
        ecus: const [],
        faults: const AdapterFaults(forcedReplies: {'ATSP0': '?'}),
      ),
      TransportKind.wifi,
    );
    final failed = session.exportableTranscript;

    expect(
      await session.connectForTest(
        FakeElm327(
          protocol: BusProtocol.can11,
          ecus: [
            FakeEcu(
              name: 'ECM',
              requestId: '7E0',
              responseId: '7E8',
              responses: {
                '0100': [0x41, 0x00, 0xBE, 0x3F, 0xA8, 0x13],
              },
            ),
          ],
        ),
        TransportKind.demo,
      ),
      isTrue,
    );
    expect(
      session.exportableTranscript,
      isNot(same(failed)),
      reason: 'once a session is live, its own traffic is what matters',
    );
    expect(session.exportableTranscriptHeader, contains('Demo'));
  });
}

/// A transport that refuses, the way a wrong IP address does.
class _DeadTransport extends BaseObdTransport {
  @override
  TransportKind get kind => TransportKind.wifi;

  @override
  String get displayName => '10.255.255.1:35000';

  @override
  Map<String, Object> get diagnosticMetadata => const {
    'host': '10.255.255.1',
    'port': 35000,
  };

  @override
  Future<void> connect() async =>
      throw const TransportException('無法連線到 10.255.255.1:35000。');

  @override
  Future<void> disconnect() async => setConnected(false);

  @override
  Future<void> write(List<int> data) async {}
}
