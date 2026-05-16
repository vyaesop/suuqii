import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/money.dart';
import '../../../l10n/app_localizations.dart';
import '../data/shifts_repository.dart';

class ShiftScreen extends ConsumerWidget {
  const ShiftScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final shiftAsync = ref.watch(currentShiftProvider);

    return Scaffold(
      body: shiftAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (shift) {
          if (shift == null) {
            return _OpenShiftView(label: l.shiftOpeningCash);
          }
          return _ActiveShiftView(shiftId: shift.id, opened: shift.openedAt,
              openingCash: shift.openingCash);
        },
      ),
    );
  }
}

class _OpenShiftView extends ConsumerStatefulWidget {
  const _OpenShiftView({required this.label});
  final String label;
  @override
  ConsumerState<_OpenShiftView> createState() => _OpenShiftViewState();
}

class _OpenShiftViewState extends ConsumerState<_OpenShiftView> {
  final _ctrl = TextEditingController(text: '0');
  bool _busy = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(widget.label, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(prefixText: 'ETB  '),
            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _busy ? null : _open,
            child: const Text('Start shift'),
          ),
        ],
      ),
    );
  }

  Future<void> _open() async {
    final amount = Decimal.tryParse(_ctrl.text.trim());
    if (amount == null || amount < Decimal.zero) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid amount')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      await ref.read(shiftsRepositoryProvider).open(openingCash: amount);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _ActiveShiftView extends ConsumerWidget {
  const _ActiveShiftView({
    required this.shiftId,
    required this.opened,
    required this.openingCash,
  });
  final String shiftId;
  final DateTime opened;
  final Decimal openingCash;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Shift open',
              style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 4),
          Text('Since ${opened.toLocal()}'),
          const SizedBox(height: 24),
          _StatRow(label: l.shiftOpeningCash, value: formatMoney(openingCash)),
          const Spacer(),
          FilledButton.icon(
            icon: const Icon(Icons.flag),
            onPressed: () => _closeShift(context, ref),
            label: Text(l.shiftEnd),
          ),
        ],
      ),
    );
  }

  Future<void> _closeShift(BuildContext context, WidgetRef ref) async {
    final result = await showModalBottomSheet<({Decimal declared, String? note})>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _CloseSheet(),
    );
    if (result == null) return;
    try {
      final r = await ref.read(shiftsRepositoryProvider).close(
            shiftId: shiftId,
            declaredCash: result.declared,
            note: result.note,
          );
      if (context.mounted) {
        showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Shift closed'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Expected: ${formatMoney(r.expected)}'),
                Text('Declared: ${formatMoney(result.declared)}'),
                Text('Variance: ${formatMoney(r.shift.variance ?? Decimal.zero)}'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
    }
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _CloseSheet extends StatefulWidget {
  const _CloseSheet();
  @override
  State<_CloseSheet> createState() => _CloseSheetState();
}

class _CloseSheetState extends State<_CloseSheet> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  @override
  void dispose() { _amount.dispose(); _note.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Declared cash', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              TextField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(prefixText: 'ETB  '),
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _note,
                decoration: const InputDecoration(labelText: 'Note (optional)'),
                maxLines: 2,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  final dec = Decimal.tryParse(_amount.text.trim());
                  if (dec == null || dec < Decimal.zero) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Enter a valid amount')),
                    );
                    return;
                  }
                  Navigator.pop(context, (
                    declared: dec,
                    note: _note.text.trim().isEmpty ? null : _note.text.trim(),
                  ));
                },
                child: const Text('Close shift'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
