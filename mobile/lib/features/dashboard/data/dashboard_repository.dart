import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suuqii/core/http/dio_client.dart';
import 'package:suuqii/features/auth/presentation/providers.dart';

part 'dashboard_repository.g.dart';

enum DashboardRange { today, week, month }

String _rangeKey(DashboardRange r) => switch (r) {
      DashboardRange.today => 'today',
      DashboardRange.week => '7d',
      DashboardRange.month => '30d',
    };

String _cacheKeyFor(DashboardRange r) =>
    'dashboard.snapshot.${_rangeKey(r)}';

class DashboardSummary {
  const DashboardSummary({
    required this.range,
    required this.revenue,
    required this.profit,
    required this.expenses,
    required this.netProfit,
    required this.creditSales,
    required this.outstandingDebt,
    required this.lowStock,
    required this.spoilageCost,
    this.fetchedAt,
    this.fromCache = false,
  });

  factory DashboardSummary.fromJson(
    Map<String, dynamic> data, {
    bool fromCache = false,
  }) {
    final low = (data['low_stock'] as List? ?? <dynamic>[])
        .cast<Map<String, dynamic>>();
    final fetchedAtRaw = data['fetched_at'] as String?;
    return DashboardSummary(
      range: data['range'] as String,
      revenue: Decimal.parse(data['revenue'] as String),
      profit: Decimal.parse(data['profit'] as String),
      expenses: Decimal.parse(data['expenses'] as String),
      netProfit: Decimal.parse(data['net_profit'] as String),
      creditSales: Decimal.parse(data['credit_sales'] as String),
      outstandingDebt: Decimal.parse(data['outstanding_debt'] as String),
      // Absent on cached snapshots written before the lots feature.
      spoilageCost:
          Decimal.parse((data['spoilage_cost'] as String?) ?? '0'),
      lowStock: low
          .map(
            (j) => LowStockItem(
              id: j['id'] as String,
              name: j['name'] as String,
              stock: Decimal.parse(j['stock'] as String),
            ),
          )
          .toList(),
      fetchedAt: fetchedAtRaw == null ? null : DateTime.parse(fetchedAtRaw),
      fromCache: fromCache,
    );
  }

  final String range;
  final Decimal revenue;
  final Decimal profit;
  final Decimal expenses;
  final Decimal netProfit;
  final Decimal creditSales;
  final Decimal outstandingDebt;
  final List<LowStockItem> lowStock;

  /// Waste line: units spoiled in the range, valued at lot cost at spoilage
  /// time. Already subtracted from [netProfit] server-side.
  final Decimal spoilageCost;

  /// When this snapshot was fetched from the server. Present on both live
  /// and cached results. UI can show "Updated 5 min ago" when offline.
  final DateTime? fetchedAt;

  /// True when the summary was loaded from the on-device cache because the
  /// network call failed. UI should show a small "Offline" indicator.
  final bool fromCache;

  Map<String, dynamic> toJson() => {
        'range': range,
        'revenue': revenue.toString(),
        'profit': profit.toString(),
        'expenses': expenses.toString(),
        'net_profit': netProfit.toString(),
        'credit_sales': creditSales.toString(),
        'outstanding_debt': outstandingDebt.toString(),
        'spoilage_cost': spoilageCost.toString(),
        'low_stock': lowStock
            .map(
              (l) => {
                'id': l.id,
                'name': l.name,
                'stock': l.stock.toString(),
              },
            )
            .toList(),
        'fetched_at':
            (fetchedAt ?? DateTime.now().toUtc()).toIso8601String(),
      };
}

class LowStockItem {
  const LowStockItem({
    required this.id,
    required this.name,
    required this.stock,
  });
  final String id;
  final String name;
  final Decimal stock;
}

class SalesSeriesPoint {
  const SalesSeriesPoint({
    required this.date,
    required this.revenue,
    required this.profit,
    required this.expenses,
    required this.saleCount,
  });
  final DateTime date;
  final Decimal revenue;
  final Decimal profit;
  final Decimal expenses;
  final int saleCount;
}

class TopProduct {
  const TopProduct({
    required this.productId,
    required this.name,
    required this.qtySold,
    required this.revenue,
    required this.profit,
  });
  final String productId;
  final String name;
  final Decimal qtySold;
  final Decimal revenue;
  final Decimal profit;
}

class PaymentMixSlice {
  const PaymentMixSlice({
    required this.method,
    required this.total,
    required this.count,
  });
  final String method;
  final Decimal total;
  final int count;
}

class DashboardRepository {
  DashboardRepository(this._dio, this._prefs);
  final Dio _dio;
  final SharedPreferences _prefs;

