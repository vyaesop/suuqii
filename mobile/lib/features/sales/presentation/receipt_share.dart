import 'package:decimal/decimal.dart';
import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/features/sales/data/sales_repository.dart';

/// One line item of a shared plain-text receipt.
class ReceiptShareLine {
  const ReceiptShareLine({
    required this.name,
    required this.qty,
    required this.unitPrice,
    required this.lineTotal,
    this.unit = '',
    this.listPrice,
  });

  final String name;

  /// Pre-formatted quantity ("2", "2.50").
  final String qty;

  /// Sale unit ("kg", "pcs"); empty when unknown (e.g. snapshots of past
  /// sales, which only store name/qty/price).
  final String unit;
  final Decimal unitPrice;
  final Decimal lineTotal;

  /// Tag price when the line was haggled below it (docs/19 §6.6); the
  /// receipt then reads "x 1000 (was 1200)". Null = no line discount.
  final Decimal? listPrice;

  bool get hasLineDiscount => listPrice != null && listPrice! > unitPrice;
}

/// One returned line in the receipt's returns block.
class ReceiptReturnLine {
  const ReceiptReturnLine({
    required this.name,
    required this.qty,
    required this.credit,
  });
  final String name;
  final String qty;

  /// Credit this line earned; null when only the block total is known.
  final Decimal? credit;
}

/// The returns block of a receipt (docs/19 §6.5 step 5): what came back,
/// the credit it earned, and what was refunded. For an exchange receipt
/// [exchangeForSaleShort] names the original sale and the main lines are
/// the replacement items.
class ReceiptReturnsBlock {
  const ReceiptReturnsBlock({
    required this.lines,
    required this.credit,
    required this.refunded,
    this.exchangeForSaleShort,
  });
  final List<ReceiptReturnLine> lines;
  final Decimal credit;
  final Decimal refunded;
  final String? exchangeForSaleShort;

  bool get isExchange => exchangeForSaleShort != null;
}

/// Whole quantities render as "3", fractional as "2.50" — mirrors the
/// quantity formatting used across the sales screens.
String receiptQtyText(double qty) =>
    qty == qty.roundToDouble() ? qty.toInt().toString() : qty.toStringAsFixed(2);

