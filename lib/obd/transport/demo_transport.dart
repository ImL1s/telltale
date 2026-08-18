/// In-app ECU simulator.
///
/// Speaks enough of the ELM327 and SAE J1979 wire protocol to be
/// indistinguishable from a real adapter as far as `Elm327Client` is concerned:
/// AT handshake, prompt framing, Mode 01 single and batched reads, Mode 03/04
/// diagnostic codes, Mode 09 VIN.
///
/// The numbers it returns come from a running drive-cycle model rather than a
/// lookup table, so the signals stay physically consistent with one another —
/// RPM drops on a gear change while road speed keeps climbing, manifold
/// pressure tracks throttle, coolant warms up once and stays warm. That
/// correlation is the whole point: a dashboard fed uncorrelated random walks
/// looks obviously fake the moment you watch two gauges at once.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'obd_transport.dart';

/// Phases of the simulated drive cycle.
enum DrivePhase { idling, accelerating, cruising, decelerating }

class DemoTransport extends BaseObdTransport {
  DemoTransport({math.Random? random, this.responseLatency = const Duration(milliseconds: 18)})
      : _random = random ?? math.Random(20260815);

  final math.Random _random;

  /// Modelled adapter turnaround. Without it the UI would report an absurd
  /// PIDs/sec and the gauges would have no motion to smooth.
  final Duration responseLatency;

  Timer? _tick;

  // ------------------------------------------------------------- state ----
  DrivePhase _phase = DrivePhase.idling;
  double _phaseElapsed = 0;
  double _phaseDuration = 3;

  double _speedKmh = 0;
  double _rpm = 780;
  double _throttlePct = 0;
  int _gear = 1;
  double _coolantC = 18;
  double _oilC = 16;
  double _fuelPct = 62;
  double _runtimeSec = 0;

  static const double _ambientC = 18;
  static const double _idleRpm = 780;
  static const double _redlineRpm = 6500;
  static const List<double> _gearRatios = [0, 38.0, 21.5, 14.8, 11.2, 9.0, 7.6];

  /// Fault codes the simulator reports for Mode 03. Chosen to exercise three
  /// of the four DTC category prefixes in the UI.
  static const List<int> _storedDtcs = [0x0301, 0x0420, 0xC123];
  bool _dtcsCleared = false;

  /// The ELM327 datasheet's own worked example (p.43), used for both its J1850
  /// and its CAN Mode 09 illustrations.
  ///
  /// The previous value spelled `TORQUEDEMO0000001`, which contains `O` and
  /// `Q` — letters ISO 3779 excludes from the VIN alphabet because they are
  /// confusable with `0` and `1`. The tests asserted on it, so the suite was
  /// certifying that the app accepts a VIN no vehicle can carry, and the
  /// validation that would have caught a corrupt read had nothing to stand on.
  static const String _vin = '1D4GP00R55B123456';

  @override
  TransportKind get kind => TransportKind.demo;

  @override
  String get displayName => 'Demo ECU (2.0L Turbo I4)';

  DrivePhase get phase => _phase;

  @override
  Future<void> connect() async {
    if (isConnected) return;
    _tick = Timer.periodic(const Duration(milliseconds: 100), (_) => _advance(0.1));
    setConnected(true);
  }

  @override
  Future<void> disconnect() async {
    _tick?.cancel();
    _tick = null;
    // Pending replies would otherwise fire into a closed controller.
    for (final timer in _scheduled) {
      timer.cancel();
    }
    _scheduled.clear();
    _echo = true;
    _protocolSearchPending = true;
    setConnected(false);
  }

  // ------------------------------------------------------- drive model ----

