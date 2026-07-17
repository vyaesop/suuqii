import 'package:flutter/material.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/l10n.dart';

/// Full-screen blocker shown when the backend answered an API call with
/// HTTP 426: this build is too old to talk to the server. Deliberately has
/// no dismiss/back affordance — the router keeps redirecting here while the
/// `updateRequiredProvider` flag is set.
class UpdateRequiredScreen extends StatelessWidget {
  const UpdateRequiredScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: SuuqSpacing.lg,
              vertical: SuuqSpacing.xl,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                children: [
                  Icon(
                    Icons.system_update_alt_rounded,
                    size: 64,
                    color: scheme.primary,
                  ),
                  const SizedBox(height: SuuqSpacing.lg),
                  Text(
                    l.updateRequiredTitle,
                    style: theme.textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: SuuqSpacing.sm),
                  Text(
                    l.updateRequiredBody,
                    style: theme.textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
