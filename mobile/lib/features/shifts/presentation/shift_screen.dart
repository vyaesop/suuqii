import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/utils/money.dart';
import 'package:suuqii/features/shifts/data/shifts_repository.dart';
import 'package:suuqii/features/shifts/domain/entities/shift.dart';
import 'package:suuqii/l10n/app_localizations.dart';
import 'package:suuqii/shared/widgets/empty_state.dart';
import 'package:suuqii/shared/widgets/section_card.dart';
import 'package:suuqii/shared/widgets/sheet_handle.dart';

class ShiftScreen extends ConsumerWidget {
  const ShiftScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final shiftAsync = ref.watch(currentShiftProvider);

    return Scaffold(
      body: shiftAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.error_outline,
          title: 'Failed to load shift',
          message: '$e',
        ),
        data: (shift) {
          if (shift == null) {
            return _OpenShiftView(label: l.shiftOpeningCash);
          }
          return _ActiveShiftView(
            shiftId: shift.id,
            opened: shift.openedAt,
            openingCash: shift.openingCash,
          );
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
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(
          horizontal: SuuqSpacing.lg,
          vertical: SuuqSpacing.md,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: SuuqSpacing.xl),
            Icon(
              Icons.timelapse_rounded,
              size: 48,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(height: SuuqSpacing.md),
            Text(
              'Start your shift',
              style: theme.textTheme.displaySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: SuuqSpacing.xs),
            Text(
              'Count the cash in the till before you start selling.',
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: SuuqSpacing.xl),
            SectionCard(
              padding: const EdgeInsets.all(SuuqSpacing.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    widget.label.toUpperCase(),
                    style: theme.textTheme.labelSmall
                        ?.copyWith(letterSpacing: 1.2),
                  ),
                  const SizedBox(height: SuuqSpacing.xs),
                  TextField(
                    controller: _ctrl,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      prefixText: 'ETB  ',
                    ),
                    style: theme.textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: SuuqSpacing.lg),
            FilledButton.icon(
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.play_arrow_rounded),
              onPressed: _busy ? null : _open,
              label: const Text('Start shift'),
            ),
          ],
        ),
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
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(shiftsRepositoryProvider).open(openingCash: amount);
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
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
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context);
    final scheme = theme.colorScheme;
    final elapsed = DateTime.now().difference(opened);

    return SafeArea(
      child: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(SuuqSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SectionCard(
                    padding: const EdgeInsets.all(SuuqSpacing.lg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: SuuqSpacing.xs),
                            Text(
                              'SHIFT OPEN',
                              style: theme.textTheme.labelSmall?.copyWith(
                                letterSpacing: 1.4,
                                color: scheme.primary,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: SuuqSpacing.sm),
                        Text(
                          _humanDuration(elapsed),
                          style: theme.textTheme.displaySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                        Text(
                          'Since ${_clock(opened.toLocal())}',
                          style: theme.textTheme.bodyMedium,
                        ),
                        const Divider(height: SuuqSpacing.xl),
                        InfoRow(
                          label: l.shiftOpeningCash,
                          value: formatMoney(openingCash),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: SuuqSpacing.md),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      'When you finish your shift, count the cash drawer. '
                      'We compare it with expected cash and surface any variance.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SuuqSpacing.md, 0, SuuqSpacing.md, SuuqSpacing.md,
            ),
            child: FilledButton.icon(
              icon: const Icon(Icons.flag_rounded),
              onPressed: () => _closeShift(context, ref),
              label: Text(l.shiftEnd),
            ),
          ),
        ],
      ),
    );
  }

  String _clock(DateTime d) =>
      '${_pad(d.hour)}:${_pad(d.minute)}';
  String _pad(int n) => n < 10 ? '0$n' : '$n';

  String _humanDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }

  Future<void> _closeShift(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final repo = ref.read(shiftsRepositoryProvider);

    // Compute the live breakdown so the cashier sees expected cash before
    // they enter their declared count.
    final preview = await repo.computeBreakdown(shiftId, openingCash);
    if (!context.mounted) return;

    final result = await showModalBottomSheet<({Decimal declared, String? note})>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CloseSheet(breakdown: preview),
    );
    if (result == null) return;
    try {
      final r = await repo.close(
        shiftId: shiftId,
        declaredCash: result.declared,
        note: result.note,
      );
      if (!context.mounted) return;
      unawaited(
        showDialog<void>(
          context: context,
          builder: (_) {
            final variance = r.shift.variance ?? Decimal.zero;
            final isShort = variance < Decimal.zero;
            final isOver = variance > Decimal.zero;
            final b = r.breakdown;
            return AlertDialog(
              title: const Text('Shift closed'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _BreakdownTable(breakdown: b),
                    const Divider(),
                    InfoRow(
                      label: 'Declared',
                      value: formatMoney(result.declared),
                    ),
                    InfoRow(
                      label: 'Variance',
                      value: formatMoney(variance),
                      emphasize: true,
                      intent: isShort
                          ? Theme.of(context).colorScheme.error
                          : isOver
                              ? Theme.of(context).colorScheme.primary
                              : null,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Done'),
                ),
              ],
            );
          },
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    }
  }
}

