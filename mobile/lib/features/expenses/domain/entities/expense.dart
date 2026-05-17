import 'package:decimal/decimal.dart';

const expenseCategories = <String>[
  'rent',
  'transport',
  'utilities',
  'salary',
  'supplies',
  'other',
];

class Expense {
  const Expense({
    required this.id,
    required this.shopId,
    required this.userId,
    required this.title,
    required this.amount,
    required this.category,
    required this.occurredAt,
    this.shiftId,
    this.description,
  });

  final String id;
  final String shopId;
  final String userId;
  final String? shiftId;
  final String title;
  final Decimal amount;
  final String category;
  final String? description;
  final DateTime occurredAt;
}
