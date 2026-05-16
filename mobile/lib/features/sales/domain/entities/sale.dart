import 'package:decimal/decimal.dart';

import '../../../inventory/domain/entities/product.dart';

enum PaymentMethod { cash, mobileMoney, credit }

class CartLine {
  CartLine({required this.product, required this.qty});
  final Product product;
  Decimal qty;
  Decimal get lineTotal => product.sellingPrice * qty;
  Decimal get lineCost => product.purchasePrice * qty;
}

class Cart {
  Cart(this.lines);
  Cart.empty() : lines = const [];
  final List<CartLine> lines;

  bool get isEmpty => lines.isEmpty;
  bool get isNotEmpty => lines.isNotEmpty;
  int get itemCount => lines.length;

  Decimal get total => lines.fold(Decimal.zero, (a, b) => a + b.lineTotal);
  Decimal get costTotal => lines.fold(Decimal.zero, (a, b) => a + b.lineCost);

  Cart add(Product p, {Decimal? qty}) {
    final next = lines.map((l) => CartLine(product: l.product, qty: l.qty)).toList();
    final i = next.indexWhere((l) => l.product.id == p.id);
    final addQty = qty ?? Decimal.one;
    if (i >= 0) {
      next[i] = CartLine(product: next[i].product, qty: next[i].qty + addQty);
    } else {
      next.add(CartLine(product: p, qty: addQty));
    }
    return Cart(next);
  }

  Cart setQty(String productId, Decimal qty) {
    if (qty <= Decimal.zero) return remove(productId);
    final next = lines.map((l) {
      if (l.product.id == productId) {
        return CartLine(product: l.product, qty: qty);
      }
      return CartLine(product: l.product, qty: l.qty);
    }).toList();
    return Cart(next);
  }

  Cart remove(String productId) =>
      Cart(lines.where((l) => l.product.id != productId).toList());
}