  void _advance(double dt) {
    _runtimeSec += dt;
    _phaseElapsed += dt;
    if (_phaseElapsed >= _phaseDuration) _nextPhase();

    final targetThrottle = switch (_phase) {
      DrivePhase.idling => 0.0,
      DrivePhase.accelerating => 62 + _random.nextDouble() * 28,
      DrivePhase.cruising => 16 + _random.nextDouble() * 9,
      DrivePhase.decelerating => 0.0,
    };
    // First-order lag: the pedal cannot teleport, and the smoothing is what
    // makes the throttle gauge look driven rather than stepped.
    _throttlePct += (targetThrottle - _throttlePct) * math.min(1.0, dt * 3.2);

    final accel = switch (_phase) {
      // Eases off as it approaches the run's target rather than pushing at a
      // constant rate until the phase ends. Without the taper the demo simply
      // accelerated for the whole phase and pinned at the 205 km/h clamp —
      // which undercuts the one thing this simulator is for, namely showing
      // that the derived figures track a plausible drive.
      DrivePhase.accelerating => math.min(
          2.6 + _throttlePct / 55,
          math.max(0.0, (_accelTargetKmh - _speedKmh) * 0.12),
        ),
      DrivePhase.cruising => (_accelTargetKmh - _speedKmh) * 0.05,
      DrivePhase.decelerating => -3.4,
      DrivePhase.idling => -6.0,
    };
    _speedKmh = (_speedKmh + accel * dt * 3.6).clamp(0.0, 160.0);

    _updateGear();

    final geared = _speedKmh * _gearRatios[_gear];
    final target = _speedKmh < 1.5
        ? _idleRpm + _throttlePct * 12
        : math.max(_idleRpm, geared + _throttlePct * 6);
    _rpm += (target - _rpm) * math.min(1.0, dt * 4.5);
    _rpm = _rpm.clamp(_idleRpm - 40, _redlineRpm + 120);

    // Warm-up: fast while cold, asymptotic near thermostat temperature.
    _coolantC += (92 - _coolantC) * dt * 0.016 + (_throttlePct / 100) * dt * 0.09;
    _oilC += (_coolantC + 8 - _oilC) * dt * 0.009;
    _fuelPct = math.max(0, _fuelPct - dt * 0.0016 * (1 + _throttlePct / 40));
  }

  /// Speed this acceleration run is heading for, in km/h.
  ///
  /// Re-rolled per run so successive laps of the demo do not look identical.
  double _accelTargetKmh = 95;

  void _nextPhase() {
    _phaseElapsed = 0;

    // A new run picks a new target: town speed, a main road, or a motorway.
    if (_phase == DrivePhase.idling) {
      _accelTargetKmh = 55 + _random.nextDouble() * 65;
    }

    // Weighted so the cycle spends most of its time in the two phases that
    // actually look interesting on a dashboard.
    _phase = switch (_phase) {
      DrivePhase.idling => DrivePhase.accelerating,
      DrivePhase.accelerating => DrivePhase.cruising,
      DrivePhase.cruising =>
        _random.nextDouble() < 0.55 ? DrivePhase.accelerating : DrivePhase.decelerating,
      DrivePhase.decelerating =>
        _speedKmh > 25 ? DrivePhase.cruising : DrivePhase.idling,
    };
    _phaseDuration = switch (_phase) {
      DrivePhase.idling => 4 + _random.nextDouble() * 4,
      DrivePhase.accelerating => 6 + _random.nextDouble() * 7,
      DrivePhase.cruising => 9 + _random.nextDouble() * 12,
      DrivePhase.decelerating => 4 + _random.nextDouble() * 5,
    };
  }

  void _updateGear() {
    if (_speedKmh < 1.5) {
      _gear = 1;
      return;
    }
    // Upshift near redline, downshift when the engine would fall below idle.
    while (_gear < 6 && _speedKmh * _gearRatios[_gear] > 5600) {
      _gear++;
    }
    while (_gear > 1 && _speedKmh * _gearRatios[_gear] < 1150) {
      _gear--;
    }
  }

  // ------------------------------------------------------ derived signals ----

  double get _mapKpa {
    const baro = 101.0;
    // Vacuum at closed throttle, boost under load — a turbo I4's signature.
    final vacuum = (1 - _throttlePct / 100) * 62 * (_rpm / _redlineRpm).clamp(0.15, 1.0);
    final boost = (_throttlePct / 100) * 78 * (_rpm / 3000).clamp(0.0, 1.25);
    return (baro - vacuum + boost).clamp(15.0, 240.0);
  }

  double get _mafGs {
    // Speed-density, same relation the physics engine inverts.
    const displacementL = 2.0;
    const ve = 0.88;
    final tK = _iatC + 273.15;
    return (_rpm * _mapKpa * displacementL * 28.97) / (120 * 8.314 * tK) * ve;
  }

