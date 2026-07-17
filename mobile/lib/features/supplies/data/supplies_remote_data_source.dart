import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';

import 'package:suuqii/features/supplies/domain/entities/supply.dart';

class SuppliesRemoteDataSource {
  SuppliesRemoteDataSource(this._dio);
  final Dio _dio;

  Future<List<Supply>> list({required String shopId}) async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/supplies');
    final items = (res.data?['items'] as List? ?? <dynamic>[])
        .cast<Map<String, dynamic>>();
    return items.map((j) => _fromJson(j, shopId: shopId)).toList();
  }

  Supply _fromJson(Map<String, dynamic> j, {required String shopId}) => Supply(
        id: j['id'] as String,
        shopId: shopId,
        name: j['name'] as String,
        unit: j['unit'] as String,
        quantityOnHand: Decimal.parse(j['quantity_on_hand'] as String),
        reorderThreshold: Decimal.parse(j['reorder_threshold'] as String),
        costPerUnit: Decimal.parse(j['cost_per_unit'] as String),
        expiryDate: j['expiry_date'] == null
            ? null
            : DateTime.parse(j['expiry_date'] as String),
      );
}
