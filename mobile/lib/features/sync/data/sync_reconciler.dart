import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/core/utils/money.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/debt/data/debts_repository.dart';
import 'package:suuqii/features/expenses/data/expenses_repository.dart';
import 'package:suuqii/features/inventory/data/lots_repository.dart';
import 'package:suuqii/features/inventory/data/products_repository.dart';
import 'package:suuqii/features/supplies/data/supplies_repository.dart';

part 'sync_reconciler.g.dart';

/// Local snapshot caches that can be re-mirrored from the server after
/// remote activity (pull) or a locally-discarded write (rejection/conflict).
enum SyncDomain { products, lots, debts, expenses, supplies }

/// Bridges the sync worker and the feature repositories.
///
/// Two jobs:
///  1. Convergence for `/sync/pull`: replicate other devices' events into the
///     local DB. Row-producing ops (sales, shifts) are applied directly and
///     idempotently; stock/debt/expense effects are converged by re-mirroring
///     the relevant server snapshots, which avoids re-implementing the
///     server's op semantics (FEFO, thresholds, write-offs) on the client.
///  2. Cleanup for server-refused local writes: when an event is rejected or
///     loses a conflict, the optimistic local rows it produced must not
///     outlive it — otherwise the device drifts from the server forever
///     (e.g. a "ghost" product that never exists server-side).
class SyncReconciler {
  SyncReconciler({
    required this.db,
    required this.shopId,
    required this.refreshProducts,
    required this.refreshLots,
    required this.refreshDebts,
    required this.refreshExpenses,
    required this.refreshSupplies,
  });

  final AppDatabase db;

  /// Current shop, or null when unauthenticated (pull never runs then, but a
  /// race on logout must not attribute rows to the wrong shop).
  final String? Function() shopId;

  final Future<void> Function() refreshProducts;
  final Future<void> Function() refreshLots;
  final Future<void> Function() refreshDebts;
  final Future<void> Function() refreshExpenses;
  final Future<void> Function() refreshSupplies;

  /// Snapshot domains a server-applied op invalidates locally.
  ///
  /// Recipes have no snapshot mirror yet (no client `refreshFromServer`) —
  /// recipe changes converge on the next full app refresh, not via pull.
  static Set<SyncDomain> domainsForOp(String op, Map<String, dynamic> payload) {
    switch (op) {
      case 'product.create':
      case 'product.update':
      case 'product.delete':
        return {SyncDomain.products};
      case 'inventory.adjust':
      case 'stock.receive':
      case 'stock.spoil':
        return {SyncDomain.products, SyncDomain.lots};
      case 'production.record':
        // Produces a product lot AND deducts recipe ingredient supplies.
        return {SyncDomain.products, SyncDomain.lots, SyncDomain.supplies};
      case 'sale.create':
        return {
          SyncDomain.products,
          SyncDomain.lots,
          if (payload['debt_id'] != null) SyncDomain.debts,
          // Bakery sales deduct ingredient supplies instead of stock.
          if (payload['supply_deductions'] != null) SyncDomain.supplies,
        };
      case 'supply.create':
      case 'supply.update':
      case 'supply.delete':
        return {SyncDomain.supplies};
      case 'sale.refund':
        return {SyncDomain.products, SyncDomain.lots};
      case 'debt.create':
      case 'debt.payment.create':
        return {SyncDomain.debts};
      case 'debt.writeoff':
        // The server books a bad-debt expense alongside the write-off.
        return {SyncDomain.debts, SyncDomain.expenses};
      case 'expense.create':
      case 'expense.update':
      case 'expense.delete':
        return {SyncDomain.expenses};
      default:
        // shift.* are applied as rows directly; recipe.set has no mirror
        // (see doc comment); unknown (newer) ops are skipped safely.
        return const {};
    }
  }

  /// Replicate one event another device pushed. Must be idempotent — the pull
  /// cursor is persisted after a page is applied, so a crash mid-page replays
  /// events on the next sync.
  Future<void> applyRemoteEvent({
    required String op,
    required Map<String, dynamic> payload,
    required String userId,
    required DateTime occurredAt,
  }) async {
    final shop = shopId();
    if (shop == null) return;
    switch (op) {
      case 'sale.create':
        await _applySale(payload, shop, userId);
      case 'sale.refund':
        final saleId = payload['sale_id'];
        if (saleId is String) {
          await (db.update(db.salesTable)..where((t) => t.id.equals(saleId)))
              .write(const SalesTableCompanion(status: Value('refunded')));
        }
      case 'shift.open':
        await db.into(db.shiftsTable).insert(
              ShiftsTableCompanion.insert(
                id: payload['id'] as String,
                shopId: shop,
                userId: userId,
                openedAt: _parseDt(payload['opened_at']) ?? occurredAt,
                openingCash: _santim(payload['opening_cash']),
              ),
              mode: InsertMode.insertOrIgnore,
            );
      case 'shift.close':
        // expected_closing_cash is computed server-side and not in the
        // payload; owner-facing variance for foreign shifts comes from the
        // server reports, not this local mirror.
        await (db.update(db.shiftsTable)
              ..where((t) => t.id.equals(payload['id'] as String)))
            .write(
          ShiftsTableCompanion(
            declaredClosingCash: Value(_santim(payload['declared_closing_cash'])),
            closedAt: Value(occurredAt),
            note: Value(payload['note'] as String?),
            updatedAt: Value(DateTime.now().toUtc()),
          ),
        );
      case 'product.delete' || 'supply.delete' || 'expense.delete':
        // Snapshot refreshes upsert but never remove rows, so deletions from
        // other devices must be applied here or they linger forever.
        final table = switch (op) {
          'product.delete' => 'products',
          'supply.delete' => 'supplies',
          _ => 'expenses',
        };
        final id = payload['id'];
        if (id is String) {
          await db.customUpdate(
            'UPDATE $table SET deleted_at = ? WHERE id = ? '
            'AND deleted_at IS NULL',
            variables: [
              Variable.withInt(sqliteDateTimeParam(occurredAt)),
              Variable.withString(id),
            ],
            updateKind: UpdateKind.update,
          );
        }
      default:
        break; // converged via domainsForOp snapshot refreshes
    }
  }

