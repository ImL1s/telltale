/// Live badges follow the shipped [AvailabilityPolicy], not a disclaimer wall.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/core/theme/app_theme.dart';
import 'package:torque_obd/diagnostics/availability.dart';
import 'package:torque_obd/obd/physics/vehicle_profile.dart';
import 'package:torque_obd/obd/pid/pid_library.dart';
import 'package:torque_obd/ui/widgets/status/datum_status_badge.dart';

void main() {
  testWidgets('estimate badge shows 估算 and opens formula details', (
    tester,
  ) async {
    final status = AvailabilityPolicy.forEstimate(
      profile: const VehicleProfile(massKg: 1500),
      value: 145,
      formula: AvailabilityPolicy.horsepowerFormula,
      quantity: '馬力',
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDatumStatusDetails(
                context,
                title: '估算公式與假設',
                status: status,
              ),
              child: DatumStatusBadge(status: status),
            ),
          ),
        ),
      ),
    );

    expect(find.textContaining('估算'), findsOneWidget);
    expect(find.textContaining('實測'), findsNothing);
    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();
    expect(find.text(AvailabilityPolicy.horsepowerFormula), findsOneWidget);
    expect(find.textContaining('車重'), findsOneWidget);
    expect(find.textContaining('迎風面積'), findsOneWidget);
    expect(find.textContaining('傳動效率'), findsOneWidget);
  });

  testWidgets('outlier badge keeps the value labelled 異常', (tester) async {
    const pid = PidLibrary.coolantTemp;
    final status = AvailabilityPolicy.decodedValue(
      structurallyValid: true,
      value: 999,
      min: pid.minValue,
      max: pid.maxValue,
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(body: DatumStatusBadge(status: status)),
      ),
    );
    expect(find.textContaining('異常'), findsOneWidget);
  });
}
