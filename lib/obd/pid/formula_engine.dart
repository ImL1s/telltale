/// Evaluates the arithmetic a PID definition carries.
///
/// The dialect is the one OBD2 apps have converged on and users already write
/// by hand: `A`..`N` bind to the reply's data bytes, with `SIGNED()`, `VAL{}`,
/// `BARO`, `ABS()` and `LOG10()` on top. Accepting it means somebody's
/// existing formula for their car works here without being retyped.
///
/// Evaluation is two-phase:
///   1. [_preprocess] binds `A`..`N` to response bytes and resolves the
///      non-arithmetic constructs — `SIGNED()`, `VAL{}`, `BARO`, `ABS()`,
///      `LOG10()` — leaving a pure arithmetic string.
///   2. [_reduce] collapses that string by repeatedly splitting on the
///      lowest-binding operator, recursing into each side.
library;

import 'dart:math' as math;

import 'pid.dart';

/// Thrown when a formula cannot be evaluated. Carries the offending source so
/// the PID editor can show the user what it choked on.
class FormulaException implements Exception {
  final String message;
  final String source;

  const FormulaException(this.message, this.source);

  @override
  String toString() => 'FormulaException: $message (in "$source")';
}

/// A cached dependency value, with the two things a bare `double` cannot say:
/// when it was measured, and which controller measured it (via its cache key).
class _CachedValue {
  const _CachedValue(this.value, this.at, this.writtenBy);
  final double value;
  final DateTime at;

  /// The equation that produced it.
  ///
  /// Two gauges can define the same hex on the same controller with different
  /// maths — a raw variant beside a converted one. They share a cache key,
  /// because `VAL{010B}` names hex and nothing else, and whichever polled last
  /// used to win. Recording the author lets an ambiguous reference be refused
  /// instead of answered arbitrarily.
  final String writtenBy;
}

class FormulaEngine {
  /// Cached values of other PIDs for `VAL{...}` lookups.
  ///
  /// Keyed by controller **and** hex, never hex alone. `7E0:221101` and
  /// `7E1:221101` are different sensors on different controllers that happen
  /// to share an identifier; collapsing them let a formula on one ECU consume
  /// the other's measurement, whichever polled last.
  final Map<String, _CachedValue> _pidCache = {};

  /// How long a cached dependency stays usable.
  ///
  /// Without an age, a source that stopped answering left its last value in
  /// the cache forever: the poller removed the visible reading and marked the
  /// fault, while every formula depending on it went on quoting the number.
  static const Duration maxCacheAge = Duration(seconds: 5);

  /// Ambient pressure per controller, on the same terms as every other
  /// dependency.
  ///
  /// A single shared value meant `7E0`'s barometric reading fed a formula
  /// evaluated on `7E1`, whichever wrote last — the very collision the `VAL{}`
  /// work removed, still open on the one input that had no byte of its own.
  /// It also survived `clearCache()`, so a pressure measured before a pause
  /// was consumed after continuity had been explicitly broken.
  final Map<String, _CachedValue> _baro = {};

  /// Records a measured ambient pressure (kPa) taken at [at].
  ///
  /// There is no default. It used to be 101.3 — sea level — which is a
  /// measurement the app never took. At 2000 m ambient is about 79.5 kPa, so
  /// `A-BARO` on a 100 kPa manifold reported -1.3 kPa instead of +20.5 kPa:
  /// plausible, labelled as derived from measurement, and wrong by the whole
  /// altitude.
  void setBaroPressure(Pid source, double kPa, DateTime at) {
    final key = _controllerKey(source.header);
    final existing = _baro[key];
    // The same conflict rule `VAL{}` uses, and it was missing here — the
    // author of each write was recorded and then consulted by nobody. A custom
    // `0133` defined as `A*10` polled beside the built-in `A` had `BARO`
    // silently alternating between two values at the polling cadence, on one
    // controller, for one measurement. `VAL{0133}` refuses that exact
    // collision, so the app was applying two opposite policies to the same
    // ambiguity depending on which spelling a formula happened to use.
    if (existing != null && _writersDisagree(existing, source.equation, kPa)) {
      _baroAmbiguous.add(key);
    }
    _baro[key] = _CachedValue(kPa, at, source.equation);
  }

