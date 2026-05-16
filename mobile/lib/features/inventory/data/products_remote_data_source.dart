import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';

import '../domain/entities/product.dart';

class ProductsRemoteDataSource {
  ProductsRemoteDataSource(this._dio);
  final Dio _dio;

  Future<List<Product>> list({String? shopId}) async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/products');
    final items = (res.data?['items'] as List? ?? []).cast<Map<String, dynamic>>();
    return items.map((j) => _fromJson(j, shopId: shopId ?? '')).toList();
  }

  Product _fromJson(Map<String, dynamic> j, {required String shopId}) => Product(
        id: j['id'] as String,
        shopId: shopId,
        name: j['name'] as String,
        category: j['category'] as String?,
        purchasePrice: Decimal.parse(j['purchase_price'] as String),
        sellingPrice: Decimal.parse(j['selling_price'] as String),
        stock: Decimal.parse(j['stock'] as String),
        lowStockThreshold: Decimal.parse(j['low_stock_threshold'] as String),
        unit: j['unit'] as String? ?? 'piece',
        barcode: j['barcode'] as String?,
        imageUrl: j['image_url'] as String?,
        clientUpdatedAt: j['client_updated_at'] == null
            ? null
            : DateTime.parse(j['client_updated_at'] as String),
      );
}
