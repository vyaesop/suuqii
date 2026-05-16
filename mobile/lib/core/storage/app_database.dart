import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../features/inventory/data/products_dao.dart';
import '../../features/sync/data/sync_queue_dao.dart';
import 'tables/audit_logs_table.dart';
import 'tables/debts_table.dart';
import 'tables/expenses_table.dart';
import 'tables/inventory_logs_table.dart';
import 'tables/products_table.dart';
import 'tables/sales_tables.dart';
import 'tables/shifts_table.dart';
import 'tables/sync_events_table.dart';

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
  daos: [SyncQueueDao, ProductsDao],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e);

  factory AppDatabase.openOn(String filePath) {
    return AppDatabase(NativeDatabase(File(filePath), setup: (db) {
      db.execute('PRAGMA journal_mode = WAL');
      db.execute('PRAGMA synchronous = NORMAL');
      db.execute('PRAGMA foreign_keys = ON');
    }));
  }

  @override
  int get schemaVersion => 1;
}

@Riverpod(keepAlive: true)
AppDatabase appDatabase(AppDatabaseRef ref) => throw UnimplementedError(
      'Override appDatabaseProvider in main.dart with the opened database',
    );
