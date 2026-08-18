/// What the detected bus protocol implies about addressing.
///
/// The app used to send `ATSH 7E0` unconditionally after protocol detection.
/// That string is an 11-bit CAN header and means nothing anywhere else: J1850,
/// ISO 9141-2 and ISO 14230-4 take three *bytes* (six hex digits), and 29-bit
/// CAN takes four. Sending it on those buses replaced the addressing `ATSP0`
/// had just established, so a vehicle could pair successfully and then answer
/// nothing — the exact failure the owner of this project named.
///
/// The datasheet's own advice, under `AT SH xx yy zz`, is that these bytes
/// "are normally assigned values for you (and are not required to be
/// adjusted)" — which is why the safe default here is to leave them alone
/// rather than to compute a cleverer value.
///
/// Every datasheet citation in this file has been checked against the text of
/// ELM327DSJ. Two earlier ones had not been, and both were wrong: this one was
/// a paraphrase attributed to a page it does not appear on, and `engineHeader`
/// cited a `6810F1` example that appears nowhere in the document at all. A
/// citation nobody checks is worth less than no citation, because it stops the
/// next reader from looking.
library;

import 'pid/pid.dart';
import 'programmable_parameters.dart';

enum ObdBusFamily {
  /// Protocol 1. Kept apart from VPW deliberately.
  ///
  /// The two used to share one `j1850` member, and the collapse manufactured
  /// its own uncertainty: `ATDPN` tells the app exactly which sub-protocol is
  /// active, the app discarded that, and the header getters then said "the
  /// family covers both and cannot choose" — refusing on the strength of
  /// information that had been thrown away one function earlier.
  ///
  /// Splitting them does not by itself supply the addresses; it makes each one
  /// answerable on its own evidence rather than jointly unanswerable.
  j1850Pwm,

  /// Protocol 2.
  j1850Vpw,
  iso9141,
  kwp2000,
  can11,
  can29,


  /// Protocol A — SAE J1939.
  ///
  /// Electrically 29-bit CAN, and nothing else in common with ISO 15765-4.
  /// J1939 is PGN-addressed with its own application layer: no J1979 mode
  /// bytes, no `7DF`-style functional ID, no ISO-TP in the sense this app
  /// reassembles. Round 7 mapped it to [can29] because both are 29-bit and
  /// *wrote a test pinning that*, which is how a wrong contract becomes
  /// load-bearing.
  ///
  /// Bus identifier width is not an application protocol. A heavy-duty
  /// vehicle normally fails the handshake's `0100` probe on its own; a
  /// permissive bridge or clone lets the app carry on and then frame every
  /// reply by rules that do not apply.
  j1939,
  /// The protocol has not been determined yet — `ATSP0` arms the search but
  /// nothing is decided until the first OBD request goes out.
  unknown,
}

class BusAddressing {
  const BusAddressing._(this.family, this.headerHexDigits,
      {this.acceptsBothReceiveWidths = false});

  final ObdBusFamily family;

  /// Width `ATSH` takes on this bus, in hex digits, or 0 when unknown.
  ///
  /// Datasheet p.11 lists exactly three forms: `SH xyz` (11-bit CAN),
  /// `SH xxyyzz` (J1850 / ISO 9141-2 / ISO 14230-4), `SH wwxxyyzz` (29-bit CAN).
  final int headerHexDigits;

  /// The identifier widths a reply may legitimately arrive on.
  ///
  /// Empty on a non-CAN bus. One entry for protocols 6-9 and for a user slot
  /// whose PP 2C bit 5 is clear; both entries when that bit says "both 11 and
  /// 29 bit".
  ///
  /// A *set*, because the same question is asked in three places — the frame
  /// parser, the complete-line extractor, and the bare-header extractor — and
  /// they were answering it differently. The bare one still compared against
  /// the transmit width, so a legal opposite-width source whose payload was
  /// lost was forgotten, and a clear it never acknowledged then passed.
  Set<int> get acceptedReceiveWidths {
    if (!isCan) return const {};
    if (acceptsBothReceiveWidths) return const {3, 8};
    return {headerHexDigits};
  }

  /// Whether replies may arrive on either CAN identifier width.
  ///
  /// [headerHexDigits] is the *transmit* width — what `ATSH` will take. For
  /// protocols 6-9 the receive width is the same, and for a user slot it need
  /// not be: PP 2C bit 7 selects the transmit length while bit 5 can make the
  /// adapter accept "both 11 and 29 bit" on receive. Reading the transmit
  /// width as the only legal receive width refused a reply the adapter had
  /// been explicitly configured to take.
  final bool acceptsBothReceiveWidths;

