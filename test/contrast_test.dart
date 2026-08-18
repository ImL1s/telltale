/// Contrast is arithmetic, not taste.
///
/// These are 10.5px status labels read at arm's length through windscreen
/// glare — the least forgiving condition this app has — and three pairs were
/// below the WCAG 2.2 minimum for normal text.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:torque_obd/core/theme/app_colors.dart';

/// WCAG 2.2 relative luminance.
double _luminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) +
      0.7152 * channel(c.g) +
      0.0722 * channel(c.b);
}

double _contrast(Color fg, Color bg) {
  final a = _luminance(fg);
  final b = _luminance(bg);
  final hi = math.max(a, b);
  final lo = math.min(a, b);
  return (hi + 0.05) / (lo + 0.05);
}

/// The WCAG 2.2 minimum for normal-size text.
const double _minimum = 4.5;

void main() {
  group('every text colour clears 4.5:1 on the surfaces it appears on', () {
    for (final entry in {
      'dark': AppPalette.dark,
      'light': AppPalette.light,
    }.entries) {
      final theme = entry.key;
      final p = entry.value;

      for (final surface in {'background': p.background, 'surface': p.surface}
          .entries) {
        for (final text in {
          'primary': p.textPrimary,
          'secondary': p.textSecondary,
          'tertiary': p.textTertiary,
        }.entries) {
          test('$theme ${text.key} on ${surface.key}', () {
            expect(
              _contrast(text.value, surface.value),
              greaterThanOrEqualTo(_minimum),
            );
          });
        }
      }

      // The foreground the theme actually puts on a filled button. The dark
      // scheme uses a near-black teal on its bright aqua rather than white, so
      // asserting white here would test a pair that never appears on screen.
      final onAccent = theme == 'dark'
          ? const Color(0xFF00201C)
          : const Color(0xFFFFFFFF);

      test('$theme: the label on a filled primary button', () {
        expect(
          _contrast(onAccent, p.accent),
          greaterThanOrEqualTo(_minimum),
        );
      });
    }
  });

  group('the stale treatment stays legible', () {
    // Dimming is the signal that a value is no longer arriving, so the
    // temptation is to push it as far as it will go. At the previous 0.42 the
    // light theme put 10.5px status text at 2.68:1 — these are labels read at
    // arm's length through windscreen glare, and a stale reading nobody can
    // read is not a gentler failure than a wrong one.
    //
    // Opacity is not the only signal either: the readouts carry
    // "（資料已過期）" as well, because colour alone excludes anyone who cannot
    // perceive the difference.
    for (final entry in {
      'dark': AppPalette.dark,
      'light': AppPalette.light,
    }.entries) {
      final p = entry.value;
      for (final surface in {'background': p.background, 'surface': p.surface}
          .entries) {
        test('${entry.key}: dimmed text on ${surface.key}', () {
          final dimmed = Color.alphaBlend(
            p.textPrimary.withValues(alpha: kStaleOpacity),
            surface.value,
          );
          final ratio = _contrast(dimmed, surface.value);
          expect(
            ratio,
            greaterThanOrEqualTo(_minimum),
            reason: 'stale text at $kStaleOpacity opacity is '
                '${ratio.toStringAsFixed(2)}:1 on ${entry.key}/${surface.key}',
          );
        });

        test('${entry.key}: the dial fades further than text could survive',
            () {
          // The two are separate constants because they are answering
          // different questions. Nothing has to be read off an arc, so it can
          // fade until the state is unmistakable; the numbers beside it cannot.
          // One value covering both forced a choice between an invisible
          // signal and illegible small text — at 0.62 the units and label
          // tokens measure 2.4–3.5:1, against a 4.5:1 minimum.
          expect(
            kStaleDecorationOpacity,
            lessThan(kStaleOpacity),
            reason: 'a dial that fades no further than its text is not a '
                'signal anyone will notice',
          );

          // And the tokens that are *not* dimmed must still pass opaque, which
          // is what makes leaving them alone the right answer.
          for (final text in {
            'secondary': p.textSecondary,
            'tertiary': p.textTertiary,
          }.entries) {
            expect(
              _contrast(text.value, surface.value),
              greaterThanOrEqualTo(_minimum),
              reason: '${text.key} carries the gauge label and units',
            );
          }
        });
      }
    }
  });
}
