import 'package:flutter/material.dart';

import 'package:suuqii/app/theme/tokens.dart';

/// A flat surface with a soft border instead of a shadow. The Scandinavian
/// alternative to elevated cards — quieter, more readable.
class SectionCard extends StatelessWidget {
  const SectionCard({
    required this.child,
    super.key,
    this.padding = const EdgeInsets.all(SuuqSpacing.md),
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(SuuqRadius.md),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(SuuqRadius.md),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(SuuqRadius.md),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

/// A label–value row, used inside cards. Label muted, value emphasised.
class InfoRow extends StatelessWidget {
  const InfoRow({
    required this.label,
    required this.value,
    super.key,
    this.emphasize = false,
    this.intent,
  });

  final String label;
  final String value;
  final bool emphasize;
  final Color? intent;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(
            child: Text(
              label,
              style: t.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Text(
            value,
            style: (emphasize ? t.titleLarge : t.bodyLarge)?.copyWith(
              fontWeight: emphasize ? FontWeight.w700 : FontWeight.w600,
              color: intent,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

/// Small uppercase section header used for grouping rows.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SuuqSpacing.md, SuuqSpacing.lg, SuuqSpacing.md, SuuqSpacing.xs,
      ),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              letterSpacing: 1.2,
            ),
      ),
    );
  }
}
