/// PID definition model — mirrors Torque's PID CSV schema.
///
/// A [Pid] is a pure value object: the hex request to send, the infix formula
/// used to turn the ECU's answer into a number, and the presentation metadata
/// (range, units) a gauge needs to draw it.
library;

import '../addressing.dart';

import 'priority_tier.dart';

/// Default CAN transmit header for the engine ECU (ECM/PCM).
const String kDefaultHeader = '7E0';

class Pid {
  /// Full descriptive title, shown in lists and dialogs.
  final String name;

  /// Abbreviated title, shown on gauge faces where space is tight.
  final String shortName;

  /// Hex mode + PID identifier, e.g. `0105` (Mode 01) or `221101` (Mode 22).
  final String modeAndPid;

  /// Infix formula evaluated against the response bytes, e.g. `((A*256)+B)/4`.
  final String equation;

  /// Gauge scale bounds.
  final double minValue;
  final double maxValue;

  /// Units label appended to displayed values.
  final String units;

  /// Custom transmit header (`AT SH`) for non-engine controllers.
  final String header;

  /// Polling priority — drives the scheduler's queue ordering.
  final PriorityTier priority;

  /// Value beyond which the gauge paints its redline zone. Null = no redline.
  final double? redlineFrom;

  /// True for PIDs the user authored rather than ones shipped with the app.
  final bool isCustom;

  /// Provenance and runtime constraints for catalog-generated signals.
  final String? ownerProfileId;
  final String? sourceSignalId;
  final String? sourceRevision;
  final String? expectedResponseId;
  final int? dataOffsetBytes;
  final int? dataLengthBytes;
  final int? responseDataLengthBytes;

  const Pid({
    required this.name,
    required this.shortName,
    required this.modeAndPid,
    required this.equation,
    required this.minValue,
    required this.maxValue,
    required this.units,
    this.header = kDefaultHeader,
    this.priority = PriorityTier.medium,
    this.redlineFrom,
    this.isCustom = false,
    this.variant,
    this.ownerProfileId,
    this.sourceSignalId,
    this.sourceRevision,
    this.expectedResponseId,
    this.dataOffsetBytes,
    this.dataLengthBytes,
    this.responseDataLengthBytes,
  });

  /// Distinguishes two definitions of the same signal that are not the same
  /// entry — e.g. a derived variant, or a user's own take on a built-in.
  final String? variant;

  /// Stable identity.
  ///
  /// Custom definitions are namespaced away from the built-ins even when they
  /// target the same hex on the same ECU. Without that, importing a stock
  /// Torque CSV — which contains `010C`, `010D`, `0105` — would give the
  /// imported rows the same ids as the shipped PIDs, and the "last one wins"
  /// lookup in the registry would quietly swap the user's formula in under the
  /// built-in's name, including for the physics inputs.
  String get id {
    final profile = ownerProfileId;
    final signal = sourceSignalId;
    if (profile != null &&
        profile.isNotEmpty &&
        signal != null &&
        signal.isNotEmpty) {
      return 'profile:${profile.length}:$profile:${signal.length}:$signal';
    }
    final suffix = variant == null ? '' : '#$variant';
    return isCustom
        ? 'custom:$header:$modeAndPid$suffix'
        : '$header:$modeAndPid$suffix';
  }

  /// The form in which a stored id is compared.
  ///
  /// [id] is built from `header` and `modeAndPid`, so canonicalising those on
  /// load changes it — and `active_pid_ids_v1` holds the *old* spelling. A
  /// gauge the user had on their dashboard then failed to resolve and simply
  /// vanished, silently, because the other stored ids still resolved and the
  /// "nothing resolved" fallback never fired.
  ///
  /// Comparing canonically rather than rewriting storage: it needs no write on
  /// load, it is idempotent, and it cannot half-complete. Only spaces are
  /// removed — case was already folded by every build that wrote these — so a
  /// `variant` the user chose cannot collide with a differently-cased one.
  static String canonicalId(String storedId) {
    // Only the structured half. Everything before `#` is a header and a
    // mode+PID, whose spelling this app owns and canonicalises; the variant
    // after it is an opaque label the CSV importer takes verbatim from the
    // user.
    //
    // Stripping spaces from the whole string collapsed `#raw value` and
    // `#rawvalue` onto one key. Two definitions of `0105` with different
    // equations then resolved to whichever the registry map kept last, so both
    // gauges painted the same number and one of them was wrong — with nothing
    // on screen to say which.
    final hash = storedId.indexOf('#');
    if (hash < 0) return storedId.replaceAll(' ', '');
    return storedId.substring(0, hash).replaceAll(' ', '') +
        storedId.substring(hash);
  }

