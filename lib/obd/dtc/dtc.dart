/// Diagnostic Trouble Code decoding (SAE J1979 Modes 03 / 07 / 0A / 04).
///
/// The spec this app is built from covers live data but not fault codes, so
/// none of this is a port — the encoding below comes from the J1979 standard
/// directly and is covered by its own unit tests with hand-built fixtures.
///
/// Each code is two bytes:
/// ```
///   bits 15-14  category  00=P powertrain  01=C chassis  10=B body  11=U network
///   bits 13-12  first digit   (0-3)
///   bits 11-8   second digit  (0-F)
///   bits  7-4   third digit   (0-F)
///   bits  3-0   fourth digit  (0-F)
/// ```
/// So `0x03 0x01` decodes to `P0301` — cylinder 1 misfire.
library;

import '../addressing.dart';

enum DtcCategory {
  powertrain('P', '動力系統'),
  chassis('C', '底盤'),
  body('B', '車身'),
  network('U', '網路');

  const DtcCategory(this.letter, this.label);

  final String letter;
  final String label;
}

/// Which J1979 mode a code was read from — they mean materially different
/// things to a driver and the UI groups by it.
enum DtcKind {
  stored('已儲存', '03', '已確認的故障，儀表板故障燈通常亮起'),
  pending('待確認', '07', '偵測到一次，尚未達到確認門檻'),
  permanent('永久', '0A', '無法用診斷儀清除，需修復後由 ECU 自行確認');

  const DtcKind(this.label, this.mode, this.description);

  final String label;
  final String mode;
  final String description;
}

class Dtc {
  final String code;
  final DtcCategory category;
  final DtcKind kind;

  /// True when the code is in the manufacturer-specific range rather than the
  /// SAE-defined one — worth flagging, since generic descriptions do not apply.
  final bool isManufacturerSpecific;

  /// Which controller reported it, when headers made that knowable.
  ///
  /// The parser has had this all along and the read threw it away, collapsing
  /// two modules reporting P0300 into one anonymous entry. Knowing that the
  /// engine *and* the transmission both see a misfire is different information
  /// from knowing that something does — it is often the difference between one
  /// fault and two.
  final String? sourceId;

  const Dtc({
    required this.code,
    required this.category,
    required this.kind,
    this.sourceId,
    required this.isManufacturerSpecific,
  });

  /// Generic description where the code is SAE-defined, else null.
  String? get description =>
      isManufacturerSpecific ? null : DtcDecoder.genericDescriptions[code];

  /// Which subsystem the code belongs to, read off its third digit.
  ///
  /// Not a description and not a guess: SAE J2012 assigns the third digit of a
  /// `P0` code to a subsystem, so `P0455` is an auxiliary-emissions fault
  /// whether or not this app has ever heard of it. That turns the fallback for
  /// an unknown code from 動力系統相關故障 — true of every code on this screen
  /// and therefore worth nothing — into something that narrows where to look.
  ///
  /// `P0` only. `P1` and `P3` are manufacturer ranges where the digit means
  /// whatever the manufacturer decided, and `P2`'s numbering does not follow
  /// the same layout at all — `P2004` is intake manifold runner control, not a
  /// fuel-metering fault. Claiming a subsystem there would be inventing one,
  /// which is the thing the description table already refuses to do.
  String? get subsystem => DtcDecoder.subsystemOf(code);

  /// Identity includes the controller.
  ///
  /// `sourceId` exists because ECM and TCM both reporting `P0301` are two
  /// observations about two modules, and the poller keys its accumulator that
  /// way. Equality did not, so any future `Set<Dtc>` or `contains` would have
  /// collapsed them into one anonymous fault — the transmission's copy
  /// silently absorbed by the engine's. Nothing in the UI uses set semantics
  /// today; this is here so that the day something does, it does not quietly
  /// lose a module.
  @override
  bool operator ==(Object other) =>
      other is Dtc &&
      other.code == code &&
      other.kind == kind &&
      other.sourceId == sourceId;

  @override
  int get hashCode => Object.hash(code, kind, sourceId);

  @override
  String toString() => code;
}

abstract final class DtcDecoder {
  static const List<DtcCategory> _categories = [
    DtcCategory.powertrain,
    DtcCategory.chassis,
    DtcCategory.body,
    DtcCategory.network,
  ];

