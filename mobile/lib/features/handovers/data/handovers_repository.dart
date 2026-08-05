import 'dart:async';
import 'dart:convert';

import 'package:decimal/decimal.dart';
import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:suuqii/core/http/dio_client.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/handovers/domain/entities/handover.dart';
import 'package:suuqii/features/inventory/data/lots_repository.dart';
import 'package:suuqii/features/sync/data/sync_worker.dart';
import 'package:uuid/uuid.dart';

part 'handovers_repository.g.dart';

/// One product line the baker is declaring: what came out of the oven and how
/// much of it went to the counter.
class HandoverDraftLine {
  const HandoverDraftLine({
    required this.productId,
    required this.productName,
    required this.produced,
    required this.handed,
    this.spoiled,
    this.expiryDate,
  });

  final String productId;
  final String productName;

  /// Units baked. Drives ingredient deduction — flour is consumed by the bake.
  final Decimal produced;

  /// Units actually passed to the counter. Usually `produced - spoiled`, but a
  /// baker may legitimately hold some back.
  final Decimal handed;
  final Decimal? spoiled;
  final DateTime? expiryDate;
}

class HandoversRemoteDataSource {
  HandoversRemoteDataSource(this._dio);
  final Dio _dio;

  /// GET /v1/handovers?status=…
  Future<List<Handover>> list({String status = 'pending'}) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/v1/handovers',
      queryParameters: {'status': status},
    );
    final items =
        (res.data?['items'] as List? ?? []).cast<Map<String, dynamic>>();
    return items.map(_parse).toList();
  }

  static Handover _parse(Map<String, dynamic> j) {
    final lines = (j['items'] as List? ?? []).cast<Map<String, dynamic>>();
    return Handover(
      id: j['id'] as String,
      fromUserId: j['from_user_id'] as String,
      toUserId: j['to_user_id'] as String?,
      acceptedByUserId: j['accepted_by_user_id'] as String?,
      shiftId: j['shift_id'] as String?,
      occurredAt: DateTime.parse(j['occurred_at'] as String),
      acceptedAt: j['accepted_at'] == null
          ? null
          : DateTime.parse(j['accepted_at'] as String),
      status: HandoverStatus.parse(j['status'] as String),
      note: j['note'] as String?,
      acceptNote: j['accept_note'] as String?,
      lines: lines
          .map(
            (l) => HandoverLine(
              id: l['id'] as String,
              productId: l['product_id'] as String,
              productName: l['product_name'] as String,
              qtyHanded: Decimal.parse(l['qty_handed'] as String),
              qtyReceived: l['qty_received'] == null
                  ? null
                  : Decimal.parse(l['qty_received'] as String),
            ),
          )
          .toList(),
    );
  }
}

/// Baker→counter handovers (docs/18-handovers.md).
///
/// A handover moves no stock. The baker's submit records *production* (which
/// creates the units and consumes the ingredients) and *the handover* (the
/// declared count) as separate sync events in one local transaction, because
/// that is one action from the baker's point of view and two facts from the
/// shop's.
class HandoversRepository {
  HandoversRepository({
    required this.db,
    required this.remote,
    required this.lots,
    required this.syncWorker,
    required this.shopId,
    required this.userId,
  });

  final AppDatabase db;
  final HandoversRemoteDataSource remote;
  final LotsRepository lots;
  final SyncWorker syncWorker;
  final String shopId;
  final String userId;

  Stream<List<Handover>> watchPending() => db.handoversDao.watchPending(shopId);
  Stream<List<Handover>> watchRecent() => db.handoversDao.watchRecent(shopId);

  /// Baker's submit: record each bake, then declare the handover.
  ///
  /// Production goes through [LotsRepository.recordProduction] so bakery costing
  /// (recipe-valued lots) and ingredient deduction stay in one place.
  Future<String> submitBake({
    required List<HandoverDraftLine> lines,
    String? toUserId,
    String? shiftId,
    String? note,
  }) async {
    if (lines.isEmpty) {
      throw StateError('Nothing to hand over');
    }
    for (final l in lines) {
      if (l.produced < Decimal.zero) {
        throw StateError('Produced quantity must not be negative');
      }
      if (l.handed < Decimal.zero) {
        throw StateError('Handed quantity must not be negative');
      }
      final spoiled = l.spoiled ?? Decimal.zero;
      if (l.handed > l.produced - spoiled) {
        throw StateError('Cannot hand over more than was baked');
      }
    }
    final seen = <String>{};
    for (final l in lines) {
      if (!seen.add(l.productId)) {
        // The server rejects duplicates too; failing here keeps the offline
        // queue clean instead of parking a doomed event in it.
        throw StateError('Each product may appear only once');
      }
    }

    for (final l in lines.where((l) => l.produced > Decimal.zero)) {
      await lots.recordProduction(
        productId: l.productId,
        quantityProduced: l.produced,
        quantitySpoiled: l.spoiled,
        expiryDate: l.expiryDate,
        note: note,
      );
    }

    final handed = lines.where((l) => l.handed > Decimal.zero).toList();
    if (handed.isEmpty) return '';

    final handoverId = const Uuid().v4();
    final now = DateTime.now().toUtc();
    final lineIds = {for (final l in handed) l.productId: const Uuid().v4()};

    await db.transaction(() async {
      await db.handoversDao.insertHandover(
        id: handoverId,
        shopId: shopId,
        fromUserId: userId,
        toUserId: toUserId,
        shiftId: shiftId,
        occurredAt: now,
        note: note,
      );
      for (final l in handed) {
        await db.handoversDao.insertLine(
          id: lineIds[l.productId]!,
          handoverId: handoverId,
          productId: l.productId,
          productName: l.productName,
          qtyHanded: l.handed,
        );
      }
      await db.into(db.syncEventsTable).insert(
            SyncEventsTableCompanion.insert(
              clientEventId: const Uuid().v4(),
              op: 'handover.create',
              occurredAt: now,
              payload: jsonEncode({
                'id': handoverId,
                if (toUserId != null) 'to_user_id': toUserId,
                if (shiftId != null) 'shift_id': shiftId,
                if (note != null && note.isNotEmpty) 'note': note,
                'occurred_at': now.toIso8601String(),
                'items': [
                  for (final l in handed)
                    {
                      'id': lineIds[l.productId],
                      'product_id': l.productId,
                      'product_name_snapshot': l.productName,
                      'qty_handed': l.handed.toString(),
                    },
                ],
              }),
            ),
          );
    });
    unawaited(syncWorker.kick());
    return handoverId;
  }