  static const _unknown = BusAddressing._(ObdBusFamily.unknown, 0);

  /// Strips the `A` that marks "found by automatic search", and only that one.
  ///
  /// The lookahead is the whole point. A plain `^A` also eats the protocol
  /// when it *is* `A` — J1939, CAN 29-bit/250k — leaving an empty string that
  /// reads as undetermined, so a J1939 vehicle lost its addressing entirely:
  /// no functional header, no header width, every global request silently
  /// physical. `AA` is auto-detected J1939 and must reduce to `A`.
  ///
  /// This is the canonical implementation. `DtcDecoder` had its own copy, the
  /// two drifted, and only one of them was fixed — which is exactly the shape
  /// of defect a shared helper prevents.
  static String normaliseProtocolNumber(String protocolNumber) =>
      protocolNumber.trim().toUpperCase().replaceFirst(RegExp(r'^A(?=.)'), '');

  /// Derives addressing from what `ATDPN` reported.
  ///
  /// The reply may carry a leading `A` meaning the protocol was found by
  /// automatic search; `A0` is the undecided state and yields [unknown]
  /// rather than a guess.
  /// [userCanOptions] is the effective PP 2C (for `B`) or PP 2E (for `C`)
  /// byte, read from `AT PPS`. Without it, `B` and `C` resolve to [unknown]:
  /// nothing else on the wire establishes what a user slot is carrying, and
  /// two rounds of review were spent proving that the plausible substitutes
  /// do not. See `_userCan`.
  /// The bus the adapter *described*, when it would not give a number.
  ///
  /// `ATDPN` prints one character and `ATDP` prints a sentence, and the app
  /// asks for both. The number is the one it reasons from — but it is a
  /// non-critical handshake step, so a clone that answers it with `?` leaves
  /// the protocol undetermined, and undetermined refuses everything: every
  /// gauge reads 匯流排錯誤, every fault-code and VIN read answers 尚未確定車輛
  /// 使用的匯流排協定，請重新連線, and reconnecting produces the same reply
  /// because the adapter answers the same way every time. That is a working
  /// adapter and a working car, permanently unusable.
  ///
  /// The description is the second witness. It is a closed whitelist over
  /// exactly the strings the datasheet documents `ATDP` printing; anything
  /// unrecognised stays unknown, because guessing a bus is how a legacy reply
  /// gets decoded with CAN framing and invents fault codes the car never set.
  static ObdBusFamily? familyFromDescription(String description) {
    final d = description.toUpperCase();
    if (d.contains('J1939')) return ObdBusFamily.j1939;
    if (d.contains('15765')) {
      // The datasheet prints these as "ISO 15765-4 (CAN 11/500)" and its three
      // siblings, so the width is stated rather than inferred.
      if (d.contains('CAN 29') || d.contains('CAN29')) return ObdBusFamily.can29;
      if (d.contains('CAN 11') || d.contains('CAN11')) return ObdBusFamily.can11;
      return null;
    }
    if (d.contains('9141')) return ObdBusFamily.iso9141;
    if (d.contains('14230')) return ObdBusFamily.kwp2000;
    if (d.contains('J1850')) {
      if (d.contains('PWM')) return ObdBusFamily.j1850Pwm;
      if (d.contains('VPW')) return ObdBusFamily.j1850Vpw;
      return null;
    }
    return null;
  }

  /// The addressing implied by an `ATDP` description, or unknown.
  factory BusAddressing.forProtocolDescription(String description) {
    final family = familyFromDescription(description);
    if (family == null) return _unknown;
    return switch (family) {
      ObdBusFamily.can11 => const BusAddressing._(ObdBusFamily.can11, 3),
      ObdBusFamily.can29 => const BusAddressing._(ObdBusFamily.can29, 8),
      ObdBusFamily.j1939 => const BusAddressing._(ObdBusFamily.j1939, 8),
      ObdBusFamily.j1850Pwm => const BusAddressing._(ObdBusFamily.j1850Pwm, 6),
      ObdBusFamily.j1850Vpw => const BusAddressing._(ObdBusFamily.j1850Vpw, 6),
      ObdBusFamily.iso9141 => const BusAddressing._(ObdBusFamily.iso9141, 6),
      ObdBusFamily.kwp2000 => const BusAddressing._(ObdBusFamily.kwp2000, 6),
      ObdBusFamily.unknown => _unknown,
    };
  }

