import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/features/debt/data/debts_repository.dart';
import 'package:suuqii/features/debt/domain/entities/debt.dart';
import 'package:suuqii/shared/widgets/empty_state.dart';
import 'package:suuqii/shared/widgets/section_card.dart';
import 'package:suuqii/shared/widgets/sheet_handle.dart';
import 'package:suuqii/shared/widgets/status_pill.dart';

class DebtDetailScreen extends ConsumerWidget {
  const DebtDetailScreen({required this.debtId, super.key});
  final String debtId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final debtsAsync = ref.watch(watchDebtsProvider());
    final paymentsAsync = ref.watch(watchDebtPaymentsProvider(debtId));
    final scheme = Theme.of(context).colorScheme;
    final l = context.l10n;

    return Scaffold(
      appBar: AppBar(title: Text(l.debtDetailTitle)),
      body: debtsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.error_outline,
          title: l.debtFailedToLoad,
          message: context.errorMessage(e),
        ),
        data: (all) {
          final d = all.where((x) => x.id == debtId).firstOrNull;
          if (d == null) {
            return EmptyState(
              icon: Icons.search_off_rounded,
              title: l.debtNotFound,
            );
          }
          final paid = d.status == DebtStatus.paid;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(SuuqSpacing.md),
                  children: [
                    SectionCard(
                      padding: const EdgeInsets.all(SuuqSpacing.lg),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 44,
                                height: 44,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: scheme.primaryContainer,
                                  borderRadius: BorderRadius.circular(
                                    SuuqRadius.sm,
                                  ),
                                ),
                                child: Text(
                                  d.customerName.isNotEmpty
                                      ? d.customerName[0].toUpperCase()
                                      : '?',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleLarge
                                      ?.copyWith(
                                        color: scheme.onPrimaryContainer,
                                      ),
                                ),
                              ),
                              const SizedBox(width: SuuqSpacing.sm),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      d.customerName,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleLarge,
                                    ),
                                    if (d.customerPhone != null)
                                      Text(
                                        d.customerPhone!,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodyMedium,
                                      ),
                                  ],
                                ),
                              ),
                              _statusPillFor(l, d),
                            ],
                          ),
                          const SizedBox(height: SuuqSpacing.lg),
                          InfoRow(
                            label: l.debtOwedLabel,
                            value: context.money(d.amountOwed),
                          ),
                          InfoRow(
                            label: l.debtPaidLabel,
                            value: context.money(d.amountPaid),
                          ),
                          const Divider(),
                          InfoRow(
                            label: l.debtRemainingLabel,
                            value: context.money(d.remaining),
                            emphasize: true,
                            intent: d.isOverdue ? scheme.error : null,
                          ),
                          if (d.dueDate != null) ...[
                            const SizedBox(height: 4),
                            InfoRow(
                              label: l.debtDueDateLabel,
                              value: context.dateShort(d.dueDate!),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: SuuqSpacing.lg),
                    Text(
                      l.debtPaymentHistory,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            letterSpacing: 1.2,
                          ),
                    ),
                    const SizedBox(height: SuuqSpacing.xs),
                    paymentsAsync.when(
                      loading: () => const Padding(
                        padding: EdgeInsets.all(SuuqSpacing.md),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                      error: (e, _) => Text(context.errorMessage(e)),
                      data: (payments) {
                        if (payments.isEmpty) {
                          return SectionCard(
                            child: Center(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: SuuqSpacing.md,
                                ),
                                child: Text(
                                  l.debtNoPaymentsYet,
                                  style: Theme.of(context).textTheme.bodyMedium,
                                ),
                              ),
                            ),
                          );
                        }
                        return SectionCard(
                          padding: EdgeInsets.zero,
                          child: Column(
                            children: [
                              for (var i = 0; i < payments.length; i++) ...[
                                if (i > 0) const Divider(height: 1),
                                _PaymentTile(payment: payments[i]),
                              ],
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
              if (!paid)
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(SuuqSpacing.md),
                    child: FilledButton.icon(
                      icon: const Icon(Icons.add_rounded),
                      label: Text(l.debtCollectPayment),
                      onPressed: () => _showCollect(context, ref, d),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _statusPillFor(AppLocalizations l, Debt d) {
    if (d.status == DebtStatus.paid) {
      return StatusPill(label: l.debtStatusPaid, intent: PillIntent.success);
    }
    if (d.isOverdue) {
      return StatusPill(label: l.debtStatusOverdue, intent: PillIntent.danger);
    }
    if (d.status == DebtStatus.partial) {
      return StatusPill(label: l.debtStatusPartial, intent: PillIntent.info);
    }
    return StatusPill(label: l.debtStatusOpen);
  }

  Future<void> _showCollect(
    BuildContext context,
    WidgetRef ref,
    Debt debt,
  ) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final result = await showModalBottomSheet<
        ({Decimal amount, String method, String? note})>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CollectSheet(max: debt.remaining),
    );
    if (result == null) return;
    if (!context.mounted) return;
    final amountText = context.money(result.amount);
    try {
      await ref.read(debtsRepositoryProvider).recordPayment(
            debtId: debt.id,
            amount: result.amount,
            method: result.method,
            note: result.note,
          );
      messenger.showSnackBar(
        SnackBar(content: Text(l.debtPaymentRecorded(amountText))),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(l.debtActionFailed(localizedErrorMessage(l, e)))),
      );
    }
  }
}

class _PaymentTile extends StatelessWidget {
  const _PaymentTile({required this.payment});
  final DebtPayment payment;

  @override
  Widget build(BuildContext context) {
    final cash = payment.method == 'cash';
    final scheme = Theme.of(context).colorScheme;
    final l = context.l10n;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: SuuqSpacing.md,
        vertical: SuuqSpacing.sm,
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(SuuqRadius.sm),
            ),
            child: Icon(
              cash ? Icons.payments_rounded : Icons.phone_iphone_rounded,
              size: 18,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: SuuqSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  cash ? l.paymentCash : l.paymentMobileMoney,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                Text(
                  context.dateTimeShort(payment.paidAt.toLocal()),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Text(
            context.money(payment.amount),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
          ),
        ],
      ),
    );
  }
}