  /// Controllers whose ambient pressure has more than one author.
  final Set<String> _baroAmbiguous = {};

  static String _controllerKey(String header) => header.toUpperCase().trim();

  /// Seeds a stand-in ambient pressure for authoring previews, where there is
  /// no live data and the only question is whether the formula is well-formed.
  ///
  /// Deliberately not usable as a runtime measurement: evaluation with a
  /// timestamp applies the same staleness rule to it as to any dependency.
  set baroPressure(double? kPa) {
    final key = _controllerKey(kDefaultHeader);
    if (kPa == null) {
      _baro.remove(key);
    } else {
      _baro[key] = _CachedValue(kPa, DateTime.now(), 'authoring');
    }
  }

  static String _cacheKey(String header, String modeAndPid) =>
      '${header.toUpperCase().trim()}:${modeAndPid.toUpperCase().trim()}';

  /// Operators grouped into precedence levels, loosest first.
  ///
  /// Grouping matters. Scanning a flat list and splitting on the first symbol
  /// found makes every operator a distinct precedence level in list order, so
  /// `A/B%C` would split on `/` and evaluate as `A/(B%C)`. `*`, `/` and `%`
  /// are one level in every language that has them, and within a level the
  /// split takes the *right-most* occurrence so repeated operators associate
  /// left to right.
  static final List<List<_Operator>> _levels = [
    [
      _Operator('==', (a, b) => a == b ? 1.0 : 0.0),
      _Operator('!=', (a, b) => a != b ? 1.0 : 0.0),
      _Operator('>=', (a, b) => a >= b ? 1.0 : 0.0),
      _Operator('<=', (a, b) => a <= b ? 1.0 : 0.0),
      _Operator('>', (a, b) => a > b ? 1.0 : 0.0),
      _Operator('<', (a, b) => a < b ? 1.0 : 0.0),
    ],
    [_Operator('|', (a, b) => (a.toInt() | b.toInt()).toDouble())],
    [_Operator('&', (a, b) => (a.toInt() & b.toInt()).toDouble())],
    [
      _Operator('+', (a, b) => a + b),
      _Operator('-', (a, b) => a - b),
    ],
    [
      _Operator('*', (a, b) => a * b),
      // Returning 0 here turns a divide-by-zero into a plausible reading. A
      // boost formula dividing by a baro value that has not arrived yet would
      // show 0 kPa rather than admitting it cannot be computed.
      _Operator('/', (a, b) {
        if (b == 0) throw const _ArithmeticFailure('除以零');
        return a / b;
      }),
      _Operator('%', (a, b) {
        if (b == 0) throw const _ArithmeticFailure('模除以零');
        // Truncated remainder, not Dart's Euclidean `%`.
        //
        // These formulas come from Torque, which is a Java app, and Java's `%`
        // takes the sign of the dividend. Dart's does not: `(A-128)%16` with
        // `A = 0x64` is `-12` in Torque and `12` here. Both are numbers, both
        // pass every structural check the editor makes, and the gauge shows
        // the wrong one with no fault — which is the failure this project
        // exists to prevent. A user's imported formula has to mean what it
        // meant where it was written.
        return a.remainder(b);
      }),
    ],
  ];

  /// Binds tighter than a unary minus, so `-A^2` is `-(A^2)`.
  static final _Operator _power = _Operator('^', (a, b) => math.pow(a, b).toDouble());

  static final RegExp _valPattern = RegExp(r'VAL\{([A-F0-9]+)\}');
  static final RegExp _signedPattern = RegExp(r'SIGNED\(([A-N])\)');
  static final RegExp _absPattern = RegExp(r'ABS\(([^()]+)\)');
  static final RegExp _log10Pattern = RegExp(r'LOG10\(([^()]+)\)');
  static final RegExp _nonHex = RegExp('[^0-9A-Fa-f]');

