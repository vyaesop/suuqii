import 'package:flutter/widgets.dart';

import 'package:suuqii/l10n/app_localizations.dart';

export 'package:suuqii/l10n/app_localizations.dart';

/// Shorthand for [AppLocalizations.of].
///
/// Usage in widgets: `Text(context.l10n.posSearchHint)`.
///
/// Key conventions (assets/l10n/app_en.arb is the template):
/// - camelCase, feature-prefixed: `posSearchHint`, `checkoutPayCash`,
///   `debtWriteOffConfirm`, `inventoryEmptyTitle` …
/// - Cross-feature strings use the `common` prefix (`commonCancel`,
///   `commonSave`) and server-error strings the `err` prefix (`errConflict`).
/// - Interpolation uses ICU placeholders (`{name}`, `{count}`, `{amount}`)
///   with placeholder metadata in the template ARB; counts use ICU plurals.
///   Money/date values are pre-formatted with the helpers in
///   `core/utils/formats.dart` and passed as String placeholders.
/// - Never concatenate translated fragments.
/// - Every key added to app_en.arb MUST get an Afaan Oromo value in
///   app_om.arb (enforced by test/l10n_parity_test.dart).
extension L10nX on BuildContext {
  AppLocalizations get l10n => AppLocalizations.of(this);
}
