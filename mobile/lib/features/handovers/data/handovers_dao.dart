import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart';

import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/core/storage/tables/handovers_table.dart';
import 'package:suuqii/features/handovers/domain/entities/handover.dart';

part 'handovers_dao.g.dart';

/// Local mirror of handovers + their two counts (docs/18-handovers.md).
///
/// Mutating methods participate in the caller's Drift transaction (Drift
/// transactions are zone-scoped) so the repository can compose a handover write
/// with its sync-event enqueue atomically.
@DriftAccessor(tables: [HandoversTable, HandoverItemsTable])
class HandoversDao extends DatabaseAccessor<AppDatabase>
    with _$HandoversDaoMixin {
  HandoversDao(super.db);

  static Decimal _dec(double v) => Decimal.parse(v.toString());

  Future<void> insertHandover({
    required String id,
    required String shopId,
    required String fromUserId,
    required DateTime occurredAt,
    String? toUserId,
    String? shiftId,
    String? note,
    String status = 'pending',
    String? acceptedByUserId,
    DateTime? acceptedAt,
    String? acceptNote,
  }) {
    return into(handoversTable).insert(
      HandoversTableCompanion.insert(
        id: id,
        shopId: shopId,
        fromUserId: fromUserId,
        toUserId: Value(toUserId),
        acceptedByUserId: Value(acceptedByUserId),
        shiftId: Value(shiftId),
        occurredAt: occurredAt,
        acceptedAt: Value(acceptedAt),
        status: Value(status),
        note: Value(note),
        acceptNote: Value(acceptNote),
      ),
      mode: InsertMode.insertOrReplace,
    );
  }

  Future<void> insertLine({
    required String id,
    required String handoverId,
    required String productId,
    required String productName,
    required Decimal qtyHanded,
    Decimal? qtyReceived,
  }) {
    return into(handoverItemsTable).insert(
      HandoverItemsTableCompanion.insert(
        id: id,
        handoverId: handoverId,
        productId: productId,
        productNameSnapshot: productName,
        qtyHanded: qtyHanded.toDouble(),
        qtyReceived: Value(qtyReceived?.toDouble()),
      ),
      mode: InsertMode.insertOrReplace,
    );
  }

  /// Record the counter's count and settle the status: `accepted` when every
  /// line matched, `disputed` when any differed.
  Future<void> applyCounts({
    required String handoverId,
    required Map<String, Decimal> countsByProductId,
    required String acceptedByUserId,
    required DateTime acceptedAt,
    String? acceptNote,
  }) async {
    final lines = await (select(handoverItemsTable)
          ..where((t) => t.handoverId.equals(handoverId)))
        .get();
    var disputed = false;
    for (final line in lines) {
      final counted = countsByProductId[line.productId];
      if (counted == null) continue;
      if (counted != _dec(line.qtyHanded)) disputed = true;
      await (update(handoverItemsTable)..where((t) => t.id.equals(line.id)))
          .write(
        HandoverItemsTableCompanion(qtyReceived: Value(counted.toDouble())),
      );
    }
    await (update(handoversTable)..where((t) => t.id.equals(handoverId))).write(
      HandoversTableCompanion(
        status: Value(disputed ? 'disputed' : 'accepted'),
        acceptedByUserId: Value(acceptedByUserId),
        acceptedAt: Value(acceptedAt),
        acceptNote: Value(acceptNote),
      ),
    );
  }

  Future<Handover?> getById(String id) async {
    final rows = await _query(ids: [id]);
    return rows.isEmpty ? null : rows.first;
  }

  /// Handovers waiting to be counted, oldest first — the counter should clear
  /// the morning's tray before the afternoon's.
  Stream<List<Handover>> watchPending(String shopId) {
    return (select(handoversTable)
          ..where((t) => t.shopId.equals(shopId))
          ..where((t) => t.status.equals('pending'))
          ..orderBy([(t) => OrderingTerm.asc(t.occurredAt)]))
        .watch()
        .asyncMap(_hydrate);
  }

  /// Recent handovers regardless of status, newest first.
  Stream<List<Handover>> watchRecent(String shopId, {int limit = 30}) {
    return (select(handoversTable)
          ..where((t) => t.shopId.equals(shopId))
          ..orderBy([(t) => OrderingTerm.desc(t.occurredAt)])
          ..limit(limit))
        .watch()
        .asyncMap(_hydrate);
  }

  Future<List<Handover>> _query({required List<String> ids}) async {
    final rows = await (select(handoversTable)
          ..where((t) => t.id.isIn(ids)))
        .get();
    return _hydrate(rows);
  }

  Future<List<Handover>> _hydrate(List<HandoverRow> rows) async {
    if (rows.isEmpty) return const [];
    final lines = await (select(handoverItemsTable)
          ..where((t) => t.handoverId.isIn(rows.map((r) => r.id).toList()))
          ..orderBy([(t) => OrderingTerm.asc(t.productNameSnapshot)]))
        .get();
    final byHandover = <String, List<HandoverLine>>{};
    for (final l in lines) {
      byHandover.putIfAbsent(l.handoverId, () => []).add(
            HandoverLine(
              id: l.id,
              productId: l.productId,
              productName: l.productNameSnapshot,
              qtyHanded: _dec(l.qtyHanded),
              qtyReceived:
                  l.qtyReceived == null ? null : _dec(l.qtyReceived!),
            ),
          );
    }
    return rows
        .map(
          (r) => Handover(
            id: r.id,
            fromUserId: r.fromUserId,
            toUserId: r.toUserId,
            acceptedByUserId: r.acceptedByUserId,
            shiftId: r.shiftId,
            occurredAt: r.occurredAt,
            acceptedAt: r.acceptedAt,
            status: HandoverStatus.parse(r.status),
            note: r.note,
            acceptNote: r.acceptNote,
            lines: byHandover[r.id] ?? const [],
          ),
        )
        .toList();
  }

  /// Mirror pass: replace local handovers with the server's.
  ///
  /// Rows with a queued local `handover.accept` are skipped — the local count
  /// is ahead of what the server knows, and overwriting it would silently
  /// discard a count the counter already made offline.
  Future<void> replaceFromServer(
    List<Handover> handovers,
    Set<String> skipIds, {
    required String shopId,
  }) async {
    await transaction(() async {
      final incoming = handovers.where((h) => !skipIds.contains(h.id)).toList();
      if (skipIds.isEmpty) {
        await delete(handoverItemsTable).go();
        await (delete(handoversTable)..where((t) => t.shopId.equals(shopId)))
            .go();
      } else {
        await (delete(handoverItemsTable)
              ..where((t) => t.handoverId.isNotIn(skipIds.toList())))
            .go();
        await (delete(handoversTable)
              ..where((t) => t.shopId.equals(shopId))
              ..where((t) => t.id.isNotIn(skipIds.toList())))
            .go();
      }
      for (final h in incoming) {
        await insertHandover(
          id: h.id,
          shopId: shopId,
          fromUserId: h.fromUserId,
          toUserId: h.toUserId,
          acceptedByUserId: h.acceptedByUserId,
          shiftId: h.shiftId,
          occurredAt: h.occurredAt,
          acceptedAt: h.acceptedAt,
          status: h.status.wire,
          note: h.note,
          acceptNote: h.acceptNote,
        );
        for (final l in h.lines) {
          await insertLine(
            id: l.id,
            handoverId: h.id,
            productId: l.productId,
            productName: l.productName,
            qtyHanded: l.qtyHanded,
            qtyReceived: l.qtyReceived,
          );
        }
      }
    });
  }
}
