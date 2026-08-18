/// The vehicle's own summary, checked against what it just answered.
///
/// These are notifier-level on purpose. Two consecutive review rounds pointed
/// out that every rule in `DtcScanNotifier.scan` — the order the census, PID 01
/// and the categories run in, and the comparison between them — was reachable
/// only through `connectDemo`, whose simulator derives its PID 01 count from
/// its own Mode 03 list and so can never disagree with itself. A rule that
/// nothing can contradict is not a tested rule.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:torque_obd/obd/dtc/dtc.dart';
import 'package:torque_obd/obd/transport/obd_transport.dart';
import 'package:torque_obd/state/dtc_scan.dart';
import 'package:torque_obd/state/obd_session.dart';
import 'package:torque_obd/state/pid_registry.dart';

import 'support/fake_elm327.dart';

Future<ProviderContainer> _container() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
}

Future<DtcScanState> _scanWith(
  ProviderContainer container,
  FakeElm327 transport,
) async {
  final connected = await container
      .read(obdSessionProvider.notifier)
      .connectForTest(transport, TransportKind.wifi);
  expect(connected, isTrue, reason: 'the fixture must connect');
  await container.read(dtcScanProvider.notifier).scan();
  return container.read(dtcScanProvider);
}

FakeEcu _ecm({
  required List<int> mil,
  required List<int> stored,
}) =>
    FakeEcu(
      name: 'ECM',
      requestId: '7E0',
      responseId: '7E8',
      responses: {
        '0100': [0x41, 0x00, 0xBE, 0x3F, 0xA8, 0x13],
        '0101': mil,
        '03': stored,
        '07': [0x47, 0x00],
        '0A': [0x4A, 0x00],
        '0902': [0x49, 0x02, 0x01, ...'1D4GP00R55B123456'.codeUnits],
      },
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the vehicle disagreeing with itself is not a clean vehicle', () {
    test('two confirmed codes claimed, one read', () async {
      // PID 01 byte A: bit 7 is the lamp, bits 0..6 the confirmed count. `82`
      // is lamp on, two codes. Mode 03 returns one. The screen may not call
      // that a finished category.
      final container = await _container();
      addTearDown(container.dispose);
      final state = await _scanWith(
        container,
        FakeElm327(
          protocol: BusProtocol.can11,
          ecus: [
            _ecm(
              mil: [0x41, 0x01, 0x82, 0x07, 0x65, 0x04],
              stored: [0x43, 0x01, 0x03, 0x01],
            ),
          ],
        ),
      );

      final stored = state.results[DtcKind.stored]!;
      expect(stored.answered, isFalse,
          reason: 'the count the vehicle reported and the count that arrived '
              'are different numbers, and the difference is the finding');
      expect(stored.failure!.message, contains('7E8'));
      expect(stored.failure!.message, contains('2'));
      expect(state.verdict, isNot(ScanVerdict.completeClean));
      expect(stored.partial.map((d) => d.code), ['P0301'],
          reason: 'the code that did arrive is still real and still shown');
    });

    test('the lamp on with nothing read at all', () async {
      final container = await _container();
      addTearDown(container.dispose);
      final state = await _scanWith(
        container,
        FakeElm327(
          protocol: BusProtocol.can11,
          ecus: [
            _ecm(
              mil: [0x41, 0x01, 0x80, 0x07, 0x65, 0x04],
              stored: [0x43, 0x00],
            ),
          ],
        ),
      );
      expect(state.results[DtcKind.stored]!.answered, isFalse);
      expect(state.verdict, isNot(ScanVerdict.completeClean));
    });

    test('agreement is not a warning', () async {
      // The other direction matters as much: if an ordinary clean car carried
      // a caveat, the caveat would stop meaning anything.
      final container = await _container();
      addTearDown(container.dispose);
      final state = await _scanWith(
        container,
        FakeElm327(
          protocol: BusProtocol.can11,
          ecus: [
            _ecm(
              mil: [0x41, 0x01, 0x00, 0x07, 0x65, 0x04],
              stored: [0x43, 0x00],
            ),
          ],
        ),
      );
      expect(state.results[DtcKind.stored]!.answered, isTrue);
      expect(state.verdict, ScanVerdict.completeClean);
    });

    test('one code claimed and one read is agreement', () async {
      final container = await _container();
      addTearDown(container.dispose);
      final state = await _scanWith(
        container,
        FakeElm327(
          protocol: BusProtocol.can11,
          ecus: [
            _ecm(
              mil: [0x41, 0x01, 0x81, 0x07, 0x65, 0x04],
              stored: [0x43, 0x01, 0x03, 0x01],
            ),
          ],
        ),
      );
      final stored = state.results[DtcKind.stored]!;
      expect(stored.answered, isTrue);
      expect(stored.codes.map((d) => d.code), ['P0301']);
    });
  });

  group('a controller found by the summary is owed an answer', () {
    test('it answers PID 01 and nothing else', () async {
      // The census hears only 7E8. `0101` is functional, so 7E9 answers it and
      // then stays silent for every fault-code class. It must not be possible
      // to call that a whole-vehicle result.
      final container = await _container();
      addTearDown(container.dispose);
      final state = await _scanWith(
        container,
        FakeElm327(
          protocol: BusProtocol.can11,
          ecus: [
            _ecm(
              mil: [0x41, 0x01, 0x00, 0x07, 0x65, 0x04],
              stored: [0x43, 0x00],
            ),
            FakeEcu(
              name: 'TCM',
              requestId: '7E1',
              responseId: '7E9',
              responses: {'0101': [0x41, 0x01, 0x00, 0x07, 0x65, 0x04]},
            ),
          ],
        ),
      );
      expect(state.verdict, isNot(ScanVerdict.completeClean),
          reason: '7E9 answered during this scan and then accounted for none '
              'of its fault-code classes');
      expect(state.results[DtcKind.stored]!.failure!.message, contains('7E9'));
    });

    test('a summary too short to read still names its controller', () async {
      // The payload is refused — three bytes is not the four J1979 defines —
      // but the identity is not. Damaged bytes must not become a status value;
      // a definite source must not disappear.
      final container = await _container();
      addTearDown(container.dispose);
      final state = await _scanWith(
        container,
        FakeElm327(
          protocol: BusProtocol.can11,
          ecus: [
            _ecm(
              mil: [0x41, 0x01, 0x00, 0x07, 0x65, 0x04],
              stored: [0x43, 0x00],
            ),
            FakeEcu(
              name: 'TCM',
              requestId: '7E1',
              responseId: '7E9',
              // `41 01 82` and nothing more.
              responses: {'0101': [0x41, 0x01, 0x82]},
            ),
          ],
        ),
      );
      expect(state.verdict, isNot(ScanVerdict.completeClean));
      expect(state.results[DtcKind.stored]!.failure!.message, contains('7E9'));
    });
  });

  group('a category that was refused is not a category that read zero', () {
    test('a negative Mode 03 keeps its own diagnosis', () async {
      // `7F 03 11` is service-not-supported. Comparing PID 01's count against
      // its empty list replaced a true statement about the link with a false
      // one about the vehicle.
      final container = await _container();
      addTearDown(container.dispose);
      final state = await _scanWith(
        container,
        FakeElm327(
          protocol: BusProtocol.can11,
          ecus: [
            _ecm(
              mil: [0x41, 0x01, 0x82, 0x07, 0x65, 0x04],
              stored: [0x7F, 0x03, 0x11],
            ),
          ],
        ),
      );
      final stored = state.results[DtcKind.stored]!;
      expect(stored.answered, isFalse);
      expect(stored.failure!.message, isNot(contains('只讀到')),
          reason: 'Mode 03 did not read zero — it refused, and that is the '
              'accurate thing to report');
    });
  });
}