  factory BusAddressing.forProtocolNumber(
    String protocolNumber, {
    int? userCanOptions,
  }) {
    // `A0` needs no case of its own: the normaliser's lookahead strips the
    // automatic-search `A` whenever something follows it, so `A0` arrives here
    // as `0`. A `trimmed == 'A0'` test was sitting beside this and could never
    // fire — harmless, and exactly the kind of dead guard that reads as
    // load-bearing to the next person deciding what may be changed.
    final trimmed = normaliseProtocolNumber(protocolNumber);
    if (trimmed.isEmpty || trimmed == '0') return _unknown;

    return switch (trimmed) {
      '1' => const BusAddressing._(ObdBusFamily.j1850Pwm, 6),
      '2' => const BusAddressing._(ObdBusFamily.j1850Vpw, 6),
      '3' => const BusAddressing._(ObdBusFamily.iso9141, 6),
      '4' || '5' => const BusAddressing._(ObdBusFamily.kwp2000, 6),
      '6' || '8' => const BusAddressing._(ObdBusFamily.can11, 3),
      '7' || '9' => const BusAddressing._(ObdBusFamily.can29, 8),
      'A' => const BusAddressing._(ObdBusFamily.j1939, 8),
      // `B` and `C` are not protocol identities. They are two configurable
      // slots, and the configuration lives in PP 2C and PP 2E — which choose
      // the identifier width *and* the data format, the latter being one of
      // none, ISO 15765-4 or J1939.
      //
      // This used to read them as 11-bit ISO 15765-4, on the reasoning that
      // they "differ only in identifier width and bitrate, both adjustable
      // settings, not a different application layer". The datasheet's own
      // defaults refute it: PP 2C ships as `E0` and PP 2E as `80`, and both
      // select data format `000` — none. A factory-default protocol B is
      // unframed CAN, and the app was running the J1979 decoder over it and
      // rendering whatever came out as fault codes.
      //
      // Without the options byte there is nothing here to decide on, and a
      // guess in either direction produces plausible wrong numbers. `AT PPS`
      // is asked for once per connection; when it cannot be had, this stays
      // unknown and every consumer refuses.
      'B' || 'C' => _userCan(userCanOptions),
      _ => _unknown,
    };
  }

  static BusAddressing _userCan(int? options) {
    // No options byte, no answer.
    //
    // Two attempts were made to avoid refusing here, on the grounds that a
    // vehicle which answered the mandatory `0100` probe should not be turned
    // away. Both were unsound, and the second one only looked sound:
    //
    //  * deriving the identifier width from a reply ignores that PP 2C keeps
    //    the *transmit* length in b7 and the *receive* length in b5, and that
    //    b5 can accept both widths at once. A reply's identifier says nothing
    //    about what requests go out on.
    //  * treating a successful ISO-TP parse of the `0100` reply as proof of
    //    ISO 15765-4 framing is circular. The datasheet allows PP 2C's format
    //    bits to be `000` — no formatting — and raw CAN bytes can have exactly
    //    the shape of a single frame. The parser would have been proving its
    //    own assumption, and the payoff for being wrong is a fabricated fault
    //    code, which is the worst thing this app can produce.
    //
    // The framing of a user slot is stated in PP 2C / PP 2E and nowhere else.
    // When the adapter will not report them, the honest answer is that this
    // bus is not identified — and the screen says which parameter would have
    // said so.
    if (options == null) return _unknown;
    return switch (UserCanFormat.of(options)) {
      UserCanFormat.iso15765 => userCanIs11Bit(options)
          ? BusAddressing._(ObdBusFamily.can11, 3,
              acceptsBothReceiveWidths: userCanAcceptsBothWidths(options))
          : BusAddressing._(ObdBusFamily.can29, 8,
              acceptsBothReceiveWidths: userCanAcceptsBothWidths(options)),
      UserCanFormat.j1939 => const BusAddressing._(ObdBusFamily.j1939, 8),
      // `none` is CAN traffic with no application layer; `reserved` is a
      // combination the datasheet declines to describe. Neither is something
      // to send `0100` at.
      UserCanFormat.none || UserCanFormat.reserved => _unknown,
    };
  }

  bool get isCan =>
      family == ObdBusFamily.can11 || family == ObdBusFamily.can29;

  /// Whether [id] is a CAN identifier that can exist at its own width.
  ///
  /// Digit count is not enough. `43020715` has eight digits and is above the
  /// 29-bit maximum, and once both widths were accepted that let a headerless
  /// Mode 03 payload be read as a source: `43020715` with body `02 43 00`,
  /// which reassembles as a clean empty answer and satisfies its own coverage
  /// check while P0715 and P0243 sat in the bytes it had eaten.
  static bool isLegalCanId(String id) => switch (id.length) {
        3 => (int.tryParse(id, radix: 16) ?? 0x800) <= 0x7FF,
        8 => (int.tryParse(id, radix: 16) ?? 0x20000000) <= 0x1FFFFFFF,
        _ => false,
      };

