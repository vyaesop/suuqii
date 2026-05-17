import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:suuqii/core/http/dio_client.dart';

part 'dashboard_repository.g.dart';

enum DashboardRange { today, week, month }

String _rangeKey(DashboardRange r) => switch (r) {
      DashboardRange.today => 'today',
      DashboardRange.week => '7d',
      DashboardRange.month => '30d',
    };

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
  });

  final String range;
  final Decimal revenue;
  final Decimal profit;
  final Decimal expenses;
  final Decimal netProfit;
  final Decimal creditSales;
  final Decimal outstandingDebt;
  final List<LowStockItem> lowStock;
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

class DashboardRepository {
  DashboardRepository(this._dio);
  final Dio _dio;

  Future<DashboardSummary> fetch(DashboardRange range) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/v1/reports/dashboard',
      queryParameters: {'range': _rangeKey(range)},
    );
    final data = res.data!;
    final low = (data['low_stock'] as List? ?? <dynamic>[])
        .cast<Map<String, dynamic>>();
    return DashboardSummary(
      range: data['range'] as String,
      revenue: Decimal.parse(data['revenue'] as String),
      profit: Decimal.parse(data['profit'] as String),
      expenses: Decimal.parse(data['expenses'] as String),
      netProfit: Decimal.parse(data['net_profit'] as String),
      creditSales: Decimal.parse(data['credit_sales'] as String),
      outstandingDebt: Decimal.parse(data['outstanding_debt'] as String),
      lowStock: low
          .map(
            (j) => LowStockItem(
              id: j['id'] as String,
              name: j['name'] as String,
              stock: Decimal.parse(j['stock'] as String),
            ),
          )
          .toList(),
    );
  }
}

@Riverpod(keepAlive: true)
DashboardRepository dashboardRepository(DashboardRepositoryRef ref) =>
    DashboardRepository(ref.watch(dioProvider));

@riverpod
Future<DashboardSummary> dashboard(
  DashboardRef ref, {
  DashboardRange range = DashboardRange.today,
}) {
  return ref.watch(dashboardRepositoryProvider).fetch(range);
}
