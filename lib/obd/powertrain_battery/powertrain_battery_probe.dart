/// One-shot, fail-closed reads for experimental powertrain battery mappings.
library;

import 'dart:async';
import 'dart:developer' as developer;

import '../elm327_client.dart';
import '../pid/formula_engine.dart';
import '../transport/obd_transport.dart';
import 'powertrain_battery_catalog.dart';
import 'powertrain_battery_profile.dart';
import 'profile_catalog_validator.dart';
import 'profile_wire_contract.dart';

typedef PowertrainBatteryProbeDiagnosticSink = void Function(
  Object exception,
  StackTrace stackTrace,
  String context,
);

enum PowertrainBatteryProbeFailure {
  invalidCatalog,
  ineligibleProfile,
  commandNotInProfile,
  unsupportedBus,
  transport,
  anonymousResponse,
  responderMismatch,
  ambiguousResponse,
  envelopeMismatch,
  payloadLengthMismatch,
  formula,
  valueOutOfRange,
  decoder,
  internal,
}

extension PowertrainBatteryProbeFailurePolicy on PowertrainBatteryProbeFailure {
  /// Failures that make the profile unsafe to try again on this connection.
  bool get requiresConnectionQuarantine => switch (this) {
    PowertrainBatteryProbeFailure.anonymousResponse ||
    PowertrainBatteryProbeFailure.responderMismatch ||
    PowertrainBatteryProbeFailure.ambiguousResponse ||
    PowertrainBatteryProbeFailure.envelopeMismatch ||
    PowertrainBatteryProbeFailure.payloadLengthMismatch ||
    PowertrainBatteryProbeFailure.formula ||
    PowertrainBatteryProbeFailure.valueOutOfRange ||
    PowertrainBatteryProbeFailure.decoder ||
    PowertrainBatteryProbeFailure.internal => true,
    _ => false,
  };
}

final class PowertrainBatteryProbeSignalReading {
  PowertrainBatteryProbeSignalReading({
    required this.signal,
    required this.value,
    required List<int> rawBytes,
  }) : rawBytes = List.unmodifiable(rawBytes);

  final PowertrainBatterySignal signal;
  final double value;
  final List<int> rawBytes;
}

final class PowertrainBatteryProbeResult {
  PowertrainBatteryProbeResult.success({
    required this.profileId,
    required this.catalogSha256,
    required this.sourceRevision,
    required this.command,
    required this.responder,
    required List<int> rawResponseBytes,
    required List<int> payloadBytes,
    required List<PowertrainBatteryProbeSignalReading> readings,
    required this.capturedAt,
  }) : rawResponseBytes = List.unmodifiable(rawResponseBytes),
       payloadBytes = List.unmodifiable(payloadBytes),
       readings = List.unmodifiable(readings),
       failure = null,
       detail = '';

  PowertrainBatteryProbeResult.failure({
    required this.profileId,
    required this.catalogSha256,
    required this.sourceRevision,
    required this.command,
    required this.failure,
    required this.detail,
    required this.capturedAt,
    this.responder,
    List<int> rawResponseBytes = const [],
  }) : rawResponseBytes = List.unmodifiable(rawResponseBytes),
       payloadBytes = const [],
       readings = const [];

  final String profileId;
  final String catalogSha256;
  final String sourceRevision;
  final PowertrainBatteryCommand? command;
  final String? responder;
  final List<int> rawResponseBytes;
  final List<int> payloadBytes;
  final List<PowertrainBatteryProbeSignalReading> readings;
  final DateTime capturedAt;
  final PowertrainBatteryProbeFailure? failure;
  final String detail;

  bool get passed => failure == null;
}