  double get _iatC => _ambientC + 6 + (_throttlePct / 100) * 14;

  double get _loadPct =>
      ((_mapKpa - 30) / 1.9 * (0.45 + 0.55 * (_rpm / _redlineRpm))).clamp(0.0, 100.0);

  // ------------------------------------------------------- wire protocol ----

  /// Echo state. A real ELM327 echoes every command until `ATE0` lands, which
  /// means the reply to `ATZ` — the step before it — always begins with `ATZ`.
  bool _echo = true;

  /// Whether the next OBD query still has to hunt for a bus protocol.
  bool _protocolSearchPending = true;

  final List<Timer> _scheduled = [];

  @override
  Future<void> write(List<int> data) async {
    if (!isConnected) {
      throw const WriteRefusedException('Demo 模擬器尚未啟動。');
    }
    final raw = ascii.decode(data, allowInvalid: true).trim();
    final command = raw.toUpperCase().replaceAll(' ', '');

    final body = _respond(command);
    // A real adapter prefixes its answer with the command it just received,
    // until echo is switched off.
    final reply = _echo && raw.isNotEmpty ? '$raw\r$body' : body;

    if (command == 'ATE0') _echo = false;
    if (command == 'ATZ') {
      // A reset restores every documented default, headers included.
      _echo = true;
      _headersOn = false;
    }

    // Answer asynchronously so callers exercise the same await path as a real
    // adapter rather than completing inline.
    final timer = Timer(responseLatency, () => emitBytes(ascii.encode(reply)));
    _scheduled.add(timer);
    _scheduled.removeWhere((t) => !t.isActive);
  }

  /// Renders [payload] the way an ELM327 puts it on the wire.
  ///
  /// Up to seven data bytes fit a single CAN frame and are printed on one line.
  /// Anything longer is an ISO-TP multi-frame transfer: the adapter prints the
  /// total length on its own line, then `0:`-prefixed segments — six bytes on
  /// the first, seven on the rest, zero-padded to a full frame.
  /// Whether `ATH1` has been issued.
  ///
  /// This simulator used to answer `OK` to `ATH1` and then never print a
  /// header — which is precisely the behaviour of a lying clone, and the app's
  /// global fault-code scan was quietly relying on it. Every demo DTC scan
  /// went through the client's "headers were requested but none arrived, parse
  /// it unattributed anyway" fallback, so the fallback was load-bearing for the
  /// shipped simulator and eight tests had pinned it as expected.
  ///
  /// A real ELM327 that says `OK` to `ATH1` prints headers. Making this one do
  /// the same is what the project's own rule asks for: the simulator has to be
  /// at least as strict as the hardware, or green tests certify a path no real
  /// adapter takes.
  bool _headersOn = false;

  /// Whether byte values are printed with separating spaces.
  ///
  /// `ATS1` at power-up, per the datasheet; the app sends `ATS0`.
  bool _spacesOn = true;

  /// The CAN identifier this simulated ECU answers from.
  static const String _responseId = '7E8';

  static String _hex(int b) =>
      b.toRadixString(16).toUpperCase().padLeft(2, '0');

  /// What separates two printed bytes: one space, or nothing under `ATS0`.
  String get _sep => _spacesOn ? ' ' : '';

  String _join(List<String> bytes) => bytes.join(_sep);

