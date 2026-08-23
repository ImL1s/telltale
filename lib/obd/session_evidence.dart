/// Immutable facts that make one physical-vehicle transcript actionable.
///
/// This is diagnostic evidence, not telemetry: the app never uploads it,
/// never asks the vehicle another question for it, and freezes it per
/// connection so an export cannot describe the adapter selected afterwards.
library;

import '../core/field_evidence/evidence_text.dart';
import '../core/field_evidence/platform_metadata.dart';
import 'physics/vehicle_profile.dart';

/// Explicit provenance for builds that talk to the no-car BLE/TCP rigs.
///
/// A rig still crosses a real OS transport, but its ELM327 and ECU are
/// simulated. The dedicated Android application ID is authoritative; the
/// compile-time flag also covers non-Android integration drivers.
const bool isObdTestRigBuild = bool.fromEnvironment('TELLTALE_TEST_RIG');

final class SessionEvidenceMetadata {
  SessionEvidenceMetadata({
    required this.sessionId,
    required this.startedAt,
    required this.platform,
    required this.vehicleProfile,
    required this.transportKind,
    required this.deviceName,
    bool testRig = isObdTestRigBuild,
    Map<String, Object?> initialTransportMetadata = const {},
  }) : testRig = testRig || platform.requiresSimulatedEvidence,
       initialTransportMetadata = Map.unmodifiable(initialTransportMetadata),
       _completedTransportMetadata = null;

  SessionEvidenceMetadata._({
    required this.sessionId,
    required this.startedAt,
    required this.platform,
    required this.vehicleProfile,
    required this.transportKind,
    required this.deviceName,
    required this.testRig,
    required this.initialTransportMetadata,
    required this._completedTransportMetadata,
  });

  final String sessionId;
  final DateTime startedAt;
  final PlatformMetadata platform;
  final VehicleProfile vehicleProfile;
  final String transportKind;
  final String deviceName;
  final bool testRig;
  final Map<String, Object?> initialTransportMetadata;
  final Map<String, Object?>? _completedTransportMetadata;

  bool get transportMetadataCompleted => _completedTransportMetadata != null;

  /// Adds the facts only a completed transport setup can know.
  ///
  /// Write-once is deliberate. A reconnect or late native callback belongs in
  /// the timestamped transcript, not in a header whose facts silently change.
  SessionEvidenceMetadata completeTransportMetadata(
    Map<String, Object?> values,
  ) {
    if (_completedTransportMetadata != null) return this;
    return SessionEvidenceMetadata._(
      sessionId: sessionId,
      startedAt: startedAt,
      platform: platform,
      vehicleProfile: vehicleProfile,
      transportKind: transportKind,
      deviceName: deviceName,
      testRig: testRig,
      initialTransportMetadata: initialTransportMetadata,
      completedTransportMetadata: Map.unmodifiable(values),
    );
  }

  /// Human-readable manifest prepended to the existing raw transcript.
  ///
  /// [latestTransportMetadata] is useful while a setup is still in progress.
  /// A finished session should call [completeTransportMetadata] once and render
  /// without it so later platform callbacks cannot rewrite history.
  String renderHeader({
    Map<String, Object?> latestTransportMetadata = const {},
  }) {
    final profile = vehicleProfile;
    final metadata = <String, Object?>{
      ...initialTransportMetadata,
      ...?_completedTransportMetadata,
      ...latestTransportMetadata,
    };
    final keys = metadata.keys.toList()..sort();
    final buffer = StringBuffer()
      ..writeln(testRig ? '# Telltale 無車測試馬具證據 v1' : '# Telltale 實車證據 v1');
    if (testRig) {
      buffer.writeln('# 證據來源：軟體 ELM327／ECU 測試馬具；不得視為實體轉接器或實車驗證。');
    }
    buffer
      ..writeln(
        '# 隱私提醒：內含原始車輛通訊，可能包含 VIN、轉接器與裝置識別資訊；'
        'App 不會主動上傳；系統備份依裝置設定，是否另行分享由你決定。',
      )
      ..writeln('# 工作階段：${_safe(sessionId)}')
      ..writeln('# 開始時間（UTC）：${startedAt.toUtc().toIso8601String()}')
      ..writeln(
        '# App：${_safe(platform.appVersion)} (${_safe(platform.appBuild)})',
      )
      ..writeln(
        '# 平台：${_safe(platform.platform)} ${_safe(platform.osVersion)} '
        '(SDK ${_safe(platform.sdkInt)})',
      )
      ..writeln('# 手機：${_safe(platform.manufacturer)} ${_safe(platform.model)}')
      ..writeln(
        '# 車輛設定：${_number(profile.displacementL)} L · '
        '${_number(profile.massKg)} kg · '
        'VE ${_number(profile.volumetricEfficiency)}% · '
        '${profile.fuelType.label} · ${profile.drivetrain.label}',
      )
      ..writeln('# 連線方式：${_safe(transportKind)}')
      ..writeln('# 裝置：${_safe(deviceName)}');
    for (final key in keys) {
      buffer.writeln('# 連線資訊.${_safe(key)}：${_safe(metadata[key])}');
    }
    return buffer.toString();
  }

  static String _number(num value) {
    final whole = value.round();
    return value == whole ? '$whole' : '$value';
  }

  /// Keeps an adapter name or endpoint from forging another header line.
  static String _safe(Object? value) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty) return unknownPlatformMetadata;
    return escapeEvidenceText(text);
  }
}
