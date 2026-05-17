import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';

import 'package:suuqii/features/expenses/domain/entities/expense.dart';

class ExpensesRemoteDataSource {
  ExpensesRemoteDataSource(this._dio);
  final Dio _dio;

  Future<List<Expense>> list({required String shopId}) async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/expenses');
    final items =
        (res.data?['items'] as List? ?? <dynamic>[]).cast<Map<String, dynamic>>();
    return items.map((j) => _fromJson(j, shopId: shopId)).toList();
  }

  Expense _fromJson(Map<String, dynamic> j, {required String shopId}) =>
      Expense(
        id: j['id'] as String,
        shopId: shopId,
        userId: j['user_id'] as String,
        shiftId: j['shift_id'] as String?,
        title: j['title'] as String,
        amount: Decimal.parse(j['amount'] as String),
        category: j['category'] as String,
        description: j['description'] as String?,
        occurredAt: DateTime.parse(j['occurred_at'] as String),
      );
}
