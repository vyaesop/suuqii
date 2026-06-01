import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/core/storage/tables/debts_table.dart';
import 'package:suuqii/features/debt/domain/entities/debt.dart';

part 'debts_dao.g.dart';

@DriftAccessor(tables: [DebtsTable, DebtPaymentsTable])
class DebtsDao extends DatabaseAccessor<AppDatabase> with _$DebtsDaoMixin {
  DebtsDao(super.db);

  Stream<List<Debt>> watchAll({required String shopId, DebtStatus? status}) {
    final q = select(debtsTable)
      ..where((t) => t.shopId.equals(shopId))
      ..where((t) => t.deletedAt.isNull())
      ..orderBy([
        (t) => OrderingTerm(expression: t.createdAt, mode: OrderingMode.desc),
      ]);
    if (status != null) {
      q.where((t) => t.status.equals(debtStatusKey(status)));
    }
    return q.watch().map((rows) => rows.map(_toDomain).toList());
  }

  Future<Debt?> getById(String id) async {
    final r =
        await (select(debtsTable)..where((t) => t.id.equals(id))).getSingleOrNull();
    return r == null ? null : _toDomain(r);
  }

  Future<void> upsertAll(List<Debt> debts) async {
    await batch((b) {
      for (final d in debts) {
        b.insert(
          debtsTable,
          DebtsTableCompanion.insert(
            id: d.id,
            shopId: d.shopId,
            saleId: Value(d.saleId),
            customerName: d.customerName,
            customerPhone: Value(d.customerPhone),
            amountOwed: d.amountOwed.toDouble(),
            amountPaid: Value(d.amountPaid.toDouble()),
            dueDate: Value(d.dueDate),
            status: Value(debtStatusKey(d.status)),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  Stream<List<DebtPayment>> watchPayments(String debtId) {
    final q = select(debtPaymentsTable)
      ..where((t) => t.debtId.equals(debtId))
      ..orderBy([
        (t) => OrderingTerm(expression: t.paidAt, mode: OrderingMode.desc),
      ]);
    return q.watch().map(
          (rows) => rows
              .map(
                (r) => DebtPayment(
                  id: r.id,
                  debtId: r.debtId,
                  amount: Decimal.parse(r.amount.toString()),
                  paidAt: r.paidAt,
                  method: r.method,
                  note: r.note,
                ),
              )
              .toList(),
        );
  }

  Debt _toDomain(DebtRow r) => Debt(
        id: r.id,
        shopId: r.shopId,
        saleId: r.saleId,
        customerName: r.customerName,
        customerPhone: r.customerPhone,
        amountOwed: Decimal.parse(r.amountOwed.toString()),
        amountPaid: Decimal.parse(r.amountPaid.toString()),
        dueDate: r.dueDate,
        status: debtStatusFrom(r.status),
      );
}
