/// Coverage for the paths the simulator never exercises.
///
/// `DemoTransport` always answers promptly and always on header 7E0, so the
/// timeout/resync machinery and the header-switching branch of `sendOnHeader`
/// had no test reaching them at all. Both are among the most delicate code in
/// the client, and both fail in ways that show wrong numbers rather than
/// errors, so they get a purpose-built transport instead.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/elm327_client.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';

/// What a healthy adapter answers during the handshake.
///
/// Spelled out rather than defaulted. An earlier version of this transport
/// answered `OK` to anything it had not been told about, which meant every test
/// silently supplied a passing reply to the critical `0100` probe — the one
/// step that proves a *vehicle* is on the bus. That default is precisely the
/// hole that let "connected to something that acknowledges everything" count as
/// a working car, so unscripted commands now answer `?` the way real hardware
/// does, and the handshake has to be satisfied on purpose.
const Map<String, (String, Duration)> _healthyHandshake = {
  'ATZ': ('ELM327 v2.1\r\r>', Duration.zero),
  'ATE0': ('OK\r>', Duration.zero),
  'ATL0': ('OK\r>', Duration.zero),
  'ATM0': ('OK\r>', Duration.zero),
  'ATS0': ('OK\r>', Duration.zero),
  'ATAT2': ('OK\r>', Duration.zero),
  'ATST66': ('OK\r>', Duration.zero),
  'ATSP0': ('OK\r>', Duration.zero),
  'ATI': ('ELM327 v2.1\r>', Duration.zero),
  'AT@1': ('Scripted Adapter\r>', Duration.zero),
  'ATRV': ('13.9V\r>', Duration.zero),
  '0100': ('41 00 BE 1F A8 13\r>', Duration.zero),
  'ATDP': ('AUTO, ISO 15765-4 (CAN 11/500)\r>', Duration.zero),
  'ATDPN': ('A6\r>', Duration.zero),
  'ATSH7E0': ('OK\r>', Duration.zero),
};

/// A transport whose replies are scripted per command, with optional delay.
class _ScriptedTransport extends BaseObdTransport {
  _ScriptedTransport(Map<String, (String, Duration)> script)
      : script = {..._healthyHandshake, ...script};

  /// command (uppercased, spaces removed) -> (reply, delay)
  final Map<String, (String, Duration)> script;

  final List<String> sent = [];

  @override
  TransportKind get kind => TransportKind.demo;

  @override
  String get displayName => 'Scripted';

  @override
  Future<void> connect() async => setConnected(true);

  @override
  Future<void> disconnect() async => setConnected(false);

  @override
  Future<void> write(List<int> data) async {
    final raw = ascii.decode(data, allowInvalid: true).trim();
    final key = raw.toUpperCase().replaceAll(' ', '');
    sent.add(key);

    // Unknown commands get `?`, as an ELM327 gives. A test that forgets to
    // script something fails on that, rather than passing on a courtesy.
    final entry = script[key] ?? ('?\r>', Duration.zero);
    if (entry.$2 == Duration.zero) {
      scheduleMicrotask(() => emitBytes(ascii.encode(entry.$1)));
    } else {
      Timer(entry.$2, () => emitBytes(ascii.encode(entry.$1)));
    }
  }
}

void main() {
  group('timeout and resynchronisation', () {
    test('a late reply is discarded instead of answering the next command',
        () async {
      final transport = _ScriptedTransport({
        // Answers well after the command timeout below.
        '010C': ('41 0C 27 10\r>', const Duration(milliseconds: 400)),
        '010D': ('41 0D 3C\r>', const Duration(milliseconds: 10)),
      });
      final client = Elm327Client(
        transport,
        commandTimeout: const Duration(milliseconds: 80),
      );
      // A real connect() is what subscribes the client to the byte stream; the
      // scripted transport answers OK to every AT step so the handshake passes.
      expect(await client.connect(), isTrue);
      transport.sent.clear();

      await expectLater(
        client.send('010C'),
        throwsA(isA<TimeoutException>()),
      );

      // The stale 010C reply is still in flight. The next command must not be
      // completed by it — 2500 rpm arriving as a speed reading is exactly the
      // desync this guards against.
      final response = await client.send('010D');
      expect(response.hexPayload, '410D3C');

      await client.dispose();
    });
  });

  group('sendOnHeader', () {
    test('switches the header and answers on it within one transaction',
        () async {
      final transport = _ScriptedTransport({
        'ATSH7E1': ('OK\r>', Duration.zero),
        '221E1C': ('62 1E 1C 02 80\r>', Duration.zero),
      });
      final client = Elm327Client(transport);
      expect(await client.connect(), isTrue);
      transport.sent.clear();

      final response = await client.sendOnHeader('7E1', '221E1C');
      expect(response.isSuccess, isTrue);
      expect(response.bytes, [0x62, 0x1E, 0x1C, 0x02, 0x80]);
      // The header switch must precede the query, and both must be sent.
      expect(transport.sent, ['ATSH7E1', '221E1C']);

      await client.dispose();
    });

    test('does not re-send the header when it is already selected', () async {
      final transport = _ScriptedTransport({
        'ATSH7E1': ('OK\r>', Duration.zero),
        '221E1C': ('62 1E 1C 02 80\r>', Duration.zero),
      });
      final client = Elm327Client(transport);
      expect(await client.connect(), isTrue);
      transport.sent.clear();

      await client.sendOnHeader('7E1', '221E1C');
      await client.sendOnHeader('7E1', '221E1C');
      expect(transport.sent.where((c) => c == 'ATSH7E1').length, 1);

      await client.dispose();
    });

    test('a refused header switch fails the whole transaction', () async {
      final transport = _ScriptedTransport({
        'ATSH7E1': ('?\r>', Duration.zero),
      });
      final client = Elm327Client(transport);
      expect(await client.connect(), isTrue);
      transport.sent.clear();

      await expectLater(
        client.sendOnHeader('7E1', '221E1C'),
        throwsA(isA<TransportException>()),
      );
      // The query must not have gone out against the wrong header.
      expect(transport.sent, isNot(contains('221E1C')));

      await client.dispose();
    });
  });
}
