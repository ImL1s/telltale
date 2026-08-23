import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/obd/transport/wifi_transport.dart';

Future<void> _waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition was not met', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  group('WifiTransport loopback socket', () {
    test('write before connect is refused before any network I/O', () async {
      final transport = WifiTransport(host: InternetAddress.loopbackIPv4.host);

      await expectLater(
        transport.write(const [0x30, 0x31, 0x30, 0x43, 0x0D]),
        throwsA(
          isA<WriteRefusedException>().having(
            (error) => error.message,
            'message',
            contains('尚未建立'),
          ),
        ),
      );
      expect(transport.isConnected, isFalse);
    });

    test('forwards fragmented bytes in order and writes exact bytes', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final accepted = server.first;
      final transport = WifiTransport(
        host: InternetAddress.loopbackIPv4.host,
        port: server.port,
      );
      addTearDown(transport.disconnect);

      final received = <int>[];
      final incomingSub = transport.incoming.listen(received.addAll);
      addTearDown(incomingSub.cancel);
      await transport.connect();
      final peer = await accepted;
      addTearDown(peer.destroy);

      peer.add(const [0x41]);
      await peer.flush();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      peer.add(const [0x42, 0x43]);
      await peer.flush();
      await _waitUntil(() => received.length == 3);
      expect(received, const [0x41, 0x42, 0x43]);

      final peerBytes = <int>[];
      final peerRead = peer.listen(peerBytes.addAll);
      addTearDown(peerRead.cancel);
      await transport.write(const [0x30, 0x31, 0x30, 0x43, 0x0D]);
      await _waitUntil(() => peerBytes.length == 5);
      expect(peerBytes, const [0x30, 0x31, 0x30, 0x43, 0x0D]);
    });

    test('peer EOF emits one false transition and clears connection', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final accepted = server.first;
      final transport = WifiTransport(
        host: InternetAddress.loopbackIPv4.host,
        port: server.port,
      );
      addTearDown(transport.disconnect);
      final changes = <bool>[];
      final changesSub = transport.connectionChanges.listen(changes.add);
      addTearDown(changesSub.cancel);

      await transport.connect();
      final peer = await accepted;
      expect(transport.isConnected, isTrue);
      await peer.close();
      await _waitUntil(() => !transport.isConnected);
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(changes, const [true, false]);
      await expectLater(
        transport.write(const [0x0D]),
        throwsA(isA<WriteRefusedException>()),
      );
    });

    test('same transport reconnects after peer EOF', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final peers = <Socket>[];
      final acceptedTwice = Completer<void>();
      final serverSub = server.listen((peer) {
        peers.add(peer);
        if (peers.length == 2) acceptedTwice.complete();
      });
      addTearDown(serverSub.cancel);
      final transport = WifiTransport(
        host: InternetAddress.loopbackIPv4.host,
        port: server.port,
      );
      addTearDown(transport.disconnect);

      await transport.connect();
      await _waitUntil(() => peers.isNotEmpty);
      await peers.first.close();
      await _waitUntil(() => !transport.isConnected);

      await transport.connect();
      await acceptedTwice.future.timeout(const Duration(seconds: 2));
      expect(transport.isConnected, isTrue);

      final bytes = <int>[];
      final incomingSub = transport.incoming.listen(bytes.addAll);
      addTearDown(incomingSub.cancel);
      peers[1].add(const [0x4F, 0x4B, 0x3E]);
      await peers[1].flush();
      await _waitUntil(() => bytes.length == 3);
      expect(bytes, const [0x4F, 0x4B, 0x3E]);
      peers[1].destroy();
    });

    test('disconnect is idempotent and emits no duplicate false', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final accepted = server.first;
      final transport = WifiTransport(
        host: InternetAddress.loopbackIPv4.host,
        port: server.port,
      );
      final changes = <bool>[];
      final changesSub = transport.connectionChanges.listen(changes.add);
      addTearDown(changesSub.cancel);

      await transport.connect();
      final peer = await accepted;
      addTearDown(peer.destroy);
      await transport.disconnect();
      await transport.disconnect();

      expect(transport.isConnected, isFalse);
      expect(changes, const [true, false]);
    });

    test(
      'connection refusal preserves cause and actionable endpoint wording',
      () async {
        final reservation = await ServerSocket.bind(
          InternetAddress.loopbackIPv4,
          0,
        );
        final refusedPort = reservation.port;
        await reservation.close();
        final transport = WifiTransport(
          host: InternetAddress.loopbackIPv4.host,
          port: refusedPort,
          connectTimeout: const Duration(milliseconds: 500),
        );

        await expectLater(
          transport.connect(),
          throwsA(
            isA<TransportException>()
                .having((error) => error.cause, 'cause', isA<SocketException>())
                .having(
                  (error) => error.message,
                  'message',
                  allOf(
                    contains(
                      '${InternetAddress.loopbackIPv4.host}:$refusedPort',
                    ),
                    contains('Wi-Fi'),
                    contains('繼續使用'),
                  ),
                ),
          ),
        );
        expect(transport.isConnected, isFalse);
      },
    );
  });
}
