import 'package:decimal/decimal.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/features/dashboard/data/boutique_reports_repository.dart';
import 'package:suuqii/features/dashboard/data/dashboard_repository.dart';

/// Parsing for the four boutique analytics shapes (docs/19 §14). The
/// endpoints mask cost fields for non-owners and omit optional ones, so every
/// parser is exercised with a full payload, a stripped one and an empty one.
void main() {
  group('size curve', () {
    test('parses sizes, colours and totals in server order', () {
      final report = SizeCurveReport.fromJson({
        'style': {'id': 'style-1', 'name': 'Slim jeans', 'brand': "Levi's"},
        'sizes': [
          {
            'size': '32',
            'received': '12',
            'sold': '9',
            'on_hand': '3',
            'sell_through': '0.75',
            'revenue': '10800.00',
          },
          {
            'size': '34',
            'received': '24',
            'sold': '6',
            'on_hand': '18',
            'sell_through': '0.25',
            'revenue': '7200.00',
          },
        ],
        'colors': [
          {
            'color': 'Blue',
            'received': '36',
            'sold': '15',
            'on_hand': '21',
            'sell_through': '0.416',
            'revenue': '18000.00',
          },
        ],
        'totals': {
          'received': '36',
          'sold': '15',
          'on_hand': '21',
          'revenue': '18000.00',
        },
      });

      expect(report.styleId, 'style-1');
      expect(report.brand, "Levi's");
      // The server orders by the style's size_set preset; the screen renders
      // that order as-is, so parsing must not reshuffle it.
      expect(report.sizes.map((r) => r.label), ['32', '34']);
      expect(report.sizes.first.sellThrough, Decimal.parse('0.75'));
      expect(report.colors.single.label, 'Blue');
      expect(report.totals.revenue, Decimal.parse('18000.00'));
      expect(report.isEmpty, isFalse);
    });

    test('tolerates a null size, a missing brand and missing numbers', () {
      final report = SizeCurveReport.fromJson({
        'style': {'id': 'style-2', 'name': 'Scarf'},
        'sizes': [
          {'size': null, 'received': '4'},
        ],
        'colors': const <Map<String, dynamic>>[],
        'totals': {'received': '4'},
      });

      expect(report.brand, isNull);
      expect(report.sizes.single.label, isNull);
      expect(report.sizes.single.sold, Decimal.zero);
      expect(report.sizes.single.revenue, Decimal.zero);
      expect(report.totals.onHand, Decimal.zero);
    });

    test('an all-empty response is empty, not an error', () {
      final report = SizeCurveReport.fromJson(const {});
      expect(report.isEmpty, isTrue);
      expect(report.styleName, '');
      expect(report.totals.received, Decimal.zero);
    });
  });

  group('dead stock', () {
    test('parses items, age, last sale and the total value', () {
      final report = DeadStockReport.fromJson({
        'days': 60,
        'items': [
          {
            'product_id': 'p1',
            'name': 'Slim jeans · 32 · Blue',
            'style_id': 'style-1',
            'size': '32',
            'color': 'Blue',
            'stock': '3',
            'age_days': 104,
            'last_sold_at': '2026-06-04',
            'unit_cost': '800.00',
            'value': '2400.00',
          },
        ],
        'total_value': '2400.00',
        'next_cursor': null,
        'has_more': false,
      });

      final item = report.items.single;
      expect(report.days, 60);
      expect(item.ageDays, 104);
      expect(item.lastSoldAt, DateTime.parse('2026-06-04'));
      expect(item.value, Decimal.parse('2400.00'));
      expect(report.totalValue, Decimal.parse('2400.00'));
      expect(report.hasMore, isFalse);
    });

    test('never-sold rows and masked costs read as null and zero', () {
      final report = DeadStockReport.fromJson({
        'days': 90,
        'items': [
          {
            'product_id': 'p2',
            'name': 'Scarf',
            'stock': '2',
            'age_days': 200,
            'last_sold_at': null,
          },
        ],
        'has_more': true,
      });

      final item = report.items.single;
      expect(item.lastSoldAt, isNull);
      expect(item.styleId, isNull);
      // Cost fields need VIEW_COSTS: absent must not blow up the card.
      expect(item.unitCost, Decimal.zero);
      expect(item.value, Decimal.zero);
      expect(report.totalValue, Decimal.zero);
      expect(report.hasMore, isTrue);
    });

    test('an empty response yields no items', () {
      final report = DeadStockReport.fromJson(const {
        'days': 60,
        'items': <Map<String, dynamic>>[],
        'total_value': '0',
      });
      expect(report.items, isEmpty);
      expect(report.totalValue, Decimal.zero);
    });
  });

  group('broken runs', () {
    test('parses the missing list with its 30-day sales', () {
      final run = BrokenRun.fromJson({
        'style_id': 'style-1',
        'name': 'Slim jeans',
        'brand': "Levi's",
        'image_url': 'https://example.test/j.jpg',
        'variant_count': 8,
        'in_stock_count': 5,
        'stock_total': '11',
        'missing': [
          {'size': '32', 'color': 'Blue', 'sold_30d': '9'},
          {'size': '34', 'color': null, 'sold_30d': '4'},
        ],
      });

      expect(run.variantCount, 8);
      expect(run.inStockCount, 5);
      expect(run.stockTotal, Decimal.parse('11'));
      expect(run.missing.first.sold30d, Decimal.parse('9'));
      expect(run.missing.last.color, isNull);
    });

    test('a style with no brand, image or missing list still parses', () {
      final run = BrokenRun.fromJson(const {
        'style_id': 'style-2',
        'name': 'Scarf',
        'variant_count': 3,
        'in_stock_count': 2,
        'stock_total': '2',
      });
      expect(run.brand, isNull);
      expect(run.imageUrl, isNull);
      expect(run.missing, isEmpty);
    });
  });

  group('top styles', () {
    test('parses a style row and a style-less product row', () {
      final items = [
        TopStyle.fromJson(const {
          'style_id': 'style-1',
          'name': 'Slim jeans',
          'brand': "Levi's",
          'quantity': '30',
          'revenue': '36000.00',
          'profit': '12000.00',
          'variant_count': 8,
        }),
        // Products with no style roll up individually so nothing is hidden.
        TopStyle.fromJson(const {
          'style_id': null,
          'name': 'Belt',
          'quantity': '4',
          'revenue': '800.00',
          'variant_count': 1,
        }),
      ];

      expect(items.first.profit, Decimal.parse('12000.00'));
      expect(items.first.variantCount, 8);
      expect(items.last.styleId, isNull);
      // profit needs VIEW_COSTS; absent for a cashier's token.
      expect(items.last.profit, Decimal.zero);
    });
  });

  group('date window', () {
    test('is half-open and covers exactly the promised number of days', () {
      final (from7, to7) = dateWindow(DashboardRange.week);
      final (from30, to30) = dateWindow(DashboardRange.month);
      final start = DateTime.parse(from7);
      final end = DateTime.parse(to7);

      expect(end.difference(start).inDays, 7);
      expect(DateTime.parse(to30).difference(DateTime.parse(from30)).inDays, 30);
      expect(to7, to30, reason: 'both windows end after today');
      expect(from7.length, 10, reason: 'YYYY-MM-DD');
    });
  });
}
