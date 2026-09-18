import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/dashboard/data/boutique_reports_repository.dart';
import 'package:suuqii/features/dashboard/data/dashboard_repository.dart';
import 'package:suuqii/features/dashboard/presentation/reports_screen.dart';
import 'package:suuqii/shared/widgets/product_image.dart';
import 'package:suuqii/shared/widgets/section_card.dart';
import 'package:suuqii/shared/widgets/status_pill.dart';

/// Boutique analytics on the reports screen (docs/19 §14.5): the rebuy list
/// first because it is the only card the owner can act on today, then what is
/// not moving, then what earns.
///
/// Renders nothing unless the shop has variants *and* the viewer is an owner:
/// all four endpoints are `VIEW_REPORTS`, so a cashier would only collect
/// 403s, and a regular shop has no styles to roll up.
class BoutiqueReportsSection extends ConsumerWidget {
  const BoutiqueReportsSection({required this.range, super.key});

  /// Shared with the rest of the reports screen — the same 7/30-day chip
  /// drives the top-styles window.
  final DashboardRange range;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authControllerProvider).valueOrNull;
    if (auth is! Authenticated || !auth.isOwner || !auth.features.hasVariants) {
      return const SizedBox.shrink();
    }

    final l = context.l10n;
    final runs = ref.watch(brokenRunsProvider);
    final dead = ref.watch(deadStockProvider(days: deadStockDefaultDays));
    final styles = ref.watch(topStylesProvider(range: range));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReportSectionHeader(l.reportRebuyList),
        const SizedBox(height: SuuqSpacing.xs),
        _ReportCard<List<BrokenRun>>(
          value: runs,
          emptyMessage: l.reportRebuyEmpty,
          isEmpty: (items) => items.isEmpty,
          onRetry: () => ref.invalidate(brokenRunsProvider),
          builder: (items) => _RowsCard(
            children: [for (final run in items) _RebuyTile(run: run)],
          ),
        ),
        const SizedBox(height: SuuqSpacing.lg),
        ReportSectionHeader(l.reportDeadStock),
        const SizedBox(height: SuuqSpacing.xs),
        _ReportCard<DeadStockReport>(
          value: dead,
          emptyMessage: l.reportDeadStockEmpty,
          isEmpty: (report) => report.items.isEmpty,
          onRetry: () =>
              ref.invalidate(deadStockProvider(days: deadStockDefaultDays)),
          builder: (report) => _DeadStockCard(report: report),
        ),
        const SizedBox(height: SuuqSpacing.lg),
        ReportSectionHeader(l.reportTopStyles),
        const SizedBox(height: SuuqSpacing.xs),
        _ReportCard<List<TopStyle>>(
          value: styles,
          emptyMessage: l.reportTopStylesEmpty,
          isEmpty: (items) => items.isEmpty,
          onRetry: () => ref.invalidate(topStylesProvider(range: range)),
          builder: (items) => _RowsCard(
            children: [
              for (var i = 0; i < items.length; i++)
                _TopStyleTile(
                  rank: i + 1,
                  style: items[i],
                  maxRevenue: items.first.revenue,
                ),
            ],
          ),
        ),
        const SizedBox(height: SuuqSpacing.lg),
      ],
    );
  }
}

/// Loading / empty / retry-able error shell shared by the three cards. A
/// report that fails to load is a line of text and a Retry button — never a
/// red error screen over the owner's other numbers.
class _ReportCard<T> extends StatelessWidget {
  const _ReportCard({
    required this.value,
    required this.emptyMessage,
    required this.isEmpty,
    required this.onRetry,
    required this.builder,
  });

  final AsyncValue<T> value;
  final String emptyMessage;
  final bool Function(T) isEmpty;
  final VoidCallback onRetry;
  final Widget Function(T) builder;

  @override
  Widget build(BuildContext context) {
    return value.when(
      loading: () => const SectionCard(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: SuuqSpacing.lg),
          child: Center(child: CircularProgressIndicator()),
        ),
      ),
      error: (e, _) => SectionCard(
        child: Column(
          children: [
            Text(
              context.errorMessage(e),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: SuuqSpacing.sm),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: Text(context.l10n.commonRetry),
            ),
          ],
        ),
      ),
      data: (data) => isEmpty(data)
          ? SectionCard(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: SuuqSpacing.md),
                child: Center(
                  child: Text(
                    emptyMessage,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
              ),
            )
          : builder(data),
    );
  }
}

