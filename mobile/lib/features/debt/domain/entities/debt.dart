import 'package:decimal/decimal.dart';

enum DebtStatus { open, partial, paid, writtenOff }

DebtStatus debtStatusFrom(String s) => switch (s) {
      'open' => DebtStatus.open,
      'partial' => DebtStatus.partial,
      'paid' => DebtStatus.paid,
      'written_off' => DebtStatus.writtenOff,
      _ => DebtStatus.open,
    };

String debtStatusKey(DebtStatus s) => switch (s) {
      DebtStatus.open => 'open',
      DebtStatus.partial => 'partial',
      DebtStatus.paid => 'paid',
      DebtStatus.writtenOff => 'written_off',
    };

class Debt {
  const Debt({
    required this.id,
    required this.shopId,
    required this.customerName,
    required this.amountOwed,
    required this.amountPaid,
    required this.status,
    this.saleId,
    this.customerPhone,
    this.dueDate,
  });

  final String id;
  final String shopId;
  final String? saleId;
  final String customerName;
  final String? customerPhone;
  final Decimal amountOwed;
  final Decimal amountPaid;
  final DateTime? dueDate;
  final DebtStatus status;

  Decimal get remaining => amountOwed - amountPaid;
  bool get isOverdue =>
      dueDate != null &&
      DateTime.now().isAfter(dueDate!) &&
      status != DebtStatus.paid;
}

class DebtPayment {
  const DebtPayment({
    required this.id,
    required this.debtId,
    required this.amount,
    required this.paidAt,
    required this.method,
    this.note,
  });

  final String id;
  final String debtId;
  final Decimal amount;
  final DateTime paidAt;
  final String method; // 'cash' | 'mobile_money'
  final String? note;
}
