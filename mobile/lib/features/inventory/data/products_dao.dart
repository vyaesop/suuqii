import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';

import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/core/storage/tables/products_table.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';

part 'products_dao.g.dart';

@DriftAccessor(tables: [ProductsTable])
class ProductsDao extends DatabaseAccessor<AppDatabase>
    with _$ProductsDaoMixin {
  ProductsDao(super.db);

  Stream<List<Product>> watchAll({String? query, String? category}) {
    final q = select(productsTable)
      ..where((t) => t.deletedAt.isNull())
      ..orderBy([(t) => OrderingTerm.asc(t.name)]);
    if (query != null && query.isNotEmpty) {
      q.where((t) => t.name.like('%$query%'));
    }
    if (category != null && category.isNotEmpty) {
      q.where((t) => t.category.equals(category));
    }
    return q.watch().map((rows) => rows.map(_toDomain).toList());
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
    await batch((b) {
      for (final p in products) {
        b.insert(
          productsTable,
          _fromDomain(p),
          mode: InsertMode.insertOrReplace,
        );
      }
    });
  }

  /// Local-only stock delta. Used inside the sales transaction.
  Future<void> applyStockDelta(String productId, Decimal delta) =>
      customStatement(
        'UPDATE products SET stock = stock + ?, updated_at = ? WHERE id = ?',
        [delta.toDouble(), sqliteDateTimeParam(DateTime.now()), productId],
      );

  Product _toDomain(ProductRow r) => Product(
        id: r.id,
        shopId: r.shopId,
        name: r.name,
        category: r.category,
        purchasePrice: Decimal.parse(r.purchasePrice.toString()),
        sellingPrice: Decimal.parse(r.sellingPrice.toString()),
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
        purchasePrice: Value(p.purchasePrice.toDouble()),
        sellingPrice: Value(p.sellingPrice.toDouble()),
        stock: Value(p.stock.toDouble()),
        lowStockThreshold: Value(p.lowStockThreshold.toDouble()),
        unit: Value(p.unit),
        barcode: Value(p.barcode),
        imageUrl: Value(p.imageUrl),
        clientUpdatedAt: Value(p.clientUpdatedAt),
      );
}
