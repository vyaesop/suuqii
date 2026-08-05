import 'package:decimal/decimal.dart';
import 'package:flutter/widgets.dart';
import 'package:intl/intl.dart';

import 'package:suuqii/core/utils/ethiopian_date.dart';
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

  /// The locale the *user* picked, before the intl downgrade.
  ///
  /// [intlLocale] maps `om` → `en` because intl ships no CLDR data for Afaan
  /// Oromo; that must not also switch an Oromo user back to Gregorian dates.
  String get rawLocale => Localizations.localeOf(this).toString();

  /// Whether dates should be shown in the Ethiopian calendar.
  bool get usesEcDates => usesEthiopianCalendar(rawLocale);

  /// e.g. "Jan 5, 2026", or "ሐምሌ 1, 2018" for am/om.
  ///
  /// Ethiopian-calendar users keep their books in EC — showing the Gregorian
  /// day means they cannot recognise their own records.
  String dateShort(DateTime d) {
    if (!usesEcDates) return DateFormat.yMMMd(intlLocale).format(d);
    return toEthiopian(d).format(latin: rawLocale.startsWith('om'));
  }

  /// e.g. "Jan 5, 2026 2:30 PM". Time of day is the same in both calendars.
  String dateTimeShort(DateTime d) {
    if (!usesEcDates) return DateFormat.yMMMd(intlLocale).add_jm().format(d);
    return '${dateShort(d)} ${timeShort(d)}';
  }

  /// e.g. "2:30 PM".
  String timeShort(DateTime d) => DateFormat.jm(intlLocale).format(d);

  /// Plain locale-aware number (quantities, counts).
  String number(Decimal n) =>
      NumberFormat.decimalPattern(intlLocale).format(n.toDouble());
}