  /// Sentinels that stand in for function names while `A`..`N` are substituted.
  /// They must contain no A-N letters of their own, hence control characters.
  static const String _absSentinel = '\u0001(';
  static const String _log10Sentinel = '\u0002(';

  /// Characters that, when they precede a `-`, mark it as unary rather than
  /// a binary subtraction.
  static const String _unaryContext = '+-*/%^&|<>(=';

  /// Keys whose value cannot be attributed to one definition.
  final Set<String> _ambiguous = {};

  /// Whether two writers to one key actually disagree.
  ///
  /// Equation *text* is not the question. `A` and `(A)` compute the same
  /// number from the same bytes, and comparing the strings marked the key
  /// permanently ambiguous — so a boost gauge went unavailable because two
  /// definitions of ambient pressure were spelled differently while producing
  /// exactly the same measurement.
  ///
  /// The honest test is whether the values disagree at the moment a reader
  /// would use them. Two definitions that agree today may diverge tomorrow —
  /// `A` and `A*2` agree only while A is zero — and this catches that when it
  /// happens rather than pre-emptively refusing every difference in spelling.
  static bool _writersDisagree(_CachedValue existing, String by, double value) {
    if (existing.writtenBy == by) return false;
    if (existing.value == value) return false;
    // NaN never equals itself; two NaNs are not a disagreement about anything.
    if (existing.value.isNaN && value.isNaN) return false;
    return true;
  }

  void cachePidValue(Pid pid, double value, DateTime at) {
    final key = _cacheKey(pid.header, pid.modeAndPid);
    final existing = _pidCache[key];
    if (existing != null && _writersDisagree(existing, pid.equation, value)) {
      // Two definitions of the same hex on the same controller, computing
      // different things. `VAL{}` names hex, so it cannot say which was meant.
      _ambiguous.add(key);
    }
    _pidCache[key] = _CachedValue(value, at, pid.equation);
  }

  /// The value [requester] should see for `VAL{[modeAndPid]}`, if any.
  ///
  /// Resolution is scoped to the requester's own controller. A formula on the
  /// ECM asking for a PID only the TCM answers gets null — which is the truth,
  /// and which the caller renders as unavailable rather than as a number.
  double? cachedPidValue(
    Pid requester,
    String modeAndPid, {
    required DateTime? now,
  }) {
    final key = _cacheKey(requester.header, modeAndPid);
    // Refused rather than resolved. Picking either answer would be picking one
    // at random, and the number that comes out looks exactly as reasonable as
    // the right one.
    if (_ambiguous.contains(key)) return null;
    // (see `isAmbiguous` — callers need to tell this refusal apart from a
    //  value that has simply not arrived)
    final entry = _pidCache[key];
    if (entry == null) return null;
    // A null `now` means the caller has no clock to judge staleness against —
    // the authoring preview. Runtime always passes one.
    if (now != null && now.difference(entry.at).abs() > maxCacheAge) return null;
    return entry.value;
  }

  /// Whether two definitions of this hex are both writing to the cache.
  ///
  /// `pidValue` returns null for three different reasons — nobody has answered
  /// yet, the answer has aged out, or two definitions disagree about what the
  /// hex means — and the caller reported all three as "no value obtained yet".
  /// For the third that is a lie about the cause: the value exists, twice, and
  /// the app is declining to choose. Telling the user to wait sends them to
  /// look for a fault in a vehicle that is answering perfectly, when what they
  /// need to do is remove one of two gauges.
  ///
  /// It is easy to reach without doing anything unusual: the shipped library
  /// defines `010B` twice — manifold pressure and turbo boost — and `010D`
  /// twice, as km/h and mph. The physics inputs are force-merged, so putting
  /// either derived gauge on the dashboard makes that hex ambiguous for as
  /// long as it is there.
  bool isAmbiguous(String header, String modeAndPid) =>
      _ambiguous.contains(_cacheKey(header, modeAndPid));