  /// Counter's submit: the second count.
  ///
  /// [countsByProductId] must cover every line — a partially counted handover
  /// has no meaningful variance, and the server rejects one outright.
  Future<void> acceptHandover({
    required String handoverId,
    required Map<String, Decimal> countsByProductId,
    String? note,
  }) async {
    final handover = await db.handoversDao.getById(handoverId);
    if (handover == null) {
      throw StateError('Handover not found');
    }
    if (!handover.isPending) {
      throw StateError('This handover has already been counted');
    }
    if (handover.fromUserId == userId) {
      // Also enforced server-side; blocking here avoids queueing an event that
      // is guaranteed to be rejected, and lets the UI say why immediately.
      throw StateError('You cannot count in a handover you made yourself');
    }
    final missing = handover.lines
        .where((l) => !countsByProductId.containsKey(l.productId))
        .toList();
    if (missing.isNotEmpty) {
      throw StateError('Count every line before submitting');
    }
    if (countsByProductId.values.any((v) => v < Decimal.zero)) {
      throw StateError('Counts must not be negative');
    }

    final now = DateTime.now().toUtc();
    await db.transaction(() async {
      await db.handoversDao.applyCounts(
        handoverId: handoverId,
        countsByProductId: countsByProductId,
        acceptedByUserId: userId,
        acceptedAt: now,
        acceptNote: note,
      );
      await db.into(db.syncEventsTable).insert(
            SyncEventsTableCompanion.insert(
              clientEventId: const Uuid().v4(),
              op: 'handover.accept',
              occurredAt: now,
              payload: jsonEncode({
                'handover_id': handoverId,
                if (note != null && note.isNotEmpty) 'note': note,
                'occurred_at': now.toIso8601String(),
                'items': [
                  for (final l in handover.lines)
                    {
                      'product_id': l.productId,
                      'qty_received': countsByProductId[l.productId]!.toString(),
                    },
                ],
              }),
            ),
          );
    });
    unawaited(syncWorker.kick());
  }

  /// Mirror handovers from the server, keeping any that still have a queued
  /// local accept (the local count is ahead of the server's view).
  Future<int> refreshFromServer() async {
    final remoteRows = await remote.list(status: 'all');
    final dirty = await _handoverIdsWithPendingAccepts();
    await db.handoversDao
        .replaceFromServer(remoteRows, dirty, shopId: shopId);
    return remoteRows.length;
  }

  Future<Set<String>> _handoverIdsWithPendingAccepts() async {
    final rows = await db.customSelect(
      "SELECT payload FROM sync_events WHERE status != 'synced' "
      "AND op IN ('handover.create', 'handover.accept')",
      readsFrom: {db.syncEventsTable},
    ).get();
    final ids = <String>{};
    for (final r in rows) {
      final payload =
          jsonDecode(r.read<String>('payload')) as Map<String, dynamic>;
      final id = (payload['handover_id'] ?? payload['id']) as String?;
      if (id != null) ids.add(id);
    }
    return ids;
  }
}

@Riverpod(keepAlive: true)
HandoversRepository handoversRepository(HandoversRepositoryRef ref) {
  final auth = ref.watch(authControllerProvider).valueOrNull;
  if (auth is! Authenticated) {
    throw StateError('HandoversRepository requires authenticated user');
  }
  return HandoversRepository(
    db: ref.watch(appDatabaseProvider),
    remote: HandoversRemoteDataSource(ref.watch(dioProvider)),
    lots: ref.watch(lotsRepositoryProvider),
    syncWorker: ref.watch(syncWorkerProvider),
    shopId: auth.shopId,
    userId: auth.userId,
  );
}

@riverpod
Stream<List<Handover>> pendingHandovers(PendingHandoversRef ref) =>
    ref.watch(handoversRepositoryProvider).watchPending();

@riverpod
Stream<List<Handover>> recentHandovers(RecentHandoversRef ref) =>
    ref.watch(handoversRepositoryProvider).watchRecent();

/// One-shot handover mirror, kicked from the handover screens. Failures are
/// swallowed — offline is normal.
@riverpod
class HandoversSync extends _$HandoversSync {
  @override
  Future<void> build() async {}

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final auth = ref.read(authControllerProvider).valueOrNull;
      if (auth is! Authenticated) return;
      await ref.read(handoversRepositoryProvider).refreshFromServer();
    });
  }
}