  bool get isKnown => family != ObdBusFamily.unknown;

  /// Whether this bus speaks the protocol this app reads.
  ///
  /// Distinct from [isKnown], and the distinction is the point: `A0` means
  /// "not determined yet" and keeps trying, while J1939 means "determined,
  /// and it is not OBD2". Answering both with the same silence is what let a
  /// J1939 bus be framed as ISO 15765-4.
  bool get supportsObd2 => isKnown && family != ObdBusFamily.j1939;

  /// The address that reaches every emissions-related controller.
  ///
  /// `7DF` for 11-bit CAN is stated by the datasheet. `18DB33F1` for 29-bit
  /// follows from the documented structure — priority `18`, `DB` for
  /// functional, `F1` for the tool — but the `33` target byte is defined in
  /// ISO 15765-4, which is paywalled, so it is conventional rather than
  /// quoted.
  ///
  /// The two legacy values are quoted, not derived. The datasheet's Periodic
  /// (Wakeup) Messages section states that default settings "will send the
  /// bytes 68 6A F1 01 00 for ISO 9141, and C1 33 F1 3E for KWP" — `01 00` and
  /// `3E` being the data, so the headers are `686AF1` and `C133F1`. They are
  /// what the adapter already has installed, which is what makes them safe to
  /// *re*-install: doing so restores a displaced header rather than choosing a
  /// new one.
  ///
  /// `C133F1` embeds a length in `C1` and that is correct, not a bug: for
  /// ISO 14230-4 the adapter honours only the two most significant bits of the
  /// format byte and recomputes the length for each message itself.
  ///
  /// Both J1850 sub-protocols are absent, and now for a reason that is about
  /// evidence rather than about this enum. ELM327DSJ gives J1850 no default
  /// request header: its Periodic (Wakeup) Messages section covers ISO 9141
  /// and KWP only, because those are the protocols that need wakeup messages
  /// at all. Its J1850 worked examples are non-legislated addressing — `E4`
  /// for a PWM physical request, `A8` for a VPW functional one, both chosen
  /// "with your knowledge of SAE J2178".
  ///
  /// Round 8 was told the legislated headers are `616AF1` for PWM and
  /// `686AF1` for VPW, sourced to ELM320 documentation. That may well be
  /// right, and it is not in any document held here — and writing a header
  /// from a plausible secondary claim is precisely what round 7's F-2 was
  /// about. Either entry can be filled in independently the moment one is
  /// verified against a primary source; the split above is what makes that
  /// possible.
  String? get functionalHeader => switch (family) {
        ObdBusFamily.can11 => '7DF',
        ObdBusFamily.can29 => '18DB33F1',
        ObdBusFamily.iso9141 => '686AF1',
        ObdBusFamily.kwp2000 => 'C133F1',
        // J1939 addresses by PGN and has no J1979 functional ID.
        ObdBusFamily.j1939 => null,
        ObdBusFamily.j1850Pwm ||
        ObdBusFamily.j1850Vpw ||
        ObdBusFamily.unknown =>
          null,
      };

