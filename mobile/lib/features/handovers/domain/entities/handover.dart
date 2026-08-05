import 'package:decimal/decimal.dart';

/// Reconciliation state of a handover.
enum HandoverStatus {
  /// Handed over, not yet counted by the counter.
  pending,

  /// Both counts agreed on every line.
  accepted,

  /// At least one line differed. This is the state the owner needs to see.
  disputed;

  static HandoverStatus parse(String raw) => switch (raw) {
        'accepted' => HandoverStatus.accepted,
        'disputed' => HandoverStatus.disputed,
        _ => HandoverStatus.pending,
      };

  String get wire => name;
}

/// One product line: the baker's count and, once reconciled, the counter's.
class HandoverLine {
  const HandoverLine({
    required this.id,
    required this.productId,
    required this.productName,
    required this.qtyHanded,
    this.qtyReceived,
  });

  final String id;
  final String productId;
  final String productName;
  final Decimal qtyHanded;
  final Decimal? qtyReceived;

  /// Counter's count minus baker's count. Null until accepted. Negative means
  /// fewer arrived than were declared.
  Decimal? get variance =>
      qtyReceived == null ? null : qtyReceived! - qtyHanded;

  bool get matches => variance == Decimal.zero;
}

/// A baker → counter transfer, recorded twice by two different people.
///
/// Moves no stock — production created the units and the sale consumes them.
/// See docs/18-handovers.md.
class Handover {
  const Handover({
    required this.id,
    required this.fromUserId,
    required this.occurredAt,
    required this.status,
    required this.lines,
    this.toUserId,
    this.acceptedByUserId,
    this.shiftId,
    this.acceptedAt,
    this.note,
    this.acceptNote,
  });

  final String id;
  final String fromUserId;
  final String? toUserId;
  final String? acceptedByUserId;
  final String? shiftId;
  final DateTime occurredAt;
  final DateTime? acceptedAt;
  final HandoverStatus status;
  final String? note;
  final String? acceptNote;
  final List<HandoverLine> lines;

  bool get isPending => status == HandoverStatus.pending;

  /// Total units the baker declared, across all lines.
  Decimal get totalHanded =>
      lines.fold(Decimal.zero, (sum, l) => sum + l.qtyHanded);

  /// Lines where the two counts disagreed.
  List<HandoverLine> get discrepancies =>
      lines.where((l) => l.qtyReceived != null && !l.matches).toList();

  /// Sum of |variance| — the honest measure of how far apart the counts were.
  /// Net would let an over-count on one line hide an under-count on another.
  Decimal get grossVariance => lines.fold(
        Decimal.zero,
        (sum, l) => sum + (l.variance?.abs() ?? Decimal.zero),
      );
}
