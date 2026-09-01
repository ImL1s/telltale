import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/core/theme/app_colors.dart';
import 'package:torque_obd/core/theme/app_theme.dart';
import 'package:torque_obd/ui/widgets/gauges/dial_gauge.dart';
import 'package:torque_obd/ui/widgets/gauges/linear_gauge.dart';
import 'package:torque_obd/ui/widgets/panel.dart';

Widget _host(
  Widget child, {
  ThemeData? theme,
  Size size = const Size(300, 300),
}) {
  return MaterialApp(
    theme: theme ?? AppTheme.dark(),
    home: Scaffold(
      body: Center(
        child: SizedBox(width: size.width, height: size.height, child: child),
      ),
    ),
  );
}

void main() {
  group('DialGauge', () {
    testWidgets('renders the value, units and label', (tester) async {
      await tester.pumpWidget(
        _host(
          const DialGauge(
            value: 2450,
            minValue: 0,
            maxValue: 8000,
            label: 'RPM',
            units: 'rpm',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('2450'), findsOneWidget);
      expect(find.text('rpm'), findsOneWidget);
      expect(find.text('RPM'), findsOneWidget);
    });

    testWidgets('clamps a value above the maximum without overflowing', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const DialGauge(
            value: 99999,
            minValue: 0,
            maxValue: 100,
            label: 'Load',
            units: '%',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('handles a value below the minimum', (tester) async {
      await tester.pumpWidget(
        _host(
          const DialGauge(
            value: -500,
            minValue: -40,
            maxValue: 215,
            label: 'Coolant',
            units: '°C',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('survives a zero-width range', (tester) async {
      // A custom PID with min == max would divide by zero if the span were not
      // guarded.
      await tester.pumpWidget(
        _host(
          const DialGauge(
            value: 5,
            minValue: 10,
            maxValue: 10,
            label: 'Flat',
            units: '',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders at a small tile size without overflow', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const DialGauge(
            value: 6800,
            minValue: 0,
            maxValue: 8000,
            label: 'Engine RPM',
            units: 'rpm',
            redlineFrom: 6500,
          ),
          size: const Size(140, 140),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows the footnote when one is supplied', (tester) async {
      await tester.pumpWidget(
        _host(
          const DialGauge(
            value: 12,
            minValue: 0,
            maxValue: 100,
            label: 'MAF',
            units: 'g/s',
            footnote: '推算值',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('推算值'), findsOneWidget);
    });

    testWidgets('renders in the light theme too', (tester) async {
      await tester.pumpWidget(
        _host(
          const DialGauge(
            value: 50,
            minValue: 0,
            maxValue: 100,
            label: 'Throttle',
            units: '%',
          ),
          theme: AppTheme.light(),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('50.0'), findsOneWidget);
    });
  });

  group('LinearGauge', () {
    testWidgets('renders label, value and bounds', (tester) async {
      await tester.pumpWidget(
        _host(
          const LinearGauge(
            value: 42,
            minValue: 0,
            maxValue: 100,
            label: 'Load',
            units: '%',
          ),
          size: const Size(300, 100),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Load'), findsOneWidget);
      expect(find.text('42.0'), findsOneWidget);
      expect(find.text('0'), findsOneWidget);
      expect(find.text('100'), findsOneWidget);
    });

    testWidgets('renders a NaN value as dashes rather than crashing', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const LinearGauge(
            value: double.nan,
            minValue: 0,
            maxValue: 100,
            label: 'Broken',
            units: '',
          ),
          size: const Size(300, 100),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('--'), findsOneWidget);
    });
  });

  group('Panel and status widgets', () {
    testWidgets('StatusPill renders its label', (tester) async {
      await tester.pumpWidget(
        _host(
          const StatusPill(label: '60 PIDs/s', tone: StatusTone.accent),
          size: const Size(200, 60),
        ),
      );
      expect(find.text('60 PIDs/s'), findsOneWidget);
    });

    testWidgets('EmptyState renders title, message and action', (tester) async {
      await tester.pumpWidget(
        _host(
          EmptyState(
            icon: Icons.tune,
            title: '儀表板是空的',
            message: '挑幾個 PID 吧。',
            action: FilledButton(onPressed: () {}, child: const Text('選擇 PID')),
          ),
          size: const Size(360, 480),
        ),
      );
      expect(find.text('儀表板是空的'), findsOneWidget);
      expect(find.text('選擇 PID'), findsOneWidget);
    });

    testWidgets('EmptyState scrolls without overflow in 200% landscape', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(832, 384);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: const MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: EmptyState(
                icon: Icons.tune,
                title: '儀表板是空的',
                message: '先停止錄製，再選擇想要顯示的 PID 項目。',
                action: FilledButton(onPressed: null, child: Text('選擇 PID')),
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(
        tester
            .widget<SingleChildScrollView>(find.byType(SingleChildScrollView))
            .primary,
        isFalse,
      );
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -100),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('Panel forwards taps', (tester) async {
      var tapped = false;
      await tester.pumpWidget(
        _host(
          Panel(onTap: () => tapped = true, child: const Text('tap me')),
          size: const Size(300, 120),
        ),
      );
      await tester.tap(find.text('tap me'));
      expect(tapped, isTrue);
    });
  });

  group('theme', () {
    test('both palettes define every token distinctly', () {
      // A copy-paste slip that left a light token holding a dark value would
      // silently wreck contrast; comparing the two catches it.
      expect(AppPalette.dark.background, isNot(AppPalette.light.background));
      expect(AppPalette.dark.textPrimary, isNot(AppPalette.light.textPrimary));
      expect(AppPalette.dark.accent, isNot(AppPalette.light.accent));
    });

    test('gauge hue assignment is stable for a given key', () {
      expect(GaugeHue.forKey('7E0:010C'), GaugeHue.forKey('7E0:010C'));
    });

    test('both themes build without throwing', () {
      expect(AppTheme.dark().brightness, Brightness.dark);
      expect(AppTheme.light().brightness, Brightness.light);
    });
  });

  group('a stale gauge', () {
    testWidgets('says so in words, not only by fading', (tester) async {
      // The fading is carried by the arc and needle now, not by the numbers —
      // dimming those far enough to read as "stale" put the units and label
      // under the contrast floor. Which means the state has to be legible
      // without relying on the fade at all, for anyone who cannot perceive it.
      await tester.pumpWidget(
        _host(
          const DialGauge(
            value: 2450,
            minValue: 0,
            maxValue: 8000,
            label: 'RPM',
            units: 'rpm',
            isStale: true,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('資料已過期'), findsOneWidget);
      expect(
        find.text('2450'),
        findsOneWidget,
        reason: 'and the reading itself stays on screen and readable',
      );
    });

    testWidgets('does not overwrite a footnote the caller supplied', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const DialGauge(
            value: 2450,
            minValue: 0,
            maxValue: 8000,
            label: 'RPM',
            units: 'rpm',
            isStale: true,
            footnote: '推算值',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('推算值'), findsOneWidget);
      expect(find.text('資料已過期'), findsNothing);
    });

    testWidgets('a fresh gauge carries no stale marker', (tester) async {
      await tester.pumpWidget(
        _host(
          const DialGauge(
            value: 2450,
            minValue: 0,
            maxValue: 8000,
            label: 'RPM',
            units: 'rpm',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('資料已過期'), findsNothing);
    });
  });
}