/// Composes the localized plain-text receipt sent through the system share
/// sheet (WhatsApp/Telegram/SMS) or copied to the clipboard. Text-only by
/// design — no image/PDF rendering.
String composeReceiptShareText(
  BuildContext context, {
  required String saleId,
  required DateTime soldAt,
  required List<ReceiptShareLine> lines,
  required Decimal subtotal,
  required Decimal discount,
  required Decimal total,
  required String paymentLabel,
  String? shopName,
  Decimal? amountTendered,
  Decimal? changeDue,
  String? customerName,
  String? customerPhone,
  DateTime? dueDate,
  ReceiptReturnsBlock? returns,
}) {
  final l = context.l10n;
  final buf = StringBuffer();
  if (shopName != null && shopName.trim().isNotEmpty) {
    buf.writeln(shopName.trim());
  }
  buf
    ..writeln(l.receiptShareHeader(saleId.substring(0, 8)))
    ..writeln(context.dateTimeShort(soldAt.toLocal()));
  if (returns != null && returns.isExchange) {
    buf
      ..writeln(l.receiptShareExchangeFor(returns.exchangeForSaleShort!))
      ..writeln()
      ..writeln(l.receiptShareNewItems);
  } else {
    buf.writeln();
  }
  for (final line in lines) {
    buf.writeln(
      line.hasLineDiscount
          ? l.receiptShareLineWas(
              line.name,
              line.qty,
              line.unit,
              context.money(line.unitPrice),
              context.money(line.listPrice!),
              context.money(line.lineTotal),
            )
          : l.receiptShareLine(
              line.name,
              line.qty,
              line.unit,
              context.money(line.unitPrice),
              context.money(line.lineTotal),
            ),
    );
  }
  buf.writeln();
  if (discount > Decimal.zero) {
    buf.writeln(l.receiptShareSubtotal(context.money(subtotal)));
    // On an exchange the "discount" is the returned goods' credit; the
    // returns block below names it as such instead of as a markdown.
    if (returns == null || !returns.isExchange) {
      buf.writeln(l.receiptShareDiscount(context.money(discount)));
    }
  }
  buf
    ..writeln(l.receiptShareTotal(context.money(total)))
    ..writeln(l.receiptSharePayment(paymentLabel));
  if (amountTendered != null) {
    buf.writeln(l.receiptShareTendered(context.money(amountTendered)));
  }
  if (changeDue != null && changeDue > Decimal.zero) {
    buf.writeln(l.receiptShareChange(context.money(changeDue)));
  }
  if (customerName != null && customerName.isNotEmpty) {
    buf.writeln(l.receiptShareCustomer(customerName));
  }
  if (customerPhone != null && customerPhone.isNotEmpty) {
    buf.writeln(l.receiptSharePhone(customerPhone));
  }
  if (dueDate != null) {
    buf.writeln(l.receiptShareDue(context.dateShort(dueDate)));
  }
  if (returns != null && returns.lines.isNotEmpty) {
    buf
      ..writeln()
      ..writeln(l.receiptShareReturnsHeader);
    for (final line in returns.lines) {
      final credit = line.credit;
      buf.writeln(
        credit == null
            ? l.saleDetailReturnLine(line.qty, line.name)
            : l.receiptShareReturnLine(
                line.name,
                line.qty,
                context.money(credit),
              ),
      );
    }
    buf.writeln(l.receiptShareCredit(context.money(returns.credit)));
    if (returns.isExchange) {
      buf.writeln(l.receiptShareCustomerPaid(context.money(total)));
    }
    if (returns.refunded > Decimal.zero) {
      buf.writeln(l.receiptShareRefunded(context.money(returns.refunded)));
    }
  }
  buf
    ..writeln()
    ..writeln(l.receiptShareThanks);
  return buf.toString();
}

/// Opens the system share sheet with the plain-text [text].
Future<void> shareReceiptText(String text) => Share.share(text);

/// Builds the returns block for a past sale from its recorded returns, or
/// null when nothing came back.
ReceiptReturnsBlock? returnsBlockFor(SaleReceiptData data) {
  if (data.returns.isEmpty) return null;
  return ReceiptReturnsBlock(
    lines: [
      for (final r in data.returns)
        for (final item in r.items)
          ReceiptReturnLine(
            name: item.productName,
            qty: receiptQtyText(item.quantity),
            credit: item.creditTotal,
          ),
    ],
    credit: data.returns.fold(Decimal.zero, (a, r) => a + r.credit),
    refunded: data.refundedTotal,
  );
}

/// Composes and shares the receipt for a past sale loaded from the local
/// snapshot tables ([SaleReceiptData]); used by the recent-sales list and
/// the sale-detail screen. Snapshots store no unit, so lines omit it.
Future<void> shareSaleReceiptData(
  BuildContext context,
  SaleReceiptData data, {
  String? shopName,
}) {
  final l = context.l10n;
  final paymentLabel = switch (data.paymentMethod) {
    'cash' => l.receiptPaidCash,
    'mobile_money' => l.receiptPaidMobile,
    'credit' => l.receiptOnCredit,
    _ => data.paymentMethod,
  };
  final text = composeReceiptShareText(
    context,
    saleId: data.id,
    soldAt: data.occurredAt,
    shopName: shopName,
    lines: [
      for (final item in data.items)
        ReceiptShareLine(
          name: item.name,
          qty: receiptQtyText(item.quantity),
          unitPrice: item.unitPrice,
          lineTotal: item.lineTotal,
          listPrice: item.hasLineDiscount ? item.listPrice : null,
        ),
    ],
    subtotal: data.subtotal,
    discount: data.discount,
    total: data.total,
    paymentLabel: paymentLabel,
    returns: returnsBlockFor(data),
  );
  return shareReceiptText(text);
}
