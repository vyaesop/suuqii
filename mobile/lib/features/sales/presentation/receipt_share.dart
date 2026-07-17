import 'package:decimal/decimal.dart';
import 'package:flutter/widgets.dart';
import 'package:share_plus/share_plus.dart';

import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/formats.dart';

/// One line item of a shared plain-text receipt.
class ReceiptShareLine {
  const ReceiptShareLine({
    required this.name,
    required this.qty,
    required this.unitPrice,
    required this.lineTotal,
    this.unit = '',
  });

  final String name;

  /// Pre-formatted quantity ("2", "2.50").
  final String qty;

  /// Sale unit ("kg", "pcs"); empty when unknown (e.g. snapshots of past
  /// sales, which only store name/qty/price).
  final String unit;
  final Decimal unitPrice;
  final Decimal lineTotal;
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
}) {
  final l = context.l10n;
  final buf = StringBuffer();
  if (shopName != null && shopName.trim().isNotEmpty) {
    buf.writeln(shopName.trim());
  }
  buf
    ..writeln(l.receiptShareHeader(saleId.substring(0, 8)))
    ..writeln(context.dateTimeShort(soldAt.toLocal()))
    ..writeln();
  for (final line in lines) {
    buf.writeln(
      l.receiptShareLine(
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
    buf
      ..writeln(l.receiptShareSubtotal(context.money(subtotal)))
      ..writeln(l.receiptShareDiscount(context.money(discount)));
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
  buf
    ..writeln()
    ..writeln(l.receiptShareThanks);
  return buf.toString();
}

/// Opens the system share sheet with the plain-text [text].
Future<void> shareReceiptText(String text) => Share.share(text);
