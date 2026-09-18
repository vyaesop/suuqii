import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';

import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/core/storage/tables/products_table.dart';
import 'package:suuqii/core/storage/tables/styles_table.dart';
import 'package:suuqii/core/utils/money.dart';
import 'package:suuqii/features/inventory/domain/entities/style.dart';

part 'styles_dao.g.dart';

@DriftAccessor(tables: [StylesTable, ProductsTable])
class StylesDao extends DatabaseAccessor<AppDatabase> with _$StylesDaoMixin {
  StylesDao(super.db);

  Stream<List<Style>> watchAll({required String shopId}) {
    return (select(stylesTable)
          ..where((t) => t.shopId.equals(shopId))
          ..where((t) => t.deletedAt.isNull())
          ..orderBy([(t) => OrderingTerm.asc(t.name)]))
        .watch()
        .map((rows) => rows.map(_toDomain).toList());
  }

  Future<Style?> getById(String id) async {
    final r = await (select(stylesTable)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    return r == null ? null : _toDomain(r);
  }

  Stream<Style?> watchById(String id) {
    return (select(stylesTable)
          ..where((t) => t.id.equals(id))
          ..where((t) => t.deletedAt.isNull()))
        .watchSingleOrNull()
        .map((r) => r == null ? null : _toDomain(r));
  }

  /// Styles with live-variant aggregates, name order. One query (GROUP BY
  /// over products) rather than N watchers — a boutique with 150 styles
  /// would otherwise open 150 streams on the inventory screen.
  Stream<List<StyleSummary>> watchSummaries({required String shopId}) {
    return customSelect(
      'SELECT s.*, '
      '       COUNT(p.id) AS variant_count, '
      '       COALESCE(SUM(p.stock), 0) AS stock_total, '
      '       COALESCE(SUM(CASE WHEN p.stock <= p.low_stock_threshold '
      '                         THEN 1 ELSE 0 END), 0) AS sizes_out '
      'FROM styles s '
      'LEFT JOIN products p ON p.style_id = s.id AND p.deleted_at IS NULL '
      'WHERE s.shop_id = ? AND s.deleted_at IS NULL '
      'GROUP BY s.id ORDER BY s.name ASC',
      variables: [Variable.withString(shopId)],
      readsFrom: {stylesTable, productsTable},
    ).watch().map(
      (rows) => rows.map((r) {
        return StyleSummary(
          style: Style(
            id: r.read<String>('id'),
            shopId: r.read<String>('shop_id'),
            name: r.read<String>('name'),
            brand: r.readNullable<String>('brand'),
            category: r.readNullable<String>('category'),
            segment: r.readNullable<String>('segment'),
            imageUrl: r.readNullable<String>('image_url'),
            defaultSellingPrice:
                decimalFromSantim(r.read<int>('default_selling_price')),
            defaultPurchasePrice:
                decimalFromSantim(r.read<int>('default_purchase_price')),
            sizeSet: r.readNullable<String>('size_set'),
            skuPrefix: r.readNullable<String>('sku_prefix'),
            clientUpdatedAt: r.readNullable<DateTime>('client_updated_at'),
          ),
          variantCount: r.read<int>('variant_count'),
          stockTotal: Decimal.parse(r.read<double>('stock_total').toString()),
          sizesOut: r.read<int>('sizes_out'),
        );
      }).toList(),
    );
  }

  Future<void> upsertAll(List<Style> styles) async {
    final now = DateTime.now();
    await batch((b) {
      for (final s in styles) {
        // DoUpdate (not insertOrReplace) so created_at survives a refresh.
        b.insert(
          stylesTable,
          _fromDomain(s),
          onConflict: DoUpdate(
            (_) => _fromDomain(s).copyWith(updatedAt: Value(now)),
          ),
        );
      }
    });
  }

  /// Soft-delete a style; the caller handles its variants.
  Future<void> softDelete(String id, DateTime at) => customUpdate(
        'UPDATE styles SET deleted_at = ?, updated_at = ? '
        'WHERE id = ? AND deleted_at IS NULL',
        variables: [
          Variable.withInt(sqliteDateTimeParam(at)),
          Variable.withInt(sqliteDateTimeParam(at)),
          Variable.withString(id),
        ],
        updates: {stylesTable},
        updateKind: UpdateKind.update,
      );

  Style _toDomain(StyleRow r) => Style(
        id: r.id,
        shopId: r.shopId,
        name: r.name,
        brand: r.brand,
        category: r.category,
        segment: r.segment,
        imageUrl: r.imageUrl,
        defaultSellingPrice: decimalFromSantim(r.defaultSellingPrice),
        defaultPurchasePrice: decimalFromSantim(r.defaultPurchasePrice),
        sizeSet: r.sizeSet,
        skuPrefix: r.skuPrefix,
        clientUpdatedAt: r.clientUpdatedAt,
      );

  StylesTableCompanion _fromDomain(Style s) => StylesTableCompanion(
        id: Value(s.id),
        shopId: Value(s.shopId),
        name: Value(s.name),
        brand: Value(s.brand),
        category: Value(s.category),
        segment: Value(s.segment),
        imageUrl: Value(s.imageUrl),
        defaultSellingPrice: Value(santimFromDecimal(s.defaultSellingPrice)),
        defaultPurchasePrice: Value(santimFromDecimal(s.defaultPurchasePrice)),
        sizeSet: Value(s.sizeSet),
        skuPrefix: Value(s.skuPrefix),
        clientUpdatedAt: Value(s.clientUpdatedAt),
      );
}
