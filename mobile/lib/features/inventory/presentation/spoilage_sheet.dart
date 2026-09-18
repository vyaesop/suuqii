import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/features/inventory/data/lots_repository.dart';
import 'package:suuqii/features/inventory/domain/entities/stock_lot.dart';
import 'package:suuqii/features/inventory/presentation/widgets/quantity_input.dart';
import 'package:suuqii/shared/widgets/sheet_handle.dart';

class SpoilageResult {
  const SpoilageResult({
    required this.quantity,
    required this.reason,
    this.lotId,
  });
  final Decimal quantity;
  final String reason;

  /// Specific batch to draw from; null = FEFO (expiring/oldest first).
  final String? lotId;
}

/// Bottom sheet: record spoilage (expired, damaged, day-old bread…).
/// Quantity + reason + optional specific batch (defaults to FEFO). Returns a
/// [SpoilageResult] on confirm, `null` on cancel. Owner-PIN challenge is the
/// caller's responsibility — spoilage is a classic shrinkage vector.
class SpoilageSheet extends ConsumerStatefulWidget {
  const SpoilageSheet({
    required this.productId,
    required this.productUnit,
    this.initialLotId,
    this.initialQuantity,
    this.initialReason,
    this.title,
    this.integerOnly = false,
    this.damagedLostWording = false,
    super.key,
  });

  final String productId;
  final String productUnit;

  /// Feature-driven wording ("Record spoilage" / "Record damaged / lost");
  /// defaults to the spoilage title.
  final String? title;

  /// `ShopFeatures.locksUnit` — whole-number quantities only.
  final bool integerOnly;

  /// `ShopFeatures.isDamagedLostWording` — which reason list to offer. It is
  /// a separate feature from [integerOnly]: a shop can lock units without
  /// selling goods that never expire.
  final bool damagedLostWording;

  /// Pre-fills for the "mark expired lot spoiled" one-tap flow.
  final String? initialLotId;
  final Decimal? initialQuantity;
  final String? initialReason;

  @override
  ConsumerState<SpoilageSheet> createState() => _SpoilageSheetState();
}

class _SpoilageSheetState extends ConsumerState<SpoilageSheet> {
  late final TextEditingController _qty;
  late String _reason;
  String? _lotId;

  static const _reasons = ['expired', 'damaged', 'day-old', 'other'];

  /// Nothing in a boutique expires or goes stale; the reasons that make
  /// sense there are damage, loss/theft, or other.
  static const _damagedLostReasons = ['damaged', 'theft', 'other'];

  List<String> get _reasonOptions =>
      widget.damagedLostWording ? _damagedLostReasons : _reasons;

  @override
  void initState() {
    super.initState();
    _qty = TextEditingController(
      text: widget.initialQuantity == null
          ? ''
          : _fmtQty(widget.initialQuantity!),
    );
    _reason = widget.initialReason ?? _reasonOptions.first;
    _lotId = widget.initialLotId;
  }

  @override
  void dispose() {
    _qty.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final lotsAsync = ref.watch(watchProductLotsProvider(widget.productId));
    final lots = lotsAsync.valueOrNull ?? const <StockLot>[];
    // Guard against a stale initial lot id that is no longer open.
    final lotValue =
        lots.any((lot) => lot.id == _lotId) ? _lotId : null;

    return SuuqSheet(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.title ?? l.spoilageTitle,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: SuuqSpacing.md),
          TextField(
            controller: _qty,
            autofocus: widget.initialQuantity == null,
            keyboardType: quantityKeyboard(integerOnly: widget.integerOnly),
            inputFormatters:
                quantityFormatters(integerOnly: widget.integerOnly),
            decoration: InputDecoration(
              labelText: l.stockAdjustQuantityLabel,
              suffixText: widget.integerOnly ? null : widget.productUnit,
            ),
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: SuuqSpacing.sm),
          DropdownButtonFormField<String>(
            initialValue: _reason,
            decoration: InputDecoration(labelText: l.stockAdjustReasonLabel),
            items: _reasonOptions
                .map(
                  (r) => DropdownMenuItem(
                    value: r,
                    child: Text(spoilageReasonLabel(l, r)),
                  ),
                )
                .toList(),
            onChanged: (v) => setState(() => _reason = v ?? _reason),
          ),
          if (lots.isNotEmpty) ...[
            const SizedBox(height: SuuqSpacing.sm),
            DropdownButtonFormField<String?>(
              initialValue: lotValue,
              decoration: InputDecoration(labelText: l.spoilageLotLabel),
              items: [
                DropdownMenuItem<String?>(
                  child: Text(l.spoilageLotAuto),
                ),
                for (final lot in lots)
                  DropdownMenuItem<String?>(
                    value: lot.id,
                    child: Text(
                      l.spoilageLotOption(
                        context.dateShort(lot.receivedAt.toLocal()),
                        _fmtQty(lot.qtyRemaining),
                        lot.expiryDate == null
                            ? '—'
                            : context.dateShort(lot.expiryDate!),
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) => setState(() => _lotId = v),
            ),
          ],
          const SizedBox(height: SuuqSpacing.lg),
          FilledButton(
            onPressed: () {
              final n = Decimal.tryParse(_qty.text.trim());
              if (n == null || n <= Decimal.zero) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l.stockAdjustEnterPositive)),
                );
                return;
              }
              Navigator.pop(
                context,
                SpoilageResult(quantity: n, reason: _reason, lotId: lotValue),
              );
            },
            child: Text(l.spoilageApply),
          ),
        ],
      ),
    );
  }

  static String _fmtQty(Decimal d) {
    final n = d.toDouble();
    if (n == n.roundToDouble()) return n.toInt().toString();
    return n.toStringAsFixed(2);
  }
}

/// Display label for a machine spoilage-reason value (the value itself is
/// persisted and must stay in English).
String spoilageReasonLabel(AppLocalizations l, String reason) {
  switch (reason) {
    case 'expired':
      return l.spoilageReasonExpired;
    case 'damaged':
      return l.stockAdjustReasonDamaged;
    case 'theft':
      return l.stockAdjustReasonTheft;
    case 'day-old':
      return l.spoilageReasonDayOld;
    case 'other':
      return l.spoilageReasonOther;
    default:
      return reason;
  }
}