  void clearCache() {
    _pidCache.clear();
    _ambiguous.clear();
    // Cleared with everything else. It is a measurement like any other, and
    // leaving it behind let a pressure from before a pause feed a formula
    // after one.
    _baro.clear();
    _baroAmbiguous.clear();
  }

  /// Evaluates [equation] against a raw ECU hex [payload].
  ///
  /// [payload] may be spaced or contiguous, and may or may not carry the
  /// positive-response prefix. Mode 01 answers (`0x41`) drop 2 leading bytes,
  /// Mode 22 answers (`0x62`) drop 3, so that `A` binds to the first *data*
  /// byte in both cases.
  double evaluate(
    String equation,
    String payload, {
    Pid? requester,
    DateTime? now,
  }) {
    return evaluateBytes(
      equation,
      parseUserTypedSampleBytes(payload),
      requester: requester,
      now: now,
    );
  }

  /// Same as [evaluate] but takes already-extracted data bytes, skipping the
  /// response-prefix heuristic. Used by the polling loop, which has already
  /// split a batched multi-PID frame into per-PID slices.
  double evaluateBytes(
    String equation,
    List<int> dataBytes, {
    Pid? requester,
    DateTime? now,
  }) {
    if (equation.trim().isEmpty) {
      throw FormulaException('Formula is empty', equation);
    }
    final double result;
    try {
      // Preprocessing has to be inside this boundary, not before it.
      // `_applyFunction` reduces its own argument, so `ABS(A/B)` with `B = 0`
      // raises `_ArithmeticFailure` during preprocessing — outside the catch
      // that turns it into a `FormulaException`. The poller only handles
      // `FormulaException`, so the raw failure took out the whole polling
      // cycle through the loop's outer catch, without invalidating the reading
      // or recording a fault: the previous value stayed on the gauge,
      // presented as current.
      final prepared = _preprocess(equation, dataBytes, requester, now);
      result = _reduce(prepared, equation);
    } on _ArithmeticFailure catch (e) {
      throw FormulaException(e.message, equation);
    }
    // NaN and infinity render as "--" at best and as a garbage gauge position
    // at worst; neither is a reading.
    if (result.isNaN || result.isInfinite) {
      throw FormulaException('運算結果不是有效數值', equation);
    }
    return result;
  }

  /// Strips the positive-response header off a **user-typed** hex sample and
  /// returns the data bytes that `A`..`N` bind to.
  ///
  /// Named for its only legitimate input. The first line below deletes every
  /// non-hex character and concatenates what is left — the blacklist strip that
  /// this project's hard rules forbid on anything that came off the wire.
  /// `DATA ERROR` survives it as `DA AE`: two bytes, plausible magnitudes, no
  /// way downstream to tell them from a sensor reading. A pinned test in
  /// `test/formula_engine_test.dart` asserts exactly that byte pair, so the
  /// hazard is recorded rather than assumed.
  ///
  /// It is deliberately kept anyway, because the two call sites take text a
  /// person typed into the PID editor's 測試用回應位元組 field: someone pasting
  /// `41 0C 1A F0` from a forum post, with whatever punctuation came along.
  /// There is no adapter on that path and no reading is published from it — the
  /// worst case is a wrong number in a preview the author is actively looking
  /// at.
  ///
  /// **No adapter-sourced string may reach here.** Wire data goes through the
  /// whitelist in `Elm327Client._hexLine`, which accepts only lines that are
  /// entirely hex byte pairs, and then arrives as `List<int>` at
  /// [evaluateBytes]. A companion test asserts that nothing under `lib/obd/`
  /// calls the string-taking overload above, which is the only route from a
  /// response line into this function.
  static List<int> parseUserTypedSampleBytes(String payload) {
    final hex = payload.replaceAll(_nonHex, '');
    final all = <int>[];
    for (var i = 0; i + 1 < hex.length; i += 2) {
      final b = int.tryParse(hex.substring(i, i + 2), radix: 16);
      if (b == null) break;
      all.add(b);
    }
    if (all.length < 2) return all;

    // 0x4X = positive response to Mode 0X; 0x62 = positive response to Mode 22.
    //
    // The header is stripped only when the whole header is there. `62 1E` is
    // two bytes and the Mode 22 header is three, so `sublist(3)` threw a raw
    // `RangeError` — outside this file's `FormulaException` contract, and the
    // editor showed the user a Dart error object.
    //
    // The `0x4X` test is also a guess, and it is stated as one here because it
    // stays a guess: a user pasting the *data* bytes of a reply whose first
    // byte happens to be `4A` sees `A` bound to the second byte instead. There
    // is no way to tell an echoed header from data that looks like one, and
    // the preview is an authoring aid where being wrong costs a re-read rather
    // than a wrong gauge. Requiring a plausible PID byte behind it narrows the
    // guess without pretending to resolve it.
    if (all[0] == 0x62 && all.length >= 4) return all.sublist(3);
    if ((all[0] & 0xF0) == 0x40 && all.length >= 3) return all.sublist(2);
    return all;
  }

