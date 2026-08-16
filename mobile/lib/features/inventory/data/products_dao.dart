import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';

import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/core/storage/tables/products_table.dart';
import 'package:suuqii/core/utils/ethiopic.dart';
import 'package:suuqii/core/utils/money.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';

part 'products_dao.g.dart';

@DriftAccessor(tables: [ProductsTable])
class ProductsDao extends DatabaseAccessor<AppDatabase>
    with _$ProductsDaoMixin {
  ProductsDao(super.db);

  Stream<List<Product>> watchAll({
    required String shopId,
    String? query,
    String? category,
  }) {
    final q = select(productsTable)
      ..where((t) => t.shopId.equals(shopId))
      ..where((t) => t.deletedAt.isNull())
      ..orderBy([(t) => OrderingTerm.asc(t.name)]);
    if (category != null && category.isNotEmpty) {
      q.where((t) => t.category.equals(category));
    }
    // Name matching happens in Dart, not SQL LIKE: Amharic homophone letters
    // (ሰ/ሠ, ሀ/ሐ/ኀ, …) must match across spellings, which needs foldForSearch
    // on both sides. Result sets are shop-sized, so this stays cheap.
    var stream = q.watch();
    if (query != null && query.trim().isNotEmpty) {
      final needle = foldForSearch(query.trim());
      stream = stream.map(
        (rows) =>
            rows.where((r) => foldForSearch(r.name).contains(needle)).toList(),
      );
    }
    return stream.map((rows) => rows.map(_toDomain).toList());
  }

  Future<Product?> getById(String id) async {
    final r = await (select(productsTable)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return r == null ? null : _toDomain(r);
  }

  Stream<Product?> watchById(String id) {
    return (select(productsTable)..where((t) => t.id.equals(id)))
        .watchSingleOrNull()
        .map((r) => r == null ? null : _toDomain(r));
  }

  Future<void> upsertAll(List<Product> products) async {
    final now = DateTime.now();
    await batch((b) {
      for (final p in products) {
        // DoUpdate (instead of insertOrReplace) so columns absent from the
        // companion — notably created_at — keep their existing values on
        // conflict rather than being reset to defaults.
        b.insert(
          productsTable,
          _fromDomain(p),
          onConflict: DoUpdate(
            (_) => _fromDomain(p).copyWith(updatedAt: Value(now)),
          ),
        );
      }
    });
  }

  /// Local-only stock delta. customUpdate (not customStatement) so watching
  /// streams refresh after the change.
  Future<void> applyStockDelta(String productId, Decimal delta) => customUpdate(
        'UPDATE products SET stock = stock + ?, updated_at = ? WHERE id = ?',
        variables: [
          Variable.withReal(delta.toDouble()),
          Variable.withInt(sqliteDateTimeParam(DateTime.now())),
          Variable.withString(productId),
        ],
        updates: {productsTable},
        updateKind: UpdateKind.update,
      );

  Product _toDomain(ProductRow r) => Product(
        id: r.id,
        shopId: r.shopId,
        name: r.name,
        category: r.category,
        purchasePrice: decimalFromSantim(r.purchasePrice),
        sellingPrice: decimalFromSantim(r.sellingPrice),
        stock: Decimal.parse(r.stock.toString()),
        lowStockThreshold: Decimal.parse(r.lowStockThreshold.toString()),
        unit: r.unit,
        barcode: r.barcode,
        imageUrl: r.imageUrl,
        clientUpdatedAt: r.clientUpdatedAt,
      );

  ProductsTableCompanion _fromDomain(Product p) => ProductsTableCompanion(
        id: Value(p.id),
        shopId: Value(p.shopId),
        name: Value(p.name),
        category: Value(p.category),
        purchasePrice: Value(santimFromDecimal(p.purchasePrice)),
        sellingPrice: Value(santimFromDecimal(p.sellingPrice)),
        stock: Value(p.stock.toDouble()),
        lowStockThreshold: Value(p.lowStockThreshold.toDouble()),
        unit: Value(p.unit),
        barcode: Value(p.barcode),
        imageUrl: Value(p.imageUrl),
        clientUpdatedAt: Value(p.clientUpdatedAt),
      );
}
