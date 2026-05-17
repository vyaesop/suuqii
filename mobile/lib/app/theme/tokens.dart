import 'package:flutter/material.dart';

/// Scandinavian design tokens — minimal, pragmatic, warm.
///
/// Palette: linen background, near-black ink, single forest-green accent.
/// Borders over shadows. Generous spacing. Soft radii (10–14).
class SuuqColors {
  SuuqColors._();

  // ---- Neutrals (warm linen / parchment family) ----
  static const linen = Color(0xFFF5F2EC);          // app background
  static const linenAlt = Color(0xFFEFEBE3);       // surface alt
  static const card = Color(0xFFFBF9F4);           // raised card
  static const cardSubtle = Color(0xFFF0EDE6);     // subtle chip / pill
  static const border = Color(0xFFE3DED4);
  static const borderStrong = Color(0xFFCFC9BD);

  static const ink = Color(0xFF1C1B19);            // primary text
  static const inkSoft = Color(0xFF4D4A44);        // secondary text
  static const inkMuted = Color(0xFF8C887F);       // tertiary text / labels
  static const inkDisabled = Color(0xFFB3AFA5);

  // ---- Accents ----
  static const forest = Color(0xFF2F5D50);         // primary accent
  static const forestSoft = Color(0xFFE2EAE5);
  static const moss = Color(0xFF7DA28A);

  static const clay = Color(0xFFB7484A);           // danger / negative
  static const claySoft = Color(0xFFF5DEDD);

  static const amber = Color(0xFFC58E2C);          // warning / overdue
  static const amberSoft = Color(0xFFF6E9CC);

  static const slate = Color(0xFF5B6F7B);          // info / neutral status
  static const slateSoft = Color(0xFFE2E9ED);

  // ---- Dark palette ----
  static const inkDark = Color(0xFF14130F);        // app background dark
  static const surfaceDark = Color(0xFF1B1A17);
  static const cardDark = Color(0xFF22211D);
  static const borderDark = Color(0xFF2D2B26);
  static const onDark = Color(0xFFEDE9DF);
  static const onDarkSoft = Color(0xFFA59F92);
  static const forestDark = Color(0xFF6FA890);
}

class SuuqRadius {
  SuuqRadius._();
  static const xs = 6.0;
  static const sm = 10.0;
  static const md = 14.0;
  static const lg = 20.0;
  static const xl = 28.0;
}

class SuuqSpacing {
  SuuqSpacing._();
  static const xxs = 4.0;
  static const xs = 8.0;
  static const sm = 12.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
  static const xxl = 48.0;
}

class SuuqShape {
  SuuqShape._();
  static final card = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(SuuqRadius.md),
    side: const BorderSide(color: SuuqColors.border),
  );
  static final pill = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(999),
  );
  static final button = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(SuuqRadius.sm),
  );
  static final input = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(SuuqRadius.sm),
  );
}