  /// Mode byte as an int, e.g. `0x01` for `010C`. Null if unparseable.
  int? get mode => modeAndPid.length >= 2
      ? int.tryParse(modeAndPid.substring(0, 2), radix: 16)
      : null;

  bool get isMode01 => modeAndPid.toUpperCase().startsWith('01');

  /// The PID byte on its own, e.g. `0x0C` for `010C`.
  int? get pidByte => modeAndPid.length >= 4
      ? int.tryParse(modeAndPid.substring(2, 4), radix: 16)
      : null;

  /// The width the app is entitled to enforce, or null when it does not know.
  ///
  /// A shipped definition's formula was written from J1979, so its width is
  /// knowledge. A user's formula is a statement about which bytes they care
  /// about, which is a different thing — and treating it as a schema is how a
  /// custom `010C` defined as `A` came to reject the perfectly valid
  /// `41 0C 1A F8`.
  /// A width was once overridable through an `explicitDataBytes` field. It
  /// was set by no definition, exposed by no editor, and silently dropped by
  /// `copyWith`, `toJson` and `toCsvRow` alike — so a value assigned to it
  /// would have survived exactly until the first edit, changing how replies
  /// were parsed when it vanished. A field that is never set and cannot
  /// persist is worse than no field, because it reads as a supported feature.
  /// If declaring a width is wanted, it wants an editor, persistence and a
  /// test, not a constructor parameter.
  int? get declaredDataBytes => isCustom ? null : inferredDataBytes;

  /// How many data bytes to consume when splitting a batched reply.
  ///
  /// A batched reply (`010C0D05` → `41 0C 1A F0 0D 3C 05 78`) carries no
  /// length field, so the only way to split it back into per-PID slices is to
  /// know how wide each one is. The declared width where there is one, and
  /// otherwise the highest `A`..`N` the formula references — which is a guess,
  /// and is why a PID without a declared width never joins a batch.
  int get dataByteCount {
    final declared = declaredDataBytes;
    if (declared != null) return declared;
    return inferredDataBytes;
  }

  /// The width implied by the formula. A hint, not a schema.
  int get inferredDataBytes {
    var highest = 0;
    // Skip letters that belong to a function name or a VAL{} reference rather
    // than being byte variables in their own right.
    final stripped = equation
        .toUpperCase()
        .replaceAll(RegExp(r'VAL\{[^}]*\}'), '')
        .replaceAll('ABS', '')
        .replaceAll('LOG10', '')
        .replaceAll('SIGNED', 'SIGNED'); // SIGNED(A) keeps its A on purpose

    for (final match in RegExp(r'\b([A-N])\b').allMatches(stripped)) {
      final index = match.group(1)!.codeUnitAt(0) - 0x41;
      if (index + 1 > highest) highest = index + 1;
    }
    return highest == 0 ? 1 : highest;
  }

  /// The span a gauge sweeps across. Guaranteed non-zero so callers can divide.
  double get span =>
      (maxValue - minValue).abs() < 1e-9 ? 1.0 : maxValue - minValue;

  /// Clamps [value] into the gauge's declared range.
  double clamp(double value) =>
      value.isNaN ? minValue : value.clamp(minValue, maxValue).toDouble();

  /// Normalises [value] to 0..1 across the gauge's range.
  double normalise(double value) =>
      ((clamp(value) - minValue) / span).clamp(0.0, 1.0);

  bool get hasRedline => redlineFrom != null && redlineFrom! < maxValue;

