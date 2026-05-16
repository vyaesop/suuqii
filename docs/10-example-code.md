# 10 — Example code (critical systems)

Snippets here are reference implementations for the load-bearing parts. Compilable code lives under `backend/` and `mobile/`.

## 1. Submit-sale use case (Flutter, domain)

```dart
// mobile/lib/features/sales/domain/usecases/submit_sale.dart
class SubmitSale {
  SubmitSale(this._repo);
  final SalesRepository _repo;

  Future<Sale> execute(
    Cart cart,
    PaymentMethod method, {
    String? customerName,
    String? customerPhone,
    DateTime? dueDate,
    String? ownerChallengeToken,
  }) async {
    if (cart.isEmpty) throw const DomainError.emptyCart();

    for (final line in cart.lines) {
      if (line.qty <= 0) throw DomainError.invalidQty(line.product.id);
      if (line.product.stock < line.qty) {
        throw DomainError.insufficientStock(line.product.id, available: line.product.stock);
      }
    }

    if (method == PaymentMethod.credit) {
      if (customerName == null || customerName.isEmpty) {
        throw const DomainError.creditNeedsCustomer();
      }
    }

    final draft = Sale.draft(
      id: Uuid.v4(),
      lines: cart.lines,
      paymentMethod: method,
      customerName: customerName,
      customerPhone: customerPhone,
      dueDate: dueDate,
      occurredAt: DateTime.now(),
    );

    return _repo.create(draft, ownerChallengeToken: ownerChallengeToken);
  }
}
```

## 2. Sales repository — atomic local write + queue (Flutter, data)

```dart
// mobile/lib/features/sales/data/repositories/sales_repository_impl.dart
class SalesRepositoryImpl implements SalesRepository {
  SalesRepositoryImpl({required this.db, required this.queue});
  final AppDatabase db;
  final SyncQueue queue;

  @override
  Future<Sale> create(Sale draft, {String? ownerChallengeToken}) async {
    return db.transaction(() async {
      // 1. insert sale
      await db.into(db.salesTable).insert(SaleMapper.toRow(draft, synced: false));
      // 2. insert items
      for (final l in draft.lines) {
        await db.into(db.saleItemsTable).insert(SaleItemMapper.toRow(saleId: draft.id, line: l));
      }
      // 3. decrement stock + write inventory_log per product
      for (final l in draft.lines) {
        await db.customStatement(
          'UPDATE products SET stock = stock - ?, updated_at = ? WHERE id = ?',
          [l.qty, DateTime.now().millisecondsSinceEpoch, l.product.id],
        );
        await db.into(db.inventoryLogsTable).insert(InventoryLog.forSale(
          productId: l.product.id, qty: l.qty, saleId: draft.id,
        ).toRow());
      }
      // 4. create debt if credit
      if (draft.paymentMethod == PaymentMethod.credit) {
        await db.into(db.debtsTable).insert(DebtMapper.fromSale(draft).toRow());
      }
      // 5. enqueue sync event
      await queue.enqueue(SyncEvent.saleCreate(
        clientEventId: Uuid.v4(),
        sale: draft,
        ownerChallengeToken: ownerChallengeToken,
      ));
      return draft.markPending();
    });
  }
}
```

## 3. Sync worker (Flutter)

```dart
// mobile/lib/features/sync/data/sync_worker.dart
class SyncWorker {
  SyncWorker(this._db, this._api, this._connectivity);
  final AppDatabase _db;
  final SyncApi _api;
  final Connectivity _connectivity;
  bool _running = false;

  Future<void> kick() async {
    if (_running) return;
    _running = true;
    try {
      while (true) {
        final online = await _connectivity.isOnline;
        if (!online) { await _connectivity.untilOnline; continue; }

        final batch = await _db.syncEventsDao.takePending(limit: 50);
        if (batch.isEmpty) break;

        try {
          final res = await _api.push(batch.map((e) => e.toDto()).toList());
          for (final r in res.results) {
            switch (r) {
              case Applied(:final clientEventId):
                await _db.syncEventsDao.markSynced(clientEventId);
              case ConflictResolved(:final clientEventId, :final serverPayload):
                await _db.applyServerOverride(serverPayload);
                await _db.syncEventsDao.markSynced(clientEventId);
              case Rejected(:final clientEventId, :final code, :final detail):
                await _db.syncEventsDao.markRejected(clientEventId, code, detail);
                _notifyUser(code, detail);
            }
          }
          await _pullSince(res.serverCursor);
        } on DioException catch (e) {
          await _db.syncEventsDao.bumpAttempts(batch.map((b) => b.id).toList(), error: e.message);
          await _backoff(batch.first.attempts + 1);
        }
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _backoff(int attempts) async {
    final base = math.min(math.pow(2, attempts).toInt(), 300);
    final jitter = Random().nextInt(base);
    await Future.delayed(Duration(seconds: base + jitter));
  }
}
```

