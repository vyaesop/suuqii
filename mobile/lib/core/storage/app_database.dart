import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:suuqii/core/storage/tables/audit_logs_table.dart';
import 'package:suuqii/core/storage/tables/debts_table.dart';
import 'package:suuqii/core/storage/tables/expenses_table.dart';
import 'package:suuqii/core/storage/tables/inventory_logs_table.dart';
import 'package:suuqii/core/storage/tables/products_table.dart';
import 'package:suuqii/core/storage/tables/recipes_table.dart';
import 'package:suuqii/core/storage/tables/sales_tables.dart';
import 'package:suuqii/core/storage/tables/shifts_table.dart';
import 'package:suuqii/core/storage/tables/stock_lots_table.dart';
import 'package:suuqii/core/storage/tables/supplies_table.dart';
import 'package:suuqii/core/storage/tables/sync_events_table.dart';
import 'package:suuqii/core/storage/tables/sync_meta_table.dart';
import 'package:suuqii/features/debt/data/debts_dao.dart';
import 'package:suuqii/features/expenses/data/expenses_dao.dart';
import 'package:suuqii/features/inventory/data/lots_dao.dart';
import 'package:suuqii/features/inventory/data/products_dao.dart';
import 'package:suuqii/features/inventory/data/recipes_dao.dart';
import 'package:suuqii/features/supplies/data/supplies_dao.dart';
import 'package:suuqii/features/sync/data/sync_queue_dao.dart';

part 'app_database.g.dart';

int sqliteDateTimeParam(DateTime value) =>
    value.toUtc().millisecondsSinceEpoch ~/ 1000;