/// Divider-separated rows in a flush card, like the top-products list.
class _RowsCard extends StatelessWidget {
  const _RowsCard({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SectionCard(
        padding: EdgeInsets.zero,
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const Divider(height: 1),
              children[i],
            ],
          ],
        ),
      );
}

/// At most this many size chips per rebuy row: `missing` is ordered by
/// 30-day sales, so the first few are the ones worth restocking and the rest
/// would only make the card tall on a 360dp screen.
const _maxRebuyChips = 6;

/// One style that has run out of some sizes while others still sell. Tapping
/// it opens the size curve, which is where the owner decides the quantities.
class _RebuyTile extends StatelessWidget {
  const _RebuyTile({required this.run});
  final BrokenRun run;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final shown = run.missing.take(_maxRebuyChips).toList();
    final overflow = run.missing.length - shown.length;

    return InkWell(
      onTap: () => context.push('/reports/size-curve?style=${run.styleId}'),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: SuuqSpacing.md,
          vertical: SuuqSpacing.sm,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 40,
              height: 40,
              child: ProductImage(
                name: run.name,
                imageUrl: run.imageUrl,
                radius: SuuqRadius.sm,
              ),
            ),
            const SizedBox(width: SuuqSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    run.name,
                    style: theme.textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    [
                      if (run.brand != null) run.brand!,
                      l.reportRebuySizesLeft(run.inStockCount, run.variantCount),
                    ].join(' · '),
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: SuuqSpacing.xs,
                    runSpacing: 4,
                    children: [
                      for (final v in shown)
                        StatusPill(
                          label: l.reportRebuyMissing(
                            _variantLabel(context, size: v.size, color: v.color),
                            context.number(v.sold30d),
                          ),
                          intent: PillIntent.warning,
                        ),
                      if (overflow > 0)
                        StatusPill(label: l.reportRebuyMore(overflow)),
                    ],
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 20),
          ],
        ),
      ),
    );
  }
}

/// "32 · Blue", or the "one size" / "no colour" wording when a dimension is
/// absent — a bare "—" reads like missing data on a rebuy chip.
String _variantLabel(
  BuildContext context, {
  required String? size,
  required String? color,
}) {
  final parts = [if (size != null) size, if (color != null) color];
  return parts.isEmpty ? context.l10n.sizeCurveOneSize : parts.join(' · ');
}

class _DeadStockCard extends StatelessWidget {
  const _DeadStockCard({required this.report});
  final DeadStockReport report;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            context.money(report.totalValue),
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.error,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            l.reportDeadStockCaption(report.days),
            style: theme.textTheme.bodySmall,
          ),
          const Divider(height: SuuqSpacing.lg),
          for (final item in report.items) _DeadStockRow(item: item),
          if (report.hasMore) ...[
            const SizedBox(height: SuuqSpacing.xs),
            Text(
              l.reportDeadStockMore(report.items.length),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class _DeadStockRow extends StatelessWidget {
  const _DeadStockRow({required this.item});
  final DeadStockItem item;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final lastSold = item.lastSoldAt;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  style: theme.textTheme.bodyMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  [
                    l.reportDeadStockAge(item.ageDays),
                    if (lastSold != null)
                      l.reportDeadStockLastSold(
                        context.dateShort(lastSold.toLocal()),
                      )
                    else
                      l.reportDeadStockNeverSold,
                  ].join(' · '),
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: SuuqSpacing.sm),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                context.money(item.value),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                context.number(item.stock),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Same shape as the top-products tile: rank, a revenue bar relative to the
/// leader, and the money on the right.
class _TopStyleTile extends StatelessWidget {
  const _TopStyleTile({
    required this.rank,
    required this.style,
    required this.maxRevenue,
  });

  final int rank;
  final TopStyle style;
  final Decimal maxRevenue;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final ratio = maxRevenue == Decimal.zero
        ? 0.0
        : (style.revenue.toDouble() / maxRevenue.toDouble()).clamp(0.0, 1.0);

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
                  style.name,
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
                  [
                    l.reportSoldAndProfit(
                      context.number(style.quantity),
                      context.money(style.profit),
                    ),
                    // Only worth saying when the row really is a run of
                    // sizes; a plain product rolls up as a single variant.
                    if (style.variantCount > 1)
                      l.reportStyleVariantCount(style.variantCount),
                  ].join(' · '),
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: SuuqSpacing.sm),
          Text(
            context.money(style.revenue),
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