  Pid copyWith({
    String? name,
    String? shortName,
    String? modeAndPid,
    String? equation,
    double? minValue,
    double? maxValue,
    String? units,
    String? header,
    PriorityTier? priority,
    double? redlineFrom,
    bool clearRedline = false,
    bool? isCustom,
    String? variant,
    String? ownerProfileId,
    String? sourceSignalId,
    String? sourceRevision,
    String? expectedResponseId,
    int? dataOffsetBytes,
    int? dataLengthBytes,
    int? responseDataLengthBytes,
  }) {
    return Pid(
      name: name ?? this.name,
      shortName: shortName ?? this.shortName,
      modeAndPid: modeAndPid ?? this.modeAndPid,
      equation: equation ?? this.equation,
      minValue: minValue ?? this.minValue,
      maxValue: maxValue ?? this.maxValue,
      units: units ?? this.units,
      header: header ?? this.header,
      priority: priority ?? this.priority,
      redlineFrom: clearRedline ? null : (redlineFrom ?? this.redlineFrom),
      isCustom: isCustom ?? this.isCustom,
      variant: variant ?? this.variant,
      ownerProfileId: ownerProfileId ?? this.ownerProfileId,
      sourceSignalId: sourceSignalId ?? this.sourceSignalId,
      sourceRevision: sourceRevision ?? this.sourceRevision,
      expectedResponseId: expectedResponseId ?? this.expectedResponseId,
      dataOffsetBytes: dataOffsetBytes ?? this.dataOffsetBytes,
      dataLengthBytes: dataLengthBytes ?? this.dataLengthBytes,
      responseDataLengthBytes:
          responseDataLengthBytes ?? this.responseDataLengthBytes,
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    'shortName': shortName,
    'modeAndPid': modeAndPid,
    'equation': equation,
    'minValue': minValue,
    'maxValue': maxValue,
    'units': units,
    'header': header,
    'priority': priority.name,
    'redlineFrom': redlineFrom,
    'isCustom': isCustom,
    'variant': variant,
    'ownerProfileId': ownerProfileId,
    'sourceSignalId': sourceSignalId,
    'sourceRevision': sourceRevision,
    'expectedResponseId': expectedResponseId,
    'dataOffsetBytes': dataOffsetBytes,
    'dataLengthBytes': dataLengthBytes,
    'responseDataLengthBytes': responseDataLengthBytes,
  };

  factory Pid.fromJson(Map<String, dynamic> json) => Pid(
    name: json['name'] as String? ?? 'Unnamed',
    shortName: json['shortName'] as String? ?? '',
    // Through the same canonicaliser the request builder uses, not merely
    // upper-cased. A stored `01 0C` reaches `pidByte` as `substring(2, 4)`
    // — the string `' 0'` — which parses to null, so the response splitter
    // cannot associate a perfectly valid `41 0C 1A F8` with the gauge and
    // the reading simply never appears. The header half of this was fixed
    // and its sibling was left as it was.
    modeAndPid: PollableServices.normalise(json['modeAndPid'] as String? ?? ''),
    equation: json['equation'] as String? ?? 'A',
    minValue: (json['minValue'] as num?)?.toDouble() ?? 0,
    maxValue: (json['maxValue'] as num?)?.toDouble() ?? 100,
    units: json['units'] as String? ?? '',
    // Normalised on the way *in*, not merely upper-cased. A definition
    // stored by an older build can hold `7 E 0`, and reading it back
    // unchanged reproduces the defect the editor was fixed for — one
    // launch later, where nobody is looking for it.
    header: BusAddressing.resolveHeader(
      json['header'] as String? ?? kDefaultHeader,
    ),
    priority: PriorityTier.fromName(json['priority'] as String?),
    redlineFrom: (json['redlineFrom'] as num?)?.toDouble(),
    isCustom: json['isCustom'] as bool? ?? false,
    variant: json['variant'] as String?,
    ownerProfileId: json['ownerProfileId'] as String?,
    sourceSignalId: json['sourceSignalId'] as String?,
    sourceRevision: json['sourceRevision'] as String?,
    expectedResponseId: _optionalHeader(json['expectedResponseId']),
    dataOffsetBytes: (json['dataOffsetBytes'] as num?)?.toInt(),
    dataLengthBytes: (json['dataLengthBytes'] as num?)?.toInt(),
    responseDataLengthBytes: (json['responseDataLengthBytes'] as num?)?.toInt(),
  );

  static String? _optionalHeader(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    return value.trim().toUpperCase().replaceAll(' ', '');
  }

  /// Torque's on-disk CSV row order, plus this app's own columns.
  ///
  /// The first eight are the schema Torque itself writes, so a file exported
  /// here still opens there. Priority, redline and variant follow as extra
  /// columns — importers that only know the original schema ignore them, and
  /// ours reads them back, so an export/import round trip is lossless instead
  /// of silently resetting every custom gauge to defaults.
  List<String> toCsvRow() => [
    name,
    shortName,
    modeAndPid,
    equation,
    minValue.toString(),
    maxValue.toString(),
    units,
    header,
    priority.name,
    redlineFrom?.toString() ?? '',
    variant ?? '',
  ];

  @override
  bool operator ==(Object other) => other is Pid && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Pid($shortName, $modeAndPid, "$equation")';
}

/// Which diagnostic services this app is willing to transmit, repeatedly, on a
/// vehicle's bus.
///
/// Custom PIDs are free-form hex, so without a rule the scheduler will send
/// whatever a CSV or the editor contains, over and over, for as long as the
/// gauge is on the dashboard. That reaches past reading:
///
///   * `2F` InputOutputControlByIdentifier — actuates outputs;
///   * `2E` WriteDataByIdentifier — writes ECU configuration;
///   * `31` RoutineControl — starts routines;
///   * `11` ECUReset, `27` SecurityAccess, `28` CommunicationControl.
///
/// An app presented as a telemetry reader that can drive an actuator is a
/// vehicle-safety boundary, not an input-validation nit — which is why this is
/// an allowlist. A service absent from it is refused even if it would work.
abstract final class PollableServices {
  /// The read-only services a gauge may poll.
  ///
  /// `01` current data, `02` freeze frame, `09` vehicle information, `22`
  /// ReadDataByIdentifier. All four answer with data and change nothing.
  static const Set<String> allowed = {'01', '02', '09', '22'};

