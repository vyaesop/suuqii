import 'package:drift/drift.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/core/storage/tables/expenses_table.dart';
import 'package:suuqii/core/utils/money.dart';
import 'package:suuqii/features/expenses/domain/entities/expense.dart';

part 'expenses_dao.g.dart';

@DriftAccessor(tables: [ExpensesTable])
class ExpensesDao extends DatabaseAccessor<AppDatabase> with _$ExpensesDaoMixin {
  ExpensesDao(super.db);

  Stream<List<Expense>> watchAll({required String shopId}) {
    final q = select(expensesTable)
      ..where((t) => t.shopId.equals(shopId))
      ..where((t) => t.deletedAt.isNull())
      ..orderBy([
        (t) => OrderingTerm(expression: t.occurredAt, mode: OrderingMode.desc),
      ]);
    return q.watch().map((rows) => rows.map(_toDomain).toList());
  }

  Future<void> upsertAll(List<Expense> items) async {
    await batch((b) {
      for (final e in items) {
        b.insert(
          expensesTable,
          ExpensesTableCompanion.insert(
            id: e.id,
            shopId: e.shopId,
            userId: e.userId,
            shiftId: Value(e.shiftId),
            title: e.title,
            amount: santimFromDecimal(e.amount),
            category: Value(e.category),
            description: Value(e.description),
            occurredAt: e.occurredAt,
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  Expense _toDomain(ExpenseRow r) => Expense(
        id: r.id,
        shopId: r.shopId,
        userId: r.userId,
        shiftId: r.shiftId,
        title: r.title,
        amount: decimalFromSantim(r.amount),
        category: r.category,
        description: r.description,
        occurredAt: r.occurredAt,
      );
}
