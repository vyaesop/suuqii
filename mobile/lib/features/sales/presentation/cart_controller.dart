import 'package:decimal/decimal.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/sales/data/sales_repository.dart';
import 'package:suuqii/features/sales/domain/entities/sale.dart';
import 'package:suuqii/features/sales/domain/entities/sale_return.dart';

part 'cart_controller.g.dart';

@riverpod
class CartController extends _$CartController {
  @override
  Cart build() {
    // Same reasoning as ExchangeMode: logout and shop switching wipe the
    // local database, and a cart still holding the previous shop's products
    // would fail its stock checks on checkout.
    ref.watch(
      authControllerProvider.select((auth) {
        final value = auth.valueOrNull;
        return value is Authenticated ? value.shopId : null;
      }),
    );
    return Cart.empty();
  }

  void addProduct(Product p, {Decimal? qty}) {
    state = state.add(p, qty: qty);
  }

  void setQty(String productId, Decimal qty) {
    state = state.setQty(productId, qty);
  }

  /// Haggled price for one line (docs/19 §6.6). Whether it needs the owner's
  /// PIN is decided at checkout from `Cart.linesBelowFloor`.
  void setUnitPrice(String productId, Decimal unitPrice) {
    state = state.setUnitPrice(productId, unitPrice);
  }

  void remove(String productId) {
    state = state.remove(productId);
  }

  void clear() {
    state = Cart.empty();
  }

  void setDiscount(Decimal value) {
    state = state.setDiscount(value);
  }

  Future<String> checkout({
    required PaymentMethod paymentMethod,
    String? customerName,
    String? customerPhone,
    DateTime? dueDate,
    String? ownerChallengeToken,
  }) async {
    final repo = ref.read(salesRepositoryProvider);
    final saleId = await repo.submit(
      cart: state,
      paymentMethod: paymentMethod,
      customerName: customerName,
      customerPhone: customerPhone,
      dueDate: dueDate,
      ownerChallengeToken: ownerChallengeToken,
    );
    clear();
    return saleId;
  }

  /// Exchange checkout: the cart holds the replacement items, [exchange] the
  /// returned ones. One local transaction writes the new sale and the
  /// return (docs/19 §13.3 "Exchange").
  ///
  /// The two events carry two distinct owner challenges — the token is
  /// single-use server-side (see [SalesRepository.submitExchange]).
  Future<SaleReturnResult> checkoutExchange({
    required ExchangeContext exchange,
    required PaymentMethod paymentMethod,
    required RefundMethod refundMethod,
    String? ownerChallengeToken,
    String? returnOwnerChallengeToken,
  }) async {
    final repo = ref.read(salesRepositoryProvider);
    final result = await repo.submitExchange(
      originalSaleId: exchange.originalSaleId,
      returnItems: exchange.items,
      reason: exchange.reason,
      note: exchange.note,
      cart: state,
      paymentMethod: paymentMethod,
      refundMethod: refundMethod,
      ownerChallengeToken: ownerChallengeToken,
      returnOwnerChallengeToken: returnOwnerChallengeToken,
    );
    clear();
    return result;
  }
}