abstract final class PowertrainBatteryProbe {
  /// Sends exactly one catalog command and never installs or schedules it.
  static Future<PowertrainBatteryProbeResult> run({
    required Elm327Client client,
    required PowertrainBatteryCatalogSnapshot snapshot,
    required String profileId,
    required String commandKey,
    Object? lifecycleOwner,
    DateTime? deadline,
    PowertrainBatteryProbeDiagnosticSink? diagnosticSink,
  }) async {
    final now = DateTime.now().toUtc();
    final catalogSha256 = snapshot.catalogSha256;
    final profile = snapshot.catalog.profiles
        .where((candidate) => candidate.id == profileId)
        .firstOrNull;
    final command = profile?.commands
        .where((candidate) => candidate.wireKey == commandKey)
        .firstOrNull;
    PowertrainBatteryProbeResult refused(
      PowertrainBatteryProbeFailure failure,
      String detail,
    ) => PowertrainBatteryProbeResult.failure(
      profileId: profile?.id ?? profileId,
      catalogSha256: catalogSha256,
      sourceRevision: profile?.source.revision ?? '',
      command: command,
      failure: failure,
      detail: detail,
      capturedAt: now,
    );

    if (!isPowertrainCatalogSha256(catalogSha256)) {
      return refused(
        PowertrainBatteryProbeFailure.invalidCatalog,
        'catalog SHA-256 is not canonical',
      );
    }
    if (profile == null || command == null) {
      return refused(
        PowertrainBatteryProbeFailure.commandNotInProfile,
        'profile/command is not present in the hash-checked catalog snapshot',
      );
    }
    final validation = const PowertrainBatteryProfileCatalogValidator()
        .validateProfile(profile);
    if (!validation.canProbe) {
      return refused(
        PowertrainBatteryProbeFailure.ineligibleProfile,
        validation.issues.isEmpty
            ? 'profile is not experimental-read-only'
            : validation.issues.join('; '),
      );
    }
    if (!client.addressing.isCan || !client.addressing.supportsObd2) {
      return refused(
        PowertrainBatteryProbeFailure.unsupportedBus,
        'experimental profile headers require a resolved OBD CAN bus',
      );
    }
    final addressing = client.addressing;
    if (!addressing.acceptsHeader(command.requestHeader) ||
        !addressing.acceptedReceiveWidths.contains(
          command.expectedResponder.length,
        )) {
      return refused(
        PowertrainBatteryProbeFailure.unsupportedBus,
        'profile request/responder identifiers do not match the resolved CAN bus width',
      );
    }

    client.transcript.recordNote(
      '實驗唯讀單次查詢：profile=${profile.id} '
      'catalog=$catalogSha256 source=${profile.source.revision} '
      'tx=${command.requestHeader} rx=${command.expectedResponder} '
      'request=${command.modeAndIdentifier}',
    );
    final ObdResponse response;
    PowertrainBatteryProbeResult transportFailed(String detail) =>
        PowertrainBatteryProbeResult.failure(
          profileId: profile.id,
          catalogSha256: catalogSha256,
          sourceRevision: profile.source.revision,
          command: command,
          failure: PowertrainBatteryProbeFailure.transport,
          detail: detail,
          capturedAt: DateTime.now().toUtc(),
        );
    try {
      response = await client.sendGlobal(
        command.modeAndIdentifier,
        header: command.requestHeader,
        timeout: client.commandTimeout,
        owner: lifecycleOwner,
        deadline: deadline,
      );
    } on TimeoutException {
      return transportFailed('experimental probe timed out');
    } on TransportException {
      return transportFailed('experimental probe transport failed');
    } on Object catch (error, stackTrace) {
      _reportDiagnostic(diagnosticSink, error, stackTrace, 'sendGlobal');
      return PowertrainBatteryProbeResult.failure(
        profileId: profile.id,
        catalogSha256: catalogSha256,
        sourceRevision: profile.source.revision,
        command: command,
        failure: PowertrainBatteryProbeFailure.internal,
        detail: 'wire invariant failed; this profile is quarantined',
        capturedAt: DateTime.now().toUtc(),
      );
    }
    // Keep decoding outside the transport exception boundary. A programming
    // defect in the decoder must never be presented as a retryable link fault.
    return decode(
      profile: profile,
      command: command,
      catalogSha256: catalogSha256,
      response: response,
      capturedAt: DateTime.now().toUtc(),
      diagnosticSink: diagnosticSink,
    );
  }

  /// Validates attribution, envelope, exact payload length, formula and range.
  static PowertrainBatteryProbeResult decode({
    required PowertrainBatteryProfile profile,
    required PowertrainBatteryCommand command,
    required String catalogSha256,
    required ObdResponse response,
    DateTime? capturedAt,
    PowertrainBatteryProbeDiagnosticSink? diagnosticSink,
  }) {
    final at = (capturedAt ?? DateTime.now()).toUtc();
    try {
      return _decodeValidated(
        profile: profile,
        command: command,
        catalogSha256: catalogSha256,
        response: response,
        capturedAt: at,
      );
    } on Object catch (error, stackTrace) {
      _reportDiagnostic(diagnosticSink, error, stackTrace, 'decode');
      // Formula failures have their own typed result inside the validated
      // decoder. Anything else is a programming/invariant failure: disclose
      // neither exception text nor a suggestion to retry, and quarantine the
      // profile through [requiresConnectionQuarantine].
      return PowertrainBatteryProbeResult.failure(
        profileId: profile.id,
        catalogSha256: catalogSha256,
        sourceRevision: profile.source.revision,
        command: command,
        failure: PowertrainBatteryProbeFailure.decoder,
        detail: 'decoder invariant failed; this profile is quarantined',
        capturedAt: at,
        rawResponseBytes: response.bytes,
      );
    }
  }

  static void _reportDiagnostic(
    PowertrainBatteryProbeDiagnosticSink? sink,
    Object exception,
    StackTrace stackTrace,
    String context,
  ) {
    try {
      (sink ?? _defaultDiagnosticSink)(exception, stackTrace, context);
    } on Object {
      // Diagnostics must never change the fail-closed result returned to UI.
    }
  }

  static void _defaultDiagnosticSink(
    Object exception,
    StackTrace stackTrace,
    String context,
  ) {
    developer.log(
      'Unexpected powertrain battery probe failure in $context',
      name: 'telltale.powertrain_battery_probe',
      error: exception,
      stackTrace: stackTrace,
    );
  }

