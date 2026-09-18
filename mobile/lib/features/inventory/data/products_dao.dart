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
      final raw = query.trim();
      final needle = foldForSearch(raw);
      stream = stream.map((rows) {
        // A typed or scanned SKU / barcode is an exact identifier, so it wins
        // over the fuzzy name filter: "JN-32-BLU" must return that one
        // variant, not every product whose name happens to contain "32".
        final exact = rows.where((r) => matchesIdentifier(r, raw)).toList();
        if (exact.isNotEmpty) return exact;
        return rows
            .where((r) => foldForSearch(r.name).contains(needle))
            .toList();
      });
    }
    return stream.map((rows) => rows.map(_toDomain).toList());
  }

  /// Exact (case-insensitive for SKUs, which are upper-cased on composition)
  /// identifier match used before the folded-name search.
  static bool matchesIdentifier(ProductRow r, String query) {
    final sku = r.sku;
    final barcode = r.barcode;
    return (sku != null && sku.toUpperCase() == query.toUpperCase()) ||
        (barcode != null && barcode.isNotEmpty && barcode == query);
  }

  /// Live variants of one style, size/colour order as stored (the UI orders
  /// them by the style's size preset).
  Stream<List<Product>> watchByStyle(String styleId) {
    return (select(productsTable)
          ..where((t) => t.styleId.equals(styleId))
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .watch()
        .map((rows) => rows.map(_toDomain).toList());
  }

  Future<List<Product>> getByStyle(String styleId) async {
    final rows = await (select(productsTable)
          ..where((t) => t.styleId.equals(styleId))
          ..where((t) => t.deletedAt.isNull()))
        .get();
    return rows.map(_toDomain).toList();
  }

  /// Soft-delete every live variant of [styleId] (style deletion, or a
  /// `style.create` the server refused).
  Future<void> softDeleteByStyle(String styleId, DateTime at) => customUpdate(
        'UPDATE products SET deleted_at = ?, updated_at = ? '
        'WHERE style_id = ? AND deleted_at IS NULL',
        variables: [
          Variable.withInt(sqliteDateTimeParam(at)),
          Variable.withInt(sqliteDateTimeParam(at)),
          Variable.withString(styleId),
        ],
        updates: {productsTable},
        updateKind: UpdateKind.update,
      );

  /// Is [sku] already carried by another live product of this shop?
  ///
  /// A hand-typed SKU goes to the server as-is and a duplicate comes back as
  /// `sku_collision` — a terminal rejection of the whole `product.create` /
  /// `product.update` — so the clash is caught here while the form is still
  /// open. Comparison is case-insensitive: composed SKUs are upper-cased, and
  /// "jn-32" must not be able to shadow "JN-32".
  Future<bool> skuTaken(
    String sku, {
    required String shopId,
    String? excludingProductId,
  }) async {
    final needle = sku.trim().toUpperCase();
    if (needle.isEmpty) return false;
    final rows = await customSelect(
      'SELECT 1 FROM products '
      'WHERE shop_id = ? AND deleted_at IS NULL '
      'AND UPPER(sku) = ? AND id <> ? LIMIT 1',
      variables: [
        Variable.withString(shopId),
        Variable.withString(needle),
        Variable.withString(excludingProductId ?? ''),
      ],
      readsFrom: {productsTable},
    ).get();
    return rows.isNotEmpty;
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
        styleId: r.styleId,
        size: r.size,
        color: r.color,
        sku: r.sku,
        minSellingPrice: r.minSellingPrice == null
            ? null
            : decimalFromSantim(r.minSellingPrice!),
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
        styleId: Value(p.styleId),
        size: Value(p.size),
        color: Value(p.color),
        sku: Value(p.sku),
        minSellingPrice: Value(
          p.minSellingPrice == null
              ? null
              : santimFromDecimal(p.minSellingPrice!),
        ),
      );
}