  /// The service byte of a request, or null if it is not well formed.
  /// The one spelling of a mode+PID identifier the whole app agrees on.
  ///
  /// Both callers of the shared validator normalised, and normalised
  /// *differently* — the editor trimmed and upper-cased, the importer
  /// upper-cased and stripped spaces — and then each stored its own version.
  /// Validation passed either way, because it normalises again internally, so
  /// the divergence only showed up downstream: `pidByte` reads
  /// `substring(2, 4)`, which for a stored `01 0C` is `' 0'` and parses to
  /// null. Type `01 0C` into the editor and the gauge never reads anything,
  /// with nothing on screen to say why, while the identical text imported from
  /// a spreadsheet works.
  static String normalise(String modeAndPid) =>
      modeAndPid.trim().toUpperCase().replaceAll(' ', '');

  static String? serviceOf(String modeAndPid) {
    final value = normalise(modeAndPid);
    if (value.length < 4 || value.length.isOdd) return null;
    if (!RegExp(r'^[0-9A-F]+$').hasMatch(value)) return null;
    return value.substring(0, 2);
  }

  /// How many bytes a well-formed request carries after the service byte.
  ///
  /// The allowlist used to check only the service, so `0205` was accepted as a
  /// freeze-frame request. SAE J1979 defines Mode 02 as service, PID **and**
  /// frame number: a conforming ECU expects `02 05 00` and may answer nothing
  /// at all. Worse is the permissive clone that answers `42 05 00 7B` anyway —
  /// the reply matched the two bytes the user supplied, `A` bound to the frame
  /// index `00`, and `A-40` displayed -40 °C where the real reading was 83 °C.
  ///
  /// Every service gets an explicit envelope. A new one may not be added to
  /// [allowed] without deciding its shape here.
  static const Map<String, int> _identifierBytes = {
    '01': 1, // PID
    '02': 2, // PID + freeze-frame number
    '09': 1, // info type
    '22': 2, // two-byte data identifier
  };

  /// The bytes a positive reply must echo back before its data begins.
  static int? identifierLength(String modeAndPid) {
    final service = serviceOf(modeAndPid);
    if (service == null) return null;
    return _identifierBytes[service];
  }

  static bool isPollable(String modeAndPid) {
    final service = serviceOf(modeAndPid);
    if (service == null || !allowed.contains(service)) return false;
    final expected = _identifierBytes[service];
    if (expected == null) return false;
    final value = modeAndPid.trim().toUpperCase().replaceAll(' ', '');
    return value.length == 2 + expected * 2;
  }