  /// Decodes a single two-byte code. Returns null for the `0x0000` padding the
  /// ECU uses to fill an unused slot in a response frame.
  static Dtc? decodePair(int a, int b, DtcKind kind, {String? sourceId}) {
    if (a == 0 && b == 0) return null;

    final category = _categories[(a >> 6) & 0x03];
    final d1 = (a >> 4) & 0x03;
    final d2 = a & 0x0F;
    final d3 = (b >> 4) & 0x0F;
    final d4 = b & 0x0F;

    final code = '${category.letter}$d1'
        '${d2.toRadixString(16).toUpperCase()}'
        '${d3.toRadixString(16).toUpperCase()}'
        '${d4.toRadixString(16).toUpperCase()}';

    // First digit 1 or 3 marks the manufacturer-specific ranges (P1xxx, P3xxx
    // and their C/B/U equivalents); 0 and 2 are SAE-defined.
    final manufacturerSpecific = d1 == 1 || d1 == 3;

    return Dtc(
      code: code,
      category: category,
      kind: kind,
      sourceId: sourceId,
      isManufacturerSpecific: manufacturerSpecific,
    );
  }

  /// Whether a reply on [protocolNumber] carries a DTC count byte.
  ///
  /// ISO 15765-4 (CAN) puts the number of codes immediately after the mode
  /// byte; the legacy protocols — J1850, ISO 9141-2, KWP2000 — go straight to
  /// the codes. [protocolNumber] is what `ATDPN` returned, which may be
  /// prefixed with `A` when the protocol was found automatically.
  static bool protocolHasCountByte(String protocolNumber) {
    // Callers must establish [protocolIsKnown] first. Guessing here is how an
    // ISO 9141 car's single stored code became a fault it never set: `43 01 33
    // 00 00 00 00` read with CAN framing takes `01` as a count, starts two
    // bytes late, and reports P3300 while losing the real P0133 — and both the
    // count check and the padding check pass on the way through.
    assert(
      protocolIsKnown(protocolNumber),
      'protocolHasCountByte called with an undetermined protocol; '
      'callers must refuse to decode instead',
    );
    final trimmed = _normaliseProtocol(protocolNumber);
    // An undetermined protocol defaults to *not* CAN, which is the direction
    // that fails closed. It used to answer `true` — and the comment a few
    // lines above is about exactly what that costs: an ISO 9141 reply read
    // with CAN framing turns a real P0133 into a P3300 the car never set.
    //
    // The assertion above catches this in debug and is stripped from a release
    // build, so the default underneath it is what actually ships. Production
    // callers go through `_busRefusal` first; this is for the next caller who
    // does not.
    if (trimmed.isEmpty || trimmed == '0') return false;
    final value = int.tryParse(trimmed, radix: 16);
    if (value == null) return false;
    // Named, not ranged. A numeric range is what broke this: narrowing it to
    // `6..9` to exclude J1939 also excluded `B` and `C`.
    //
    // The reasoning given here for putting them back was that the datasheet
    // calls them "User1 CAN (11 bit ID, 125 kbaud)" and "User2 CAN", so they
    // were ISO 15765-4 with a configurable width and bitrate — a setting, not
    // a different application protocol. That was wrong, and the asterisks in
    // the datasheet's own protocol list mark those figures as adjustable
    // defaults. PP 2C's low three bits choose the data format, and `000` — the
    // factory value — is *no formatting at all*. See `_canProtocols` below.
    //
    // What that cost: a Mode 03 reply `43 02 01 03 07 00` on a forced `ATSPB`
    // bus, decoded without its count byte, pairs `(02,01)` and `(03,07)` into
    // P0201 and P0307 — two fault codes the vehicle never set, rendered with
    // the same confident red chip as a real one.
    //
    // `A` is J1939 and is refused by `protocolIsKnown` before anything reaches
    // here, so it needs no case; the assertion above enforces that.
    return _canProtocols.contains(trimmed);
  }

  /// The ELM327 protocol numbers that carry ISO 15765-4 framing *by their
  /// number alone*.
  ///
  /// `6`-`9` are the four standard variants. `A` is J1939 and is deliberately
  /// absent.
  ///
  /// `B` and `C` were here, on the reasoning that the user CAN protocols
  /// "differ only in identifier width and bitrate, both adjustable settings,
  /// not a different application layer". The datasheet's own defaults refute
  /// that: PP 2C ships as `E0` and PP 2E as `80`, and the data-format bits in
  /// both are `000` — no formatting. The format is one of none, ISO 15765-4 or
  /// SAE J1939, chosen per slot, so the letter establishes nothing and this
  /// decoder cannot see the options byte.
  ///
  /// Excluding them here is not the same as refusing them: `BusAddressing`
  /// does see the options byte, and the production callers ask it. What this
  /// set governs is the string API, which must not answer a question it has no
  /// evidence for — the previous version of that mistake decoded unframed CAN
  /// as J1979 and drew the result as fault codes.
  static const Set<String> _canProtocols = {'6', '7', '8', '9'};

