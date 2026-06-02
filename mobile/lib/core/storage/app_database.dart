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
import 'package:suuqii/core/storage/tables/supplies_table.dart';
import 'package:suuqii/core/storage/tables/sync_events_table.dart';
import 'package:suuqii/features/debt/data/debts_dao.dart';
import 'package:suuqii/features/expenses/data/expenses_dao.dart';
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
    SuppliesTable,
    RecipeItemsTable,
  ],
  daos: [SyncQueueDao, ProductsDao, DebtsDao, ExpensesDao, SuppliesDao, RecipesDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  factory AppDatabase.openOn(String filePath) {
    return AppDatabase(
      NativeDatabase(
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
  int get schemaVersion => 4;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async => m.createAll(),
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
        },
      );

  /// Wipe all shop-scoped data. Called on logout or when a different shop
  /// account is detected on login, so stale data from a previous session never
  /// leaks into the new one.
  Future<void> clearAllShopData() async {
    await transaction(() async {
      await customStatement('DELETE FROM sync_events');
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