class _CloseSheet extends StatefulWidget {
  const _CloseSheet({required this.breakdown});
  final ShiftBreakdown breakdown;
  @override
  State<_CloseSheet> createState() => _CloseSheetState();
}

class _CloseSheetState extends State<_CloseSheet> {
  final _amount = TextEditingController();
  final _note = TextEditingController();
  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SuuqSheet(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Close shift', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            'Here is what should be in the drawer. Count the actual cash, '
            'then enter it below.',
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: SuuqSpacing.md),
          _BreakdownTable(breakdown: widget.breakdown),
          const SizedBox(height: SuuqSpacing.md),
          TextField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: 'Declared cash',
              prefixText: 'ETB  ',
            ),
            style: theme.textTheme.displaySmall?.copyWith(
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: SuuqSpacing.sm),
          TextField(
            controller: _note,
            decoration: const InputDecoration(
              labelText: 'Note (optional)',
              helperText: 'e.g. gave too much change to a customer',
            ),
            maxLines: 2,
          ),
          const SizedBox(height: SuuqSpacing.lg),
          FilledButton(
            onPressed: () {
              final dec = Decimal.tryParse(_amount.text.trim());
              if (dec == null || dec < Decimal.zero) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Enter a valid amount')),
                );
                return;
              }
              Navigator.pop(
                context,
                (
                  declared: dec,
                  note: _note.text.trim().isEmpty ? null : _note.text.trim(),
                ),
              );
            },
            child: const Text('Close shift'),
          ),
        ],
      ),
    );
  }
}

class _BreakdownTable extends StatelessWidget {
  const _BreakdownTable({required this.breakdown});
  final ShiftBreakdown breakdown;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final b = breakdown;
    return Container(
      padding: const EdgeInsets.all(SuuqSpacing.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(SuuqRadius.md),
      ),
      child: Column(
        children: [
          _BreakdownRow(label: 'Opening cash', value: b.openingCash),
          _BreakdownRow(label: '+ Cash sales', value: b.cashSales),
          _BreakdownRow(label: '+ Debt collected', value: b.debtCollected),
          _BreakdownRow(label: '− Expenses', value: b.expenses, subtract: true),
          _BreakdownRow(
            label: '− Cash refunds',
            value: b.cashRefunds,
            subtract: true,
          ),
          Divider(color: scheme.outlineVariant, height: SuuqSpacing.md),
          _BreakdownRow(
            label: 'Expected in drawer',
            value: b.expected,
            emphasize: true,
          ),
        ],
      ),
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow({
    required this.label,
    required this.value,
    this.subtract = false,
    this.emphasize = false,
  });
  final String label;
  final Decimal value;
  final bool subtract;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = (emphasize
            ? theme.textTheme.titleMedium
            : theme.textTheme.bodyMedium)
        ?.copyWith(
      fontWeight: emphasize ? FontWeight.w700 : FontWeight.w500,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text(formatMoney(value), style: style),
        ],
      ),
    );
  }
}
