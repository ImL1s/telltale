/// Five instruments, not five palettes.
///
/// The request these exist for was explicit: skins that are not colour swaps.
/// So the rules worth pinning are the ones that would quietly turn them back
/// into one — a geometry that stops being read from the theme, an animation
/// that ignores a skin asking for none, a picker whose preview drifts from
/// what selecting it produces.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:torque_obd/core/theme/app_theme.dart';
import 'package:torque_obd/core/theme/app_colors.dart';
import 'package:torque_obd/core/theme/gauge_skin.dart';
import 'package:torque_obd/ui/widgets/gauges/dial_gauge.dart';

void main() {
  group('the five differ in more than colour', () {
    test('there are five, each with a stable id', () {
      expect(GaugeSkin.all, hasLength(5));
      final ids = GaugeSkin.all.map((s) => s.id).toSet();
      expect(ids, hasLength(5), reason: 'ids are what gets persisted');
    });

    test('no two share the same geometry', () {
      // The property that makes these instruments rather than themes. Two
      // skins with identical angles, track width, pointer and ticks would be
      // the same dial in another colour, which is the thing being avoided.
      final shapes = GaugeSkin.all
          .map((s) => '${s.startAngle}/${s.sweepAngle}/${s.trackFraction}'
              '/${s.pointer}/${s.ticks}')
          .toSet();
      expect(shapes, hasLength(GaugeSkin.all.length));
    });

    test('they do not all draw a pointer, and they do not all animate', () {
      expect(GaugeSkin.all.map((s) => s.pointer).toSet().length,
          greaterThan(1));
      expect(GaugeSkin.all.where((s) => !s.animatesValue), isNotEmpty,
          reason: 'a racing instrument that eases shows where the engine was, '
              'which is the one thing it exists not to do');
      expect(GaugeSkin.all.where((s) => s.animatesValue), isNotEmpty);
    });

    test('every sweep stays inside a full turn and starts somewhere real', () {
      for (final skin in GaugeSkin.all) {
        expect(skin.sweepAngle, greaterThan(0), reason: skin.id);
        expect(skin.sweepAngle, lessThanOrEqualTo(2 * 3.14159266),
            reason: '${skin.id} would overlap itself');
        expect(skin.trackFraction, inInclusiveRange(0.01, 0.4),
            reason: '${skin.id} would be a disc or a hairline');
      }
    });
  });

  group('selection survives, and unknown selections do not break the app', () {
    test('an id round-trips', () {
      for (final skin in GaugeSkin.all) {
        expect(GaugeSkin.byId(skin.id), same(skin));
      }
    });

    test('an unknown id falls back rather than throwing', () {
      // A skin removed in a later release must not stop the app opening on a
      // phone that had it selected.
      expect(GaugeSkin.byId('a-skin-from-the-future'), GaugeSkin.cluster);
      expect(GaugeSkin.byId(null), GaugeSkin.cluster);
    });
  });

  group('the theme carries it', () {
    test('both brightnesses get the skin that was asked for', () {
      // A skin that only existed in one of them would strand anybody who
      // drives at night.
      for (final skin in GaugeSkin.all) {
        expect(AppTheme.dark(skin: skin).extension<GaugeSkin>(), same(skin));
        expect(AppTheme.light(skin: skin).extension<GaugeSkin>(), same(skin));
      }
    });

    test('the default is the instrument every screenshot was taken of', () {
      expect(AppTheme.dark().extension<GaugeSkin>(), GaugeSkin.cluster);
    });

    testWidgets('a widget outside any theme still draws something',
        (tester) async {
      // `context.gaugeSkin` falls back rather than throwing, so a preview or a
      // test pumping a bare MaterialApp renders a dial instead of nothing.
      late GaugeSkin seen;
      await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (context) {
          seen = context.gaugeSkin;
          return const SizedBox.shrink();
        }),
      ));
      expect(seen, GaugeSkin.cluster);
    });
  });

  test('switching instruments does not interpolate between them', () {
    // Halfway between a needle and no needle is not a thing to draw, and a
    // dial that morphs its geometry while the numbers keep updating is
    // unreadable for the duration — on a screen somebody may be glancing at
    // from a driving seat.
    final mid = GaugeSkin.cluster.lerp(GaugeSkin.minimal, 0.4);
    expect(mid, GaugeSkin.cluster);
    final past = GaugeSkin.cluster.lerp(GaugeSkin.minimal, 0.6);
    expect(past, GaugeSkin.minimal);
  });

  group('the face is a treatment, not a decoration', () {
    // Round 34 found this drawn unconditionally: `GaugeFace` was declared on
    // the skin, passed into the painter and never read, so `minimal`, `track`
    // and `night` all got the recessed disc they explicitly refuse and
    // `classic` never got its plate. The commit claimed a per-skin face
    // treatment it had not implemented, and nothing went red — a painter's
    // output is not something a unit test can see. A `Paint` is.
    const palette = AppPalette.dark;
    final colors = GaugeHue.aqua.resolve(Brightness.dark);
    Paint? fillFor(GaugeFace face) => faceFillFor(
          face,
          palette: palette,
          colors: colors,
          centre: const Offset(50, 50),
          radius: 50,
          arcRadius: 44,
        );

    test('flat draws nothing at all', () {
      expect(fillFor(GaugeFace.flat), isNull,
          reason: 'the tile\'s own surface showing through is the whole point '
              'of the skins that ask for it');
    });

    test('recessed is a gradient, so the dial reads as sunk into the panel',
        () {
      final paint = fillFor(GaugeFace.recessed);
      expect(paint, isNotNull);
      expect(paint!.shader, isNotNull);
    });

    test('plate is a flat lighter disc, because printed faces have no depth',
        () {
      final paint = fillFor(GaugeFace.plate);
      expect(paint, isNotNull);
      expect(paint!.shader, isNull);
      // Compared as packed ARGB: `Color` equality went wide-gamut, so two
      // identical colours built by different routes are not `==`.
      expect(paint.color.toARGB32(), palette.surfaceHigh.toARGB32());
      expect(paint.color.computeLuminance(),
          greaterThan(palette.surface.computeLuminance()),
          reason: 'a plate sits above the panel it is mounted on, so it is '
              'lighter than the card rather than darker — the claim, not just '
              'the token it happens to be written as');
    });

    test('every skin gets the face it asked for', () {
      // The end-to-end version. Three of the five want no disc; exactly one
      // wants a plate.
      final byFace = <GaugeFace, List<String>>{};
      for (final skin in GaugeSkin.all) {
        (byFace[skin.face] ??= []).add(skin.id);
      }
      expect(byFace[GaugeFace.flat], isNotNull);
      expect(byFace[GaugeFace.flat]!.length, greaterThan(1));
      expect(byFace[GaugeFace.plate], ['classic']);
      expect(byFace[GaugeFace.recessed], ['cluster']);
    });
  });

  testWidgets('and the painter actually draws it', (tester) async {
    // Round 35. The tests above hold `faceFillFor`, which is a pure function
    // returning a `Paint`. Nothing held the *call site* — comment out the
    // `drawCircle` in `_GaugeChromePainter` and every one of them stays green
    // while every gauge in the app loses its face. That is the same gap one
    // level up from the one round 34 found, and moving a rule somewhere
    // testable is not the same as testing it.
    //
    // Pinned on pixels, because that is the only thing that can tell whether
    // a canvas was drawn on. Two skins that differ *only* in face treatment
    // must produce different images; if the painter ignores the face they are
    // identical.
    Future<ui.Image> render(GaugeSkin skin) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      // A palette whose surface differs sharply from the face treatments, so
      // a missing fill is a visible difference rather than a subtle one.
      const palette = AppPalette.dark;
      paintGaugeChromeForTest(
        canvas,
        const Size(120, 120),
        palette: palette,
        skin: skin,
        colors: GaugeHue.aqua.resolve(Brightness.dark),
      );
      return recorder.endRecording().toImage(120, 120);
    }

    late List<int> flatPixels;
    late List<int> platePixels;
    await tester.runAsync(() async {
      final flat = await render(GaugeSkin.minimal.copyWith(
        // Only the face differs: same geometry, same everything else, so any
        // difference in the image is the face and nothing else.
        startAngle: GaugeSkin.classic.startAngle,
        sweepAngle: GaugeSkin.classic.sweepAngle,
        trackFraction: GaugeSkin.classic.trackFraction,
        ticks: GaugeSkin.classic.ticks,
        face: GaugeFace.flat,
      ));
      final plate = await render(GaugeSkin.classic.copyWith(
        face: GaugeFace.plate,
      ));
      flatPixels = (await flat.toByteData(format: ui.ImageByteFormat.rawRgba))!
          .buffer
          .asUint8List();
      platePixels = (await plate.toByteData(format: ui.ImageByteFormat.rawRgba))!
          .buffer
          .asUint8List();
    });

    expect(flatPixels, isNot(equals(platePixels)),
        reason: 'a skin that asks for no face and one that asks for a plate '
            'cannot render identically — if they do, the painter is not '
            'reading the face at all');
  });

  testWidgets('the numeral style actually prints numbers', (tester) async {
    // `GaugeTicks.numerals` was declared, chosen by `classic`, described in the
    // picker as 整圈數字 — and `_paintTicks` returned early only for `none` and
    // `segmented`, so it fell through to `graduated` and drew the same marks as
    // everything else. A declared case silently aliased to another, which is
    // the shape round 34 found in the face treatment.
    //
    // Pinned on pixels for the same reason that one is: a painter's output is
    // not something a unit test can see, and two skins differing only in tick
    // style must not render identically.
    Future<ui.Image> render(GaugeTicks ticks) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      paintGaugeChromeForTest(
        canvas,
        const Size(240, 240),
        palette: AppPalette.dark,
        skin: GaugeSkin.classic.copyWith(ticks: ticks),
        colors: GaugeHue.aqua.resolve(Brightness.dark),
        minValue: 0,
        maxValue: 8000,
      );
      return recorder.endRecording().toImage(240, 240);
    }

    late List<int> graduated;
    late List<int> numerals;
    await tester.runAsync(() async {
      final a = await render(GaugeTicks.graduated);
      final b = await render(GaugeTicks.numerals);
      graduated = (await a.toByteData(format: ui.ImageByteFormat.rawRgba))!
          .buffer
          .asUint8List();
      numerals = (await b.toByteData(format: ui.ImageByteFormat.rawRgba))!
          .buffer
          .asUint8List();
    });

    expect(numerals, isNot(equals(graduated)),
        reason: 'a dial that prints its scale cannot render identically to one '
            'that only marks it');
  });
}