class _CollectSheet extends StatefulWidget {
  const _CollectSheet({required this.max});
  final Decimal max;

  @override
  State<_CollectSheet> createState() => _CollectSheetState();
}

class _CollectSheetState extends State<_CollectSheet> {
  late final TextEditingController _amount;
  final _note = TextEditingController();
  String _method = 'cash';

  @override
  void initState() {
    super.initState();
    _amount = TextEditingController(text: widget.max.toString());
  }

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return SuuqSheet(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l.debtCollectPayment,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          Text(
            l.debtRemainingAmount(context.money(widget.max)),
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: SuuqSpacing.md),
          TextField(
            controller: _amount,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: l.debtAmountLabel,
              prefixText: 'ETB  ',
            ),
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: SuuqSpacing.sm),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(
                value: 'cash',
                label: Text(l.paymentCash),
                icon: const Icon(Icons.payments_rounded),
              ),
              ButtonSegment(
                value: 'mobile_money',
                label: Text(l.paymentMobile),
                icon: const Icon(Icons.phone_iphone_rounded),
              ),
            ],
            selected: {_method},
            onSelectionChanged: (s) => setState(() => _method = s.first),
          ),
          const SizedBox(height: SuuqSpacing.sm),
          TextField(
            controller: _note,
            decoration: InputDecoration(
              labelText: l.debtNoteOptional,
            ),
          ),
          const SizedBox(height: SuuqSpacing.lg),
          FilledButton(
            onPressed: () {
              final d = Decimal.tryParse(_amount.text.trim());
              if (d == null || d <= Decimal.zero) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l.debtEnterValidAmount)),
                );
                return;
              }
              Navigator.pop(
                context,
                (
                  amount: d,
                  method: _method,
                  note: _note.text.trim().isEmpty ? null : _note.text.trim(),
                ),
              );
            },
            child: Text(l.commonConfirm),
          ),
        ],
      ),
    );
  }
}
