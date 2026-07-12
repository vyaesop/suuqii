import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/features/dashboard/data/dashboard_repository.dart';
import 'package:suuqii/shared/widgets/section_card.dart';

class ReportsScreen extends ConsumerStatefulWidget {
  const ReportsScreen({super.key});

  @override
  ConsumerState<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends ConsumerState<ReportsScreen> {
  DashboardRange _range = DashboardRange.week;

  @override
  Widget build(BuildContext context) {
    final seriesAsync = ref.watch(salesSeriesProvider(range: _range));
    final topAsync = ref.watch(topProductsProvider(range: _range));
    final mixAsync = ref.watch(paymentMixProvider(range: _range));
    final l = context.l10n;

    return Scaffold(
      appBar: AppBar(title: Text(l.settingsReports)),
      body: RefreshIndicator(
        onRefresh: () async {
          ref
            ..invalidate(salesSeriesProvider(range: _range))
            ..invalidate(topProductsProvider(range: _range))
            ..invalidate(paymentMixProvider(range: _range));
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            SuuqSpacing.md,
            SuuqSpacing.sm,
            SuuqSpacing.md,
            SuuqSpacing.xxl,
          ),
          children: [
            SegmentedButton<DashboardRange>(
              segments: [
                ButtonSegment(
                  value: DashboardRange.week,
                  label: Text(l.dashboardRange7Days),
                ),
                ButtonSegment(
                  value: DashboardRange.month,
                  label: Text(l.dashboardRange30Days),
                ),
              ],
              selected: {_range},
              onSelectionChanged: (s) => setState(() => _range = s.first),
            ),
            const SizedBox(height: SuuqSpacing.lg),
            _SectionHeader(l.reportSalesOverTime),
            const SizedBox(height: SuuqSpacing.xs),
            seriesAsync.when(
              loading: _loadingCard,
              error: (e, _) => _errorCard(context.errorMessage(e)),
              data: (points) => points.isEmpty
                  ? _emptyCard(l.reportNoSalesYet)
                  : SectionCard(
                      child: _SalesBarChart(points: points),
                    ),
            ),
            const SizedBox(height: SuuqSpacing.lg),
            _SectionHeader(l.reportTopProducts),
            const SizedBox(height: SuuqSpacing.xs),
            topAsync.when(
              loading: _loadingCard,
              error: (e, _) => _errorCard(context.errorMessage(e)),
              data: (items) => items.isEmpty
                  ? _emptyCard(l.reportNoSoldProducts)
                  : SectionCard(
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          for (var i = 0; i < items.length; i++) ...[
                            if (i > 0) const Divider(height: 1),
                            _TopProductTile(
                              rank: i + 1,
                              product: items[i],
                              maxRevenue: items.first.revenue,
                            ),
                          ],
                        ],
                      ),
                    ),
            ),
            const SizedBox(height: SuuqSpacing.lg),
            _SectionHeader(l.reportPaymentMix),
            const SizedBox(height: SuuqSpacing.xs),
            mixAsync.when(
              loading: _loadingCard,
              error: (e, _) => _errorCard(context.errorMessage(e)),
              data: (mix) => mix.isEmpty
                  ? _emptyCard(l.reportNoSalesInRange)
                  : SectionCard(child: _PaymentMixView(mix: mix)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _loadingCard() => const SectionCard(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: SuuqSpacing.lg),
          child: Center(child: CircularProgressIndicator()),
        ),
      );

  Widget _errorCard(String msg) => SectionCard(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: SuuqSpacing.md),
          child: Center(child: Text(msg)),
        ),
      );

  Widget _emptyCard(String msg) => SectionCard(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: SuuqSpacing.md),
          child: Center(
            child: Text(msg, style: Theme.of(context).textTheme.bodyMedium),
          ),
        ),
      );
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              letterSpacing: 1.2,
            ),
      );
}

