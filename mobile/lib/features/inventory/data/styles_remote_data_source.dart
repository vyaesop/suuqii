import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';

import 'package:suuqii/features/inventory/domain/entities/style.dart';

/// `GET /v1/styles` (docs/19 §13.4): keyset-paginated on `(name, id)`.
/// `default_purchase_price` is "0" unless the caller has VIEW_COSTS; stored
/// as-is, the owner-only UI is the only place that shows it.
class StylesRemoteDataSource {
  StylesRemoteDataSource(this._dio);
  final Dio _dio;

  static const _pageSize = 200;

  Future<List<Style>> list({required String shopId}) async {
    final out = <Style>[];
    String? cursor;
    // Bounded loop: a boutique has a few hundred styles at most, and the
    // guard keeps a misbehaving server from spinning us forever.
    for (var page = 0; page < 50; page++) {
      final res = await _dio.get<Map<String, dynamic>>(
        '/v1/styles',
        queryParameters: {
          'limit': _pageSize,
          if (cursor != null) 'cursor': cursor,
        },
      );
      final data = res.data ?? const <String, dynamic>{};
      final items =
          (data['items'] as List? ?? const []).cast<Map<String, dynamic>>();
      out.addAll(items.map((j) => _fromJson(j, shopId: shopId)));
      final hasMore = data['has_more'] == true;
      cursor = data['next_cursor'] as String?;
      if (!hasMore || cursor == null) break;
    }
    return out;
  }

  Style _fromJson(Map<String, dynamic> j, {required String shopId}) => Style(
        id: j['id'] as String,
        shopId: shopId,
        name: j['name'] as String,
        brand: j['brand'] as String?,
        category: j['category'] as String?,
        segment: j['segment'] as String?,
        imageUrl: j['image_url'] as String?,
        defaultSellingPrice:
            Decimal.parse((j['default_selling_price'] as String?) ?? '0'),
        // Masked to "0" (or omitted) for non-owners.
        defaultPurchasePrice:
            Decimal.parse((j['default_purchase_price'] as String?) ?? '0'),
        sizeSet: j['size_set'] as String?,
        skuPrefix: j['sku_prefix'] as String?,
        clientUpdatedAt: j['client_updated_at'] == null
            ? null
            : DateTime.parse(j['client_updated_at'] as String),
      );
}