  /// Delegates to the addressing module, which owns protocol identity.
  ///
  /// This used to be a second copy of the same normaliser. The copies drifted
  /// — one had the lookahead that keeps bare `A` (J1939) intact and the other
  /// did not — and only the one under test was ever fixed.
  static String _normaliseProtocol(String protocolNumber) =>
      BusAddressing.normaliseProtocolNumber(protocolNumber);

  /// Whether the adapter has actually settled on a bus protocol.
  ///
  /// `ATSP0` only *arms* the automatic search; `ATDPN` answers `A0` until the
  /// first OBD request has run it, and a clone can answer `?` or time out
  /// entirely. An undetermined protocol has no framing, and the two questions
  /// that follow — does this carry a count byte, is this CAN — used to answer
  /// it in opposite directions: `protocolHasCountByte('')` said CAN,
  /// `protocolIsCan('')` said not CAN. Neither guess is safe, so nothing that
  /// depends on framing may proceed without checking this first.
  static bool protocolIsKnown(String protocolNumber) {
    final trimmed = _normaliseProtocol(protocolNumber);
    // `A0` reaches here as `0` — the normaliser strips the automatic-search
    // prefix whenever a character follows it — so it needs no case of its own.
    if (trimmed.isEmpty || trimmed == '0') return false;
    // `A` is J1939: determined, and not a bus whose fault codes this decoder
    // can read. That is a different state from undetermined, and both were
    // being answered with the same silence — so a permissive bridge could put
    // the app on a J1939 bus and have every reply framed by ISO 15765-4 rules
    // that do not apply.
    if (trimmed == 'A') return false;
    // `B` and `C` for the reason given on `_canProtocols`: configurable slots,
    // and the configuration is not in the letter.
    if (trimmed == 'B' || trimmed == 'C') return false;
    return int.tryParse(trimmed, radix: 16) != null;
  }

  /// True when [protocolNumber] identifies a CAN bus.
  ///
  /// Multi-PID batching is a CAN-only feature; issuing it on a legacy bus
  /// returns a single PID's data or an error rather than the batch.
  static bool protocolIsCan(String protocolNumber) {
    final trimmed = _normaliseProtocol(protocolNumber);
    if (trimmed.isEmpty || trimmed == '0') return false; // undecided: don't batch
    // The same named set. J1939 (`A`) shares the physical layer and none of
    // the framing, so batching J1979 PIDs on it means nothing; `B` and `C`
    // carry whatever PP 2C / PP 2E say they carry, which this API cannot see,
    // so it declines to answer for them. `BusAddressing` can, and the
    // production callers ask it.
    return _canProtocols.contains(trimmed);
  }