  static PowertrainBatteryProbeResult _decodeValidated({
    required PowertrainBatteryProfile profile,
    required PowertrainBatteryCommand command,
    required String catalogSha256,
    required ObdResponse response,
    required DateTime capturedAt,
  }) {
    final at = capturedAt;
    PowertrainBatteryProbeResult failed(
      PowertrainBatteryProbeFailure failure,
      String detail, {
      String? responder,
      List<int> raw = const [],
    }) => PowertrainBatteryProbeResult.failure(
      profileId: profile.id,
      catalogSha256: catalogSha256,
      sourceRevision: profile.source.revision,
      command: command,
      failure: failure,
      detail: detail,
      capturedAt: at,
      responder: responder,
      rawResponseBytes: raw,
    );

    if (!response.isSuccess) {
      return failed(
        PowertrainBatteryProbeFailure.transport,
        'adapter response: ${response.errorCode.name}',
      );
    }
    if (!response.headersEnabled) {
      return failed(
        PowertrainBatteryProbeFailure.anonymousResponse,
        'the adapter did not prove response headers were enabled',
        raw: response.bytes,
      );
    }
    if (response.frames.length != 1) {
      return failed(
        PowertrainBatteryProbeFailure.ambiguousResponse,
        'expected exactly one complete response frame',
        raw: response.bytes,
      );
    }
    final frame = response.frames.single;
    final responder = frame.sourceId?.toUpperCase();
    if (responder != command.expectedResponder.toUpperCase()) {
      return failed(
        PowertrainBatteryProbeFailure.responderMismatch,
        'expected ${command.expectedResponder}, received ${responder ?? 'anonymous'}',
        responder: responder,
        raw: frame.bytes,
      );
    }

    final requestService = int.tryParse(command.mode, radix: 16);
    final identifier = _hexBytes(command.identifier);
    if (requestService == null || identifier == null) {
      return failed(
        PowertrainBatteryProbeFailure.envelopeMismatch,
        'profile service or identifier is not hexadecimal',
        responder: responder,
        raw: frame.bytes,
      );
    }
    final expectedPrefix = [requestService + 0x40, ...identifier];
    final bytes = frame.bytes;
    if (bytes.length < expectedPrefix.length ||
        !_startsWith(bytes, expectedPrefix)) {
      return failed(
        PowertrainBatteryProbeFailure.envelopeMismatch,
        'positive response service/identifier echo does not match the request',
        responder: responder,
        raw: bytes,
      );
    }
    final payload = bytes.sublist(expectedPrefix.length);
    if (payload.length != command.payloadLength) {
      return failed(
        PowertrainBatteryProbeFailure.payloadLengthMismatch,
        'expected ${command.payloadLength} payload bytes, received ${payload.length}',
        responder: responder,
        raw: bytes,
      );
    }

    final formula = FormulaEngine();
    final readings = <PowertrainBatteryProbeSignalReading>[];
    for (final signal in command.signals) {
      final end = signal.offset + signal.width;
      if (signal.offset < 0 || signal.width <= 0 || end > payload.length) {
        return failed(
          PowertrainBatteryProbeFailure.payloadLengthMismatch,
          '${signal.id} byte window is outside the validated payload',
          responder: responder,
          raw: bytes,
        );
      }
      final raw = payload.sublist(signal.offset, end);
      double value;
      try {
        value = formula.evaluateBytes(signal.equation, raw);
      } on FormulaException catch (error) {
        return failed(
          PowertrainBatteryProbeFailure.formula,
          '${signal.id}: $error',
          responder: responder,
          raw: bytes,
        );
      }
      if (!value.isFinite ||
          value < signal.minValue ||
          value > signal.maxValue) {
        return failed(
          PowertrainBatteryProbeFailure.valueOutOfRange,
          '${signal.id} decoded $value outside '
          '${signal.minValue}..${signal.maxValue}',
          responder: responder,
          raw: bytes,
        );
      }
      readings.add(
        PowertrainBatteryProbeSignalReading(
          signal: signal,
          value: value,
          rawBytes: raw,
        ),
      );
    }

    return PowertrainBatteryProbeResult.success(
      profileId: profile.id,
      catalogSha256: catalogSha256,
      sourceRevision: profile.source.revision,
      command: command,
      responder: responder!,
      rawResponseBytes: bytes,
      payloadBytes: payload,
      readings: readings,
      capturedAt: at,
    );
  }

  static List<int>? _hexBytes(String value) {
    if (value.length.isOdd) return null;
    final result = <int>[];
    for (var index = 0; index < value.length; index += 2) {
      final byte = int.tryParse(value.substring(index, index + 2), radix: 16);
      if (byte == null) return null;
      result.add(byte);
    }
    return result;
  }

  static bool _startsWith(List<int> value, List<int> prefix) {
    if (value.length < prefix.length) return false;
    for (var index = 0; index < prefix.length; index++) {
      if (value[index] != prefix[index]) return false;
    }
    return true;
  }
}
