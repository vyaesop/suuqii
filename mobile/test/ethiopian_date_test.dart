import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/core/utils/ethiopian_date.dart';

void main() {
  group('known anchors', () {
    // Ethiopian New Year (Meskerem 1) falls on 11 September in the three years
    // before a Gregorian leap year, and 12 September in the year before it.
    test('Meskerem 1 lands on the right Gregorian day', () {
      expect(toEthiopian(DateTime(2025, 9, 11)), const EthiopianDate(2018, 1, 1));
      expect(toEthiopian(DateTime(2024, 9, 11)), const EthiopianDate(2017, 1, 1));
      expect(toEthiopian(DateTime(2023, 9, 12)), const EthiopianDate(2016, 1, 1));
    });

    test("the client's ledger dates convert as they wrote them", () {
      // Their sheet runs Hamle (month 11) 1–26 of 2018 EC.
      expect(toEthiopian(DateTime(2026, 7, 8)), const EthiopianDate(2018, 11, 1));
      expect(toEthiopian(DateTime(2026, 8, 2)), const EthiopianDate(2018, 11, 26));
    });

    test('the compact form matches the dd-mm-yy they type by hand', () {
      expect(toEthiopian(DateTime(2026, 7, 8)).compact, '01-11-18');
      expect(toEthiopian(DateTime(2026, 8, 2)).compact, '26-11-18');
    });

    test('the first day of the era round-trips', () {
      // Not asserted against a Gregorian date: the proleptic Gregorian value
      // for year 8 CE depends on which convention you pick, and the property
      // that matters here is that conversion is lossless.
      const epoch = EthiopianDate(1, 1, 1);
      expect(toEthiopian(fromEthiopian(epoch)), epoch);
    });
  });

  group('leap years and Pagumē', () {
    test('leap years are those where year % 4 == 3', () {
      expect(EthiopianDate.isLeapYear(2015), isTrue);
      expect(EthiopianDate.isLeapYear(2019), isTrue);
      expect(EthiopianDate.isLeapYear(2018), isFalse);
      expect(EthiopianDate.isLeapYear(2016), isFalse);
    });

    test('Pagumē is 5 days normally and 6 in a leap year', () {
      expect(EthiopianDate.daysInMonth(2018, 13), 5);
      expect(EthiopianDate.daysInMonth(2019, 13), 6);
      expect(EthiopianDate.daysInMonth(2018, 1), 30);
      expect(EthiopianDate.daysInMonth(2018, 12), 30);
    });

    test('the 6th of Pagumē exists only in a leap year', () {
      const leap = EthiopianDate(2019, 13, 6);
      expect(toEthiopian(fromEthiopian(leap)), leap);
      // The day after is New Year.
      final next = fromEthiopian(leap).add(const Duration(days: 1));
      expect(toEthiopian(next), const EthiopianDate(2020, 1, 1));
    });

    test('a non-leap year rolls from Pagumē 5 straight into New Year', () {
      const last = EthiopianDate(2018, 13, 5);
      expect(toEthiopian(fromEthiopian(last)), last);
      final next = fromEthiopian(last).add(const Duration(days: 1));
      expect(toEthiopian(next), const EthiopianDate(2019, 1, 1));
    });
  });

  group('round-trip', () {
    test('every day across a four-year leap cycle survives both directions',
        () {
      // Four years covers one full leap cycle, which is where naive
      // fixed-offset conversions break.
      var d = DateTime(2024);
      final end = DateTime(2028);
      var checked = 0;
      while (d.isBefore(end)) {
        final ec = toEthiopian(d);
        expect(
          fromEthiopian(ec),
          d,
          reason: '$d → $ec → ${fromEthiopian(ec)}',
        );
        expect(ec.month, inInclusiveRange(1, 13));
        expect(ec.day, inInclusiveRange(1, EthiopianDate.daysInMonth(ec.year, ec.month)));
        d = d.add(const Duration(days: 1));
        checked++;
      }
      expect(checked, greaterThan(1460));
    });

    test('consecutive Gregorian days are consecutive Ethiopian days', () {
      var d = DateTime(2026, 8, 25); // straddles Pagumē → New Year
      for (var i = 0; i < 30; i++) {
        final a = toEthiopian(d);
        final b = toEthiopian(d.add(const Duration(days: 1)));
        final gap = fromEthiopian(b).difference(fromEthiopian(a)).inDays;
        expect(gap, 1, reason: '$a → $b should be one day apart');
        d = d.add(const Duration(days: 1));
      }
    });
  });

  group('formatting and locale gating', () {
    test('month names are used, not numbers', () {
      final ec = toEthiopian(DateTime(2026, 7, 8));
      expect(ec.format(), 'ሐምሌ 1, 2018');
      expect(ec.format(latin: true), 'Adoolessa 1, 2018');
    });

    test('only am and om get Ethiopian dates', () {
      expect(usesEthiopianCalendar('am'), isTrue);
      expect(usesEthiopianCalendar('om'), isTrue);
      expect(usesEthiopianCalendar('am_ET'), isTrue);
      expect(usesEthiopianCalendar('om-ET'), isTrue);
      expect(usesEthiopianCalendar('en'), isFalse);
      expect(usesEthiopianCalendar('en_US'), isFalse);
    });
  });
}
