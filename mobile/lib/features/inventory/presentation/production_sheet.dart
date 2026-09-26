import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/shared/widgets/sheet_handle.dart';

class ProductionResult {
  const ProductionResult({
    required this.produced,
    this.spoiled,
    this.expiryDate,
    this.note,
  });
  final Decimal produced;
  final Decimal? spoiled;
  final DateTime? expiryDate;
  final String? note;
}

/// Bakery bottom sheet: record a production run — units produced, units
/// spoiled/burnt, optional expiry (bread usually keeps 1–2 days) and note.
/// Returns a [ProductionResult] on confirm, `null` on cancel. Owner-PIN
/// challenge is the caller's responsibility.
class ProductionSheet extends StatefulWidget {
  const ProductionSheet({required this.productUnit, super.key});

  final String productUnit;

  @override
  State<ProductionSheet> createState() => _ProductionSheetState();
}

class _ProductionSheetState extends State<ProductionSheet> {
  final _produced = TextEditingController();
  final _spoiled = TextEditingController();
  final _note = TextEditingController();
  DateTime? _expiry;

  @override
  void dispose() {
    _produced.dispose();
    _spoiled.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickExpiry() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      // Bread usually keeps a day or two — start the picker at tomorrow.
      initialDate:
          _expiry ?? DateTime(now.year, now.month, now.day + 1),
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: DateTime(now.year + 1),
    );
    if (picked != null) setState(() => _expiry = picked);
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return SuuqSheet(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l.productionTitle,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: SuuqSpacing.md),
          TextField(
            controller: _produced,
            autofocus: true,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: l.productionProducedLabel,
              suffixText: widget.productUnit,
            ),
            style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: SuuqSpacing.sm),
          TextField(
            controller: _spoiled,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: l.productionSpoiledLabel,
              suffixText: widget.productUnit,
              helperText: l.productionSpoiledHelper,
            ),
          ),
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
          const SizedBox(height: SuuqSpacing.sm),
          TextField(
            controller: _note,
            decoration: InputDecoration(labelText: l.stockReceiveNoteLabel),
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: SuuqSpacing.lg),
          FilledButton(
            onPressed: _submit,
            child: Text(l.productionApply),
          ),
        ],
      ),
    );
  }

  void _submit() {
    final l = context.l10n;
    final produced = Decimal.tryParse(_produced.text.trim());
    if (produced == null || produced <= Decimal.zero) {
      SuuqSheet.showMessage(context, l.stockAdjustEnterPositive);
      return;
    }
    Decimal? spoiled;
    final spoiledText = _spoiled.text.trim();
    if (spoiledText.isNotEmpty) {
      spoiled = Decimal.tryParse(spoiledText);
      if (spoiled == null || spoiled < Decimal.zero || spoiled > produced) {
        SuuqSheet.showMessage(context, l.productionSpoiledInvalid);
        return;
      }
    }
    final note = _note.text.trim();
    Navigator.pop(
      context,
      ProductionResult(
        produced: produced,
        spoiled: spoiled,
        expiryDate: _expiry,
        note: note.isEmpty ? null : note,
      ),
    );
  }
}
