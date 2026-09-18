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
import 'package:suuqii/features/inventory/data/styles_repository.dart';
import 'package:suuqii/features/sales/domain/entities/sale_return.dart';
import 'package:suuqii/features/supplies/data/supplies_repository.dart';
import 'package:uuid/uuid.dart';

part 'sync_reconciler.g.dart';

/// Local snapshot caches that can be re-mirrored from the server after
/// remote activity (pull) or a locally-discarded write (rejection/conflict).
enum SyncDomain { products, lots, debts, expenses, supplies, styles }

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
    required this.refreshStyles,
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
  final Future<void> Function() refreshStyles;

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
      case 'style.create':
      case 'style.update':
      case 'style.add_variants':
      case 'style.delete':
        // A style event also creates/renames/deletes its variant products.
        return {SyncDomain.styles, SyncDomain.products};
      case 'sale.refund':
      case 'sale.return':
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
      case 'sale.return':
        await _applySaleReturn(payload, shop, userId);
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
      case 'style.delete':
        // Same reasoning as the row deletes below, plus the variants: the
        // products mirror would keep them alive forever otherwise.
        final id = payload['id'];
        if (id is String) {
          await db.transaction(() async {
            await db.productsDao.softDeleteByStyle(id, occurredAt);
            await db.stylesDao.softDelete(id, occurredAt);
          });
        }
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
    if (op == 'style.create') {
      // Same ghost problem, one level up: the style and every variant it
      // created must disappear or the boutique keeps selling phantoms.
      final id = payload['id'];
      if (id is String) {
        final now = DateTime.now().toUtc();
        await db.transaction(() async {
          await db.productsDao.softDeleteByStyle(id, now);
          await db.stylesDao.softDelete(id, now);
        });
      }
      return {SyncDomain.styles, SyncDomain.products, SyncDomain.lots};
    }
    if (op == 'style.add_variants') {
      final variants = payload['variants'];
      if (variants is List) {
        final now = DateTime.now().toUtc();
        for (final v in variants) {
          if (v is Map && v['id'] is String) {
            await (db.update(db.productsTable)
                  ..where((t) => t.id.equals(v['id'] as String)))
                .write(ProductsTableCompanion(deletedAt: Value(now)));
          }
        }
      }
      return {SyncDomain.styles, SyncDomain.products, SyncDomain.lots};
    }
    if (op == 'sale.return') {
      // The return never happened server-side. Left behind, its rows keep
      // counting towards the cumulative over-return check (those units could
      // never be returned again on this device), keep the sale
      // `partially_returned` (so `refund()` refuses it), and — for an
      // exchange — keep inflating `effectiveTotalSantim`, which would credit
      // every later return above what the server books. The restored stock
      // and lots come back from the snapshot refresh.
      final id = payload['id'];
      final saleId = payload['sale_id'];
      if (id is String && saleId is String) {
        await db.transaction(() async {
          await db.saleReturnsDao.deleteReturn(id);
          await _recomputeSaleStatus(saleId);
        });
      }
      return {SyncDomain.products, SyncDomain.lots};
    }
    // sale.create: the local sale row is deliberately kept — the cash was
    // physically taken, and the red sync badge is where the owner resolves
    // it. The stock/debt side-effects still revert to server truth below.
    return domainsForOp(op, payload);
  }

  /// Re-derive `sales.status` from the returns that are actually left:
  /// none → completed, every sold unit back → refunded, otherwise partial.
  Future<void> _recomputeSaleStatus(String saleId) async {
    final saleItems = await (db.select(db.saleItemsTable)
          ..where((t) => t.saleId.equals(saleId)))
        .get();
    final returned = await db.saleReturnsDao.returnedQtyBySaleItem(saleId);
    final anyReturned =
        returned.values.any((qty) => qty > Decimal.zero);
    final fullyReturned = saleItems.isNotEmpty &&
        saleItems.every(
          (si) =>
              (returned[si.id] ?? Decimal.zero) >=
              Decimal.parse(si.quantity.toString()),
        );
    await (db.update(db.salesTable)..where((t) => t.id.equals(saleId))).write(
      SalesTableCompanion(
        status: Value(
          !anyReturned
              ? 'completed'
              : (fullyReturned ? 'refunded' : 'partially_returned'),
        ),
      ),
    );
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
      SyncDomain.styles: refreshStyles,
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
                listPrice: Value(
                  item['list_price'] is String
                      ? _santim(item['list_price'])
                      : null,
                ),
              ),
              mode: InsertMode.insertOrIgnore,
            );
      }
    });
  }

  /// Mirror another device's partial return (docs/19 §13.3) when the sale
  /// is known here: return rows with the same proportional credit the server
  /// computed, and the sale's status. Stock and lots converge through the
  /// `{products, lots}` snapshot refresh — re-implementing the FIFO reversal
  /// for foreign events would only duplicate what the server already did.
  /// Idempotent on the return id.
  Future<void> _applySaleReturn(
    Map<String, dynamic> payload,
    String shop,
    String userId,
  ) async {
    final returnId = payload['id'];
    final saleId = payload['sale_id'];
    if (returnId is! String || saleId is! String) return;
    final occurredAt = _parseDt(payload['occurred_at']);
    if (occurredAt == null) return;
    final reason = ReturnReason.fromWire(payload['reason'] as String?);
    if (reason == null) return;
    await db.transaction(() async {
      final sale = await (db.select(db.salesTable)
            ..where((t) => t.id.equals(saleId)))
          .getSingleOrNull();
      if (sale == null) return; // never sold here; nothing to annotate
      if (await db.saleReturnsDao.exists(returnId)) return;
      final saleItems = {
        for (final si in await (db.select(db.saleItemsTable)
              ..where((t) => t.saleId.equals(saleId)))
            .get())
          si.id: si,
      };
      final returnedSoFar =
          await db.saleReturnsDao.returnedQtyBySaleItem(saleId);
      final calculator = await db.saleReturnsDao.calculatorFor(sale);
      await db.saleReturnsDao.insertReturn(
        id: returnId,
        shopId: shop,
        saleId: saleId,
        userId: userId,
        shiftId: payload['shift_id'] as String?,
        occurredAt: occurredAt,
        refundAmountSantim: _santim(payload['refund_amount']),
        refundMethod: switch (payload['refund_method']) {
          'cash' => RefundMethod.cash,
          'mobile_money' => RefundMethod.mobileMoney,
          _ => null,
        },
        exchangeSaleId: payload['exchange_sale_id'] as String?,
        reason: reason,
        note: payload['note'] as String?,
      );
      final items = payload['items'];
      final nowReturning = <String, Decimal>{};
      if (items is List) {
        for (final raw in items) {
          if (raw is! Map) continue;
          final item = raw.cast<String, dynamic>();
          final saleItemId = item['sale_item_id'];
          final si = saleItemId is String ? saleItems[saleItemId] : null;
          if (si == null) continue;
          final qty = Decimal.tryParse(item['quantity'] as String? ?? '');
          if (qty == null) continue;
          await db.saleReturnsDao.insertItem(
            id: (item['id'] as String?) ?? const Uuid().v4(),
            returnId: returnId,
            saleItemId: si.id,
            quantity: qty,
            condition:
                ReturnCondition.fromWire(item['condition'] as String?) ??
                    ReturnCondition.resellable,
            creditUnitSantim: calculator.creditUnitSantim(si.unitPrice),
          );
          nowReturning[si.id] = (nowReturning[si.id] ?? Decimal.zero) + qty;
        }
      }
      final fullyReturned = saleItems.values.every((si) {
        final back = (returnedSoFar[si.id] ?? Decimal.zero) +
            (nowReturning[si.id] ?? Decimal.zero);
        return back >= Decimal.parse(si.quantity.toString());
      });
      await (db.update(db.salesTable)..where((t) => t.id.equals(saleId))).write(
        SalesTableCompanion(
          status: Value(fullyReturned ? 'refunded' : 'partially_returned'),
        ),
      );
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
      // Supplies exist only for shops with the feature; the endpoint still
      // answers (empty) for the others, but skip the roundtrip entirely.
      () async {
        if (auth()?.features.hasSupplies ?? false) {
          await ref.read(suppliesRepositoryProvider).refreshFromServer();
        }
      },
    ),
    refreshStyles: () => guarded(
      () async {
        if (auth()?.features.hasVariants ?? false) {
          await ref.read(stylesRepositoryProvider).refreshFromServer();
        }
      },
    ),
  );
}
