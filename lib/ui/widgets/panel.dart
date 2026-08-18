/// Shared surface primitives.
///
/// Cards here get their separation from a hairline border plus a very slight
/// gradient rather than a drop shadow — on a near-black ground a shadow is
/// invisible, so borrowing the Material elevation model would leave every
/// surface looking flat.
library;

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

class Panel extends StatelessWidget {
  const Panel({
    required this.child,
    this.padding = const EdgeInsets.all(Spacing.lg),
    this.onTap,
    this.accent,
    this.isActive = false,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  /// Tints the border and adds a top hairline in this colour, used to mark a
  /// panel as belonging to a particular signal.
  final Color? accent;

  final bool isActive;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final borderColour = isActive
        ? (accent ?? palette.accent).withValues(alpha: 0.55)
        : palette.hairline;

    final content = AnimatedContainer(
      duration: Motion.fast,
      curve: Motion.standard,
      padding: padding,
      decoration: BoxDecoration(
        borderRadius: Radii.cardRadius,
        border: Border.all(color: borderColour),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color.alphaBlend(
              (accent ?? palette.accent).withValues(alpha: isActive ? 0.09 : 0.03),
              palette.surface,
            ),
            palette.surface,
          ],
        ),
      ),
      child: child,
    );

    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      borderRadius: Radii.cardRadius,
      child: InkWell(
        onTap: onTap,
        borderRadius: Radii.cardRadius,
        splashColor: (accent ?? palette.accent).withValues(alpha: 0.10),
        highlightColor: (accent ?? palette.accent).withValues(alpha: 0.05),
        child: content,
      ),
    );
  }
}

/// Small all-caps heading that introduces a group of controls.
class SectionHeading extends StatelessWidget {
  const SectionHeading(this.text, {this.trailing, super.key});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Spacing.md, top: Spacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(text.toUpperCase(), style: context.texts.labelSmall),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Status pill — connection state, fastMode, PIDs/sec, fault counts.
class StatusPill extends StatelessWidget {
  const StatusPill({
    required this.label,
    this.icon,
    this.tone = StatusTone.neutral,
    this.dense = false,
    super.key,
  });

  final String label;
  final IconData? icon;
  final StatusTone tone;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final colour = switch (tone) {
      StatusTone.neutral => palette.textSecondary,
      StatusTone.good => palette.success,
      StatusTone.warn => palette.warning,
      StatusTone.bad => palette.danger,
      StatusTone.accent => palette.accent,
    };

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? Spacing.sm : Spacing.md,
        vertical: dense ? 3 : Spacing.xs + 1,
      ),
      decoration: BoxDecoration(
        color: colour.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: colour.withValues(alpha: 0.30)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: dense ? 12 : 14, color: colour),
            const SizedBox(width: Spacing.xs + 1),
          ],
          Text(
            label,
            style: (dense ? context.texts.labelSmall : context.texts.labelMedium)
                ?.copyWith(color: colour, letterSpacing: 0.2),
          ),
        ],
      ),
    );
  }
}

enum StatusTone { neutral, good, warn, bad, accent }

/// Empty-state block: icon, headline, explanation, optional action.
class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.action,
    super.key,
  });

  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Spacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(Spacing.lg),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: palette.surfaceAlt,
                border: Border.all(color: palette.hairline),
              ),
              child: Icon(icon, size: 30, color: palette.textTertiary),
            ),
            const SizedBox(height: Spacing.lg),
            Text(title, style: context.texts.titleLarge, textAlign: TextAlign.center),
            const SizedBox(height: Spacing.sm),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: context.texts.bodyMedium,
              ),
            ),
            if (action != null) ...[
              const SizedBox(height: Spacing.xl),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
