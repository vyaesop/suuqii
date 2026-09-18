import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/inventory/presentation/widgets/quantity_input.dart';
import 'package:suuqii/shared/widgets/sheet_handle.dart';

/// Result of the stock sheet: either a proper batch receive (quantity, unit
/// cost, optional expiry + spoiled-on-arrival) or a manual correction
/// (negative `inventory.adjust`).
sealed class StockAdjustResult {
  const StockAdjustResult();
}

class ReceiveStockResult extends StockAdjustResult {
  const ReceiveStockResult({
    required this.quantity,
    required this.unitCost,
    this.expiryDate,
    this.spoiledQuantity,
    this.note,
  });
  final Decimal quantity;
  final Decimal unitCost;
  final DateTime? expiryDate;
  final Decimal? spoiledQuantity;
  final String? note;
}

class RemoveStockResult extends StockAdjustResult {
  const RemoveStockResult({required this.quantity, required this.reason});

  /// Positive; the caller applies it as a negative delta.
  final Decimal quantity;
  final String reason;
}

/// Bottom sheet for stock input. "Add" is a full batch receive (creates a
/// stock lot: cost, expiry, spoiled-on-arrival); "Remove" stays a manual
/// correction via inventory.adjust. Returns a [StockAdjustResult] on confirm
/// or `null` on cancel. The owner-PIN challenge is the caller's
/// responsibility.
class StockAdjustSheet extends StatefulWidget {
  const StockAdjustSheet({
    required this.product,
    this.showExpiry = true,
    this.integerOnly = false,
    super.key,
  });

  final Product product;

  /// `ShopFeatures.tracksExpiry` — apparel never expires, so boutiques get no
  /// expiry picker on receive.
  final bool showExpiry;

  /// `ShopFeatures.locksUnit` — whole-number quantities only.
  final bool integerOnly;

  @override
  State<StockAdjustSheet> createState() => _StockAdjustSheetState();
}

class _StockAdjustSheetState extends State<StockAdjustSheet> {
  final _qty = TextEditingController();
  late final TextEditingController _cost;
  final _spoiled = TextEditingController();
  final _note = TextEditingController();
  DateTime? _expiry;
  String _movement = 'receive';
  String _reason = 'count correction';

  /// Correction reasons for the Remove segment. Expired/damaged goods should
  /// go through "Record spoilage" instead, so they are valued at lot cost.
  static const _removeReasons = ['count correction', 'theft', 'transfer out'];

  @override
  void initState() {
    super.initState();
    // Prefill with the product's last cost (0 for cashiers — the server
    // masks purchase prices; they type the invoice cost themselves).
    final last = widget.product.purchasePrice;
    _cost = TextEditingController(
      text: last > Decimal.zero ? last.toStringAsFixed(2) : '',
    );
  }

