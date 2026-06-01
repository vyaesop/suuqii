import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/shared/widgets/sheet_handle.dart';

/// Bottom sheet for stock adjustments. Returns a signed delta + reason
/// (positive for restocks, negative for adjustments) on confirm, or `null`
/// on cancel. The owner-PIN challenge is the caller's responsibility.
class StockAdjustSheet extends StatefulWidget {
  const StockAdjustSheet({super.key});

  @override
  State<StockAdjustSheet> createState() => _StockAdjustSheetState();
}

class _StockAdjustSheetState extends State<StockAdjustSheet> {
  final _qty = TextEditingController();
  String _movement = 'restock';
  String _reason = 'restock';

  static const _reasonsByMovement = {
    'restock': ['restock', 'supplier delivery', 'transfer in'],
    'adjustment': [
      'count correction',
      'waste',
      'damaged',
      'theft',
      'transfer out',
    ],
  };

  @override
  void initState() {
    super.initState();
    _reason = _reasonsByMovement[_movement]!.first;
  }

  @override
  void dispose() {
    _qty.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SuuqSheet(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Adjust stock',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: SuuqSpacing.md),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'restock',
                label: Text('Add'),
                icon: Icon(Icons.add_rounded),
              ),
              ButtonSegment(
                value: 'adjustment',
                label: Text('Remove'),
                icon: Icon(Icons.remove_rounded),
              ),
            ],
            selected: {_movement},
            onSelectionChanged: (s) => setState(() {
              _movement = s.first;
              _reason = _reasonsByMovement[_movement]!.first;
            }),
          ),
          const SizedBox(height: SuuqSpacing.md),
          TextField(
            controller: _qty,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Quantity'),
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: SuuqSpacing.sm),
          DropdownButtonFormField<String>(
            value: _reason,
            decoration: const InputDecoration(labelText: 'Reason'),
            items: _reasonsByMovement[_movement]!
                .map(
                  (r) => DropdownMenuItem(value: r, child: Text(r)),
                )
                .toList(),
            onChanged: (v) => setState(() => _reason = v ?? _reason),
          ),
          const SizedBox(height: SuuqSpacing.lg),
          FilledButton(
            onPressed: () {
              final n = Decimal.tryParse(_qty.text.trim());
              if (n == null || n <= Decimal.zero) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Enter a positive number')),
                );
                return;
              }
              final signed = _movement == 'restock' ? n : -n;
              Navigator.pop(context, (delta: signed, reason: _reason));
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }
}
