import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';

import 'package:suuqii/features/debt/domain/entities/debt.dart';

class DebtsRemoteDataSource {
  DebtsRemoteDataSource(this._dio);
  final Dio _dio;

  Future<List<Debt>> list({required String shopId, String? status}) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/v1/debts',
      queryParameters: {if (status != null) 'status': status},
    );
    final items =
        (res.data?['items'] as List? ?? <dynamic>[]).cast<Map<String, dynamic>>();
    return items.map((j) => _fromJson(j, shopId: shopId)).toList();
  }

  Debt _fromJson(Map<String, dynamic> j, {required String shopId}) => Debt(
        id: j['id'] as String,
        shopId: shopId,
        customerName: j['customer_name'] as String,
        customerPhone: j['customer_phone'] as String?,
        amountOwed: Decimal.parse(j['amount_owed'] as String),
        amountPaid: Decimal.parse(j['amount_paid'] as String),
        dueDate: j['due_date'] == null
            ? null
            : DateTime.parse(j['due_date'] as String),
        status: debtStatusFrom(j['status'] as String),
      );
}