  String _frame(List<int> payload) {
    final hex = payload.map(_hex).toList();

    if (hex.length <= 7) {
      if (!_headersOn) return '${_join(hex)}\r>';
      // With headers on the adapter prints the responding CAN ID, the ISO-TP
      // PCI byte it strips when they are off, and the frame's zero padding.
      // A Single Frame PCI is `0<len>`.
      //
      // The padding was missing here while the multi-frame branch below had it
      // — an internal inconsistency that meant the simulator never produced
      // the shape the datasheet actually prints. Its own worked example is
      // unambiguous:
      //
      //     7E8 06 41 00 BE 3F B8 13 00
      //
      // Six data bytes declared, six delivered, and one `00` filling the frame
      // out to eight. A CAN frame is eight bytes on the wire whatever the
      // payload occupies, and with headers on the adapter prints all of it.
      // The parser has always handled this; nothing here ever exercised it.
      final padded = [
        ...hex,
        ...List.filled(7 - hex.length, '00'),
      ];
      return '$_responseId$_sep${_hex(payload.length & 0x0F)}$_sep'
          '${_join(padded)}\r>';
    }

    final lines = <String>[];
    if (!_headersOn) {
      lines.add(payload.length.toRadixString(16).toUpperCase().padLeft(3, '0'));
    }

    var index = 0;
    var seq = 0;
    while (index < hex.length) {
      final take = seq == 0 ? 6 : 7;
      final segment = hex.sublist(index, math.min(index + take, hex.length));
      // Real frames are padded out to eight bytes with zeros.
      final padded = [...segment, ...List.filled(take - segment.length, '00')];
      if (_headersOn) {
        // Datasheet p.44: with headers on there is no separate length line and
        // no `N:` prefix — the byte after the CAN ID is the PCI.
        final pci = seq == 0
            ? [0x10 | ((payload.length >> 8) & 0x0F), payload.length & 0xFF]
                .map(_hex)
                .join(_sep)
            : _hex(0x20 | (seq & 0x0F));
        lines.add('$_responseId$_sep$pci$_sep${_join(padded)}');
      } else {
        lines.add('${seq.toRadixString(16).toUpperCase()}:$_sep${_join(padded)}');
      }
      index += take;
      seq++;
    }
    return '${lines.join('\r')}\r>';
  }

  String _respond(String command) {
    if (command.isEmpty) return '>';

    if (command.startsWith('AT')) return _respondAt(command);

    // The first OBD query after an automatic protocol search makes a real
    // adapter announce `SEARCHING...` before the answer. Reproducing it here is
    // what exercises the client's extended-deadline path.
    var prefix = '';
    if (_protocolSearchPending) {
      _protocolSearchPending = false;
      prefix = 'SEARCHING...\r';
    }

    if (command.startsWith('01')) return prefix + _respondMode01(command);

    if (command.startsWith('02') && command.length == 6) {
      return prefix + _respondMode02(command);
    }

    if (command == '03') return prefix + _respondStoredDtcs();
    // Through `_frame` like every other reply, so these carry a header when
    // one has been asked for. Hand-built strings here were how Mode 07 and
    // Mode 0A stayed anonymous even after the rest of the simulator learned to
    // print headers.
    if (command == '07') return prefix + _frame([0x47, 0x00]); // no pending
    if (command == '0A') return prefix + _frame([0x4A, 0x00]); // no permanent
    if (command == '04') {
      _dtcsCleared = true;
      return prefix + _frame([0x44]);
    }
    if (command == '0902') return prefix + _respondVin();

    // Hex-shaped or not, and the two get different answers.
    //
    // `ZZ` is not a request at all; `22F190` is a perfectly good one this
    // simulator has no data for. Mapping both to `NO DATA` made a malformed
    // custom command look like an unsupported sensor, which is the wrong
    // diagnosis to hand an author debugging their own PID.
    if (command.isEmpty || !RegExp(r'^[0-9A-F]+$').hasMatch(command)) {
      return '?\r>';
    }

    // A valid OBD request this simulator does not model is `NO DATA`, not `?`.
    //
    // The ELM327 is a protocol converter: it puts hex on the bus and reports
    // `NO DATA` when nothing comes back. `?` means "I did not understand the
    // command" and is reserved for its own AT vocabulary (datasheet p.7).
    // Answering `?` taught the client that `unknownCommand` is a normal reply
    // to a vehicle request — and in demo mode a custom Mode 22 PID was
    // reported as 轉接器不支援此指令 when the honest answer is that this
    // simulated car does not have that sensor.
    return 'NO DATA\r>';
  }

