import 'package:flutter/material.dart';

import 'package:suuqii/app/theme/tokens.dart';

/// Calm, centred empty state. One icon, one title, one short line of help,
/// optional CTA. Used across list screens.
class EmptyState extends StatelessWidget {
  const EmptyState({
    required this.icon,
    required this.title,
    super.key,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(SuuqSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: scheme.surfaceContainer,
                shape: BoxShape.circle,
                border: Border.all(color: scheme.outlineVariant),
              ),
              child: Icon(icon, color: scheme.onSurfaceVariant, size: 26),
            ),
            const SizedBox(height: SuuqSpacing.md),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            if (message != null) ...[
              const SizedBox(height: SuuqSpacing.xs),
              Text(
                message!,
                style: Theme.of(context).textTheme.bodyMedium,
                textAlign: TextAlign.center,
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: SuuqSpacing.lg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