  /// Why a request was refused, for showing the author.
  static String? rejectionReason(String modeAndPid) {
    final service = serviceOf(modeAndPid);
    if (service == null) {
      return '不是有效的模式+PID（只接受十六進位字元，且位元組須成對）。';
    }
    if (!allowed.contains(service)) {
      return '服務 $service 不是唯讀查詢，不能週期性發送到車上。'
          '只允許 ${allowed.join('、')}（現值、凍結幀、車輛資訊、ReadDataByIdentifier）。';
    }
    final expected = _identifierBytes[service]!;
    final value = normalise(modeAndPid);
    if (value.length != 2 + expected * 2) {
      return switch (service) {
        '02' => '凍結幀查詢需要 PID 與幀編號兩個位元組，例如 020500（PID 05、第 0 幀）。',
        '22' => 'ReadDataByIdentifier 需要兩個位元組的識別碼，例如 221101。',
        _ => '服務 $service 的查詢需要 $expected 個位元組的識別碼。',
      };
    }
    return null;
  }
}

/// One place that decides whether a PID definition is admissible.
///
/// The CSV importer refused a malformed range or header and the editor did
/// not — it silently substituted `0`/`100` for unparseable bounds and accepted
/// any header text, so the same definition was rejected on import and accepted
/// when typed. A needle then read as authoritative against a scale nobody
/// chose, or the runtime marked the PID unsupported for a header that could
/// never exist on any bus.
abstract final class PidDefinition {
  /// 11-bit CAN is 3 hex digits, the legacy families 6, 29-bit CAN 8.
  static final RegExp _header = RegExp(
    r'^([0-9A-F]{3}|[0-9A-F]{6}|[0-9A-F]{8})$',
  );

  /// Why this definition cannot be saved, or null when it can.
  /// [requireBounds] distinguishes the two callers. The CSV importer treats
  /// empty bounds as "use the default", because a spreadsheet column can
  /// legitimately be blank. The editor cannot: a gauge without a scale has
  /// nothing to draw against, and the field is right there.
  static String? rejectionReason({
    required String name,
    required String modeAndPid,
    required String header,
    required String minText,
    required String maxText,
    String? redlineText,
    bool requireBounds = false,
  }) {
    if (name.trim().isEmpty) return '請輸入名稱。';

    final service = PollableServices.rejectionReason(modeAndPid);
    if (service != null) return service;

    final headerValue = header.trim().toUpperCase().replaceAll(' ', '');
    if (headerValue.isNotEmpty && !_header.hasMatch(headerValue)) {
      return '「$header」不是有效的標頭'
          '（11-bit CAN 為 3 碼、舊協定為 6 碼、29-bit CAN 為 8 碼）。';
    }

    final min = double.tryParse(minText.trim());
    final max = double.tryParse(maxText.trim());
    if (requireBounds && (minText.trim().isEmpty || maxText.trim().isEmpty)) {
      return '請填寫量程的上下限。';
    }
    if (minText.trim().isNotEmpty && min == null) {
      return '量程下限「$minText」不是有效的數值。';
    }
    if (maxText.trim().isNotEmpty && max == null) {
      return '量程上限「$maxText」不是有效的數值。';
    }
    // `double.tryParse` accepts `NaN` and `Infinity`, and every comparison
    // against NaN is false — so `max <= min` waved them straight through. What
    // reaches the screen is not a broken gauge but a confident one: the dial's
    // `((value - min) / (max - min)).clamp(0, 1)` evaluates to **1.0** for NaN
    // in Dart, so the needle sits at full scale and the arc lights completely,
    // for a vehicle at idle.
    //
    // The second consequence is worse for being invisible. `jsonEncode`
    // throws `JsonUnsupportedObjectError` on a non-finite double, so saving
    // wedges *and leaves the definition in memory* — after which every later
    // save of any custom PID throws too, until that one entry is removed.
    //
    // A spreadsheet exports `NaN` on its own; nobody has to be malicious.
    if (min != null && !min.isFinite) {
      return '量程下限必須是有限的數值。';
    }
    if (max != null && !max.isFinite) {
      return '量程上限必須是有限的數值。';
    }
    if (redlineText != null && redlineText.trim().isNotEmpty) {
      final redline = double.tryParse(redlineText.trim());
      if (redline == null) return '紅線起點「$redlineText」不是有效的數值。';
      if (!redline.isFinite) return '紅線起點必須是有限的數值。';
    }
    if (min != null && max != null && max <= min) {
      return '量程上限必須大於下限。';
    }
    return null;
  }
}
