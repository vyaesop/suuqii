import 'package:decimal/decimal.dart';

import 'package:suuqii/core/utils/money.dart';

/// Wire vocabulary of `sale.return` (docs/19 §13.3). Kept as enums so a typo
/// cannot reach the payload; [wire] is the exact server string.
enum ReturnCondition {
  resellable('resellable'),
  damaged('damaged');

  const ReturnCondition(this.wire);
  final String wire;

  static ReturnCondition? fromWire(String? value) {
    for (final c in values) {
      if (c.wire == value) return c;
    }
    return null;
  }
}

enum ReturnReason {
  wrongSize('wrong_size'),
  defect('defect'),
  changedMind('changed_mind'),
  other('other');

  const ReturnReason(this.wire);
  final String wire;

  static ReturnReason? fromWire(String? value) {
    for (final r in values) {
      if (r.wire == value) return r;
    }
    return null;
  }
}

/// Money handed back on a return. `null` on the wire when the whole credit
/// was netted into an exchange.
enum RefundMethod {
  cash('cash'),
  mobileMoney('mobile_money');

  const RefundMethod(this.wire);
  final String wire;
}

/// One line the customer brings back.
class ReturnLine {
  const ReturnLine({
    required this.saleItemId,
    required this.quantity,
    required this.condition,
  });

  final String saleItemId;
  final Decimal quantity;
  final ReturnCondition condition;
}

/// The per-unit credit rule of docs/19 §13.3, shared by the repository (what
/// is written), the reconciler (what other devices wrote) and the return
/// sheet (what the cashier is shown), so all three agree to the santim.
///
/// The sale-level discount is shared proportionally across lines. An
/// exchange carries the returned goods' credit as the replacement sale's
/// `discount`; that money was really paid (on the original sale), so it is
/// added back into `effectiveTotal` before the ratio — otherwise returning
/// the replacement would credit only the cash top-up.
class ReturnCreditCalculator {
  const ReturnCreditCalculator({
    required this.subtotalSantim,
    required this.effectiveTotalSantim,
  });

  /// `sale.subtotal`, int64 santim.
  final int subtotalSantim;

  /// `sale.total + Σ credit of returns whose exchange_sale_id is this sale`.
  final int effectiveTotalSantim;

  /// Whether the discount is shared at all: `ratio = min(1, effective /
  /// subtotal)` is exactly 1 when the customer paid the full subtotal (or
  /// more, after exchange credit is added back) or the sale had no subtotal.
  bool get _fullCredit =>
      subtotalSantim <= 0 || effectiveTotalSantim >= subtotalSantim;

  /// Credit per returned unit for a line sold at [unitPriceSantim]:
  /// `unit_price × ratio`, rounded half away from zero to the santim
  /// (Python's ROUND_HALF_UP for positive money). Pure integer arithmetic —
  /// no binary floating point in between.
  int creditUnitSantim(int unitPriceSantim) {
    if (_fullCredit) return unitPriceSantim;
    final numerator =
        BigInt.from(unitPriceSantim) * BigInt.from(effectiveTotalSantim);
    final denominator = BigInt.from(subtotalSantim);
    // floor((2n + d) / 2d) == round-half-up(n / d) for non-negative n, d.
    return ((numerator * BigInt.two + denominator) ~/
            (denominator * BigInt.two))
        .toInt();
  }

  /// `Σ qty × credit_unit`, rounded to the santim once at the end, like the
  /// server's `credit_total.quantize(_CENT)`.
  int creditTotalSantim(
    Iterable<({int unitPriceSantim, Decimal quantity})> lines,
  ) {
    var total = Decimal.zero;
    for (final line in lines) {
      total += line.quantity *
          decimalFromSantim(creditUnitSantim(line.unitPriceSantim));
    }
    return santimFromDecimal(total);
  }
}

/// The pending half of an exchange while the cashier rings up the new items
/// (docs/19 §6.5 step 3). Lives in the exchange-mode provider until checkout
/// submits sale + return together, or the cashier cancels.
class ExchangeContext {
  const ExchangeContext({
    required this.originalSaleId,
    required this.items,
    required this.reason,
    required this.credit,
    this.note,
    this.itemNames = const {},
  });

  final String originalSaleId;
  final List<ReturnLine> items;

  /// `sale_item_id` → product name snapshot, for the receipt's returns block.
  final Map<String, String> itemNames;
  final ReturnReason reason;
  final String? note;

  /// Credit for the returned lines, birr. Becomes the replacement sale's
  /// `discount` (capped at its subtotal); any excess is refunded.
  final Decimal credit;

  /// Short reference shown in the cart bar banner ("#abcd1234").
  String get originalSaleShort => originalSaleId.length > 8
      ? originalSaleId.substring(0, 8)
      : originalSaleId;

  /// How the replacement nets against the credit for a cart of [subtotal].
  ExchangeSettlement settle(Decimal subtotal) {
    final applied = credit < subtotal ? credit : subtotal;
    return ExchangeSettlement(
      creditApplied: applied,
      customerPays: subtotal - applied,
      refund: credit - applied,
    );
  }
}

class ExchangeSettlement {
  const ExchangeSettlement({
    required this.creditApplied,
    required this.customerPays,
    required this.refund,
  });

  /// The replacement sale's `discount`.
  final Decimal creditApplied;

  /// The replacement sale's `total` — what changes hands, if anything.
  final Decimal customerPays;

  /// `max(0, credit − new subtotal)` — the return's `refund_amount`.
  final Decimal refund;

  bool get isEven => customerPays == Decimal.zero && refund == Decimal.zero;
}

/// Outcome of `SalesRepository.submitReturn` / `submitExchange`.
class SaleReturnResult {
  const SaleReturnResult({
    required this.returnId,
    required this.credit,
    required this.refundAmount,
    this.exchangeSaleId,
  });

  final String returnId;
  final Decimal credit;
  final Decimal refundAmount;
  final String? exchangeSaleId;
}

/// A return the repository refused before writing anything. [code] mirrors
/// the server's `DomainError.code` so the UI maps both the same way.
class SaleReturnException implements Exception {
  const SaleReturnException(this.code, this.message);

  /// `not_found` | `already_refunded` | `return_exceeds_sold` |
  /// `invalid_payload`.
  final String code;
  final String message;

  @override
  String toString() => 'SaleReturnException($code): $message';
}

/// A non-owner tried to sell below the floor without the owner's PIN. The
/// POS turns this into the PIN prompt (docs/19 §6.6); the server would
/// otherwise reject the event with `below_price_floor` after the fact.
class BelowPriceFloorException implements Exception {
  const BelowPriceFloorException(this.productNames);

  final List<String> productNames;

  @override
  String toString() =>
      'BelowPriceFloorException: ${productNames.join(', ')} priced below floor';
}