  /// Decodes a full Mode 03/07/0A response payload.
  ///
  /// [bytes] is the reassembled hex payload including the response mode byte
  /// (`0x43`, `0x47` or `0x4A`).
  ///
  /// [hasCountByte] must reflect the bus protocol rather than be guessed from
  /// the data. Guessing gets it wrong on real replies: `43 01 43 01 96` is a
  /// legacy two-code answer (`P0143`, `P0196`), but a heuristic that accepts
  /// any plausible-looking count reads the leading `01` as "one code", starts
  /// two bytes late, and reports a single `C0301` that the car never set —
  /// both real faults lost and a fictional one invented.
  static List<Dtc> decodeResponse(
    List<int> bytes,
    DtcKind kind, {
    bool hasCountByte = true,
    String? sourceId,
  }) {
    if (bytes.isEmpty) return const [];

    final expectedMode = int.parse(kind.mode, radix: 16) + 0x40;
    var offset = 0;
    if (bytes[offset] == expectedMode) offset++;
    if (offset >= bytes.length) {
      // On CAN the count byte is part of the answer, so `43` on its own is not
      // "no codes" — it is a reply that stopped before it said anything. It
      // was returning an empty list, and an empty list here is a clean bill of
      // health: 未偵測到故障碼, on a scan whose Mode 03 payload was one byte
      // long.
      //
      // A legacy bus has no count byte, and a bare `43` there really is a
      // controller with nothing to report.
      if (hasCountByte) {
        throw StateError('故障碼回應只有服務位元組，沒有數量位元組');
      }
      return const [];
    }

    var declared = -1;
    var end = bytes.length;

    if (hasCountByte) {
      declared = bytes[offset];
      offset++;

      // The count is a claim, and the payload has to honour it. `2 + 2*count`
      // is the meaningful length; everything past it is CAN frame padding.
      final needed = offset + declared * 2;

      if (bytes.length < needed) {
        // Announced more codes than arrived. Reporting the ones that did
        // arrive presents a truncated read as a finished scan.
        throw StateError(
          '故障碼回應宣告 $declared 筆，實際資料不足（需要 $needed 位元組，收到 ${bytes.length}）',
        );
      }

      // Beyond the declared window only padding is legal. Real data there
      // means the count and the payload disagree, and the count is what the
      // decoder would otherwise trust — `43 00 03 01` declares nothing and
      // carries P0301, which currently reads out as a clean bill of health.
      //
      // Every byte is inspected, not every pair. Stepping in twos with an
      // `i + 1 < length` guard skipped a lone trailing byte entirely, so
      // `43 00 FF` passed as "no codes" and `43 01 01 33 07` reported P0133
      // while hiding that the frame was cut mid-code. A dangling byte is not
      // padding; it is the visible end of something that did not all arrive.
      for (var i = needed; i < bytes.length; i++) {
        if (bytes[i] != 0) {
          throw StateError('故障碼回應宣告 $declared 筆，卻在宣告範圍外帶有資料');
        }
      }

      end = needed;
    }

    // Fault codes are two bytes each, so an odd remainder is a truncated read
    // — `43 FF` is half of a code, and returning an empty list for it is
    // indistinguishable from a genuinely clean scan.
    if ((end - offset).isOdd) {
      throw StateError('故障碼回應長度為奇數，最後一個位元組不完整（截斷的回覆）');
    }

    final codes = <Dtc>[];
    for (var i = offset; i + 1 < end; i += 2) {
      // `00 00` is SAE padding for this mode, not fault code P0000.
      final dtc = decodePair(bytes[i], bytes[i + 1], kind, sourceId: sourceId);
      if (dtc != null) codes.add(dtc);
    }

    if (declared >= 0 && codes.length != declared) {
      throw StateError('故障碼回應宣告 $declared 筆，實際解出 ${codes.length} 筆');
    }
    return codes;
  }

  /// Encodes back to the two raw bytes. Used by tests and by the CSV exporter.
  static (int, int)? encode(String code) {
    if (code.length != 5) return null;
    final categoryIndex = _categories.indexWhere((c) => c.letter == code[0].toUpperCase());
    if (categoryIndex < 0) return null;

    final d1 = int.tryParse(code[1], radix: 16);
    final d2 = int.tryParse(code[2], radix: 16);
    final d3 = int.tryParse(code[3], radix: 16);
    final d4 = int.tryParse(code[4], radix: 16);
    if (d1 == null || d2 == null || d3 == null || d4 == null || d1 > 3) return null;

    return ((categoryIndex << 6) | (d1 << 4) | d2, (d3 << 4) | d4);
  }

  /// The SAE-defined codes drivers actually hit. Anything absent falls back to
  /// the category label rather than an invented description — guessing at a
  /// fault code is worse than admitting the app does not know it.
  ///
  /// Written here rather than imported, and that is a decision rather than
  /// laziness. The two large MIT-licensed DTC datasets on GitHub turn out to be
  /// one corpus wearing two labels — 7,387 codes in common, 99.3% of the
  /// descriptions byte-identical, including a shared copy-paste artifact — so
  /// taking both buys no corroboration. Most of their coverage uses post-2002
  /// SAE J2012 wording, and only the 2002 revision is incorporated by reference
  /// into US federal regulation; a repository's MIT licence covers its code, not
  /// its right to redistribute somebody else's standard text. No
  /// Traditional Chinese dataset with a usable licence exists at all, so the
  /// translation had to be written by hand whichever way the licensing went.
  ///
  /// The reason to care shows up in the data itself: the most-reposted
  /// "commonest fault codes" table on the web lists **P0411 as an EVAP purge
  /// fault**. It is not. `P0411` is secondary air injection; `P0441` is the
  /// EVAP one. Copying that description sends somebody to check a fuel cap
  /// while an air pump fails — a plausible-looking wrong answer, which is the
  /// same failure class `Elm327Client._parse`'s whitelist exists to prevent,
  /// arriving through a different door.
  ///
  /// Manufacturer-specific codes stay `null` deliberately: a P1xxx means
  /// whatever the manufacturer says it means, and the generic table has no
  /// standing to guess.
  /// The subsystem SAE J2012 assigns to each `P0` block by its third digit.
  ///
  /// `P00xx` covers both fuel/air metering and auxiliary emission controls,
  /// which is why its entry names both rather than picking one.
  static const Map<int, String> powertrainSubsystems = {
    0: '燃油與空氣計量、輔助排放控制',
    1: '燃油與空氣計量',
    2: '燃油與空氣計量（噴油嘴迴路）',
    3: '點火系統或失火',
    4: '輔助排放控制',
    5: '車速控制與怠速系統',
    6: '電腦輸出迴路',
    7: '變速箱',
    8: '變速箱',
    // Published as "control modules, input and output signals". An earlier
    // wording here said 變速箱與控制模組訊號 — half of that was invented to make
    // it read like its neighbours, which is the same liberty the P2270
    // description was dropped for.
    9: '控制模組輸入／輸出訊號',
  };

