import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:suuqii/core/http/dio_client.dart';
import 'package:suuqii/features/dashboard/data/dashboard_repository.dart';

part 'boutique_reports_repository.g.dart';

/// Boutique analytics (docs/19-boutique-shop-type.md §14): four owner-only
/// live reads that turn the batch and sale data already on the server into
/// the three questions a boutique owner asks — which sizes to rebuy, what is
/// not moving, which styles earn.
///
/// Every field is parsed defensively (missing → zero/null) the same way the
/// styles remote data source does: cost-bearing fields are masked or omitted
/// for non-owners, and a report is never worth a red screen.

Decimal _dec(Object? raw) =>
    raw is String ? (Decimal.tryParse(raw) ?? Decimal.zero) : Decimal.zero;

int _int(Object? raw) => raw is int ? raw : int.tryParse('$raw') ?? 0;

DateTime? _date(Object? raw) => raw is String ? DateTime.tryParse(raw) : null;

List<Map<String, dynamic>> _rows(Object? raw) =>
    (raw as List? ?? const []).whereType<Map<String, dynamic>>().toList();

/// One line of the size curve — a size or a colour, identically shaped.
class SizeCurveRow {
  const SizeCurveRow({
    required this.label,
    required this.received,
    required this.sold,
    required this.onHand,
    required this.sellThrough,
    required this.revenue,
  });

  /// [key] is `'size'` or `'color'` — the two lists differ only in that name.
  factory SizeCurveRow.fromJson(
    Map<String, dynamic> j, {
    required String key,
  }) =>
      SizeCurveRow(
        label: j[key] as String?,
        received: _dec(j['received']),
        sold: _dec(j['sold']),
        onHand: _dec(j['on_hand']),
        sellThrough: _dec(j['sell_through']),
        revenue: _dec(j['revenue']),
      );

  /// `size` or `color` from the wire; null for "one size" / no colour.
  final String? label;
  final Decimal received;
  final Decimal sold;
  final Decimal onHand;

  /// `sold / received`, 0..1 (can exceed 1 only if stock arrived off-book).
  final Decimal sellThrough;
  final Decimal revenue;
}

class SizeCurveTotals {
  const SizeCurveTotals({
    required this.received,
    required this.sold,
    required this.onHand,
    required this.revenue,
  });

  factory SizeCurveTotals.fromJson(Map<String, dynamic> j) => SizeCurveTotals(
        received: _dec(j['received']),
        sold: _dec(j['sold']),
        onHand: _dec(j['on_hand']),
        revenue: _dec(j['revenue']),
      );

  final Decimal received;
  final Decimal sold;
  final Decimal onHand;
  final Decimal revenue;
}

/// GET /v1/reports/size-curve (§14.1).
class SizeCurveReport {
  const SizeCurveReport({
    required this.styleId,
    required this.styleName,
    required this.brand,
    required this.sizes,
    required this.colors,
    required this.totals,
  });

  factory SizeCurveReport.fromJson(Map<String, dynamic> j) {
    final style = (j['style'] as Map<String, dynamic>?) ?? const {};
    return SizeCurveReport(
      styleId: (style['id'] as String?) ?? '',
      styleName: (style['name'] as String?) ?? '',
      brand: style['brand'] as String?,
      // Server order is the style's `size_set` preset order (the same run
      // order `size_presets.dart` uses), so it is rendered as received.
      sizes: _rows(j['sizes'])
          .map((r) => SizeCurveRow.fromJson(r, key: 'size'))
          .toList(),
      colors: _rows(j['colors'])
          .map((r) => SizeCurveRow.fromJson(r, key: 'color'))
          .toList(),
      totals: SizeCurveTotals.fromJson(
        (j['totals'] as Map<String, dynamic>?) ?? const {},
      ),
    );
  }

  final String styleId;
  final String styleName;
  final String? brand;
  final List<SizeCurveRow> sizes;
  final List<SizeCurveRow> colors;
  final SizeCurveTotals totals;

