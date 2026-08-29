import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/core/field_evidence/platform_metadata.dart';
import 'package:torque_obd/obd/physics/vehicle_evidence.dart';
import 'package:torque_obd/obd/physics/vehicle_profile.dart';
import 'package:torque_obd/obd/session_evidence.dart';

const _epaEvidence = EvidenceRef(
  sourceId: 'us-epa-fueleconomy-vehicles',
  publisher: 'U.S. EPA / U.S. DOE',
  sourceUrl: 'https://www.fueleconomy.gov/feg/download.shtml',
  revision: '2026-08-07',
  retrievedAt: '2026-08-29T14:28:23+00:00',
  sha256: '6dc8aed9232a88844e18f0160e94eeaa75abc0dcf8a36286e3166797f4933331',
  market: 'United States',
  locator: 'epa_id=12345',
  year: 2024,
  make: 'Example',
  model: 'Roadster',
  trim: '2.0 RWD 6MT',
);

void main() {
  group('field evidence header', () {
    test('renders a deterministic evidence manifest', () {
      const profile = VehicleProfile(
        displacementL: 1.8,
        massKg: 1420,
        volumetricEfficiency: 88,
        fuelType: FuelType.gasoline,
        drivetrain: Drivetrain.fwd,
        isConfirmed: true,
      );
      final evidence = SessionEvidenceMetadata(
        sessionId: '20260821T031405000Z-7',
        startedAt: DateTime.utc(2026, 8, 21, 3, 14, 5),
        platform: const PlatformMetadata(
          applicationId: 'com.cbstudio.telltale',
          appVersion: '1.0.3',
          appBuild: '4',
          platform: 'android',
          osVersion: '16',
          manufacturer: 'Samsung',
          model: 'SM-S9380',
          sdkInt: '36',
        ),
        vehicleProfile: profile,
        transportKind: 'Wi-Fi',
        deviceName: 'OBD-II',
        initialTransportMetadata: const {
          'wifi.port': '35000',
          'wifi.host': '192.168.0.10',
        },
      );

      expect(evidence.testRig, isFalse);
      expect(
        evidence.renderHeader(),
        equals(
          '# Telltale 實車證據 v1\n'
          '# 隱私提醒：內含原始車輛通訊，可能包含 VIN、轉接器與裝置識別資訊；'
          'App 不會主動上傳；系統備份依裝置設定，是否另行分享由你決定。\n'
          '# 工作階段：20260821T031405000Z-7\n'
          '# 開始時間（UTC）：2026-08-21T03:14:05.000Z\n'
          '# App：1.0.3 (4)\n'
          '# 平台：android 16 (SDK 36)\n'
          '# 手機：Samsung SM-S9380\n'
          '# 連線開始車輛設定快照（UTC 2026-08-21T03:14:05.000Z）：'
          '1.8 L · 1420 kg · VE 88% · 汽油 · 前輪驅動\n'
          '# 連線開始車輛設定 JSON：'
          '${SessionEvidenceMetadata.vehicleProfileSnapshotJson(profile)}\n'
          '# 連線開始車輛設定狀態：已確認\n'
          '# 連線開始車輛設定來源：官方／原廠 0/8 · 手動輸入 0/8 · 通用 8/8 · 科學模型 0/8\n'
          '# 連線開始車輛設定解析：官方精確 0/8 · 本次確認 8/8 · 未解析 0/8 · 歧義 0/8 · 衝突 0/8\n'
          '# 連線方式：Wi-Fi\n'
          '# 裝置：OBD-II\n'
          '# 連線資訊.wifi.host：192.168.0.10\n'
          '# 連線資訊.wifi.port：35000\n',
        ),
      );

      final profileJsonLine = evidence
          .renderHeader()
          .split('\n')
          .singleWhere((line) => line.startsWith('# 連線開始車輛設定 JSON：'));
      final profileJson = jsonDecode(
        profileJsonLine.substring('# 連線開始車輛設定 JSON：'.length),
      ) as Map<String, dynamic>;
      expect(profileJson['fields'], isA<Map<String, dynamic>>());
      expect(profileJson['fields'], hasLength(8));
      expect(profileJson['dragCoefficient'], 0.3);
      expect(profileJson['frontalAreaM2'], 2.2);
      expect(profileJson['rollingResistance'], 0.015);
    });

    test('renders exact field provenance without upgrading other fields', () {
      final evidence = SessionEvidenceMetadata(
        sessionId: 'source-1',
        startedAt: DateTime.utc(2026, 8, 29),
        platform: PlatformMetadata.unknown(),
        vehicleProfile: VehicleProfile.sourced(
          displacementL: SourcedField(
            value: 2.0,
            origin: VehicleFieldOrigin.officialRegistry,
            resolution: EvidenceResolution.verifiedExact,
            evidence: _epaEvidence,
          ),
        ),
        transportKind: 'Wi-Fi',
        deviceName: 'OBD-II',
      );

      final header = evidence.renderHeader();
      expect(
        header,
        contains(
          '# 連線開始車輛設定來源：官方／原廠 1/8 · '
          '手動輸入 0/8 · 通用 7/8 · 科學模型 0/8',
        ),
      );
      expect(
        header,
        contains(
          '# 連線開始車輛設定解析：官方精確 1/8 · '
          '本次確認 0/8 · 未解析 7/8 · 歧義 0/8 · 衝突 0/8',
        ),
      );
      expect(
        header,
        contains(
          '# 連線開始車輛設定證據.排氣量：U.S. EPA / U.S. DOE · '
          'us-epa-fueleconomy-vehicles · United States · epa_id=12345 · '
          'sha256=6dc8aed9232a88844e18f0160e94eeaa75abc0dcf8a36286e3166797f4933331',
        ),
      );
      expect(header, isNot(contains('# 連線開始車輛設定證據.車重')));
    });

    test('the .rig application ID is simulated without a Dart define', () {
      final evidence = SessionEvidenceMetadata(
        sessionId: 'rig-1',
        startedAt: DateTime.utc(2026, 8, 23),
        platform: const PlatformMetadata(
          applicationId: 'com.cbstudio.telltale.rig',
          appVersion: '1.0.4-rig',
          appBuild: '5',
          platform: 'android',
          osVersion: '16',
          manufacturer: 'Google',
          model: 'Pixel 9',
          sdkInt: '36',
        ),
        vehicleProfile: const VehicleProfile(),
        transportKind: 'Bluetooth LE',
        deviceName: 'TelltaleELM',
        testRig: false,
      );

      expect(evidence.testRig, isTrue);
      final header = evidence.renderHeader();
      expect(header, startsWith('# Telltale 無車測試馬具證據 v1\n'));
      expect(header, contains('不得視為實體轉接器或實車驗證'));
      expect(header, contains('# 連線開始車輛設定狀態：未確認'));
      expect(header, isNot(contains('# Telltale 實車證據')));
    });

    test('an unexpected Android application ID renders a rig header', () {
      final evidence = SessionEvidenceMetadata(
        sessionId: 'repackaged-1',
        startedAt: DateTime.utc(2026, 8, 23),
        platform: const PlatformMetadata(
          applicationId: 'com.example.repackaged',
          appVersion: '1.0.4',
          appBuild: '5',
          platform: 'android',
          osVersion: '16',
          manufacturer: 'Google',
          model: 'Pixel 9',
          sdkInt: '36',
        ),
        vehicleProfile: const VehicleProfile(),
        transportKind: 'Bluetooth LE',
        deviceName: 'OBD-II',
      );

      expect(evidence.testRig, isTrue);
      expect(evidence.renderHeader(), startsWith('# Telltale 無車測試馬具證據 v1\n'));
      expect(evidence.renderHeader(), isNot(contains('# Telltale 實車證據')));
    });

    test(
      'unknown stays unknown and untrusted values cannot forge header lines',
      () {
        final evidence = SessionEvidenceMetadata(
          sessionId: 'session\n# 偽造：成功',
          startedAt: DateTime.utc(2026),
          platform: PlatformMetadata.unknown(),
          vehicleProfile: const VehicleProfile(),
          transportKind: '',
          deviceName: 'adapter\r\n# 協定：假資料\x00\x1B\u202Ehidden',
          initialTransportMetadata: const {
            'ble.uuid': '',
            'ble.name': 'car\nowner',
          },
        );

        final header = evidence.renderHeader(
          latestTransportMetadata: const {'ble.mtu': 'request\rfailed'},
        );
        expect(header, contains(r'工作階段：session\n# 偽造：成功'));
        expect(header, contains('# App：unknown (unknown)'));
        expect(header, contains('# 連線方式：unknown'));
        expect(
          header,
          contains(r'裝置：adapter\r\n# 協定：假資料\x00\x1B\u{202E}hidden'),
        );
        expect(header, contains('# 連線資訊.ble.uuid：unknown'));
        expect(header, contains(r'# 連線資訊.ble.name：car\nowner'));
        expect(header, contains(r'# 連線資訊.ble.mtu：request\rfailed'));
        expect(header.split('\n'), isNot(contains('# 偽造：成功')));
        expect(header.split('\n'), isNot(contains('# 協定：假資料')));
        expect(header, isNot(contains('\x00')));
        expect(header, isNot(contains('\x1B')));
        expect(header, isNot(contains('\u202E')));
      },
    );

    test(
      'post-connect transport facts replace their frozen pending values once',
      () {
        final evidence = SessionEvidenceMetadata(
          sessionId: 's1',
          startedAt: DateTime.utc(2026),
          platform: PlatformMetadata.unknown(),
          vehicleProfile: const VehicleProfile(),
          transportKind: 'Bluetooth LE',
          deviceName: 'OBDII',
          initialTransportMetadata: const {
            'ble.notify': 'unknown',
            'ble.requestedMtu': '185',
          },
        );

        final completed = evidence.completeTransportMetadata(const {
          'ble.notify': 'ffe1',
          'ble.mtuRequest': 'accepted',
        });
        final ignoredSecondCompletion = completed.completeTransportMetadata(
          const {'ble.notify': 'different'},
        );

        expect(completed.renderHeader(), contains('# 連線資訊.ble.notify：ffe1'));
        expect(
          ignoredSecondCompletion.renderHeader(),
          contains('# 連線資訊.ble.notify：ffe1'),
        );
        expect(
          ignoredSecondCompletion.renderHeader(),
          isNot(contains('different')),
        );
      },
    );

    test(
      'profile-change notes contain a reconstructable provenance snapshot',
      () {
        final profile = VehicleProfile.sourced(
          displacementL: SourcedField(
            value: 2.0,
            origin: VehicleFieldOrigin.officialRegistry,
            resolution: EvidenceResolution.verifiedExact,
            evidence: _epaEvidence,
          ),
        );
        final note = SessionEvidenceMetadata.vehicleProfileChangeNote(
          profile,
          recordedAt: DateTime.utc(2026, 8, 29, 15, 30),
        );
        const marker = 'profile_json=';
        final json = jsonDecode(
          note.substring(note.indexOf(marker) + marker.length),
        ) as Map<String, dynamic>;
        final fields = json['fields'] as Map<String, dynamic>;

        expect(note, contains('recorded_at_utc=2026-08-29T15:30:00.000Z'));
        expect(json['isConfirmed'], isFalse);
        expect(fields, hasLength(8));
        expect(
          (fields['displacementL'] as Map<String, dynamic>)['origin'],
          VehicleFieldOrigin.officialRegistry.name,
        );
        expect(
          (fields['displacementL'] as Map<String, dynamic>)['resolution'],
          EvidenceResolution.verifiedExact.name,
        );
        final evidence =
            (fields['displacementL'] as Map<String, dynamic>)['evidence']
                as Map<String, dynamic>;
        expect(evidence['locator'], 'epa_id=12345');
        expect(evidence['sha256'], _epaEvidence.sha256);
      },
    );
  });
}