  /// The subsystem for a `P0` code, or null for anything else.
  ///
  /// Deliberately narrow — see [Dtc.subsystem] for why `P1`, `P2` and `P3` are
  /// excluded rather than approximated.
  static String? subsystemOf(String code) {
    if (code.length != 5) return null;
    if (code[0] != 'P' || code[1] != '0') return null;
    final block = int.tryParse(code[2], radix: 16);
    if (block == null) return null;
    return powertrainSubsystems[block];
  }

  static const Map<String, String> genericDescriptions = {
    'B0001': '駕駛座安全氣囊裝置故障',
    'P0011': '「A」凸輪軸正時過前或系統效能異常（Bank 1）',
    'P0014': '「B」凸輪軸正時過前或系統效能異常（Bank 1）',
    'P0016': '曲軸與凸輪軸位置訊號不同步（Bank 1 感知器 A）',
    'P0087': '燃油軌／系統壓力過低',
    'P0088': '燃油軌／系統壓力過高',
    'P0100': '空氣流量感知器 (MAF) 電路故障',
    'P0101': '空氣流量感知器範圍/效能異常',
    'P0102': '空氣流量感知器電路輸入過低',
    'P0103': '空氣流量感知器電路輸入過高',
    'P0105': '進氣歧管絕對壓力／大氣壓力感知器電路故障',
    'P0106': '進氣歧管絕對壓力感知器範圍/效能異常',
    'P0107': '進氣歧管絕對壓力感知器電路輸入過低',
    'P0108': '進氣歧管絕對壓力感知器電路輸入過高',
    'P0110': '進氣溫度感知器電路故障',
    'P0111': '進氣溫度感知器範圍/效能異常',
    'P0112': '進氣溫度感知器電路輸入過低',
    'P0113': '進氣溫度感知器電路輸入過高',
    'P0115': '冷卻液溫度感知器電路故障',
    'P0116': '冷卻液溫度感知器範圍/效能異常',
    'P0117': '冷卻液溫度感知器電路輸入過低',
    'P0118': '冷卻液溫度感知器電路輸入過高',
    'P0120': '節氣門位置感知器電路故障',
    'P0121': '節氣門位置感知器範圍/效能異常',
    'P0122': '節氣門位置感知器電路輸入過低',
    'P0123': '節氣門位置感知器電路輸入過高',
    'P0125': '冷卻液溫度不足以進入閉迴路燃油控制',
    'P0128': '冷卻液溫度低於節溫器調節溫度',
    'P0130': '含氧感知器電路故障 (Bank 1 Sensor 1)',
    'P0131': '含氧感知器電路電壓過低 (Bank 1 Sensor 1)',
    'P0132': '含氧感知器電路電壓過高 (Bank 1 Sensor 1)',
    'P0133': '含氧感知器反應過慢 (Bank 1 Sensor 1)',
    'P0134': '含氧感知器無活性訊號 (Bank 1 Sensor 1)',
    'P0135': '含氧感知器加熱器電路故障 (Bank 1 Sensor 1)',
    'P0136': '含氧感知器電路故障 (Bank 1 Sensor 2)',
    'P0137': '含氧感知器電路電壓過低 (Bank 1 Sensor 2)',
    'P0138': '含氧感知器電路電壓過高 (Bank 1 Sensor 2)',
    'P0140': '含氧感知器無活性訊號 (Bank 1 Sensor 2)',
    'P0141': '含氧感知器加熱器電路故障 (Bank 1 Sensor 2)',
    'P0150': '含氧感知器電路故障 (Bank 2 Sensor 1)',
    'P0155': '含氧感知器加熱器電路故障 (Bank 2 Sensor 1)',
    'P0156': '含氧感知器電路故障 (Bank 2 Sensor 2)',
    'P0161': '含氧感知器加熱器電路故障 (Bank 2 Sensor 2)',
    'P0170': '燃油修正異常 (Bank 1)',
    'P0171': '混合比過稀 (Bank 1)',
    'P0172': '混合比過濃 (Bank 1)',
    'P0173': '燃油修正異常 (Bank 2)',
    'P0174': '混合比過稀 (Bank 2)',
    'P0175': '混合比過濃 (Bank 2)',
    'P0190': '燃油軌壓力感知器電路故障',
    'P0201': '噴油嘴電路故障／開路 — 第 1 缸',
    'P0202': '噴油嘴電路故障／開路 — 第 2 缸',
    'P0203': '噴油嘴電路故障／開路 — 第 3 缸',
    'P0204': '噴油嘴電路故障／開路 — 第 4 缸',
    'P0217': '引擎過熱',
    'P0221': '節氣門／油門踏板位置感知器 B 範圍或效能異常',
    'P0222': '節氣門／油門踏板位置感知器 B 電路輸入過低',
    'P0223': '節氣門／油門踏板位置感知器 B 電路輸入過高',
    'P0234': '渦輪／機械增壓過壓',
    'P0299': '渦輪／機械增壓「A」增壓不足',
    'P0300': '偵測到隨機/多缸失火',
    'P0301': '第 1 缸失火',
    'P0302': '第 2 缸失火',
    'P0303': '第 3 缸失火',
    'P0304': '第 4 缸失火',
    'P0305': '第 5 缸失火',
    'P0306': '第 6 缸失火',
    'P0307': '第 7 缸失火',
    'P0308': '第 8 缸失火',
    'P0316': '起動後隨即偵測到失火',
    'P0325': '爆震感知器電路故障 (Bank 1)',
    'P0326': '爆震感知器範圍/效能異常 (Bank 1)',
    'P0327': '爆震感知器電路輸入過低 (Bank 1)',
    'P0328': '爆震感知器電路輸入過高 (Bank 1)',
    'P0330': '爆震感知器電路故障 (Bank 2)',
    'P0335': '曲軸位置感知器電路故障',
    'P0336': '曲軸位置感知器範圍/效能異常',
    'P0340': '凸輪軸位置感知器電路故障',
    'P0341': '凸輪軸位置感知器範圍/效能異常',
    'P0351': '點火線圈 A 一次/二次電路故障',
    'P0352': '點火線圈 B 一次/二次電路故障',
    'P0353': '點火線圈 C 一次/二次電路故障',
    'P0354': '點火線圈 D 一次/二次電路故障',
    'P0355': '點火線圈 E 一次/二次電路故障',
    'P0356': '點火線圈 F 一次/二次電路故障',
    'P0400': '廢氣再循環 (EGR) 流量故障',
    'P0401': '廢氣再循環 (EGR) 流量不足',
    'P0402': '廢氣再循環 (EGR) 流量過大',
    'P0403': '廢氣再循環 (EGR) 控制電路故障',
    'P0404': '廢氣再循環 (EGR) 控制電路範圍/效能異常',
    'P0410': '二次空氣噴射系統故障',
    'P0411': '二次空氣噴射系統流量不正確',
    'P0412': '二次空氣噴射切換閥 A 電路故障',
    'P0420': '觸媒轉換器效率低於門檻 (Bank 1)',
    'P0430': '觸媒轉換器效率低於門檻 (Bank 2)',
    'P0440': '蒸發排放控制系統故障',
    'P0441': '蒸發排放系統清除流量不正確',
    'P0442': '蒸發排放系統偵測到小漏氣',
    'P0443': '蒸發排放清除閥控制電路故障',
    'P0446': '蒸發排放通風控制電路故障',
    'P0447': '蒸發排放通風控制電路開路',
    'P0449': '蒸發排放通風閥/電磁閥電路故障',
    'P0451': '蒸發排放壓力感知器範圍/效能異常',
    'P0452': '蒸發排放壓力感知器電路輸入過低',
    'P0453': '蒸發排放壓力感知器電路輸入過高',
    'P0455': '蒸發排放系統偵測到大漏氣',
    'P0456': '蒸發排放系統偵測到極小漏氣',
    'P0480': '冷卻風扇 1 控制電路故障',
    'P0500': '車速感知器故障',
    'P0505': '怠速控制系統故障',
    'P0506': '怠速轉速低於預期',
    'P0507': '怠速轉速高於預期',
    'P0508': '怠速控制電路輸入過低',
    'P0509': '怠速控制電路輸入過高',
    'P0560': '系統電壓故障',
    'P0562': '系統電壓過低',
    'P0563': '系統電壓過高',
    'P0603': '控制模組內部記憶體（KAM）錯誤',
    'P0605': '控制模組內部唯讀記憶體（ROM）錯誤',
    'P0606': 'ECM/PCM 處理器故障',
    'P0700': '變速箱控制模組要求點亮故障燈 —— 故障碼在變速箱模組裡，請另外讀取',
    'P0701': '變速箱控制系統範圍/效能異常',
    'P0702': '變速箱控制系統電氣故障',
    'P0705': '排檔位置感知器電路故障',
    'P0715': '輸入軸／渦輪轉速感知器電路故障',
    'P0720': '輸出軸轉速感知器電路故障',
    'P0730': '檔位比不正確',
    'P0740': '扭力轉換器離合器電路故障',
    'P0741': '扭力轉換器離合器卡在未鎖定狀態',
    'P0750': '換檔電磁閥 A 故障',
    'P0755': '換檔電磁閥 B 故障',
    'P2135': '節氣門位置感知器 A/B 電壓不一致',
    'U0100': '與 ECM/PCM 失去通訊',
    'U0101': '與變速箱控制模組失去通訊',
    'U0121': '與 ABS 控制模組失去通訊',
    'U0140': '與車身控制模組失去通訊',
    'U0155': '與儀表板控制模組失去通訊',
  };
}