  /// Nothing was ever bought for this style — the curve has nothing to draw.
  bool get isEmpty => sizes.isEmpty && colors.isEmpty;
}

/// One variant that has been sitting unsold (§14.2).
class DeadStockItem {
  const DeadStockItem({
    required this.productId,
    required this.name,
    required this.stock,
    required this.ageDays,
    required this.unitCost,
    required this.value,
    this.styleId,
    this.size,
    this.color,
    this.lastSoldAt,
  });

  factory DeadStockItem.fromJson(Map<String, dynamic> j) => DeadStockItem(
        productId: (j['product_id'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        styleId: j['style_id'] as String?,
        size: j['size'] as String?,
        color: j['color'] as String?,
        stock: _dec(j['stock']),
        ageDays: _int(j['age_days']),
        lastSoldAt: _date(j['last_sold_at']),
        // Cost fields need VIEW_COSTS; masked to "0" / omitted otherwise.
        unitCost: _dec(j['unit_cost']),
        value: _dec(j['value']),
      );

  final String productId;
  final String name;
  final String? styleId;
  final String? size;
  final String? color;
  final Decimal stock;

  /// Days since the oldest *open* lot arrived — the age of the stock that is
  /// actually on the shelf, not of the first ever receipt.
  final int ageDays;
  final DateTime? lastSoldAt;
  final Decimal unitCost;
  final Decimal value;
}

class DeadStockReport {
  const DeadStockReport({
    required this.days,
    required this.items,
    required this.totalValue,
    required this.hasMore,
  });

  factory DeadStockReport.fromJson(Map<String, dynamic> j) => DeadStockReport(
        days: _int(j['days']),
        items: _rows(j['items']).map(DeadStockItem.fromJson).toList(),
        totalValue: _dec(j['total_value']),
        hasMore: j['has_more'] == true,
      );

  final int days;
  final List<DeadStockItem> items;

  /// Money tied up across the *whole* result, not just the loaded page.
  final Decimal totalValue;

  /// More rows exist beyond the page we loaded; the card says so rather than
  /// paging endlessly — `total_value` is the number that matters here.
  final bool hasMore;
}

/// A depleted variant inside a broken run (§14.3).
class BrokenRunVariant {
  const BrokenRunVariant({
    required this.sold30d,
    this.size,
    this.color,
  });

  factory BrokenRunVariant.fromJson(Map<String, dynamic> j) =>
      BrokenRunVariant(
        size: j['size'] as String?,
        color: j['color'] as String?,
        sold30d: _dec(j['sold_30d']),
      );

  final String? size;
  final String? color;
  final Decimal sold30d;
}

/// GET /v1/reports/broken-runs (§14.3) — the rebuy list.
class BrokenRun {
  const BrokenRun({
    required this.styleId,
    required this.name,
    required this.variantCount,
    required this.inStockCount,
    required this.stockTotal,
    required this.missing,
    this.brand,
    this.imageUrl,
  });

  factory BrokenRun.fromJson(Map<String, dynamic> j) => BrokenRun(
        styleId: (j['style_id'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        brand: j['brand'] as String?,
        imageUrl: j['image_url'] as String?,
        variantCount: _int(j['variant_count']),
        inStockCount: _int(j['in_stock_count']),
        stockTotal: _dec(j['stock_total']),
        // Ordered by sold_30d descending: the sizes worth rebuying first.
        missing: _rows(j['missing']).map(BrokenRunVariant.fromJson).toList(),
      );

  final String styleId;
  final String name;
  final String? brand;
  final String? imageUrl;
  final int variantCount;
  final int inStockCount;
  final Decimal stockTotal;
  final List<BrokenRunVariant> missing;
}

/// GET /v1/reports/top-styles (§14.4).
class TopStyle {
  const TopStyle({
    required this.name,
    required this.quantity,
    required this.revenue,
    required this.profit,
    required this.variantCount,
    this.styleId,
    this.brand,
    this.imageUrl,
  });

  factory TopStyle.fromJson(Map<String, dynamic> j) => TopStyle(
        // Null for a plain product with no style — rolled up on its own so
        // nothing is hidden from the ranking.
        styleId: j['style_id'] as String?,
        name: (j['name'] as String?) ?? '',
        brand: j['brand'] as String?,
        imageUrl: j['image_url'] as String?,
        quantity: _dec(j['quantity']),
        revenue: _dec(j['revenue']),
        // Needs VIEW_COSTS; absent for everyone else.
        profit: _dec(j['profit']),
        variantCount: _int(j['variant_count']),
      );

  final String? styleId;
  final String name;
  final String? brand;
  final String? imageUrl;
  final Decimal quantity;
  final Decimal revenue;
  final Decimal profit;
  final int variantCount;
}

/// Variants with no sale in this many days count as dead stock. Two months
/// is one season's grace in Ethiopian apparel retail.
const deadStockDefaultDays = 60;

class BoutiqueReportsRepository {
  BoutiqueReportsRepository(this._dio);
  final Dio _dio;

  /// How many dead-stock rows the card loads. The report is a prompt, not a
  /// ledger: the owner acts on the worst offenders and on `total_value`,
  /// which the server computes over the whole result, so there is nothing to
  /// gain from paging the tail in behind it.
  static const deadStockPageSize = 10;

  Future<SizeCurveReport> sizeCurve(String styleId) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/v1/reports/size-curve',
      queryParameters: {'style_id': styleId},
    );
    return SizeCurveReport.fromJson(res.data ?? const {});
  }

  Future<DeadStockReport> deadStock({required int days}) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/v1/reports/dead-stock',
      queryParameters: {'days': days, 'limit': deadStockPageSize},
    );
    return DeadStockReport.fromJson(res.data ?? const {});
  }

