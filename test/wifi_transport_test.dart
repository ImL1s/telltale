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
  group('WifiTransport Android route lease', () {
    test('binds before connect and restores immediately afterward', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final events = <String>[];
      late final WifiTransport transport;
      final binder = _RecordingBinder(
        events,
        // The route must be restored before the connection is offered to
        // anyone; observing isConnected from inside release() is what pins
        // that ordering rather than just bind/connect/release adjacency.
        beforeRelease: () => expect(
          transport.isConnected,
          isFalse,
          reason: 'release must run before the connection is offered',
        ),
      );
      transport = WifiTransport(
        host: InternetAddress.loopbackIPv4.host,
        port: server.port,
        routeBinder: binder,
        socketConnector: (host, port, timeout) async {
          events.add('connect');
          return Socket.connect(host, port, timeout: timeout);
        },
      );
      addTearDown(transport.disconnect);

      await transport.connect();
      final peer = await server.first;
      addTearDown(peer.destroy);

      expect(events, const ['bind', 'connect', 'release']);
      expect(transport.isConnected, isTrue);
    });

    test('a bind that outlives the budget skips the socket entirely', () async {
      final events = <String>[];
      final transport = WifiTransport(
        host: '192.0.2.1',
        connectTimeout: const Duration(milliseconds: 100),
        routeBinder: _RecordingBinder(
          events,
          delay: const Duration(milliseconds: 150),
        ),
        socketConnector: (host, port, timeout) async {
          events.add('connect');
          throw StateError('must not connect on an exhausted budget');
        },
      );

      await expectLater(
        transport.connect(),
        throwsA(
          isA<TransportException>().having(
            (error) => error.message,
            'message',
            contains('逾時'),
          ),
        ),
      );

      expect(events, const ['bind', 'release']);
      expect(transport.isConnected, isFalse);
    });

    test('an unexpected connector failure still restores the route', () async {
      // Socket.connect only throws SocketException/TimeoutException, but the
      // connector is injectable; a refactor must not be able to leak the
      // process-wide binding through a new exception shape.
      final events = <String>[];
      final transport = WifiTransport(
        host: '192.0.2.1',
        routeBinder: _RecordingBinder(events),
        socketConnector: (host, port, timeout) async {
          events.add('connect');
          throw StateError('unexpected shape');
        },
      );

      await expectLater(transport.connect(), throwsA(isA<StateError>()));

      expect(events, const ['bind', 'connect', 'release']);
      expect(transport.isConnected, isFalse);
    });

    test('restores the route when socket connection fails', () async {
      final events = <String>[];
      final binder = _RecordingBinder(events);
      final transport = WifiTransport(
        host: '192.0.2.1',
        routeBinder: binder,
        socketConnector: (host, port, timeout) async {
          events.add('connect');
          throw const SocketException('refused');
        },
      );

      await expectLater(transport.connect(), throwsA(isA<TransportException>()));

      expect(events, const ['bind', 'connect', 'release']);
      expect(transport.isConnected, isFalse);
    });

    test('route selection failure is clear and skips socket I/O', () async {
      var connected = false;
      final transport = WifiTransport(
        host: '192.168.0.10',
        routeBinder: _UnavailableBinder(),
        socketConnector: (host, port, timeout) async {
          connected = true;
          throw StateError('must not connect');
        },
      );

      await expectLater(
        transport.connect(),
        throwsA(
          isA<TransportException>()
              .having((error) => error.cause, 'cause', isA<WifiRouteException>())
              .having(
                (error) => error.message,
                'message',
                allOf(contains('Wi-Fi'), contains('192.168.0.10')),
              ),
        ),
      );
      expect(connected, isFalse);
    });

    test('binding time is deducted from the one connect budget', () async {
      Duration? socketBudget;
      final transport = WifiTransport(
        host: '192.0.2.1',
        connectTimeout: const Duration(milliseconds: 200),
        routeBinder: _DelayedBinder(const Duration(milliseconds: 80)),
        socketConnector: (host, port, timeout) async {
          socketBudget = timeout;
          throw const SocketException('refused');
        },
      );

      await expectLater(transport.connect(), throwsA(isA<TransportException>()));

      expect(socketBudget, isNotNull);
      expect(socketBudget!, lessThan(const Duration(milliseconds: 160)));
      expect(socketBudget!, greaterThan(Duration.zero));
    });

    test('a failed restore rejects and destroys the new connection', () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      final transport = WifiTransport(
        host: InternetAddress.loopbackIPv4.host,
        port: server.port,
        routeBinder: _RestoreFailureBinder(),
      );

      await expectLater(
        transport.connect(),
        throwsA(
          isA<TransportException>().having(
            (error) => error.message,
            'message',
            contains('路由'),
          ),
        ),
      );
      final peer = await server.first;
      // `peer.done` is IOSink.done — it completes only on a *local* close and
      // never observes the remote end dying, so it would hang here forever.
      // Listening to the stream is how a peer actually sees the destroy: EOF
      // completes it, an RST errors it, and an implementation that leaks the
      // socket does neither and times out.
      final peerSawClose = Completer<void>();
      peer.listen(
        (_) {},
        onDone: peerSawClose.complete,
        onError: (Object _) => peerSawClose.complete(),
      );
      await expectLater(
        peerSawClose.future.timeout(const Duration(seconds: 2)),
        completes,
      );
      expect(transport.isConnected, isFalse);
    });
  });

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

final class _RecordingBinder implements WifiRouteBinder {
  _RecordingBinder(this.events, {this.delay = Duration.zero, this.beforeRelease});

  final List<String> events;
  final Duration delay;
  final void Function()? beforeRelease;

  @override
  Future<WifiRouteLease> bindForHost(String host) async {
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    events.add('bind');
    return _RecordingLease(events, beforeRelease);
  }
}

final class _RecordingLease implements WifiRouteLease {
  _RecordingLease(this.events, this.beforeRelease);

  final List<String> events;
  final void Function()? beforeRelease;

  @override
  Future<void> release() async {
    beforeRelease?.call();
    events.add('release');
  }
}

final class _UnavailableBinder implements WifiRouteBinder {
  @override
  Future<WifiRouteLease> bindForHost(String host) {
    throw const WifiRouteException('no matching Wi-Fi route');
  }
}

final class _DelayedBinder implements WifiRouteBinder {
  _DelayedBinder(this.delay);

  final Duration delay;

  @override
  Future<WifiRouteLease> bindForHost(String host) async {
    await Future<void>.delayed(delay);
    return const NoopWifiRouteLease();
  }
}

final class _RestoreFailureBinder implements WifiRouteBinder {
  @override
  Future<WifiRouteLease> bindForHost(String host) async {
    return _RestoreFailureLease();
  }
}

final class _RestoreFailureLease implements WifiRouteLease {
  @override
  Future<void> release() {
    throw const WifiRouteException('restore failed');
  }
}