  String _preprocess(
    String equation,
    List<int> bytes,
    Pid? requester,
    DateTime? now,
  ) {
    var s = equation.replaceAll(' ', '').toUpperCase();
    // Normalise the Unicode minus that sneaks in from copy-pasted formulas.
    s = s.replaceAll('−', '-');

    if (s.contains('BARO')) {
      if (requester == null) {
        throw FormulaException('無法判斷 BARO 所屬的控制器，拒絕求值', equation);
      }
      final controller = _controllerKey(requester.header);
      if (_baroAmbiguous.contains(controller)) {
        throw FormulaException(
          '有兩個定義同時提供大氣壓力，數值可能是其中任何一個，因此無法採用。'
          '請移除其中一個測量大氣壓力的錶。',
          equation,
        );
      }
      final baro = _baro[controller];
      // Absent ambient pressure is not sea level. Refusing here is what turns
      // "wrong by the altitude" into "unavailable", which the gauge can show.
      if (baro == null) {
        throw FormulaException('尚未取得大氣壓力量測值，無法計算', equation);
      }
      // `now == null` is the authoring path, which has no measurements to age.
      if (now != null && now.difference(baro.at).abs() > maxCacheAge) {
        throw FormulaException('大氣壓力量測值已過期，無法計算', equation);
      }
      s = s.replaceAll('BARO', _format(baro.value));
    }

    s = s.replaceAllMapped(_valPattern, (m) {
      final key = m.group(1)!;
      // `VAL{}` names a PID on *some* controller. Without knowing which one is
      // asking, the reference cannot be resolved to a specific sensor — and
      // resolving it to whichever controller wrote the key last is the defect.
      if (requester == null) {
        throw FormulaException('無法判斷 VAL{$key} 所屬的控制器，拒絕求值', equation);
      }
      // `now == null` is the authoring path, which has no measurements to age
      // — the same exemption BARO gets a few lines above, for the same reason.
      final cached = cachedPidValue(
        requester,
        key,
        now: now ?? _pidCache[_cacheKey(requester.header, key)]?.at,
      );
      // Substituting zero for a PID that has not been read yet is how a boost
      // gauge ends up displaying raw manifold pressure: `A-VAL{0133}` quietly
      // becomes `A-0`. Refuse until the dependency actually exists — and until
      // it is fresh, because a dependency that stopped answering leaves a
      // number that looks exactly like one that is still arriving.
      if (cached == null) {
        throw FormulaException(
          isAmbiguous(requester.header, key)
              // Not "remove one of the gauges", which is advice that can be
              // followed exactly and change nothing. `PollingEngine` merges
              // `PidLibrary.physicsInputs` into the active set on every
              // update, so `010B`, `010C` and `010D` are read whether or not a
              // gauge for them is on the dashboard — take the MAP gauge off
              // and the ambiguity is still there, with nothing on screen left
              // to remove. The action that works is changing the *definition*.
              ? '有兩個定義同時解讀 $key，數值可能是其中任何一個，因此無法採用。'
                  '請讓其中一個改用不同的模式+PID。'
                  '注意：推算數值需要的 PID（010B、010C、010D）本 App 一定會讀取，'
                  '把面板上的錶移掉不會停止讀取它們。'
              : '尚未取得相依 PID $key 的有效數值',
          equation,
        );
      }
      return _format(cached);
    });

    s = s.replaceAllMapped(_signedPattern, (m) {
      final letter = m.group(1)!;
      final index = letter.codeUnitAt(0) - 0x41; // 'A'
      if (index >= bytes.length) {
        throw FormulaException(
          '公式參照位元組 $letter，但回應只有 ${bytes.length} 個位元組',
          equation,
        );
      }
      final raw = bytes[index];
      return _format((raw >= 128 ? raw - 256 : raw).toDouble());
    });

    // Shield function names before single-letter substitution, otherwise the
    // `A` in `ABS` and the `G` in `LOG10` would be replaced by byte values.
    s = s.replaceAll('ABS(', _absSentinel).replaceAll('LOG10(', _log10Sentinel);

    for (var i = 0; i < 14; i++) {
      final letter = String.fromCharCode(0x41 + i);
      final pattern = RegExp('\\b$letter\\b');
      if (!pattern.hasMatch(s)) continue;

      // Substituting 0 for a byte the ECU did not send produces a confident
      // wrong number rather than an error — a truncated RPM reply would read
      // 1664 instead of 1724 and nothing would look amiss. Refuse instead.
      if (i >= bytes.length) {
        throw FormulaException(
          '公式參照位元組 $letter，但回應只有 ${bytes.length} 個位元組',
          equation,
        );
      }
      s = s.replaceAll(pattern, bytes[i].toString());
    }

    s = s.replaceAll(_absSentinel, 'ABS(').replaceAll(_log10Sentinel, 'LOG10(');

    // Alternating, not one pass each in a fixed order.
    //
    // Both patterns exclude parentheses so that each pass necessarily collapses
    // an *innermost* call. Running ABS once and then LOG10 once therefore made
    // exactly one nesting order work: `LOG10(ABS(A))` reduced, `ABS(LOG10(A))`
    // did not — ABS could not see past the inner parentheses on its pass, and
    // by the time LOG10 had removed them ABS was over. The formula was refused
    // at authoring time with nothing wrong in it.
    //
    // `_unwrapFunctionParens` handles the other shape a user writes by habit,
    // `ABS((A-1))`, where the argument is parenthesised for its own sake.
    //
    // Each pass either shrinks the string or leaves it alone, so the loop ends.
    var previous = '';
    var guard = 0;
    while (previous != s) {
      if (++guard > 64) {
        throw FormulaException('公式的函式巢狀太深', equation);
      }
      previous = s;
      s = _applyFunction(s, _absPattern, equation, (v) => v.abs());
      // `LOG10` of zero or a negative number is undefined, and answering 0
      // makes an impossible input look like an ordinary reading:
      // `LOG10(A-128)` with `A = 0` displayed a confident 0 rather than
      // admitting the expression has no value there.
      s = _applyFunction(s, _log10Pattern, equation, (v) {
        if (v <= 0) {
          throw FormulaException('LOG10 的引數必須大於 0（收到 $v）', equation);
        }
        return math.log(v) / math.ln10;
      });
      s = _unwrapFunctionParens(s, equation);
    }

    return s;
  }

