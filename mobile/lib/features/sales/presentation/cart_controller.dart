import 'package:decimal/decimal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../inventory/domain/entities/product.dart';
import '../data/sales_repository.dart';
import '../domain/entities/sale.dart';

part 'cart_controller.g.dart';

@riverpod
class CartController extends _$CartController {
  @override
  Cart build() => Cart.empty();

  void addProduct(Product p, {Decimal? qty}) {
    state = state.add(p, qty: qty);
  }

  void setQty(String productId, Decimal qty) {
    state = state.setQty(productId, qty);
  }

  void remove(String productId) {
    state = state.remove(productId);
  }

  void clear() {
    state = Cart.empty();
  }

  Future<String> checkout({
    required PaymentMethod paymentMethod,
    String? customerName,
    String? customerPhone,
    DateTime? dueDate,
  }) async {
    final repo = ref.read(salesRepositoryProvider);
    final saleId = await repo.submit(
      cart: state,
      paymentMethod: paymentMethod,
      customerName: customerName,
      customerPhone: customerPhone,
      dueDate: dueDate,
    );
    clear();
    return saleId;
  }
}