  /// The programmable-parameter summary, in the layout a real ELM327 prints.
  ///
  /// Four `xx:yy S` entries per line, twelve lines, where `S` is `N` when the
  /// parameter is switched on and `F` when the factory default is in force.
  static const List<int> _ppFactoryDefaults = [
    0xFF, 0x00, 0xFF, 0x32, 0x01, 0xFF, 0xF1, 0x09, //
    0xFF, 0x00, 0x0A, 0xFF, 0x68, 0x0D, 0x9A, 0xD5, //
    0x0D, 0x00, 0xFF, 0x55, 0x50, 0x0A, 0xFF, 0x6D, //
    0x31, 0x31, 0xFF, 0xFF, 0x03, 0x0F, 0x4A, 0xFF, //
    0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0xFF, //
    0xFF, 0xFF, 0x3C, 0x02, 0xE0, 0x04, 0x80, 0x0A, //
  ];

  static String _ppHex(int v) =>
      v.toRadixString(16).toUpperCase().padLeft(2, '0');

  String _ppSummary() {
    final lines = <String>[];
    for (var row = 0; row < 12; row++) {
      final entries = <String>[];
      for (var column = 0; column < 4; column++) {
        final pp = row * 4 + column;
        entries.add('${_ppHex(pp)}:${_ppHex(_ppFactoryDefaults[pp])} F');
      }
      lines.add(entries.join('     '));
    }
    return '${lines.join('\r')}\r>';
  }

  String _respondAt(String command) {
    if (command == 'ATZ') {
      _protocolSearchPending = true;
      return 'ELM327 v2.1\r\r>';
    }
    if (command == 'ATSP0') {
      _protocolSearchPending = true;
      return 'OK\r>';
    }
    if (command == 'ATI') return 'ELM327 v2.1\r>';
    if (command == 'AT@1') return 'Torque Demo ECU\r>';
    // Answered because this simulator claims v2.1, and `ATPPS` shipped in
    // v1.1.
    //
    // It used to fall through to `?`, which made the demo adapter internally
    // inconsistent in exactly the way `AdapterIdentity` was written to catch —
    // and the check duly caught it on the first run, on our own simulator.
    // That is the check working, and the simulator being less strict than the
    // hardware it stands in for, which this file's rule forbids.
    //
    // Factory defaults from the datasheet's PP table, in the `xx:yy N/F`
    // layout a real `ATPPS` prints. `F` is off, `N` is on; PP `2C`/`2D`/`2E`
    // carry the CAN options the client reads back.
    if (command == 'ATPPS') return _ppSummary();
    if (command == 'ATRV') return '${(13.9 + _random.nextDouble() * 0.35).toStringAsFixed(1)}V\r>';
    // Undecided until the first OBD request has actually run the search. A
    // simulator that answers `A6` straight away hides the entire class of bug
    // where the app configures itself from a protocol that was never found.
    if (command == 'ATDP') {
      return _protocolSearchPending
          ? 'AUTO\r>'
          : 'AUTO, ISO 15765-4 (CAN 11/500)\r>';
    }
    if (command == 'ATDPN') return _protocolSearchPending ? 'A0\r>' : 'A6\r>';

    // Answering `OK` and then not doing it is what a clone does. Both of these
    // change what every later reply looks like, so they are executed.
    if (command == 'ATH1') {
      _headersOn = true;
      return 'OK\r>';
    }
    if (command == 'ATH0') {
      _headersOn = false;
      return 'OK\r>';
    }
    // `ATS0` removes the spaces between printed bytes, and this simulator
    // acknowledged it and went on printing them.
    //
    // That is the clone pattern the codebase already refuses for `ATH1`:
    // answered `OK`, did nothing. It also meant the app's own initialisation
    // sequence — which sends `ATS0` — was never exercised against the
    // rendering it actually produces, and that rendering is the one where a
    // header and its first byte run together and the parser has to tell two
    // readings of the same characters apart.
    if (command == 'ATS0' || command == 'ATS1') {
      _spacesOn = command == 'ATS1';
      return 'OK\r>';
    }

    // Commands this simulator implements but whose effect it does not model.
    // Acknowledging them is honest — a real adapter does the same, and none of
    // them changes what the replies look like here.
    const acknowledged = {
      // Echo and formatting. `ATE0` takes effect in `_respond`, which is why
      // it is not switched on above — but it is still a command this adapter
      // implements and must acknowledge.
      'ATE0', 'ATE1', 'ATL0', 'ATL1', 'ATM0', 'ATM1',
      // Timing and framing.
      'ATAT0', 'ATAT1', 'ATAT2', 'ATCAF0', 'ATCAF1',
      // Resets.
      'ATD', 'ATWS',
    };
    if (acknowledged.contains(command) ||
        command.startsWith('ATST') ||
        command.startsWith('ATSH') ||
        command.startsWith('ATCRA') ||
        command.startsWith('ATSP')) {
      return 'OK\r>';
    }

    // Everything else gets `?`, which is what an ELM327 answers to a command
    // it does not recognise (datasheet p.7). Answering `OK` to anything at all
    // is clone behaviour, and a simulator more permissive than the hardware
    // certifies paths no real adapter takes — this one had the app's global
    // fault-code scan resting on exactly that for four rounds.
    return '?\r>';
  }

