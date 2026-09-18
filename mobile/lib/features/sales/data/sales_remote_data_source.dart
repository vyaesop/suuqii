import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';

import 'package:suuqii/features/sales/domain/entities/sale_return.dart';

/// `GET /v1/sales/{id}` (docs/19 §13.4): one sale with its lines and every
/// return so far. The cross-device fallback for the return sheet — a sale
/// rung up on phone A is not in phone B's local database.
class SalesRemoteDataSource {
  SalesRemoteDataSource(this._dio);
  final Dio _dio;

  /// Null when the server does not know the sale (404); other failures
  /// propagate so the UI can tell "offline" from "no such sale".
  Future<RemoteSale?> getSale(String saleId) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>('/v1/sales/$saleId');
      return RemoteSale.fromJson(res.data!);
    } on DioException catch (e) {
      if (e.response?.statusCode == 404) return null;
      rethrow;
    }
  }
}

class RemoteSale {
  const RemoteSale({
    required this.id,
    required this.shiftId,
    required this.userId,
    required this.subtotal,
    required this.discount,
    required this.total,
    required this.paymentMethod,
    required this.status,
    required this.occurredAt,
    required this.items,
    required this.returns,
  });

  factory RemoteSale.fromJson(Map<String, dynamic> j) => RemoteSale(
        id: j['id'] as String,
        shiftId: j['shift_id'] as String?,
        userId: j['user_id'] as String,
        subtotal: Decimal.parse(j['subtotal'] as String),
        discount: Decimal.parse((j['discount'] as String?) ?? '0'),
        total: Decimal.parse(j['total'] as String),
        paymentMethod: j['payment_method'] as String,
        status: j['status'] as String,
        occurredAt: DateTime.parse(j['occurred_at'] as String).toUtc(),
        items: [
          for (final raw in (j['items'] as List? ?? const []))
            RemoteSaleItem.fromJson((raw as Map).cast<String, dynamic>()),
        ],
        returns: [
          for (final raw in (j['returns'] as List? ?? const []))
            RemoteSaleReturn.fromJson((raw as Map).cast<String, dynamic>()),
        ],
      );

  final String id;
  final String? shiftId;
  final String userId;
  final Decimal subtotal;
  final Decimal discount;
  final Decimal total;
  final String paymentMethod;
  final String status;
  final DateTime occurredAt;
  final List<RemoteSaleItem> items;
  final List<RemoteSaleReturn> returns;
}

class RemoteSaleItem {
  const RemoteSaleItem({
    required this.id,
    required this.productId,
    required this.productNameSnapshot,
    required this.quantity,
    required this.unitPrice,
    required this.listPrice,
    required this.returnedQuantity,
  });

  factory RemoteSaleItem.fromJson(Map<String, dynamic> j) => RemoteSaleItem(
        id: j['id'] as String,
        productId: j['product_id'] as String,
        productNameSnapshot: j['product_name_snapshot'] as String,
        quantity: Decimal.parse(j['quantity'] as String),
        unitPrice: Decimal.parse(j['unit_price'] as String),
        listPrice: j['list_price'] == null
            ? null
            : Decimal.parse(j['list_price'] as String),
        returnedQuantity:
            Decimal.parse((j['returned_quantity'] as String?) ?? '0'),
      );

  final String id;
  final String productId;
  final String productNameSnapshot;
  final Decimal quantity;
  final Decimal unitPrice;
  final Decimal? listPrice;
  final Decimal returnedQuantity;
}

class RemoteSaleReturn {
  const RemoteSaleReturn({
    required this.id,
    required this.userId,
    required this.shiftId,
    required this.occurredAt,
    required this.refundAmount,
    required this.refundMethod,
    required this.exchangeSaleId,
    required this.reason,
    required this.note,
    required this.items,
  });

  factory RemoteSaleReturn.fromJson(Map<String, dynamic> j) => RemoteSaleReturn(
        id: j['id'] as String,
        userId: j['user_id'] as String? ?? '',
        shiftId: j['shift_id'] as String?,
        occurredAt: DateTime.parse(j['occurred_at'] as String).toUtc(),
        refundAmount: Decimal.parse(j['refund_amount'] as String),
        refundMethod: j['refund_method'] as String?,
        exchangeSaleId: j['exchange_sale_id'] as String?,
        reason: ReturnReason.fromWire(j['reason'] as String?),
        note: j['note'] as String?,
        items: [
          for (final raw in (j['items'] as List? ?? const []))
            RemoteSaleReturnItem.fromJson((raw as Map).cast<String, dynamic>()),
        ],
      );

  final String id;
  final String userId;
  final String? shiftId;
  final DateTime occurredAt;
  final Decimal refundAmount;
  final String? refundMethod;
  final String? exchangeSaleId;
  final ReturnReason? reason;
  final String? note;
  final List<RemoteSaleReturnItem> items;
}

class RemoteSaleReturnItem {
  const RemoteSaleReturnItem({
    required this.id,
    required this.saleItemId,
    required this.quantity,
    required this.condition,
    required this.unitPrice,
  });

  factory RemoteSaleReturnItem.fromJson(Map<String, dynamic> j) =>
      RemoteSaleReturnItem(
        id: j['id'] as String?,
        saleItemId: j['sale_item_id'] as String,
        quantity: Decimal.parse(j['quantity'] as String),
        condition: ReturnCondition.fromWire(j['condition'] as String?) ??
            ReturnCondition.resellable,
        unitPrice: Decimal.parse((j['unit_price'] as String?) ?? '0'),
      );

  /// The server's row id where it sends one. Null on older servers, in which
  /// case the cache derives a deterministic id instead — a random one would
  /// defeat `insertOrIgnore` and double the line on a second fetch.
  final String? id;

  final String saleItemId;
  final Decimal quantity;
  final ReturnCondition condition;

  /// Proportional credit per unit as the server computed it.
  final Decimal unitPrice;
}