  /// A function whose argument is itself parenthesised: `ABS((A-1))`.
  ///
  /// The function patterns exclude parentheses so each pass targets an
  /// innermost call, which means they cannot see this shape at all — and it is
  /// how people write. Reducing the inner group turns it back into something
  /// the ordinary pass matches on the next turn.
  static final RegExp _functionWrappedParens =
      RegExp(r'(ABS|LOG10)\(\s*(\([^()]*\))\s*\)');

  String _unwrapFunctionParens(String input, String source) {
    var s = input;
    var guard = 0;
    while (true) {
      final match = _functionWrappedParens.firstMatch(s);
      if (match == null) return s;
      if (++guard > 64) {
        throw FormulaException('公式的括號巢狀太深', source);
      }
      final inner = _reduce(match.group(2)!, source);
      s = s.replaceRange(
          match.start, match.end, '${match.group(1)}(${_format(inner)})');
    }
  }

  /// Repeatedly collapses the innermost `NAME(...)` call until none remain.
  /// The pattern excludes nested parens, so each pass necessarily targets an
  /// innermost call and the string strictly shrinks.
  String _applyFunction(
    String input,
    RegExp pattern,
    String source,
    double Function(double) fn,
  ) {
    var s = input;
    var guard = 0;
    while (true) {
      final match = pattern.firstMatch(s);
      if (match == null) return s;
      if (++guard > 64) {
        throw FormulaException('Formula nests functions too deeply', source);
      }
      final inner = _reduce(match.group(1)!, source);
      s = s.replaceRange(match.start, match.end, _format(fn(inner)));
    }
  }