class _SalesBarChart extends StatelessWidget {
  const _SalesBarChart({required this.points});
  final List<SalesSeriesPoint> points;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l = context.l10n;
    final maxRevenue = points
        .map((p) => p.revenue.toDouble())
        .fold<double>(0, (a, b) => b > a ? b : a);
    final totalRevenue = points.fold<Decimal>(
      Decimal.zero,
      (a, p) => a + p.revenue,
    );
    final totalProfit = points.fold<Decimal>(
      Decimal.zero,
      (a, p) => a + p.profit,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.revenue, style: theme.textTheme.bodySmall),
                  Text(
                    context.money(totalRevenue),
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.profit, style: theme.textTheme.bodySmall),
                  Text(
                    context.money(totalProfit),
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: scheme.primary,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: SuuqSpacing.md),
        SizedBox(
          height: 120,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: points.map((p) {
              final ratio = maxRevenue == 0
                  ? 0.0
                  : (p.revenue.toDouble() / maxRevenue).clamp(0.02, 1.0);
              return Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Tooltip(
                    message:
                        '${context.dateShort(p.date)}\n${context.money(p.revenue)}',
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Expanded(
                          child: Align(
                            alignment: Alignment.bottomCenter,
                            child: FractionallySizedBox(
                              heightFactor: ratio,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: scheme.primary,
                                  borderRadius: const BorderRadius.vertical(
                                    top: Radius.circular(4),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: points.map((p) {
            return Expanded(
              child: Center(
                child: Text(
                  _dayLabel(context, p.date),
                  style: theme.textTheme.labelSmall,
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  static String _dayLabel(BuildContext context, DateTime d) =>
      DateFormat.E(context.intlLocale).format(d).substring(0, 1);
}

class _TopProductTile extends StatelessWidget {
  const _TopProductTile({
    required this.rank,
    required this.product,
    required this.maxRevenue,
  });
  final int rank;
  final TopProduct product;
  final Decimal maxRevenue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l = context.l10n;
    final ratio = maxRevenue == Decimal.zero
        ? 0.0
        : (product.revenue.toDouble() / maxRevenue.toDouble()).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: SuuqSpacing.md,
        vertical: SuuqSpacing.sm,
      ),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text(
              l.reportRank(rank),
              style: theme.textTheme.titleSmall?.copyWith(
                color: scheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  product.name,
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: ratio,
                    backgroundColor: scheme.surfaceContainerHighest,
                    color: scheme.primary,
                    minHeight: 5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l.reportSoldAndProfit(
                    _fmtQty(product.qtySold),
                    context.money(product.profit),
                  ),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: SuuqSpacing.sm),
          Text(
            context.money(product.revenue),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  static String _fmtQty(Decimal d) {
    final n = d.toDouble();
    if (n == n.roundToDouble()) return n.toInt().toString();
    return n.toStringAsFixed(2);
  }
}

class _PaymentMixView extends StatelessWidget {
  const _PaymentMixView({required this.mix});
  final List<PaymentMixSlice> mix;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final l = context.l10n;
    final total = mix.fold<Decimal>(
      Decimal.zero,
      (a, m) => a + m.total,
    );
    final byMethod = {for (final m in mix) m.method: m};

    final methods = [
      (
        key: 'cash',
        label: l.paymentCash,
        icon: Icons.payments_rounded,
        color: scheme.primary,
      ),
      (
        key: 'mobile_money',
        label: l.paymentMobileMoney,
        icon: Icons.phone_iphone_rounded,
        color: scheme.tertiary,
      ),
      (
        key: 'credit',
        label: l.paymentCredit,
        icon: Icons.access_time_rounded,
        color: scheme.error,
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Stacked bar
        ClipRRect(
          borderRadius: BorderRadius.circular(SuuqRadius.sm),
          child: SizedBox(
            height: 14,
            child: Row(
              children: methods.map((m) {
                final slice = byMethod[m.key];
                final ratio = total == Decimal.zero || slice == null
                    ? 0.0
                    : slice.total.toDouble() / total.toDouble();
                if (ratio == 0) return const SizedBox.shrink();
                return Expanded(
                  flex: (ratio * 1000).round(),
                  child: Container(color: m.color),
                );
              }).toList(),
            ),
          ),
        ),
        const SizedBox(height: SuuqSpacing.sm),
        for (final m in methods)
          if (byMethod[m.key] != null) ...[
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: m.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: SuuqSpacing.xs),
                  Icon(m.icon, size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: SuuqSpacing.xs),
                  Expanded(
                    child: Text(
                      m.label,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                  Text(
                    context.money(byMethod[m.key]!.total),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ],
      ],
    );
  }
}