  /// The engine controller's *physical* address on this bus.
  ///
  /// Distinct from [functionalHeader], which reaches every emissions module,
  /// and from `kDefaultHeader`, which is the app's stored preference and only
  /// names something on 11-bit CAN.
  ///
  /// Needed because "do not transmit the stored default" is only equivalent to
  /// "address the engine" while nothing else has changed the adapter. Once a
  /// custom PID has installed a header of its own, leaving the adapter alone
  /// sends the next built-in query to *that* controller — and if it answers,
  /// the reading is indistinguishable from the right one.
  ///
  /// `18DA10F1` follows the documented 29-bit structure with the physical
  /// target byte in place of the functional one.
  ///
  /// **Every legacy family is null, and that is the finding rather than a
  /// gap.** This used to return `6810F1` for all three, justified by a
  /// datasheet example that does not exist — `68 10 F1` appears nowhere in
  /// ELM327DSJ. The physical example on that subject is `AT SH E4 10 F1`, and
  /// `E4` is a J1850 *PWM* priority byte. Each family refutes the constant
  /// separately:
  ///
  /// - J1850 needs a priority byte chosen per sub-protocol from SAE J2178,
  ///   and the datasheet warns "many vehicles will simply not support these
  ///   extra addressing modes";
  /// - ISO 9141-2 defines only functional addressing for OBD, so there is no
  ///   standard physical engine request to send;
  /// - ISO 14230-4 honours only the top two bits of the format byte, and
  ///   `0x68` is `01` where the adapter's own default `0xC1` is `11` — a
  ///   different addressing mode, not a different target.
  ///
  /// The consequence of the constant was not a refusal but a silence: one
  /// custom PID with an explicit legacy header, and every built-in query after
  /// it went to an address nobody answers. All gauges dark, `NO DATA`,
  /// three-strike backoff — while the custom PID itself kept working, which is
  /// harder to diagnose than a clean disconnect.
  ///
  /// Callers restoring a displaced header should fall back to
  /// [functionalHeader]: a built-in J1979 request is a functional one by
  /// nature, and the functional header is what the adapter had installed
  /// before the custom PID displaced it.
  String? get engineHeader => switch (family) {
        ObdBusFamily.can11 => kDefaultHeader,
        ObdBusFamily.can29 => '18DA10F1',
        ObdBusFamily.j1850Pwm ||
        ObdBusFamily.j1850Vpw ||
        ObdBusFamily.iso9141 ||
        ObdBusFamily.kwp2000 ||
        ObdBusFamily.j1939 ||
        ObdBusFamily.unknown =>
          null,
      };

  /// The header to install when something has displaced the adapter's own.
  ///
  /// The engine's physical address where one is defined, the functional
  /// address otherwise — and null on J1850, where neither is. Null means the
  /// app cannot get back to a known addressing state and must say so rather
  /// than transmit a guess.
  String? get restoreHeader => engineHeader ?? functionalHeader;

  /// The one spelling of a header the whole app agrees on.
  ///
  /// The same defect the mode+PID identifier had, in the field beside it. The
  /// shared validator canonicalised — `trim().toUpperCase().replaceAll(' ',
  /// '')` — and the editor stored `trim().toUpperCase()`, keeping internal
  /// spaces. So `7 E 0` passed validation, enabled Save, and was stored in a
  /// spelling `isAppDefault` and `acceptsHeader` both reject: the PID then
  /// polled with no `ATSH` at all, on the adapter's functional default, and
  /// whichever controller answered first filled the gauge.
  static String normaliseHeader(String header) =>
      header.trim().toUpperCase().replaceAll(' ', '');

  /// The header to *store*, which is the normalised one or the app default.
  ///
  /// The one place an absent header becomes a present one. The CSV importer
  /// did this with its own ternary and the editor did not do it at all, so a
  /// cleared CAN 標頭 field stored `''` — which `shouldTransmit` reads as
  /// "do not address anything", so `_pollBatch` marks the PID unsupported and
  /// the gauge reads as though the car has no such sensor. The identical blank
  /// arriving from a spreadsheet worked.
  ///
  /// Separate from [normaliseHeader] on purpose: normalising is about
  /// spelling, and substituting a default is a decision. Only storage
  /// boundaries make it.
  static String resolveHeader(String header) {
    final value = normaliseHeader(header);
    return value.isEmpty ? kDefaultHeader : value;
  }

  /// Whether [header] is a syntactically possible header on this bus.
  bool acceptsHeader(String header) {
    if (!isKnown) return false;
    // Through the one normaliser, like everything else that reads a header.
    // Trimming and upper-casing without stripping internal spaces is what let
    // `7 E 0` pass the editor's validator and then be rejected here.
    final value = normaliseHeader(header);
    if (value.length != headerHexDigits) return false;
    return RegExp(r'^[0-9A-F]+$').hasMatch(value);
  }

  /// Whether [header] is the value the app stores when the user has not chosen
  /// one.
  ///
  /// It happens to be `7E0`, which is a real engine address on 11-bit CAN and
  /// meaningless everywhere else. Treating it as "no preference" rather than
  /// as an instruction is what keeps a legacy vehicle working.
  static bool isAppDefault(String header) =>
      normaliseHeader(header) == kDefaultHeader;

  /// Whether this header should actually be transmitted before a query.
  ///
  /// False means "leave the adapter's own addressing alone", which is correct
  /// whenever the stored default is not meaningful on the detected bus.
  bool shouldTransmit(String header) {
    if (isAppDefault(header)) {
      // Only an instruction on the one bus where it names something.
      return family == ObdBusFamily.can11;
    }
    return acceptsHeader(header);
  }

  @override
  String toString() => 'BusAddressing(${family.name}, $headerHexDigits digits)';
}
