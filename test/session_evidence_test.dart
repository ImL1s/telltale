import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/core/field_evidence/platform_metadata.dart';
import 'package:torque_obd/obd/physics/vehicle_profile.dart';
import 'package:torque_obd/obd/session_evidence.dart';

void main() {
  group('field evidence header', () {
    test('renders a deterministic evidence manifest', () {
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
        vehicleProfile: const VehicleProfile(
          displacementL: 1.8,
          massKg: 1420,
          volumetricEfficiency: 88,
          fuelType: FuelType.gasoline,
          drivetrain: Drivetrain.fwd,
        ),
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
          '# 車輛設定：1.8 L · 1420 kg · VE 88% · 汽油 · 前輪驅動\n'
          '# 連線方式：Wi-Fi\n'
          '# 裝置：OBD-II\n'
          '# 連線資訊.wifi.host：192.168.0.10\n'
          '# 連線資訊.wifi.port：35000\n',
        ),
      );
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
  });
}