## 4. Drift schema fragment

```dart
// mobile/lib/core/storage/tables/sales_tables.dart
@DataClassName('SaleRow')
class SalesTable extends Table {
  TextColumn get id => text()();
  TextColumn get shopId => text()();
  TextColumn get shiftId => text().nullable()();
  TextColumn get userId => text()();
  RealColumn get subtotal => real()();
  RealColumn get discount => real().withDefault(const Constant(0))();
  RealColumn get total => real()();
  RealColumn get costTotal => real()();
  TextColumn get paymentMethod => text()();
  TextColumn get status => text().withDefault(const Constant('completed'))();
  DateTimeColumn get occurredAt => dateTime()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  BoolColumn get synced => boolean().withDefault(const Constant(false))();
  @override Set<Column> get primaryKey => {id};
}
```

## 5. FastAPI sync push endpoint

```python
# backend/app/api/v1/sync.py
from fastapi import APIRouter, Depends, Header
from sqlalchemy.ext.asyncio import AsyncSession
from app.core.deps import current_user, current_shop, db_session, current_device
from app.schemas.sync import SyncPushRequest, SyncPushResponse
from app.services.sync_service import SyncService

router = APIRouter(prefix="/sync", tags=["sync"])

@router.post("/push", response_model=SyncPushResponse)
async def push(
    req: SyncPushRequest,
    db: AsyncSession = Depends(db_session),
    user = Depends(current_user),
    shop = Depends(current_shop),
    device_id: str = Depends(current_device),
    owner_challenge: str | None = Header(default=None, alias="X-Owner-Challenge"),
):
    svc = SyncService(db, shop, user, device_id, owner_challenge=owner_challenge)
    results = []
    for event in req.events:
        results.append(await svc.apply(event))
    await db.commit()
    return SyncPushResponse(results=results, server_cursor=await svc.current_cursor())
```

## 6. Sync service replay (backend)

```python
# backend/app/services/sync_service.py
class SyncService:
    def __init__(self, db, shop, user, device_id, owner_challenge=None):
        self.db = db; self.shop = shop; self.user = user
        self.device_id = device_id; self.challenge = owner_challenge

    async def apply(self, event: SyncEvent) -> SyncResult:
        # idempotency
        existing = await self._lookup_event(event.client_event_id)
        if existing:
            return SyncResult.applied(event.client_event_id)  # no-op

        try:
            handler = self._handler_for(event.op)
            payload = await handler(event.payload)
        except ConflictError as e:
            return SyncResult.conflict(event.client_event_id, e.server_payload)
        except OwnerPinRequired:
            return SyncResult.rejected(event.client_event_id, "owner_pin_required")
        except DomainError as e:
            return SyncResult.rejected(event.client_event_id, e.code, str(e))

        await self._record_event(event)
        return SyncResult.applied(event.client_event_id)

    async def _handle_sale_create(self, p: dict) -> dict:
        # insert sale, items, inventory_logs (delta), debts if credit
        # validations: products belong to this shop, prices not tampered
        ...
```

## 7. Owner PIN gate (Flutter)

```dart
// mobile/lib/shared/widgets/pin_dialog.dart
Future<String?> requestOwnerChallenge(BuildContext context, WidgetRef ref) async {
  final pin = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const OwnerPinSheet(),
  );
  if (pin == null) return null;
  try {
    final token = await ref.read(authRepositoryProvider).verifyOwnerPin(pin);
    return token;
  } on OwnerPinFailure {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Wrong PIN')));
    }
    return null;
  }
}
```

Usage:
```dart
final token = await requestOwnerChallenge(context, ref);
if (token == null) return;
await ref.read(productRepositoryProvider).updatePrice(p.id, newPrice, ownerChallengeToken: token);
```

## 8. Shift close (backend)

```python
async def close_shift(self, shift_id: UUID, declared_cash: Decimal) -> Shift:
    shift = await self._load_open_shift(shift_id)
    cash_sales = await self._sum_sales(shift_id, payment_method='cash')
    expenses_paid_cash = await self._sum_cash_expenses(shift_id)
    debt_collected_cash = await self._sum_debt_payments(shift_id, method='cash')
    expected = shift.opening_cash + cash_sales + debt_collected_cash - expenses_paid_cash

    shift.declared_closing_cash = declared_cash
    shift.expected_closing_cash = expected
    shift.closed_at = func.now()
    await self.db.flush()
    return shift
```

See `docs/13-shift-reconciliation.md` for the full formula.
