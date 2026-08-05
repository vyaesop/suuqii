/// Ethiopian (Ge'ez) calendar conversion.
///
/// The client this was built for keeps their books in Ethiopian dates — their
/// ledger runs Hamle 1–26, 2018 EC. Showing them "8 July 2026" for a day they
/// know as ጠሐሌ ፩ means they cannot recognise their own takings, so every date
/// the app displays goes through here when the locale is `am` or `om`.
///
/// The Ethiopian year has 12 months of 30 days plus Pagumē, a 13th month of 5
/// days (6 in a leap year). Leap years are those where `year % 4 == 3`, which
/// is why the offset below is keyed on that remainder.
///
/// Conversion goes via the Julian Day Number so it is exact for every date
/// rather than approximated from a fixed offset — the Gregorian gap drifts
/// across a century and a naive "+7 years, +8 months" is wrong for part of
/// every year.
library;

import 'package:flutter/foundation.dart';

/// Julian Day Number offset for the Amete Mihret era (the ordinary Ethiopian
/// era, "year of mercy"). Not to be confused with Amete Alem, which is 5500
/// years earlier — using that constant silently shifts every date by a year.
///
/// Anchor this against a known pair when changing it: 11 September 2025 is
/// Meskerem 1, 2018 EC.
const int _ameteMihretEpoch = 1723856;

/// Month names, Meskerem (1) through Pagumē (13).
const List<String> ethiopianMonthsAm = [
  'መስከረም', 'ጥቅምት', 'ኅዳር', 'ታኅሣሥ', 'ጥር', 'የካቲት',
  'መጋቢት', 'ሚያዝያ', 'ግንቦት', 'ሰኔ', 'ሐምሌ', 'ነሐሴ', 'ጳጉሜን',
];

/// Latin-script names, used for Afaan Oromo, which writes the same months.
const List<String> ethiopianMonthsOm = [
  'Fulbaana', 'Onkololeessa', 'Sadaasa', 'Muddee', 'Amajjii', 'Guraandhala',
  'Bitooteessa', 'Ebla', 'Caamsaa', 'Waxabajjii', 'Adoolessa', 'Hagayya',
  'Qaammee',
];

/// A date in the Ethiopian calendar.
@immutable
class EthiopianDate {
  const EthiopianDate(this.year, this.month, this.day);

  final int year;

  /// 1..13 — 13 is Pagumē, the 5- or 6-day intercalary month.
  final int month;
  final int day;

  bool get isPagume => month == 13;

  /// Ethiopian leap years fall where `year % 4 == 3`, the year before a
  /// Gregorian leap year.
  static bool isLeapYear(int year) => year % 4 == 3;

  static int daysInMonth(int year, int month) {
    if (month < 13) return 30;
    return isLeapYear(year) ? 6 : 5;
  }

  String monthName({bool latin = false}) =>
      (latin ? ethiopianMonthsOm : ethiopianMonthsAm)[month - 1];

  /// "ሐምሌ 1, 2018" / "Adoolessa 1, 2018".
  String format({bool latin = false}) =>
      '${monthName(latin: latin)} $day, $year';

  /// "01-11-18" — the compact dd-mm-yy the client already writes by hand.
  String get compact =>
      '${_two(day)}-${_two(month)}-${_two(year % 100)}';

  static String _two(int v) => v.toString().padLeft(2, '0');

  @override
  String toString() => format();

  @override
  bool operator ==(Object other) =>
      other is EthiopianDate &&
      other.year == year &&
      other.month == month &&
      other.day == day;

  @override
  int get hashCode => Object.hash(year, month, day);
}

/// Julian Day Number for a Gregorian date (Fliegel–Van Flandern).
int _gregorianToJdn(int year, int month, int day) {
  final a = ((14 - month) / 12).floor();
  final y = year + 4800 - a;
  final m = month + 12 * a - 3;
  return day +
      ((153 * m + 2) / 5).floor() +
      365 * y +
      (y / 4).floor() -
      (y / 100).floor() +
      (y / 400).floor() -
      32045;
}

/// Inverse of [_gregorianToJdn].
DateTime _jdnToGregorian(int jdn) {
  final a = jdn + 32044;
  final b = ((4 * a + 3) / 146097).floor();
  final c = a - ((146097 * b) / 4).floor();
  final d = ((4 * c + 3) / 1461).floor();
  final e = c - ((1461 * d) / 4).floor();
  final m = ((5 * e + 2) / 153).floor();
  final day = e - ((153 * m + 2) / 5).floor() + 1;
  final month = m + 3 - 12 * (m / 10).floor();
  final year = 100 * b + d - 4800 + (m / 10).floor();
  return DateTime(year, month, day);
}

/// Convert a Gregorian date to the Ethiopian calendar.
///
/// Uses the date's local Y/M/D as given — callers should pass a local
/// `DateTime`, since "which day was this sale on" is a local-time question.
EthiopianDate toEthiopian(DateTime gregorian) {
  final jdn = _gregorianToJdn(gregorian.year, gregorian.month, gregorian.day);
  final elapsed = jdn - _ameteMihretEpoch;
  final r = elapsed % 1461;
  // The `r ~/ 1460` terms are what handle the 6-day Pagumē: the fourth year of
  // each cycle has 366 days, so day 1460 belongs to the year that is ending,
  // not the one starting.
  final n = (r % 365) + 365 * (r ~/ 1460);
  final year = 4 * (elapsed ~/ 1461) + (r ~/ 365) - (r ~/ 1460);
  return EthiopianDate(year, (n ~/ 30) + 1, (n % 30) + 1);
}

/// Convert an Ethiopian date back to Gregorian.
DateTime fromEthiopian(EthiopianDate ec) {
  final jdn = _ameteMihretEpoch +
      365 +
      365 * (ec.year - 1) +
      ec.year ~/ 4 +
      30 * (ec.month - 1) +
      (ec.day - 1);
  return _jdnToGregorian(jdn);
}

/// Whether [localeTag] should see Ethiopian dates.
///
/// Amharic and Afaan Oromo speakers in Ethiopia keep books in EC; an `en`
/// locale is treated as "show me Gregorian", which is also what a diaspora or
/// NGO user expects.
bool usesEthiopianCalendar(String localeTag) {
  final lang = localeTag.split(RegExp('[_-]')).first.toLowerCase();
  return lang == 'am' || lang == 'om';
}