  double _reduce(String expression, String source) {
    var s = expression.trim();
    if (s.isEmpty) throw FormulaException('Empty sub-expression', source);

    // Collapse parentheses innermost-first.
    var guard = 0;
    while (s.contains('(')) {
      if (++guard > 256) {
        throw FormulaException('Formula nests parentheses too deeply', source);
      }
      final close = s.indexOf(')');
      if (close == -1) throw FormulaException('Unbalanced parentheses', source);
      final open = s.lastIndexOf('(', close);
      if (open == -1) throw FormulaException('Unbalanced parentheses', source);
      final value = _reduce(s.substring(open + 1, close), source);
      s = s.replaceRange(open, close + 1, _format(value));
    }

    final literal = double.tryParse(s);
    if (literal != null) return literal;

    for (final level in _levels) {
      // Right-most match across the whole level, so equal-precedence operators
      // associate left to right: 10-5-2 is (10-5)-2, not 10-(5-2).
      var bestIndex = -1;
      _Operator? bestOp;
      for (final op in level) {
        final index = _findBinaryOperator(s, op.symbol);
        if (index > bestIndex) {
          bestIndex = index;
          bestOp = op;
        }
      }
      if (bestIndex > 0 && bestOp != null) {
        final left = _reduce(s.substring(0, bestIndex), source);
        final right = _reduce(s.substring(bestIndex + bestOp.symbol.length), source);
        return bestOp.apply(left, right);
      }
    }

    // Unary sign is resolved before exponentiation but after every binary
    // level above, which is what makes `-A^2` evaluate to `-(A^2)`.
    if (s.startsWith('-')) return -_reduce(s.substring(1), source);
    if (s.startsWith('+')) return _reduce(s.substring(1), source);

    // Exponentiation is right-associative: 2^3^2 is 2^(3^2) = 512. Splitting on
    // the right-most `^` (as every other level does) would give (2^3)^2 = 64,
    // so this level takes the *left-most* occurrence instead.
    final powerIndex = s.indexOf(_power.symbol);
    if (powerIndex > 0) {
      return _power.apply(
        _reduce(s.substring(0, powerIndex), source),
        _reduce(s.substring(powerIndex + 1), source),
      );
    }

    // Tighter than `^`: this is a negative value, not a negated expression.
    if (s.startsWith(_negative)) return -_reduce(s.substring(1), source);

    if (s.startsWith('~')) return (~_reduce(s.substring(1), source).toInt()).toDouble();
    if (s.startsWith('!')) return _reduce(s.substring(1), source) == 0.0 ? 1.0 : 0.0;

    throw FormulaException('Cannot parse "$s"', source);
  }

  /// Finds the right-most occurrence of [op] that is acting as a binary
  /// operator. Scanning right-to-left and recursing left makes repeated
  /// same-precedence operators associate left-to-right.
  int _findBinaryOperator(String s, String op) {
    for (var i = s.length - 1; i >= 0; i--) {
      if (!s.startsWith(op, i)) continue;
      if (op == '-' && (i == 0 || _unaryContext.contains(s[i - 1]))) {
        continue; // unary sign, not a subtraction
      }
      return i;
    }
    return -1;
  }