  /// Handles both a single read (`010C`) and a fastMode batch (`010C0D05`).
  ///
  /// A batch answers with one `41` followed by each PID and its data, exactly
  /// as the datasheet shows — which for three or more PIDs overruns a single
  /// CAN frame and becomes a multi-frame reply.
  String _respondMode01(String command) {
    var body = command.substring(2);
    // A trailing digit on a batched request is the "number of responses
    // expected" hint, not another PID.
    if (body.length.isOdd) body = body.substring(0, body.length - 1);
    if (body.isEmpty) return '?\r>';

    final payload = <int>[];
    for (var i = 0; i < body.length; i += 2) {
      final code = body.substring(i, i + 2);
      final bytes = _mode01Data(code);
      if (bytes == null) continue;
      if (payload.isEmpty) payload.add(0x41);
      payload.add(int.parse(code, radix: 16));
      payload.addAll(bytes);
    }
    if (payload.isEmpty) return 'NO DATA\r>';
    return _frame(payload);
  }

  /// Returns the raw data bytes for a Mode 01 PID, or null when unsupported.
  /// The blocks that exist purely to chain to the next one.
  ///
  /// Consulted before `_mode01Data`, which is what stops `_supportMask` from
  /// recursing into the mask it is building.
  static const Set<String> _supportBlocks = {'20', '40'};

  bool _supportsPid(String code) =>
      _supportBlocks.contains(code) || _mode01Data(code) != null;

  /// The J1979 support bitmask for the 32 PIDs after [base].
  ///
  /// The MSB of the first byte is `base + 1`; the LSB of the last is
  /// `base + 0x20`, which doubles as "the next block exists".
  List<int> _supportMask(int base) {
    var bits = 0;
    for (var i = 1; i <= 32; i++) {
      final code =
          (base + i).toRadixString(16).toUpperCase().padLeft(2, '0');
      if (_supportsPid(code)) bits |= 1 << (32 - i);
    }
    return [
      (bits >> 24) & 0xFF,
      (bits >> 16) & 0xFF,
      (bits >> 8) & 0xFF,
      bits & 0xFF,
    ];
  }