/// Why a fault-code read did not produce codes.
///
/// Modelled rather than flattened to an empty list, because "the controller
/// answered and had nothing" and "we never found out" look identical on screen
/// once both become `[]` — and one of them is a clinical statement a person
/// could drive away on.
class DtcReadException implements Exception {
  const DtcReadException(
    this.message, {
    this.kind = DtcReadFailure.error,
    this.partial = const [],
    this.pendingSources = const {},
    this.terminalSources = const {},
    this.heardAboutService = const {},
    this.silentSources = const {},
    this.repeatWouldHarm = false,
  });

  final String message;
  final DtcReadFailure kind;

  /// Whether re-issuing the operation that failed would damage something.
  ///
  /// True only for a clear that reached the bus. Once a functional `04` has
  /// been transmitted, at least one controller may have erased its fault
  /// memory — and a second global clear reaches that controller again and
  /// resets its readiness monitors a second time, costing the vehicle another
  /// full drive cycle before it can pass an emissions test.
  ///
  /// The messages already say so. This is the same fact in a form the *screen*
  /// can act on, because saying "do not do that" beside a live button is
  /// advice, and the user standing at a car with a fault light on has every
  /// reason to try again.
  final bool repeatWouldHarm;

  /// Controllers that answered `7F xx 78` and still owe a terminal reply.
  ///
  /// Carried so a retry can tell whether the *same* controller finished. It
  /// used to be discarded, and a later reply from any source closed the
  /// category — so a transmission promising an answer could be discharged by
  /// the engine's unrelated clean one.
  final Set<String> pendingSources;