  /// Marks a value that is negative *in itself*, as opposed to an expression
  /// with a leading minus sign.
  ///
  /// The distinction is load-bearing. Reducing `(-A)^2` collapses the bracket
  /// first, and splicing the result back as a plain `-3.0` throws away the
  /// author's grouping: the reducer then sees `-3.0^2.0` and correctly applies
  /// the usual rule that a unary minus binds looser than exponentiation,
  /// yielding −9 where the brackets asked for 9. A marked negative binds
  /// tighter than `^`, so both spellings mean what they say.
  static const String _negative = '\u0003';

  /// Renders a double back into the expression string. Plain `toString()` emits
  /// `1e-7` style output for small magnitudes, which the reducer would then
  /// mis-split on the `-`; fixed notation avoids that entirely.
  static String _format(double value) {
    // A non-finite intermediate used to be rendered as `0.0` and the reduction
    // carried on, so `((-1)^0.5)+90` quietly collapsed to 90 — an invalid
    // expression producing a plausible temperature. An evaluation that cannot
    // continue has to say so.
    if (value.isNaN || value.isInfinite) {
      throw const FormulaException('運算結果不是有效數值', '');
    }
    final magnitude = value.abs();
    final rendered = magnitude == magnitude.roundToDouble() && magnitude < 1e15
        ? magnitude.toStringAsFixed(1)
        : magnitude.toStringAsFixed(10);
    return value < 0 ? '$_negative$rendered' : rendered;
  }

  /// The PIDs an equation references through `VAL{...}`.
  ///
  /// Exposed so the editor can tell "this formula is malformed" apart from
  /// "this formula depends on a PID that has not been polled yet" — the second
  /// is not an authoring error and must not block saving.
  static Iterable<String> valReferences(String equation) =>
      _valPattern.allMatches(equation.toUpperCase()).map((m) => m.group(1)!);

  /// A stand-in PID used when validating or previewing a formula with no live
  /// data.
  ///
  /// Seeding and resolving both go through it, so an authoring preview can
  /// resolve `VAL{}` without giving the runtime any way to resolve a reference
  /// whose controller is unknown — the two paths share no state.
  static Pid probePid(String modeAndPid) => Pid(
        name: 'probe',
        shortName: 'probe',
        modeAndPid: modeAndPid,
        equation: 'A',
        minValue: 0,
        maxValue: 1,
        units: '',
      );

  /// Seeds stand-in values for every external reference in [equation].
  ///
  /// Authoring is about whether a formula is well-formed. Applying the runtime
  /// rule — refuse until the dependency has actually been measured — would
  /// make every `VAL{}` and `BARO` formula permanently unsaveable, including
  /// the ones the help text recommends.
  void seedForAuthoring(String equation, {double sample = 1}) {
    final at = DateTime.now();
    for (final dependency in valReferences(equation)) {
      cachePidValue(probePid(dependency), sample, at);
    }
    if (equation.toUpperCase().contains('BARO')) {
      setBaroPressure(probePid('0000'), 101.3, at);
    }
  }

  /// Validates [equation] without live data by evaluating it against a probe
  /// payload. Returns null when the formula is sound, else the error message.
  static String? validate(String equation, {List<int>? sampleBytes}) {
    try {
      final engine = FormulaEngine()..seedForAuthoring(equation);
      engine.evaluateBytes(
        equation,
        sampleBytes ?? List<int>.filled(14, 1),
        requester: probePid('0000'),
      );
      return null;
    } on FormulaException catch (e) {
      return e.message;
    } catch (e) {
      return e.toString();
    }
  }
}

/// Internal signal for an arithmetic domain error, converted to a
/// [FormulaException] at the public boundary.
class _ArithmeticFailure implements Exception {
  final String message;
  const _ArithmeticFailure(this.message);
}

class _Operator {
  final String symbol;
  final double Function(double, double) apply;

  _Operator(this.symbol, this.apply);
}
