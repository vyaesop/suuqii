import 'package:flutter/material.dart';

import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/shared/widgets/status_pill.dart';

/// Color-coded expiry pill: red once expired, amber when ≤ [warnDays] days
/// out, neutral otherwise. [daysToExpiry] uses the stock-lot convention
/// (negative = expired, 0 = expires today).
class ExpiryBadge extends StatelessWidget {
  const ExpiryBadge({
    required this.expiryDate,
    required this.daysToExpiry,
    this.warnDays = 3,
    super.key,
  });

  final DateTime expiryDate;
  final int daysToExpiry;
  final int warnDays;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final PillIntent intent;
    final String label;
    if (daysToExpiry < 0) {
      intent = PillIntent.danger;
      label = l.expiryExpired;
    } else if (daysToExpiry == 0) {
      intent = PillIntent.danger;
      label = l.expiryToday;
    } else if (daysToExpiry <= warnDays) {
      intent = PillIntent.warning;
      label = l.expiryInDays(daysToExpiry);
    } else {
      intent = PillIntent.neutral;
      label = context.dateShort(expiryDate);
    }
    return StatusPill(
      label: label,
      intent: intent,
      icon: Icons.schedule_rounded,
    );
  }
}
