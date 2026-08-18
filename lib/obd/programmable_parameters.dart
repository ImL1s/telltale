/// The adapter's persistent configuration, as printed by `AT PPS`.
///
/// Two questions this app must not guess at are answered here and nowhere
/// else, because `ATDPN` does not carry them:
///
///   * whether protocol `B` or `C` is even an OBD-II bus (PP 2C / PP 2E), and
///   * whether the adapter handles Response Pending for us (PP 2A bit 2).
///
/// Both were previously inferred — one from the protocol letter, one from a
/// version banner — and both inferences produce a plausible wrong answer
/// rather than an error.
library;

/// One `AT PPS` reading.
///
/// The trailing letter on each entry is the part that matters and the part
/// that is easy to skip. From the datasheet's own worked example (ELM327DSJ
/// p.67): after enabling PP 01, the summary shows `01:00 N` and the text reads
/// "You can see that PP 01 now shows a value of 00, and it is enabled (oN),
/// while the others are all off."
///
/// So `N` is **on** and `F` is **off**, and a parameter that is off is not in
/// effect no matter what value is stored beside it: the factory default
/// applies instead. Reading `2C:01 F` as "ISO 15765-4" would be the same class
/// of mistake as `ATCFC0` — the syntax read correctly and the semantics
/// inverted.
class ProgrammableParameters {
  const ProgrammableParameters._(this._stored, this._enabled);

  /// Nothing has been read. Every question answers "unknown", which is what
  /// the callers are built to handle.
  const ProgrammableParameters.unread()
      : _stored = const {},
        _enabled = const {};

  final Map<int, int> _stored;
  final Set<int> _enabled;

  /// Whether a summary was actually obtained. An adapter that does not
  /// implement `AT PPS` answers `?`, and a clone may answer something else
  /// entirely; neither is a configuration.
  bool get wasRead => _stored.isNotEmpty;

  /// Factory defaults, for the parameters this app consults.
  ///
  /// From the Programmable Parameter table (ELM327DSJ p.72-73). These are what
  /// is in effect whenever the corresponding entry reads `F`.
  static const Map<int, int> _factoryDefault = {
    0x2A: 0x3C, // CAN error checking, applies to protocols 6 to C
    0x2C: 0xE0, // Protocol B (USER1) CAN options
    0x2E: 0x80, // Protocol C (USER2) CAN options
  };

  /// The value actually governing the adapter's behaviour, or null if unknown.
  int? effective(int parameter) {
    // Absent is not the same as present-and-disabled.
    //
    // This used to answer from `wasRead`, so one parsed entry anywhere in a
    // truncated page made every *other* parameter report its factory default.
    // A summary cut short before PP 2A had the app conclude that response
    // pending was handled — on an adapter whose 2A said otherwise — and
    // decline the second Mode 03 that would have returned the fault. The
    // parser's own contract is that a partial summary must not be completed by
    // guessing; this is where that contract is kept.
    if (!_stored.containsKey(parameter)) return null;
    if (_enabled.contains(parameter)) return _stored[parameter];
    return _factoryDefault[parameter];
  }

  /// Whether this summary reported [parameter] at all.
  bool sawParameter(int parameter) => _stored.containsKey(parameter);

  /// Whether the adapter extends its own timeout on `7F xx 78`.
  ///
  /// "If bit 2 of PP 2A is set (it is by default), the ELM327 will support
  /// this part of J1979, changing the timeout to 5 seconds for you if it sees
  /// a Response Pending message." (ELM327DSJ, *Response Pending Messages*.)
  ///
  /// Null when unknown, and the caller must read that as "no". Assuming the
  /// adapter is handling it when it is not means declining to re-ask a
  /// controller that said "wait" — and a known stored fault is then never
  /// read.
  bool? get responsePendingHandled {
    final value = effective(0x2A);
    return value == null ? null : value & 0x04 != 0;
  }

  /// The options byte governing user CAN protocol [protocolLetter].
  int? userCanOptions(String protocolLetter) => switch (protocolLetter) {
        'B' => effective(0x2C),
        'C' => effective(0x2E),
        _ => null,
      };

  /// `hh:vv S`, whitespace-separated, twelve to a screen.
  static final RegExp _entry =
      RegExp(r'\b([0-9A-F]{2}):([0-9A-F]{2})\s+([NF])\b', caseSensitive: false);

  /// Parses an `AT PPS` reply.
  ///
  /// Anything that does not match the documented shape is discarded rather
  /// than interpreted. A partial or garbled summary yields whatever entries
  /// were intact, and an unparseable one yields [ProgrammableParameters.unread]
  /// — never a default-shaped guess.
  factory ProgrammableParameters.parse(String raw) {
    final stored = <int, int>{};
    final enabled = <int>{};
    for (final match in _entry.allMatches(raw)) {
      final parameter = int.parse(match.group(1)!, radix: 16);
      stored[parameter] = int.parse(match.group(2)!, radix: 16);
      if (match.group(3)!.toUpperCase() == 'N') enabled.add(parameter);
    }
    if (stored.isEmpty) return const ProgrammableParameters.unread();
    return ProgrammableParameters._(
      Map.unmodifiable(stored),
      Set.unmodifiable(enabled),
    );
  }
}

/// What a user CAN protocol's options byte says about framing.
///
/// From PP 2C's bit table (ELM327DSJ p.73): `b7` is the transmit ID length
/// (`0` 29-bit, `1` 11-bit) and `b2 b1 b0` choose the data format — `000`
/// none, `001` ISO 15765-4, `010` SAE J1939. Every other combination is
/// reserved and the datasheet says the results are unpredictable.
///
/// The default is the point. PP 2C ships as `E0` and PP 2E as `80`, and both
/// have `b2 b1 b0 == 000`: **at factory settings, protocols B and C carry no
/// data formatting at all.** They are not OBD-II buses until somebody makes
/// them one, so mapping `ATDPN B` to ISO 15765-4 was not a small
/// approximation — it ran the J1979 decoder over unframed CAN traffic.
enum UserCanFormat {
  /// No formatting. Not an OBD-II bus.
  none,

  /// ISO 15765-4, which is what protocols 6-9 are.
  iso15765,

  /// SAE J1939, which this app refuses for its own reasons.
  j1939,

  /// A reserved combination. The datasheet declines to say what happens.
  reserved;

  static UserCanFormat of(int options) => switch (options & 0x07) {
        0 => UserCanFormat.none,
        1 => UserCanFormat.iso15765,
        2 => UserCanFormat.j1939,
        _ => UserCanFormat.reserved,
      };
}

/// Whether [options] selects 11-bit transmit identifiers.
bool userCanIs11Bit(int options) => options & 0x80 != 0;

/// Whether [options] makes the adapter accept *both* receive widths.
///
/// PP 2C bit 5: "Receive ID Length — 0: as set by b7, 1: both 11 and 29 bit"
/// (ELM327DSJ p.73). Transmit width and receive width are separate settings,
/// and a slot configured this way will legitimately answer on the width its
/// requests do not use.
bool userCanAcceptsBothWidths(int options) => options & 0x20 != 0;
