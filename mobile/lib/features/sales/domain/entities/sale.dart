import 'package:decimal/decimal.dart';

import 'package:suuqii/features/inventory/domain/entities/product.dart';

enum PaymentMethod { cash, mobileMoney, credit }

class CartLine {
  CartLine({required this.product, required this.qty});
  final Product product;
  Decimal qty;
  Decimal get lineTotal => product.sellingPrice * qty;
  Decimal get lineCost => product.purchasePrice * qty;
}

class Cart {
  Cart(this.lines, {Decimal? discount}) : discount = discount ?? Decimal.zero;
  Cart.empty()
      : lines = const [],
        discount = Decimal.zero;
  final List<CartLine> lines;

  /// Whole-cart discount in money units (ETB). Applied to subtotal at
  /// checkout time; stored on the Sale.discount column server-side.
  final Decimal discount;

  bool get isEmpty => lines.isEmpty;
  bool get isNotEmpty => lines.isNotEmpty;
  int get lineCount => lines.length;
  Decimal get itemCount => lines.fold(Decimal.zero, (a, b) => a + b.qty);

  Decimal get subtotal => lines.fold(Decimal.zero, (a, b) => a + b.lineTotal);
  Decimal get total {
    final t = subtotal - discount;
    return t < Decimal.zero ? Decimal.zero : t;
  }

  Decimal get costTotal => lines.fold(Decimal.zero, (a, b) => a + b.lineCost);

  Decimal qtyFor(String productId) {
    for (final line in lines) {
      if (line.product.id == productId) return line.qty;
    }
    return Decimal.zero;
  }

  Cart add(Product p, {Decimal? qty}) {
    final next =
        lines.map((l) => CartLine(product: l.product, qty: l.qty)).toList();
    final i = next.indexWhere((l) => l.product.id == p.id);
    final addQty = qty ?? Decimal.one;
    if (i >= 0) {
      next[i] = CartLine(product: next[i].product, qty: next[i].qty + addQty);
    } else {
      next.add(CartLine(product: p, qty: addQty));
    }
    return Cart(next, discount: discount);
  }

  Cart setQty(String productId, Decimal qty) {
    if (qty <= Decimal.zero) return remove(productId);
    final next = lines.map((l) {
      if (l.product.id == productId) {
        return CartLine(product: l.product, qty: qty);
      }
      return CartLine(product: l.product, qty: l.qty);
    }).toList();
    return Cart(next, discount: discount);
  }

  Cart remove(String productId) {
    final remaining = lines
        .where((l) => l.product.id != productId)
        .map((l) => CartLine(product: l.product, qty: l.qty))
        .toList();
    return Cart(
      remaining,
      discount: remaining.isEmpty ? Decimal.zero : discount,
    );
  }

  Cart setDiscount(Decimal value) => Cart(
        lines.map((l) => CartLine(product: l.product, qty: l.qty)).toList(),
        discount: value < Decimal.zero ? Decimal.zero : value,
      );
}
