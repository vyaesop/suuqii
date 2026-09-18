import 'package:drift/drift.dart';

/// A boutique style: the shared half of a garment (name, brand, image,
/// default prices, size run). Each sellable size × colour is an ordinary
/// `products` row pointing back here via `products.style_id`
/// (docs/19-boutique-shop-type.md §2, option A).
@DataClassName('StyleRow')
class StylesTable extends Table {
  @override
  String get tableName => 'styles';

  TextColumn get id => text()();
  TextColumn get shopId => text()();
  TextColumn get name => text()();
  TextColumn get brand => text().nullable()();
  TextColumn get category => text().nullable()();

  /// men | women | kids | unisex, or null.
  TextColumn get segment => text().nullable()();
  TextColumn get imageUrl => text().nullable()();

  /// Money: int64 santim (1 birr = 100 santim), same convention as products.
  IntColumn get defaultSellingPrice => integer()();
  IntColumn get defaultPurchasePrice =>
      integer().withDefault(const Constant(0))();

  /// Size preset key (core/shop_type/size_presets.dart); null = custom.
  TextColumn get sizeSet => text().nullable()();

  /// Up to 8 chars, e.g. "JN" → variants "JN-32-BLU".
  TextColumn get skuPrefix => text().nullable()();
  DateTimeColumn get clientUpdatedAt => dateTime().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get deletedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