  @override
  void dispose() {
    _qty.dispose();
    _cost.dispose();
    _spoiled.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickExpiry() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _expiry ?? now,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 5),
    );
    if (picked != null) setState(() => _expiry = picked);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final receiving = _movement == 'receive';
    return SuuqSheet(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            receiving ? l.stockReceiveTitle : l.stockAdjustTitle,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: SuuqSpacing.md),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(
                value: 'receive',
                label: Text(l.commonAdd),
                icon: const Icon(Icons.add_rounded),
              ),
              ButtonSegment(
                value: 'adjustment',
                label: Text(l.commonRemove),
                icon: const Icon(Icons.remove_rounded),
              ),
            ],
            selected: {_movement},
            onSelectionChanged: (s) => setState(() => _movement = s.first),
          ),
          const SizedBox(height: SuuqSpacing.md),
          TextField(
            controller: _qty,
            keyboardType: quantityKeyboard(integerOnly: widget.integerOnly),
            inputFormatters:
                quantityFormatters(integerOnly: widget.integerOnly),
            decoration: InputDecoration(
              labelText: l.stockAdjustQuantityLabel,
              suffixText: widget.integerOnly ? null : widget.product.unit,
            ),
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: SuuqSpacing.sm),
          if (receiving) ...[
            TextField(
              controller: _cost,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: l.stockReceiveUnitCostLabel,
                prefixText: 'ETB  ',
              ),
            ),
            if (widget.showExpiry) ...[
              const SizedBox(height: SuuqSpacing.sm),
              InkWell(
                onTap: _pickExpiry,
                borderRadius: BorderRadius.circular(SuuqRadius.sm),
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: l.stockReceiveExpiryLabel,
                    suffixIcon: _expiry == null
                        ? const Icon(Icons.event_rounded)
                        : IconButton(
                            icon: const Icon(Icons.clear_rounded, size: 18),
                            onPressed: () => setState(() => _expiry = null),
                          ),
                  ),
                  child: Text(
                    _expiry == null
                        ? l.stockReceiveNoExpiry
                        : context.dateShort(_expiry!),
                  ),
                ),
              ),
            ],
            const SizedBox(height: SuuqSpacing.sm),
            TextField(
              controller: _spoiled,
              keyboardType: quantityKeyboard(integerOnly: widget.integerOnly),
              inputFormatters:
                  quantityFormatters(integerOnly: widget.integerOnly),
              decoration: InputDecoration(
                labelText: l.stockReceiveSpoiledLabel,
                suffixText: widget.integerOnly ? null : widget.product.unit,
              ),
            ),
            const SizedBox(height: SuuqSpacing.sm),
            TextField(
              controller: _note,
              decoration:
                  InputDecoration(labelText: l.stockReceiveNoteLabel),
              textCapitalization: TextCapitalization.sentences,
            ),
          ] else ...[
            DropdownButtonFormField<String>(
              initialValue: _reason,
              decoration:
                  InputDecoration(labelText: l.stockAdjustReasonLabel),
              items: _removeReasons
                  .map(
                    (r) => DropdownMenuItem(
                      value: r,
                      child: Text(_reasonLabel(l, r)),
                    ),
                  )
                  .toList(),
              onChanged: (v) => setState(() => _reason = v ?? _reason),
            ),
            const SizedBox(height: SuuqSpacing.xs),
            Text(
              l.stockAdjustSpoilageHint,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: SuuqSpacing.lg),
          FilledButton(
            onPressed: _submit,
            child: Text(
              receiving ? l.stockReceiveApply : l.stockAdjustApply,
            ),
          ),
        ],
      ),
    );
  }

  void _submit() {
    final l = context.l10n;
    final n = Decimal.tryParse(_qty.text.trim());
    if (n == null || n <= Decimal.zero) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.stockAdjustEnterPositive)),
      );
      return;
    }
    if (_movement != 'receive') {
      Navigator.pop(context, RemoveStockResult(quantity: n, reason: _reason));
      return;
    }
    final cost = Decimal.tryParse(_cost.text.trim()) ?? Decimal.zero;
    if (cost < Decimal.zero) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.stockAdjustEnterPositive)),
      );
      return;
    }
    final spoiledText = _spoiled.text.trim();
    Decimal? spoiled;
    if (spoiledText.isNotEmpty) {
      spoiled = Decimal.tryParse(spoiledText);
      if (spoiled == null || spoiled < Decimal.zero || spoiled > n) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.stockReceiveSpoiledInvalid)),
        );
        return;
      }
    }
    final note = _note.text.trim();
    Navigator.pop(
      context,
      ReceiveStockResult(
        quantity: n,
        unitCost: cost,
        expiryDate: _expiry,
        spoiledQuantity: spoiled,
        note: note.isEmpty ? null : note,
      ),
    );
  }

  /// Display label for a machine reason value (the value itself is persisted
  /// and must stay in English).
  String _reasonLabel(AppLocalizations l, String reason) {
    switch (reason) {
      case 'count correction':
        return l.stockAdjustReasonCountCorrection;
      case 'theft':
        return l.stockAdjustReasonTheft;
      case 'transfer out':
        return l.stockAdjustReasonTransferOut;
      default:
        return reason;
    }
  }
}
