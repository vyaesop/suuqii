import 'package:flutter/material.dart';

import 'package:suuqii/app/theme/tokens.dart';

/// A small rounded label used to denote a state — debt status, sale status,
/// stock state, etc. Comes with a built-in palette of semantic intents.
enum PillIntent { neutral, success, warning, danger, info }

class StatusPill extends StatelessWidget {
  const StatusPill({
    required this.label,
    this.intent = PillIntent.neutral,
    this.icon,
    super.key,
  });

  final String label;
  final PillIntent intent;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = _palette(intent, context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: fg,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  (Color, Color) _palette(PillIntent i, BuildContext c) {
    final isDark = Theme.of(c).brightness == Brightness.dark;
    switch (i) {
      case PillIntent.success:
        return isDark
            ? (const Color(0xFF2A3E36), SuuqColors.forestDark)
            : (SuuqColors.forestSoft, SuuqColors.forest);
      case PillIntent.warning:
        return isDark
            ? (const Color(0xFF3D331C), SuuqColors.amberSoft)
            : (SuuqColors.amberSoft, SuuqColors.amber);
      case PillIntent.danger:
        return isDark
            ? (const Color(0xFF3D2A2A), SuuqColors.claySoft)
            : (SuuqColors.claySoft, SuuqColors.clay);
      case PillIntent.info:
        return isDark
            ? (const Color(0xFF2A3540), SuuqColors.slateSoft)
            : (SuuqColors.slateSoft, SuuqColors.slate);
      case PillIntent.neutral:
        return isDark
            ? (SuuqColors.cardDark, SuuqColors.onDarkSoft)
            : (SuuqColors.cardSubtle, SuuqColors.inkSoft);
    }
  }
}