  Future<List<BrokenRun>> brokenRuns() async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/v1/reports/broken-runs',
    );
    return _rows(res.data?['items']).map(BrokenRun.fromJson).toList();
  }

  Future<List<TopStyle>> topStyles(
    DashboardRange range, {
    int limit = 5,
  }) async {
    final (from, to) = dateWindow(range);
    final res = await _dio.get<Map<String, dynamic>>(
      '/v1/reports/top-styles',
      queryParameters: {'from': from, 'to': to, 'limit': limit},
    );
    return _rows(res.data?['items']).map(TopStyle.fromJson).toList();
  }
}

/// `[from, to)` in `YYYY-MM-DD` for a dashboard range. The window is
/// half-open (§14), so `to` is tomorrow and a 7-day range starts 6 days back:
/// that is exactly seven calendar days including today, which is what the
/// "7 days" chip on the reports screen promises.
(String, String) dateWindow(DashboardRange range) {
  final days = range == DashboardRange.month ? 30 : 7;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  return (
    _ymd(today.subtract(Duration(days: days - 1))),
    _ymd(today.add(const Duration(days: 1))),
  );
}

String _ymd(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

@Riverpod(keepAlive: true)
BoutiqueReportsRepository boutiqueReportsRepository(
  BoutiqueReportsRepositoryRef ref,
) =>
    BoutiqueReportsRepository(ref.watch(dioProvider));

@riverpod
Future<SizeCurveReport> sizeCurve(SizeCurveRef ref, String styleId) =>
    ref.watch(boutiqueReportsRepositoryProvider).sizeCurve(styleId);

@riverpod
Future<DeadStockReport> deadStock(DeadStockRef ref, {required int days}) =>
    ref.watch(boutiqueReportsRepositoryProvider).deadStock(days: days);

@riverpod
Future<List<BrokenRun>> brokenRuns(BrokenRunsRef ref) =>
    ref.watch(boutiqueReportsRepositoryProvider).brokenRuns();

@riverpod
Future<List<TopStyle>> topStyles(
  TopStylesRef ref, {
  DashboardRange range = DashboardRange.week,
}) =>
    ref.watch(boutiqueReportsRepositoryProvider).topStyles(range);