@DriftDatabase(
  tables: [
    ProductsTable,
    SalesTable,
    SaleItemsTable,
    InventoryLogsTable,
    DebtsTable,
    DebtPaymentsTable,
    ExpensesTable,
    ShiftsTable,
    AuditLogsTable,
    SyncEventsTable,
    SyncMetaTable,
    SuppliesTable,
    RecipeItemsTable,
    StockLotsTable,
    LotConsumptionsTable,
  ],
  daos: [
    SyncQueueDao,
    ProductsDao,
    DebtsDao,
    ExpensesDao,
    SuppliesDao,
    RecipesDao,
    LotsDao,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  factory AppDatabase.openOn(String filePath) {
    return AppDatabase(
      // createInBackground keeps sqlite work off the UI isolate.
      NativeDatabase.createInBackground(
        File(filePath),
        setup: (db) {
          db
            ..execute('PRAGMA journal_mode = WAL')
            ..execute('PRAGMA synchronous = NORMAL')
            ..execute('PRAGMA foreign_keys = ON');
        },
      ),
    );
  }

  @override
  int get schemaVersion => 9;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async {
          await m.createAll();
          await _createIndexes();
        },
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await _repairLegacyDateTimes();
          }
          if (from < 3) {
            await m.createTable(suppliesTable);
            await m.createTable(recipeItemsTable);
          }
          if (from < 4) {
            await m.addColumn(recipeItemsTable, recipeItemsTable.recipeUnit);
          }
          if (from < 5) {
            await _createIndexes();
          }
          if (from < 6) {
            await _migrateMoneyToSantim();
          }
          if (from < 7) {
            await m.createTable(stockLotsTable);
            await m.createTable(lotConsumptionsTable);
            await m.addColumn(suppliesTable, suppliesTable.expiryDate);
            // Lot indexes are in _createIndexes (IF NOT EXISTS — re-runnable).
            await _createIndexes();
          }
          if (from < 8) {
            await _backfillOpeningLots();
          }
          if (from < 9) {
            await m.createTable(syncMetaTable);
          }
        },
      );

  /// v7 → v8: stock that existed before lot tracking has no batch, so it
  /// would be invisible in the batch view and mis-costed on sale (FEFO would
  /// fall through to the *current* last cost). Turn each in-stock product's
  /// existing quantity into an "opening balance" lot at its current purchase
  /// price. Idempotent: only for products that have no lot yet. The server
  /// backfills independently (migration 0008); the next lot sync replaces
  /// these local opening lots with the server's, so there is no double count.
  Future<void> _backfillOpeningLots() async {
    await customStatement(
      'INSERT INTO stock_lots '
      '(id, product_id, qty_received, qty_remaining, unit_cost_santim, '
      ' expiry_date, received_at, note) '
      "SELECT 'opening-' || p.id, p.id, p.stock, p.stock, p.purchase_price, "
      "       NULL, COALESCE(p.created_at, CAST(strftime('%s','now') AS INTEGER)), "
      "       'Opening balance' "
      'FROM products p '
      'WHERE p.stock > 0 AND p.deleted_at IS NULL '
      '  AND NOT EXISTS (SELECT 1 FROM stock_lots l WHERE l.product_id = p.id)',
    );
  }

  /// v5 → v6: money columns move from REAL birr to INTEGER santim
  /// (1 birr = 100 santim) so SQL arithmetic over money is exact.
  ///
  /// SQLite is dynamically typed, so rewriting the stored values in place
  /// plus the new Dart-side int mapping is sufficient — no table rebuild.
  /// ROUND() before CAST because CAST truncates toward zero.
  Future<void> _migrateMoneyToSantim() async {
    const moneyColumns = <String, List<String>>{
      'products': ['purchase_price', 'selling_price'],
      'sales': ['subtotal', 'discount', 'total', 'cost_total'],
      'sale_items': ['unit_price', 'unit_cost'],
      'debts': ['amount_owed', 'amount_paid'],
      'debt_payments': ['amount'],
      'expenses': ['amount'],
      'shifts': [
        'opening_cash',
        'declared_closing_cash',
        'expected_closing_cash',
      ],
      'supplies': ['cost_per_unit'],
    };
    for (final entry in moneyColumns.entries) {
      for (final column in entry.value) {
        await customStatement(
          'UPDATE ${entry.key} '
          'SET $column = CAST(ROUND($column * 100) AS INTEGER) '
          'WHERE $column IS NOT NULL',
        );
      }
    }
  }

  /// Hot-path indexes. IF NOT EXISTS so this is safe to run from both
  /// onCreate and onUpgrade.
  Future<void> _createIndexes() async {
    const statements = [
      'CREATE INDEX IF NOT EXISTS idx_sync_events_status_id ON sync_events (status, id)',
      'CREATE INDEX IF NOT EXISTS idx_products_shop_id ON products (shop_id)',
      'CREATE INDEX IF NOT EXISTS idx_sale_items_sale_id ON sale_items (sale_id)',
      'CREATE INDEX IF NOT EXISTS idx_inventory_logs_product_id ON inventory_logs (product_id)',
      'CREATE INDEX IF NOT EXISTS idx_debts_shop_id ON debts (shop_id)',
      'CREATE INDEX IF NOT EXISTS idx_debt_payments_debt_id ON debt_payments (debt_id)',
      'CREATE INDEX IF NOT EXISTS idx_stock_lots_product_id ON stock_lots (product_id)',
      'CREATE INDEX IF NOT EXISTS idx_lot_consumptions_lot_id ON lot_consumptions (lot_id)',
      'CREATE INDEX IF NOT EXISTS idx_lot_consumptions_sale_item_id ON lot_consumptions (sale_item_id)',
    ];
    for (final sql in statements) {
      await customStatement(sql);
    }
  }

  /// Wipe all shop-scoped data. Called on logout or when a different shop
  /// account is detected on login, so stale data from a previous session never
  /// leaks into the new one.
  Future<void> clearAllShopData() async {
    await transaction(() async {
      await customStatement('DELETE FROM sync_events');
      await customStatement('DELETE FROM sync_meta');
      await customStatement('DELETE FROM lot_consumptions');
      await customStatement('DELETE FROM stock_lots');
      await customStatement('DELETE FROM inventory_logs');
      await customStatement('DELETE FROM sale_items');
      await customStatement('DELETE FROM sales');
      await customStatement('DELETE FROM debt_payments');
      await customStatement('DELETE FROM debts');
      await customStatement('DELETE FROM expenses');
      await customStatement('DELETE FROM shifts');
      await customStatement('DELETE FROM audit_logs');
      await customStatement('DELETE FROM recipe_items');
      await customStatement('DELETE FROM supplies');
      await customStatement('DELETE FROM products');
    });
  }

  Future<void> _repairLegacyDateTimes() async {
    Future<void> repair(String table, String column) {
      return customStatement(
        'UPDATE $table '
        "SET $column = CAST(strftime('%s', $column) AS INTEGER) "
        "WHERE typeof($column) = 'text' AND $column IS NOT NULL",
      );
    }

    await repair('sync_events', 'occurred_at');
    await repair('sync_events', 'enqueued_at');
    await repair('sync_events', 'last_attempt_at');

    await repair('products', 'client_updated_at');
    await repair('products', 'created_at');
    await repair('products', 'updated_at');
    await repair('products', 'deleted_at');

    await repair('sales', 'occurred_at');
    await repair('sales', 'created_at');
    await repair('sales', 'deleted_at');

    await repair('inventory_logs', 'created_at');
  }
}

@Riverpod(keepAlive: true)
AppDatabase appDatabase(AppDatabaseRef ref) => throw UnimplementedError(
      'Override appDatabaseProvider in main.dart with the opened database',
    );