  /// The server refused this local event permanently (rejected, or lost a
  /// conflict to a newer server state). Undo/quarantine the optimistic local
  /// write and report which snapshots to re-mirror so local state returns to
  /// server truth instead of drifting forever.
  Future<Set<SyncDomain>> onLocalDiscarded(
    String op,
    Map<String, dynamic> payload,
  ) async {
    if (op == 'product.create') {
      // The product never existed server-side; a snapshot refresh upserts but
      // never deletes, so the ghost row must be hidden explicitly or the
      // cashier keeps selling a product every sale of which will be refused.
      final id = payload['id'];
      if (id is String) {
        await (db.update(db.productsTable)..where((t) => t.id.equals(id)))
            .write(
          ProductsTableCompanion(deletedAt: Value(DateTime.now().toUtc())),
        );
      }
      return {SyncDomain.products, SyncDomain.lots};
    }
    // sale.create: the local sale row is deliberately kept — the cash was
    // physically taken, and the red sync badge is where the owner resolves
    // it. The stock/debt side-effects still revert to server truth below.
    return domainsForOp(op, payload);
  }

  /// Re-mirror the given snapshot domains. Failures are independent: one
  /// unreachable endpoint must not stop the others (next sync retries).
  Future<void> refreshDomains(Set<SyncDomain> domains) async {
    final jobs = <SyncDomain, Future<void> Function()>{
      SyncDomain.products: refreshProducts,
      SyncDomain.lots: refreshLots,
      SyncDomain.debts: refreshDebts,
      SyncDomain.expenses: refreshExpenses,
      SyncDomain.supplies: refreshSupplies,
    };
    for (final domain in domains) {
      try {
        await jobs[domain]!();
      } catch (e) {
        debugPrint('sync refresh $domain failed: $e');
      }
    }
  }

  Future<void> _applySale(
    Map<String, dynamic> payload,
    String shop,
    String userId,
  ) async {
    final saleId = payload['id'] as String;
    final occurredAt = _parseDt(payload['occurred_at']);
    if (occurredAt == null) return;
    await db.transaction(() async {
      final inserted = await db.into(db.salesTable).insert(
            SalesTableCompanion.insert(
              id: saleId,
              shopId: shop,
              shiftId: Value(payload['shift_id'] as String?),
              userId: userId,
              subtotal: _santim(payload['subtotal']),
              discount: Value(_santim(payload['discount'])),
              total: _santim(payload['total']),
              costTotal: _santim(payload['cost_total']),
              paymentMethod: payload['payment_method'] as String,
              occurredAt: occurredAt,
              synced: const Value(true),
            ),
            mode: InsertMode.insertOrIgnore,
          );
      if (inserted == 0) return; // already replicated earlier
      final items = payload['items'];
      if (items is! List) return;
      for (final raw in items) {
        if (raw is! Map) continue;
        final item = raw.cast<String, dynamic>();
        await db.into(db.saleItemsTable).insert(
              SaleItemsTableCompanion.insert(
                id: item['id'] as String,
                saleId: saleId,
                productId: item['product_id'] as String,
                productNameSnapshot: item['product_name_snapshot'] as String,
                quantity: double.parse(item['quantity'] as String),
                unitPrice: _santim(item['unit_price']),
                unitCost: _santim(item['unit_cost']),
              ),
              mode: InsertMode.insertOrIgnore,
            );
      }
    });
  }

  static DateTime? _parseDt(Object? iso) =>
      iso is String ? DateTime.tryParse(iso)?.toUtc() : null;

  /// Payload money values are decimal birr strings (e.g. "12.50") — the same
  /// encoding the repositories enqueue. Missing/null means 0.
  static int _santim(Object? value) => value is String
      ? santimFromDecimal(Decimal.parse(value))
      : 0;
}

@Riverpod(keepAlive: true)
SyncReconciler syncReconciler(SyncReconcilerRef ref) {
  // Repositories are resolved lazily (ref.read at call time): they require an
  // authenticated session and themselves depend on the sync worker, so eager
  // watching here would both crash pre-login and create a provider cycle.
  Authenticated? auth() {
    final a = ref.read(authControllerProvider).valueOrNull;
    return a is Authenticated ? a : null;
  }

  Future<void> guarded(Future<void> Function() job) async {
    if (auth() == null) return;
    await job();
  }

  return SyncReconciler(
    db: ref.read(appDatabaseProvider),
    shopId: () => auth()?.shopId,
    refreshProducts: () => guarded(
      () => ref.read(productsRepositoryProvider).refreshFromServer(),
    ),
    refreshLots: () => guarded(
      () => ref.read(lotsRepositoryProvider).refreshFromServer(),
    ),
    refreshDebts: () => guarded(
      () => ref.read(debtsRepositoryProvider).refreshFromServer(),
    ),
    refreshExpenses: () => guarded(
      () => ref.read(expensesRepositoryProvider).refreshFromServer(),
    ),
    refreshSupplies: () => guarded(
      // Supplies exist only for bakery shops; the endpoint still answers
      // (empty) for retail shops, but skip the roundtrip entirely.
      () async {
        if (auth()?.isBakery ?? false) {
          await ref.read(suppliesRepositoryProvider).refreshFromServer();
        }
      },
    ),
  );
}
