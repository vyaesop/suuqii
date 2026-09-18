import 'package:decimal/decimal.dart';

import 'package:suuqii/features/inventory/domain/entities/product.dart';

enum PaymentMethod { cash, mobileMoney, credit }

class CartLine {
  CartLine({required this.product, required this.qty, Decimal? unitPrice})
      : unitPrice = unitPrice ?? product.sellingPrice;

  final Product product;
  Decimal qty;

  /// What the customer is actually charged per unit. Defaults to the list
  /// price; a boutique cashier may haggle it down (docs/19 §6.6). Persisted
  /// as `sale_items.unit_price`, with the list price alongside so receipts
  /// and the price-leakage report can see the gap.
  final Decimal unitPrice;

  /// The product's selling price at the time the line was added — the
  /// "was" price on a haggled receipt.
  Decimal get listPrice => product.sellingPrice;

  /// Haggling floor (docs/19 §13.3): the explicit minimum when set, else the
  /// list price itself — with no floor configured, any discount at all is
  /// the owner's call.
  Decimal get floorPrice => product.minSellingPrice ?? product.sellingPrice;

  bool get hasLineDiscount => unitPrice < listPrice;

  /// True when this line needs the owner: below the explicit floor, or
  /// discounted at all when no floor is set. Mirrors the server's
  /// `_below_floor_items` exactly, so a sale that passes here is not
  /// bounced back later by sync.
  bool get isBelowFloor => unitPrice < floorPrice;

  Decimal get lineTotal => unitPrice * qty;
  Decimal get lineCost => product.purchasePrice * qty;

  CartLine copy({Decimal? qty, Decimal? unitPrice}) => CartLine(
        product: product,
        qty: qty ?? this.qty,
        unitPrice: unitPrice ?? this.unitPrice,
      );
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

  /// Lines a non-owner cannot sell without the owner's PIN.
  List<CartLine> get linesBelowFloor =>
      lines.where((l) => l.isBelowFloor).toList();

  Decimal qtyFor(String productId) {
    for (final line in lines) {
      if (line.product.id == productId) return line.qty;
    }
    return Decimal.zero;
  }

  List<CartLine> _copyLines() => lines.map((l) => l.copy()).toList();

  Cart add(Product p, {Decimal? qty}) {
    final next = _copyLines();
    final i = next.indexWhere((l) => l.product.id == p.id);
    final addQty = qty ?? Decimal.one;
    if (i >= 0) {
      next[i] = next[i].copy(qty: next[i].qty + addQty);
    } else {
      next.add(CartLine(product: p, qty: addQty));
    }
    return Cart(next, discount: discount);
  }

  Cart setQty(String productId, Decimal qty) {
    if (qty <= Decimal.zero) return remove(productId);
    final next = lines.map((l) {
      if (l.product.id == productId) return l.copy(qty: qty);
      return l.copy();
    }).toList();
    return Cart(next, discount: discount);
  }

  /// Negotiated price for one line. Negative prices are refused (the server
  /// rejects them as `invalid_payload`); zero is a legitimate giveaway.
  Cart setUnitPrice(String productId, Decimal unitPrice) {
    if (unitPrice < Decimal.zero) {
      throw ArgumentError.value(unitPrice, 'unitPrice', 'must not be negative');
    }
    final next = lines.map((l) {
      if (l.product.id == productId) return l.copy(unitPrice: unitPrice);
      return l.copy();
    }).toList();
    return Cart(next, discount: discount);
  }

  Cart remove(String productId) {
    final remaining =
        lines.where((l) => l.product.id != productId).map((l) => l.copy()).toList();
    return Cart(
      remaining,
      discount: remaining.isEmpty ? Decimal.zero : discount,
    );
  }

  Cart setDiscount(Decimal value) => Cart(
        _copyLines(),
        discount: value < Decimal.zero ? Decimal.zero : value,
      );
}
