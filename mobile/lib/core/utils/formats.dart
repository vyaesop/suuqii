import 'package:decimal/decimal.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import 'package:suuqii/core/utils/money.dart';

/// intl ships no CLDR data for Afaan Oromo (`om`), so NumberFormat/DateFormat
/// would throw for it. Verify the tag and fall back to `en` — numerals stay
/// western and grouping stays `1,234.56` either way, which is what Ethiopian
/// retail users expect.
String verifiedIntlLocale(String tag) =>
    Intl.verifiedLocale(tag, NumberFormat.localeExists, onFailure: (_) => 'en') ??
    'en';

/// Locale-aware formatting helpers for screens.
///
/// Always use these (not `toStringAsFixed` / raw `DateFormat`) so amounts and
/// dates follow the active app locale.
extension FormatX on BuildContext {
  /// The active locale, downgraded to one intl has data for.
  String get intlLocale =>
      verifiedIntlLocale(Localizations.localeOf(this).toString());

  /// "ETB 1,234.56" — birr with locale-aware grouping.
  String money(Decimal amount) => formatMoney(amount, locale: intlLocale);

  /// [money] for int64 santim (persistence representation).
  String moneyFromSantim(int santim) => money(decimalFromSantim(santim));

  /// e.g. "Jan 5, 2026".
  String dateShort(DateTime d) => DateFormat.yMMMd(intlLocale).format(d);

  /// e.g. "Jan 5, 2026 2:30 PM".
  String dateTimeShort(DateTime d) =>
      DateFormat.yMMMd(intlLocale).add_jm().format(d);

  /// e.g. "2:30 PM".
  String timeShort(DateTime d) => DateFormat.jm(intlLocale).format(d);

  /// Plain locale-aware number (quantities, counts).
  String number(Decimal n) =>
      NumberFormat.decimalPattern(intlLocale).format(n.toDouble());
}
