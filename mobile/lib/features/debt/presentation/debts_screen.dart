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
  final _search = TextEditingController();
  String _query = '';
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
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      body: Column(
        children: [
          // Search by customer name or phone; styled to match the POS
          // product search field.
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SuuqSpacing.md,
              SuuqSpacing.xs,
              SuuqSpacing.md,
              0,
            ),
            child: SizedBox(
              height: 48,
              child: TextField(
                controller: _search,
                onChanged: (value) => setState(() => _query = value),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
                decoration: InputDecoration(
                  hintText: l.debtSearchHint,
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    size: 24,
                    color: scheme.onSurfaceVariant,
                  ),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear_rounded, size: 20),
                          tooltip: l.commonCancel,
                          onPressed: () {
                            _search.clear();
                            setState(() => _query = '');
                          },
                        ),
                  fillColor: scheme.surfaceContainer,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: SuuqSpacing.md,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(999),
                    borderSide: BorderSide(color: scheme.outlineVariant),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(999),
                    borderSide: BorderSide(color: scheme.outlineVariant),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(999),
                    borderSide: BorderSide(color: scheme.primary, width: 1.5),
                  ),
                ),
              ),
            ),
          ),
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
              children: [
                _DebtList(status: DebtStatus.open, query: _query),
                _DebtList(status: DebtStatus.partial, query: _query),
                _DebtList(status: DebtStatus.paid, query: _query),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DebtList extends ConsumerWidget {
  const _DebtList({required this.status, this.query = ''});
  final DebtStatus status;
  final String query;

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
        data: (all) {
          final q = query.trim().toLowerCase();
          final items = q.isEmpty
              ? all
              : all
                  .where(
                    (d) =>
                        d.customerName.toLowerCase().contains(q) ||
                        (d.customerPhone ?? '').toLowerCase().contains(q),
                  )
                  .toList();
          if (items.isEmpty && q.isNotEmpty) {
            return EmptyState(
              icon: Icons.search_off_rounded,
              title: l.debtSearchNoMatchTitle,
              message: l.debtSearchNoMatchMessage,
            );
          }
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
              SuuqSpacing.md,
              SuuqSpacing.xs,
              SuuqSpacing.md,
              SuuqSpacing.lg,
            ),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(height: SuuqSpacing.xs),
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
    return Semantics(
      button: true,
      label: debt.customerName,
      child: Material(
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
                              if (debt.customerPhone != null)
                                debt.customerPhone!,
                              if (debt.dueDate != null)
                                l.debtDueShort(
                                  context.dateShort(debt.dueDate!),
                                ),
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
                        color: debt.isOverdue ? scheme.error : scheme.onSurface,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
