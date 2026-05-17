import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/utils/money.dart';
import 'package:suuqii/features/dashboard/data/dashboard_repository.dart';
import 'package:suuqii/shared/widgets/section_card.dart';
import 'package:suuqii/shared/widgets/status_pill.dart';

class OwnerDashboardScreen extends ConsumerStatefulWidget {
  const OwnerDashboardScreen({super.key});

  @override
  ConsumerState<OwnerDashboardScreen> createState() =>
      _OwnerDashboardScreenState();
}

class _OwnerDashboardScreenState extends ConsumerState<OwnerDashboardScreen> {
  DashboardRange _range = DashboardRange.today;

  @override
  Widget build(BuildContext context) {
    final summaryAsync = ref.watch(dashboardProvider(range: _range));
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async => ref.refresh(dashboardProvider(range: _range)),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            SuuqSpacing.md, SuuqSpacing.xs, SuuqSpacing.md, SuuqSpacing.xxl,
          ),
          children: [
            _RangeSelector(
              value: _range,
              onChanged: (r) => setState(() => _range = r),
            ),
            const SizedBox(height: SuuqSpacing.md),
            summaryAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: SuuqSpacing.xxl),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => Padding(
                padding: const EdgeInsets.symmetric(vertical: SuuqSpacing.xl),
                child: Center(child: Text('$e')),
              ),
              data: _buildSummary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummary(DashboardSummary s) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Hero net-profit card
        SectionCard(
          padding: const EdgeInsets.all(SuuqSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'NET PROFIT',
                style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
              ),
              const SizedBox(height: 4),
              Text(
                formatMoney(s.netProfit),
                style: theme.textTheme.displayMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: SuuqSpacing.sm),
              Row(
                children: [
                  _SmallStat(label: 'Revenue', value: formatMoney(s.revenue)),
                  const SizedBox(width: SuuqSpacing.md),
                  _SmallStat(
                    label: 'Expenses',
                    value: formatMoney(s.expenses),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: SuuqSpacing.md),
        Row(
          children: [
            Expanded(
              child: _KpiTile(
                label: 'Profit',
                value: formatMoney(s.profit),
                icon: Icons.trending_up_rounded,
              ),
            ),
            const SizedBox(width: SuuqSpacing.sm),
            Expanded(
              child: _KpiTile(
                label: 'Credit sales',
                value: formatMoney(s.creditSales),
                icon: Icons.access_time_rounded,
              ),
            ),
          ],
        ),
        const SizedBox(height: SuuqSpacing.sm),
        _KpiTile(
          label: 'Outstanding debt',
          value: formatMoney(s.outstandingDebt),
          icon: Icons.account_balance_wallet_rounded,
          intent: s.outstandingDebt.toDouble() > 0
              ? PillIntent.warning
              : PillIntent.neutral,
        ),
        const SizedBox(height: SuuqSpacing.lg),
        Text(
          'LOW STOCK',
          style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
        ),
        const SizedBox(height: SuuqSpacing.xs),
        if (s.lowStock.isEmpty)
          SectionCard(
            child: Row(
              children: [
                Icon(
                  Icons.check_circle_outline_rounded,
                  color: theme.colorScheme.primary,
                  size: 20,
                ),
                const SizedBox(width: SuuqSpacing.xs),
                Text('All stock healthy', style: theme.textTheme.bodyMedium),
              ],
            ),
          )
        else
          SectionCard(
            padding: EdgeInsets.zero,
            child: Column(
              children: [
                for (var i = 0; i < s.lowStock.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  ListTile(
                    leading: Icon(
                      Icons.warning_amber_rounded,
                      color: theme.colorScheme.error,
                    ),
                    title: Text(s.lowStock[i].name),
                    trailing: StatusPill(
                      label: '${s.lowStock[i].stock} left',
                      intent: PillIntent.warning,
                    ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }
}

class _RangeSelector extends StatelessWidget {
  const _RangeSelector({required this.value, required this.onChanged});
  final DashboardRange value;
  final ValueChanged<DashboardRange> onChanged;

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<DashboardRange>(
      segments: const [
        ButtonSegment(value: DashboardRange.today, label: Text('Today')),
        ButtonSegment(value: DashboardRange.week, label: Text('7 days')),
        ButtonSegment(value: DashboardRange.month, label: Text('30 days')),
      ],
      selected: {value},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}

class _SmallStat extends StatelessWidget {
  const _SmallStat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          const SizedBox(height: 2),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _KpiTile extends StatelessWidget {
  const _KpiTile({
    required this.label,
    required this.value,
    required this.icon,
    this.intent = PillIntent.neutral,
  });
  final String label;
  final String value;
  final IconData icon;
  final PillIntent intent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SectionCard(
      padding: const EdgeInsets.all(SuuqSpacing.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(SuuqRadius.xs),
                ),
                child: Icon(
                  icon,
                  size: 16,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: SuuqSpacing.xs),
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.bodySmall,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: SuuqSpacing.xs),
          Text(
            value,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
              color: intent == PillIntent.warning ? scheme.error : null,
            ),
          ),
        ],
      ),
    );
  }
}
