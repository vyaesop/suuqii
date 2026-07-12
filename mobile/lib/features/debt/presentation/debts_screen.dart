import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/features/debt/data/debts_repository.dart';
import 'package:suuqii/features/debt/domain/entities/debt.dart';
import 'package:suuqii/shared/widgets/empty_state.dart';
import 'package:suuqii/shared/widgets/status_pill.dart';

class DebtsScreen extends ConsumerStatefulWidget {
  const DebtsScreen({super.key});

  @override
  ConsumerState<DebtsScreen> createState() => _DebtsScreenState();
}

class _DebtsScreenState extends ConsumerState<DebtsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  bool _kicked = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_kicked) {
        _kicked = true;
        ref.read(debtsSyncProvider.notifier).refresh();
      }
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: SuuqSpacing.md),
            child: TabBar(
              controller: _tabs,
              tabs: [
                Tab(text: l.debtTabOpen),
                Tab(text: l.debtTabPartial),
                Tab(text: l.debtTabPaid),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: const [
                _DebtList(status: DebtStatus.open),
                _DebtList(status: DebtStatus.partial),
                _DebtList(status: DebtStatus.paid),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DebtList extends ConsumerWidget {
  const _DebtList({required this.status});
  final DebtStatus status;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final debtsAsync = ref.watch(watchDebtsProvider(status: status));
    final l = context.l10n;
    return RefreshIndicator(
      onRefresh: () => ref.read(debtsSyncProvider.notifier).refresh(),
      child: debtsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.error_outline,
          title: l.debtFailedToLoad,
          message: context.errorMessage(e),
        ),
        data: (items) {
          if (items.isEmpty) {
            return EmptyState(
              icon: switch (status) {
                DebtStatus.open => Icons.account_balance_wallet_outlined,
                DebtStatus.partial => Icons.timelapse_rounded,
                DebtStatus.paid => Icons.check_circle_outline_rounded,
                DebtStatus.writtenOff => Icons.cancel_outlined,
              },
              title: switch (status) {
                DebtStatus.open => l.debtEmptyOpenTitle,
                DebtStatus.partial => l.debtEmptyPartialTitle,
                DebtStatus.paid => l.debtEmptyPaidTitle,
                DebtStatus.writtenOff => l.debtEmptyWrittenOffTitle,
              },
              message: status == DebtStatus.paid
                  ? l.debtEmptyPaidMessage
                  : l.debtEmptyMessage,
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(
              SuuqSpacing.md, SuuqSpacing.xs, SuuqSpacing.md, SuuqSpacing.lg,
            ),
            itemCount: items.length,
            separatorBuilder: (_, __) =>
                const SizedBox(height: SuuqSpacing.xs),
            itemBuilder: (_, i) => _DebtRow(debt: items[i]),
          );
        },
      ),
    );
  }
}

class _DebtRow extends StatelessWidget {
  const _DebtRow({required this.debt});
  final Debt debt;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final l = context.l10n;
    final fraction = debt.amountOwed.toDouble() == 0
        ? 0.0
        : (debt.amountPaid.toDouble() / debt.amountOwed.toDouble())
            .clamp(0.0, 1.0);
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(SuuqRadius.md),
      child: InkWell(
        onTap: () => context.push('/debts/${debt.id}'),
        borderRadius: BorderRadius.circular(SuuqRadius.md),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(SuuqRadius.md),
            border: Border.all(color: scheme.outlineVariant),
          ),
          padding: const EdgeInsets.all(SuuqSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(SuuqRadius.sm),
                    ),
                    child: Text(
                      debt.customerName.isNotEmpty
                          ? debt.customerName[0].toUpperCase()
                          : '?',
                      style: theme.textTheme.titleMedium,
                    ),
                  ),
                  const SizedBox(width: SuuqSpacing.sm),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          debt.customerName,
                          style: theme.textTheme.titleSmall,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          [
                            if (debt.customerPhone != null) debt.customerPhone!,
                            if (debt.dueDate != null)
                              l.debtDueShort(context.dateShort(debt.dueDate!)),
                          ].join(' · '),
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (debt.isOverdue)
                    StatusPill(
                      label: l.debtStatusOverdue,
                      intent: PillIntent.danger,
                    ),
                ],
              ),
              const SizedBox(height: SuuqSpacing.sm),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: fraction,
                  backgroundColor: scheme.surfaceContainerHighest,
                  color: debt.isOverdue ? scheme.error : scheme.primary,
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: SuuqSpacing.xs),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${context.money(debt.amountPaid)} / ${context.money(debt.amountOwed)}',
                    style: theme.textTheme.bodySmall,
                  ),
                  Text(
                    context.money(debt.remaining),
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: debt.isOverdue
                          ? scheme.error
                          : scheme.onSurface,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
