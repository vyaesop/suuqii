import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/features/shifts/data/shifts_repository.dart';
import 'package:suuqii/features/shifts/domain/entities/shift.dart';
import 'package:suuqii/shared/widgets/empty_state.dart';
import 'package:suuqii/shared/widgets/section_card.dart';
import 'package:suuqii/shared/widgets/sheet_handle.dart';

class ShiftScreen extends ConsumerWidget {
  const ShiftScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final shiftAsync = ref.watch(currentShiftProvider);

    return Scaffold(
      body: shiftAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.error_outline,
          title: l.shiftLoadFailedTitle,
          message: context.errorMessage(e),
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
    final l = context.l10n;
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
              l.shiftStartTitle,
              style: theme.textTheme.displaySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: SuuqSpacing.xs),
            Text(
              l.shiftStartSubtitle,
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
              label: Text(l.shiftStartCta),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _open() async {
    final l = context.l10n;
    final amount = Decimal.tryParse(_ctrl.text.trim());
    if (amount == null || amount < Decimal.zero) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.shiftEnterValidAmount)),
      );
      return;
    }
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(shiftsRepositoryProvider).open(openingCash: amount);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(localizedErrorMessage(l, e))),
      );
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
    final l = context.l10n;
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
                              l.shiftOpenBadge,
                              style: theme.textTheme.labelSmall?.copyWith(
                                letterSpacing: 1.4,
                                color: scheme.primary,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: SuuqSpacing.sm),
                        Text(
                          _humanDuration(l, elapsed),
                          style: theme.textTheme.displaySmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                        Text(
                          l.shiftSinceTime(
                            context.timeShort(opened.toLocal()),
                          ),
                          style: theme.textTheme.bodyMedium,
                        ),
                        const Divider(height: SuuqSpacing.xl),
                        InfoRow(
                          label: l.shiftOpeningCash,
                          value: context.money(openingCash),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: SuuqSpacing.md),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      l.shiftCloseHint,
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

  String _humanDuration(AppLocalizations l, Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    if (h > 0) return l.shiftDurationHoursMinutes(h, m);
    return l.shiftDurationMinutes(m);
  }

  Future<void> _closeShift(BuildContext context, WidgetRef ref) async {
    final l = context.l10n;
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
              title: Text(l.shiftClosedTitle),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _BreakdownTable(breakdown: b),
                    const Divider(),
                    InfoRow(
                      label: l.shiftDeclaredLabel,
                      value: context.money(result.declared),
                    ),
                    InfoRow(
                      label: l.shiftVariance,
                      value: context.money(variance),
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
                  child: Text(l.commonDone),
                ),
              ],
            );
          },
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(localizedErrorMessage(l, e))),
      );
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
    final l = context.l10n;
    final theme = Theme.of(context);
    return SuuqSheet(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.shiftCloseTitle, style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            l.shiftCloseSubtitle,
            style: theme.textTheme.bodyMedium,
          ),
          const SizedBox(height: SuuqSpacing.md),
          _BreakdownTable(breakdown: widget.breakdown),
          const SizedBox(height: SuuqSpacing.md),
          TextField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: l.shiftDeclaredCash,
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
            decoration: InputDecoration(
              labelText: l.shiftNoteLabel,
              helperText: l.shiftNoteHelper,
            ),
            maxLines: 2,
          ),
          const SizedBox(height: SuuqSpacing.lg),
          FilledButton(
            onPressed: () {
              final dec = Decimal.tryParse(_amount.text.trim());
              if (dec == null || dec < Decimal.zero) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l.shiftEnterValidAmount)),
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
            child: Text(l.shiftCloseCta),
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
    final l = context.l10n;
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
          _BreakdownRow(label: l.shiftBreakdownOpening, value: b.openingCash),
          _BreakdownRow(label: l.shiftBreakdownCashSales, value: b.cashSales),
          _BreakdownRow(
            label: l.shiftBreakdownDebtCollected,
            value: b.debtCollected,
          ),
          _BreakdownRow(
            label: l.shiftBreakdownExpenses,
            value: b.expenses,
            subtract: true,
          ),
          _BreakdownRow(
            label: l.shiftBreakdownCashRefunds,
            value: b.cashRefunds,
            subtract: true,
          ),
          Divider(color: scheme.outlineVariant, height: SuuqSpacing.md),
          _BreakdownRow(
            label: l.shiftBreakdownExpected,
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
          Text(context.money(value), style: style),
        ],
      ),
    );
  }
}