  List<int>? _mode01Data(String code) {
    int byte(num v) => v.round().clamp(0, 255);
    List<int> word(num v) {
      final raw = v.round().clamp(0, 65535);
      return [(raw >> 8) & 0xFF, raw & 0xFF];
    }

    switch (code) {
      // Derived from the cases below rather than written beside them.
      //
      // Hand-written constants drifted from the handler in both directions and
      // each direction lied to the app that uses this simulator to verify
      // itself. Five shipped gauges — fuel pressure `0A`, EGR `2C`, ambient
      // `46`, oil temperature `5C`, fuel rate `5E` — were answered while the
      // mask denied them, so adding one of those to the dashboard mid-session
      // had it marked "this vehicle does not have that sensor" on the
      // simulator's own authority. Twenty-one others were claimed and never
      // answered, so a custom PID on any of them entered a batch, came back
      // short, and switched fast mode off for the session: the exact failure
      // round 6's batching gate exists to prevent, manufactured by the
      // simulator.
      //
      // A simulator more permissive *or* more restrictive than the hardware
      // certifies paths no real adapter takes. Deriving it makes the two
      // impossible to disagree.
      case '00':
        return _supportMask(0x00);
      case '20':
        return _supportMask(0x20);
      case '40':
        return _supportMask(0x40);
      case '01':
        // The vehicle's own summary: bit 7 of byte A is the fault lamp, bits
        // 0 to 6 the number of confirmed emissions codes. Derived from the
        // Mode 03 list this simulator serves, and from whether a clear has
        // happened, for the same reason the support mask is derived — a
        // simulator that contradicts itself certifies nothing, and the check
        // this PID exists for is precisely "does 0101 agree with Mode 03".
        //
        // Bytes B, C and D are the readiness monitors, which this app does not
        // decode; they are present because the reply has four bytes.
        final stored = _dtcsCleared ? 0 : _storedDtcs.length;
        return [
          (stored > 0 ? 0x80 : 0x00) | (stored & 0x7F),
          0x07,
          0x65,
          0x04,
        ];
      case '04':
        return [byte(_loadPct * 255 / 100)];
      case '05':
        return [byte(_coolantC + 40)];
      case '06':
      case '07':
        return [byte((_random.nextDouble() * 6 - 3 + 100) * 128 / 100)];
      case '0A':
        return [byte(320 / 3)];
      case '0B':
        return [byte(_mapKpa)];
      case '0C':
        return word(_rpm * 4);
      case '0D':
        return [byte(_speedKmh)];
      case '0E':
        return [byte((14 + _throttlePct / 8 + 64) * 2)];
      case '0F':
        return [byte(_iatC + 40)];
      case '10':
        return word(_mafGs * 100);
      case '11':
        return [byte(_throttlePct * 255 / 100)];
      case '1F':
        return word(_runtimeSec);
      case '21':
        return word(_dtcsCleared ? 0 : 138);
      case '2C':
        return [byte(_throttlePct < 25 ? 18 * 255 / 100 : 0)];
      case '2F':
        return [byte(_fuelPct * 255 / 100)];
      case '33':
        return [byte(101)];
      case '42':
        return word((13.9 + _random.nextDouble() * 0.3) * 1000);
      case '43':
        return word(_loadPct * 255 / 100);
      case '45':
        return [byte(_throttlePct * 255 / 100)];
      case '46':
        return [byte(_ambientC + 40)];
      case '5C':
        return [byte(_oilC + 40)];
      case '5E':
        return word(_mafGs * 0.33094 * 20);
      default:
        return null;
    }
  }

  String _respondStoredDtcs() {
    if (_dtcsCleared) return _frame([0x43, 0x00]);
    final payload = <int>[0x43, _storedDtcs.length];
    for (final dtc in _storedDtcs) {
      payload.add((dtc >> 8) & 0xFF);
      payload.add(dtc & 0xFF);
    }
    return _frame(payload);
  }

  /// Service 02 — the freeze frame, plus the trap that comes with it.
  ///
  /// Request is `02 <PID> <frame>` and the reply echoes both before its data.
  /// Only frame `00` exists here, which is true of nearly every real vehicle;
  /// anything else is `NO DATA` rather than a helpful substitute, because an
  /// adapter that answered frame 3 with frame 0's contents would let the app
  /// mislabel a snapshot.
  ///
  /// The values are **deliberately different from the live Mode 01 ones** and
  /// deliberately fixed. A frozen moment does not move, and if this returned
  /// the current readings then an app that mistakenly polled Mode 01 and called
  /// it a freeze frame would look correct here forever.
  ///
  /// The trap: after a clear, PID 02 answers `00 00` — no causing code, so no
  /// frame — while every other PID still answers, with zeroes, exactly as a
  /// real controller does. Those zeroes decode into 0 rpm, −40 °C coolant and
  /// 0% load: well-formed, precise, and describing a moment that never
  /// happened. The simulator produces the trap on purpose so that removing the
  /// app's gate is visible rather than plausible.
  String _respondMode02(String command) {
    final pid = command.substring(2, 4);
    final frame = command.substring(4, 6);
    if (frame != '00') return 'NO DATA\r>';

    // Each published block. Bit 0 of a mask is the next block's base, so a
    // frame carrying anything above 0x20 has to say so here or the app has no
    // way to know to ask — and `0121`, distance driven with the lamp on, is in
    // that range and is one of the more useful things a frame holds.
    if (pid == '00' || pid == '20' || pid == '40' || pid == '60') {
      final base = int.parse(pid, radix: 16);
      return _frame([0x42, base, 0x00, ..._freezeMask(base)]);
    }

    if (pid == '02') {
      // The code that caused the frame to be stored: the first one confirmed,
      // which for this simulated car is the misfire. Zero after a clear.
      final cause = _dtcsCleared ? 0 : _storedDtcs.first;
      return _frame([0x42, 0x02, 0x00, (cause >> 8) & 0xFF, cause & 0xFF]);
    }

    final data = _freezeData(pid);
    if (data == null) return 'NO DATA\r>';
    return _frame([
      0x42,
      int.parse(pid, radix: 16),
      0x00,
      // Cleared means no frame, and a controller with no frame answers with
      // zeroes rather than refusing. Same width, no content.
      ...(_dtcsCleared ? List.filled(data.length, 0) : data),
    ]);
  }

