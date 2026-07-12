import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';

import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/core/storage/tables/supplies_table.dart';
import 'package:suuqii/core/utils/money.dart';
import 'package:suuqii/features/inventory/domain/entities/stock_lot.dart'
    show expiryDateString;
import 'package:suuqii/features/supplies/domain/entities/supply.dart';

part 'supplies_dao.g.dart';

@DriftAccessor(tables: [SuppliesTable])
class SuppliesDao extends DatabaseAccessor<AppDatabase> with _$SuppliesDaoMixin {
  SuppliesDao(super.db);

  Stream<List<Supply>> watchAll({required String shopId}) {
    return (select(suppliesTable)
          ..where((t) => t.shopId.equals(shopId))
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .watch()
        .map((rows) => rows.map(_toDomain).toList());
  }

  Future<Supply?> getById(String id) async {
    final r = await (select(suppliesTable)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return r == null ? null : _toDomain(r);
  }

  Future<List<Supply>> getAllByShop(String shopId) async {
    final rows = await (select(suppliesTable)
          ..where((t) => t.shopId.equals(shopId))
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .get();
    return rows.map(_toDomain).toList();
  }

  Future<void> upsertAll(List<Supply> items) async {
    await batch((b) {
      for (final s in items) {
        b.insert(
          suppliesTable,
          SuppliesTableCompanion.insert(
            id: s.id,
            shopId: s.shopId,
            name: s.name,
            unit: Value(s.unit),
            quantityOnHand: Value(s.quantityOnHand.toDouble()),
            reorderThreshold: Value(s.reorderThreshold.toDouble()),
            costPerUnit: Value(santimFromDecimal(s.costPerUnit)),
            expiryDate: Value(
              s.expiryDate == null ? null : expiryDateString(s.expiryDate!),
            ),
          ),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  /// Returns the unit string for a supply without loading the full row.
  Future<String?> getUnit(String id) async {
    final rows = await customSelect(
      'SELECT unit FROM supplies WHERE id = ? LIMIT 1',
      variables: [Variable.withString(id)],
      readsFrom: {suppliesTable},
    ).get();
    return rows.isEmpty ? null : rows.first.read<String>('unit');
  }

  Future<void> applyDelta(String id, Decimal delta) => customUpdate(
        'UPDATE supplies SET quantity_on_hand = quantity_on_hand + ?, '
        'updated_at = ? WHERE id = ?',
        variables: [
          Variable.withReal(delta.toDouble()),
          Variable.withInt(sqliteDateTimeParam(DateTime.now())),
          Variable.withString(id),
        ],
        updates: {suppliesTable},
        updateKind: UpdateKind.update,
      );

  Supply _toDomain(SupplyRow r) => Supply(
        id: r.id,
        shopId: r.shopId,
        name: r.name,
        unit: r.unit,
        quantityOnHand: Decimal.parse(r.quantityOnHand.toString()),
        reorderThreshold: Decimal.parse(r.reorderThreshold.toString()),
        costPerUnit: decimalFromSantim(r.costPerUnit),
        expiryDate: r.expiryDate == null ? null : DateTime.parse(r.expiryDate!),
        deletedAt: r.deletedAt,
      );
}
