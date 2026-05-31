import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/http/dio_client.dart';
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
            if (summaryAsync.valueOrNull?.fromCache ?? false) ...[
              _OfflineBanner(fetchedAt: summaryAsync.valueOrNull?.fetchedAt),
              const SizedBox(height: SuuqSpacing.sm),
            ],
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
            const SizedBox(height: SuuqSpacing.lg),
            _AnomalyScanCard(onScan: _scanAnomalies),
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

  Future<void> _scanAnomalies() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await ref.read(dioProvider).post<Map<String, dynamic>>(
            '/v1/audit/scan-anomalies',
          );
      final written = (res.data!['written'] as List).length;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            written == 0
                ? 'Scan complete — nothing unusual'
                : '$written anomaly${written == 1 ? "" : " entries"} '
                  'written to audit',
          ),
          action: written > 0
              ? SnackBarAction(
                  label: 'View',
                  onPressed: () => context.push('/audit'),
                )
              : null,
        ),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Scan failed: $e')));
    }
  }
}

class _AnomalyScanCard extends StatefulWidget {
  const _AnomalyScanCard({required this.onScan});
  final Future<void> Function() onScan;

  @override
  State<_AnomalyScanCard> createState() => _AnomalyScanCardState();
}

class _AnomalyScanCardState extends State<_AnomalyScanCard> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SectionCard(
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
              Icons.health_and_safety_outlined,
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
                  'Anomaly scan',
                  style: theme.textTheme.titleSmall,
                ),
                Text(
                  'Check for oversells, large variances, stale shifts.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: SuuqSpacing.sm),
          OutlinedButton(
            onPressed: _busy
                ? null
                : () async {
                    setState(() => _busy = true);
                    try {
                      await widget.onScan();
                    } finally {
                      if (mounted) setState(() => _busy = false);
                    }
                  },
            child: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Scan'),
          ),
        ],
      ),
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

class _OfflineBanner extends StatelessWidget {
  const _OfflineBanner({this.fetchedAt});
  final DateTime? fetchedAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: SuuqSpacing.md,
        vertical: SuuqSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(SuuqRadius.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(Icons.cloud_off_rounded, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: SuuqSpacing.xs),
          Expanded(
            child: Text(
              fetchedAt == null
                  ? 'Showing offline snapshot'
                  : 'Offline snapshot — updated ${_relative(fetchedAt!)}',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  static String _relative(DateTime when) {
    final diff = DateTime.now().toUtc().difference(when.toUtc());
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