  /// The support mask for the frame, derived from [_freezeData] for the same
  /// reason the Mode 01 mask is derived from its handler: a simulator that
  /// claims a PID it will not answer, or answers one it denies, certifies a
  /// path no real adapter takes.
  List<int> _freezeMask(int base) {
    var bits = 0;
    for (var i = 1; i <= 32; i++) {
      final code =
          (base + i).toRadixString(16).toUpperCase().padLeft(2, '0');
      // PID 02 is the causing code, which is not in the data table but is
      // always present in a frame that exists.
      final present = code == '02' || _freezeData(code) != null;
      // The last bit of a mask is the next block's base, and it means "that
      // mask exists", not "that PID is a sensor". Derived by asking whether
      // anything in the next block is present, so the two can never disagree.
      final isContinuation = i == 32;
      final claimed = isContinuation
          ? _blockHasAnything(base + 0x20)
          : present;
      if (claimed) bits |= 1 << (32 - i);
    }
    return [
      (bits >> 24) & 0xFF,
      (bits >> 16) & 0xFF,
      (bits >> 8) & 0xFF,
      bits & 0xFF,
    ];
  }

  /// Whether any PID in the block starting at [base] is in the frame.
  static bool _blockHasAnything(int base) {
    for (var i = 1; i <= 32; i++) {
      final code =
          (base + i).toRadixString(16).toUpperCase().padLeft(2, '0');
      if (_freezeData(code) != null) return true;
    }
    return false;
  }

  /// The moment itself: a cylinder-1 misfire under load, part way up a slip
  /// road. Every number here is what the sensor read at that instant, encoded
  /// exactly as J1979 encodes it.
  static List<int>? _freezeData(String code) => switch (code) {
        // Monitor status at the time. The app has no gauge definition for it,
        // so it exercises the "present in the frame, not decodable here" count
        // rather than becoming a reading.
        '01' => const [0x83, 0x07, 0x65, 0x04],
        // Fuel system status — also undecodable as a gauge, also present.
        '03' => const [0x02, 0x00],
        '04' => const [189], // 74.1 % load
        '05' => const [131], // 91 °C coolant
        '06' => const [138], // +7.8 % short fuel trim
        '07' => const [143], // +11.7 % long fuel trim
        '0B' => const [62], // 62 kPa manifold pressure
        '0C' => const [0x2C, 0xA0], // 2856 rpm
        '0D' => const [78], // 78 km/h
        '0E' => const [152], // 12° timing advance
        '0F' => const [74], // 34 °C intake air
        '10' => const [0x07, 0x30], // 18.40 g/s mass air flow
        '11' => const [105], // 41.2 % throttle
        '1F' => const [0x04, 0xDF], // 1247 s since engine start
        // Above 0x20 on purpose: without something here the second support
        // block never exists, and the app's loop over the published blocks is
        // a rule this simulator cannot exercise.
        '21' => const [0x00, 0xD2], // 210 km driven with the lamp on
        _ => null,
      };

  /// Mode 09 PID 02. Always multi-frame — the VIN alone is 17 bytes — so this
  /// is the path that exercises the length header and sequence prefixes.
  String _respondVin() {
    return _frame([0x49, 0x02, 0x01, ...ascii.encode(_vin)]);
  }
}
