/// What the adapter says about itself, checked against what can exist.
///
/// This file makes exactly one claim and refuses a larger one. It can tell
/// whether an adapter is **lying about its own firmware**. It cannot tell
/// whether the numbers it reports about the car are true, and nothing here
/// should be read as though it could.
///
/// That boundary was drawn from evidence rather than caution. The widely
/// repeated story that counterfeit ELM327s invent plausible sensor values — a
/// constant 95 °C coolant is the usual example — traces back to a single
/// vendor page with no source, no test and no reference behind it. What clones
/// are actually documented to do is *refuse* or *corrupt loudly*: truncate a
/// command to two bytes, freeze on a long reply, answer `NO DATA` before the
/// bus could have answered, or report 215 °C and −64 rpm from a misaligned
/// frame. Those the parser already catches, because they do not look right.
///
/// So the useful question is not "are these readings real" — software cannot
/// answer that without a second independent measurement — but "is this device
/// what it claims to be", which is answerable from replies the handshake
/// already collects. No extra command is sent for this.
///
/// And even that question only has a *negative* answer worth having. Car
/// Scanner's own adapter guide puts it plainly: on bulk clones the version
/// number "is simply three or four characters of text. If you really ask, the
/// Chinese will write your birthday there." So a banner that contradicts
/// itself proves something; a banner that does not contradict itself proves
/// nothing at all, and no copy built on this may imply otherwise.
library;

/// How the `ATPPS` probe ended.
///
/// Three states, not two, and the distinction is the whole reason this enum
/// exists. `ProgrammableParameters.wasRead` is `false` for an explicit `?`, a
/// timeout, a garbled reply and a thrown exception alike, because
/// `_readProgrammableParameters` swallows everything. Keying a clone
/// accusation on it would manufacture one out of a dropped Bluetooth packet —
/// on the screen where being wrong costs the most trust.
///
/// Only [refused] is evidence about the device. [unavailable] is evidence
/// about the moment.
enum PpsProbe {
  /// Parsed. The adapter implements the command.
  read,

  /// The adapter answered `?`: it does not know the command.
  refused,

  /// Timed out, was unreadable, or threw. Says nothing either way.
  unavailable,
}

/// A single doubt about the adapter's self-description.
class AdapterConcern {
  const AdapterConcern(this.summary, this.detail);

  /// One line, for a list.
  final String summary;

  /// What was observed and why it means anything.
  final String detail;
}

/// The adapter's own account of itself, and where it fails to add up.
class AdapterIdentity {
  const AdapterIdentity({
    required this.version,
    required this.identity,
    required this.pps,
  });

  /// The `ATI` banner, verbatim.
  final String version;

  /// The `AT@1` device identifier, verbatim. Empty if it refused.
  final String identity;

  final PpsProbe pps;

  /// Firmware versions Elm Electronics never released.
  ///
  /// From the ELM327 datasheet's own revision history. `v1.5` is the famous
  /// one — it is printed on a large share of the adapters sold — and `v1.4a`
  /// is the same trick one digit over. An adapter reporting one of these is
  /// not necessarily *bad*; a great many of them work. It is only, definitely,
  /// not running the firmware it names.
  static const Set<String> neverReleased = {'1.5', '1.4a'};

  /// The banner's version number, lowercased, or null if it does not carry one.
  String? get versionNumber {
    final match = RegExp(r'ELM327\s+v?([0-9]+\.[0-9]+[a-z]?)', caseSensitive: false)
        .firstMatch(version);
    return match?.group(1)?.toLowerCase();
  }

  /// Comparable form of the version, for "at least v1.1" questions. Null when
  /// the banner does not name a version this can read.
  double? get versionValue {
    final v = versionNumber;
    if (v == null) return null;
    // A trailing letter is a revision of the same release, so `1.4b` sorts as
    // `1.4` here. Nothing below asks a question finer than that.
    return double.tryParse(RegExp(r'^[0-9]+\.[0-9]+').firstMatch(v)?.group(0) ?? '');
  }

  /// Everything that does not add up, in the order worth reading.
  ///
  /// Empty is not a clean bill of health — it means nothing contradicted
  /// itself, which is all that was asked.
  List<AdapterConcern> get concerns {
    final found = <AdapterConcern>[];
    final number = versionNumber;

    if (number != null && neverReleased.contains(number)) {
      found.add(AdapterConcern(
        '回報的韌體版本 v$number 官方從未發行',
        'ELM327 的原廠 Elm Electronics 沒有出過這個版本 —— 這台轉接器上的'
            '韌體不是它自稱的那一份。很多這種轉接器仍然可用，'
            '但它對自己的描述已經不可靠，遇到讀不到的狀況時值得先懷疑它。',
      ));
    }

    final value = versionValue;
    if (pps == PpsProbe.refused && value != null && value >= 1.1) {
      found.add(AdapterConcern(
        '自稱 v$number，卻不認得 v1.1 就有的 ATPPS 指令',
        '可程式參數摘要（ATPPS）從 ELM327 v1.1 起就存在，連 OBDLink 這類'
            '高階轉接器也支援。自稱的版本與實際實作的指令對不起來。',
      ));
    }

    if (identity.isEmpty) {
      found.add(const AdapterConcern(
        '不回應 AT@1（第一版就有的裝置識別指令）',
        '這條指令從 ELM327 v1.0 就存在。不回應代表這顆晶片的指令集比'
            '任何一版官方韌體都少。',
      ));
    }

    return found;
  }

  /// Whether anything contradicted itself.
  bool get isSelfConsistent => concerns.isEmpty;

  /// One line for the export header, always safe to print.
  String get summaryLine {
    final v = version.isEmpty ? '（未回報）' : version;
    final id = identity.isEmpty ? '（未回應 AT@1）' : identity;
    final pp = switch (pps) {
      PpsProbe.read => 'ATPPS 已讀取',
      PpsProbe.refused => 'ATPPS 遭拒（?）',
      PpsProbe.unavailable => 'ATPPS 無回應',
    };
    return '$v · $id · $pp · ${concerns.length} 項自述不一致';
  }
}