  /// Controllers that were owed this question and said nothing at all.
  ///
  /// Distinct from every other set here, all of which record something a
  /// controller *did*. Silence is the one outcome with no reply to attach it
  /// to, and it is the one that can turn one module's `43 00` into a verdict
  /// about a whole vehicle — so the read carries the names out rather than
  /// only counting them into a sentence.
  ///
  /// Named so a caller can do something about it. A functional broadcast that
  /// one module missed is not the same as a module that will not answer, and
  /// on 11-bit CAN the difference is one physically addressed request away.
  final Set<String> silentSources;

  /// Controllers that gave a *final* answer during the same exchange.
  ///
  /// A reply can be mixed — the engine reports a fault while the transmission
  /// says it is still working — and that exchange fails as incomplete. Without
  /// carrying who finished, a retry cannot tell an obligation that has been
  /// discharged from one that never existed, and the accumulated debt only
  /// ever grows.
  final Set<String> terminalSources;

  /// Controllers whose reply was *about this service*, whether or not the
  /// exchange as a whole could be read.
  ///
  /// Distinct from [terminalSources], which is a trustworthy finished answer.
  /// A reply the adapter ended with `<RX ERROR` is not data and must not be
  /// decoded — and a controller that printed a Mode 03 response in it has
  /// plainly answered Mode 03. Saying nobody did contradicts the wire.
  final Set<String> heardAboutService;

