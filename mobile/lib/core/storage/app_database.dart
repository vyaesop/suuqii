import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:suuqii/core/storage/tables/audit_logs_table.dart';
import 'package:suuqii/core/storage/tables/debts_table.dart';
import 'package:suuqii/core/storage/tables/expenses_table.dart';
import 'package:suuqii/core/storage/tables/inventory_logs_table.dart';
import 'package:suuqii/core/storage/tables/products_table.dart';
import 'package:suuqii/core/storage/tables/sales_tables.dart';
import 'package:suuqii/core/storage/tables/shifts_table.dart';
import 'package:suuqii/core/storage/tables/sync_events_table.dart';
import 'package:suuqii/features/debt/data/debts_dao.dart';
import 'package:suuqii/features/expenses/data/expenses_dao.dart';
import 'package:suuqii/features/inventory/data/products_dao.dart';
import 'package:suuqii/features/sync/data/sync_queue_dao.dart';

part 'app_database.g.dart';

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
  ],
  daos: [SyncQueueDao, ProductsDao, DebtsDao, ExpensesDao],
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
  int get schemaVersion => 1;
}

@Riverpod(keepAlive: true)
AppDatabase appDatabase(AppDatabaseRef ref) => throw UnimplementedError(
      'Override appDatabaseProvider in main.dart with the opened database',
    );