  /// Fetches the dashboard summary, transparently falling back to a cached
  /// snapshot if the network call fails. The live response is also written
  /// to cache so the next offline open is fast.
  Future<DashboardSummary> fetch(DashboardRange range) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        '/v1/reports/dashboard',
        queryParameters: {'range': _rangeKey(range)},
      );
      final summary = DashboardSummary.fromJson(res.data!).copyWithFetched();
      await _writeCache(range, summary);
      return summary;
    } catch (e) {
      final cached = _readCache(range);
      if (cached != null) return cached;
      rethrow;
    }
  }

  DashboardSummary? _readCache(DashboardRange range) {
    final raw = _prefs.getString(_cacheKeyFor(range));
    if (raw == null) return null;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      return DashboardSummary.fromJson(json, fromCache: true);
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeCache(
    DashboardRange range,
    DashboardSummary summary,
  ) async {
    await _prefs.setString(
      _cacheKeyFor(range),
      jsonEncode(summary.toJson()),
    );
  }

  Future<List<SalesSeriesPoint>> fetchSalesSeries(DashboardRange range) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/v1/reports/sales-series',
      queryParameters: {'range': _rangeKey(range)},
    );
    final series = (res.data!['series'] as List).cast<Map<String, dynamic>>();
    return series
        .map(
          (j) => SalesSeriesPoint(
            date: DateTime.parse(j['date'] as String),
            revenue: Decimal.parse(j['revenue'] as String),
            profit: Decimal.parse(j['profit'] as String),
            expenses: Decimal.parse(j['expenses'] as String),
            saleCount: j['sale_count'] as int,
          ),
        )
        .toList();
  }

  Future<List<TopProduct>> fetchTopProducts(
    DashboardRange range, {
    int limit = 10,
  }) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/v1/reports/top-products',
      queryParameters: {'range': _rangeKey(range), 'limit': limit},
    );
    final items = (res.data!['items'] as List).cast<Map<String, dynamic>>();
    return items
        .map(
          (j) => TopProduct(
            productId: j['product_id'] as String,
            name: j['name'] as String,
            qtySold: Decimal.parse(j['qty_sold'] as String),
            revenue: Decimal.parse(j['revenue'] as String),
            profit: Decimal.parse(j['profit'] as String),
          ),
        )
        .toList();
  }

  Future<List<PaymentMixSlice>> fetchPaymentMix(DashboardRange range) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/v1/reports/payment-mix',
      queryParameters: {'range': _rangeKey(range)},
    );
    final methods =
        (res.data!['methods'] as List).cast<Map<String, dynamic>>();
    return methods
        .map(
          (j) => PaymentMixSlice(
            method: j['method'] as String,
            total: Decimal.parse(j['total'] as String),
            count: j['count'] as int,
          ),
        )
        .toList();
  }
}

extension on DashboardSummary {
  DashboardSummary copyWithFetched() => DashboardSummary(
        range: range,
        revenue: revenue,
        profit: profit,
        expenses: expenses,
        netProfit: netProfit,
        creditSales: creditSales,
        outstandingDebt: outstandingDebt,
        lowStock: lowStock,
        spoilageCost: spoilageCost,
        fetchedAt: DateTime.now().toUtc(),
      );
}

@Riverpod(keepAlive: true)
Future<DashboardRepository> dashboardRepository(
  DashboardRepositoryRef ref,
) async {
  final prefs = await ref.watch(sharedPrefsProvider.future);
  return DashboardRepository(ref.watch(dioProvider), prefs);
}

@riverpod
Future<DashboardSummary> dashboard(
  DashboardRef ref, {
  DashboardRange range = DashboardRange.today,
}) async {
  final repo = await ref.watch(dashboardRepositoryProvider.future);
  return repo.fetch(range);
}

@riverpod
Future<List<SalesSeriesPoint>> salesSeries(
  SalesSeriesRef ref, {
  DashboardRange range = DashboardRange.week,
}) async {
  final repo = await ref.watch(dashboardRepositoryProvider.future);
  return repo.fetchSalesSeries(range);
}

@riverpod
Future<List<TopProduct>> topProducts(
  TopProductsRef ref, {
  DashboardRange range = DashboardRange.week,
}) async {
  final repo = await ref.watch(dashboardRepositoryProvider.future);
  return repo.fetchTopProducts(range);
}

@riverpod
Future<List<PaymentMixSlice>> paymentMix(
  PaymentMixRef ref, {
  DashboardRange range = DashboardRange.week,
}) async {
  final repo = await ref.watch(dashboardRepositoryProvider.future);
  return repo.fetchPaymentMix(range);
}