  /// Codes that *were* read, on a scan that could not be completed.
  ///
  /// A scan where one controller answers and another refuses has produced real
  /// faults and an unknown remainder. Discarding the faults hides something
  /// the driver needs; presenting them as the whole answer is the defect this
  /// exists to prevent. Both are reported, and the screen says which is which.
  final List<Dtc> partial;

  @override
  String toString() => message;
}

/// The vehicle's controllers returned more than one complete, distinct VIN.
///
/// Controller order cannot decide which identity is authoritative, so callers
/// must keep the vehicle unknown and retain no candidate.
class VinIdentityConflictException extends DtcReadException {
  const VinIdentityConflictException(super.message);
}

enum DtcReadFailure {
  /// Nothing came back. On an optional class (Mode 07 pending, Mode 0A
  /// permanent) this is ordinary — Mode 0A is not universal before about 2012.
  /// On Mode 03 it means the question was not answered, which is not the same
  /// as the car being clean.
  ///
  /// The ELM327 generates `NO DATA` itself when nothing arrives before its
  /// timeout, so it does not even prove the ECU is silent — a filtered or slow
  /// reply produces it too.
  noAnswer,

  /// The controller explicitly refused, or the reply contradicted itself.
  error,

  /// The link went away mid-scan. Distinct from both of the above because the
  /// vehicle never got the chance to answer.
  disconnected,

  /// A controller answered `7F xx 78` — ISO 14229's
  /// `requestCorrectlyReceived-ResponsePending`.
  ///
  /// Distinct from every other outcome because it is not a failure at all: the
  /// controller has the request and is working on it. Erasing fault memory
  /// takes time, and slow legacy modules do this routinely. What follows
  /// should be a wait, not a diagnosis.
  pending,

  /// The adapter would not print response headers, so nobody knows how many
  /// controllers answered.
  ///
  /// Not a failure of the vehicle and not a failure of the request: the codes
  /// in [DtcReadException.partial] are real faults from a real reply. What
  /// cannot be claimed is coverage — an empty answer might be a clean car or a
  /// single controller of five. So the category reports as unanswered, keeps
  /// its codes, and the verdict comes out partial rather than clean.
  unattributed,
}

/// What a completed fault-code scan is entitled to claim.
///
/// This lived in the DTC screen as a single boolean, `_canDeclareClean`, which
/// asked only whether the *stored* class had answered and whether any codes had
/// been found. Mode 07 timing out and Mode 0A answering `NO DATA` therefore
/// left the screen rendering both failures **and** a green "no fault codes
/// detected" — a whole-vehicle all-clear resting on one category out of three.
///
/// It is a domain rule, not a presentation detail, so it lives where it can be
/// tested rather than inside a widget's private state.
enum ScanVerdict {
  notScanned,

  /// Every class answered and none reported a fault. The only state that may
  /// be rendered as an unqualified all-clear.
  completeClean,

  /// Everything that answered reported nothing, but some class did not answer.
  /// Whatever it would have said is unknown — which is not the same as clean.
  partialClean,

  faultsFound,

  /// Mode 03 itself did not answer. Every OBD-II vehicle must support it, so
  /// without it there is no scan at all, whatever the optional classes did.
  failed,
}

/// Decides what [answered] and [totalCodes] entitle the caller to claim.
///
/// [answered] is the set of classes that returned a usable result this round —
/// a refusal or a timeout is not one, and neither is a decode that had to be
/// rejected.
ScanVerdict scanVerdict({
  required bool hasScanned,
  required int totalCodes,
  required Set<DtcKind> answered,
  bool optionalCoverageComplete = true,
}) {
  if (!hasScanned) return ScanVerdict.notScanned;
  if (totalCodes > 0) return ScanVerdict.faultsFound;
  if (!answered.contains(DtcKind.stored)) return ScanVerdict.failed;
  if (answered.length != DtcKind.values.length) return ScanVerdict.partialClean;
  // Every class answered is not the same as every class answered by everybody.
  //
  // Modes 07 and 0A are optional in J1979, so a controller that never
  // implements them is a legal, healthy vehicle rather than a fault — and
  // holding it to those classes made ordinary cars look broken. But a module
  // that was never asked has not reported that it is clean, and the difference
  // is exactly what an unqualified green panel would erase.
  return optionalCoverageComplete
      ? ScanVerdict.completeClean
      : ScanVerdict.partialClean;
}
