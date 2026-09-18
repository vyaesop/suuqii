import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/features/dashboard/data/boutique_reports_repository.dart';
import 'package:suuqii/shared/widgets/empty_state.dart';
import 'package:suuqii/shared/widgets/section_card.dart';

/// The buying grid for one style (docs/19 §14.1): a bar per size showing what
/// sold against what was bought, the same split per colour, and the totals.
/// Owner-only and read-only — it is reached from the style screen and from a
/// rebuy row, both of which are already behind the owner guard.
class SizeCurveScreen extends ConsumerWidget {
  const SizeCurveScreen({required this.styleId, super.key});

  final String styleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final async = ref.watch(sizeCurveProvider(styleId));

    return Scaffold(
      appBar: AppBar(title: Text(l.sizeCurveTitle)),
      body: RefreshIndicator(
        onRefresh: () async => ref.refresh(sizeCurveProvider(styleId).future),
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          // A report that fails to load is offered again, not thrown at the
          // owner as a red screen.
          error: (e, _) => ListView(
            children: [
              const SizedBox(height: SuuqSpacing.xxl),
              EmptyState(
                icon: Icons.error_outline,
                title: l.inventoryLoadFailedTitle,
                message: context.errorMessage(e),
                action: FilledButton.icon(
                  onPressed: () => ref.invalidate(sizeCurveProvider(styleId)),
                  icon: const Icon(Icons.refresh_rounded),
                  label: Text(l.commonRetry),
                ),
              ),
            ],
          ),
          data: (report) => report.isEmpty
              ? ListView(
                  children: [
                    const SizedBox(height: SuuqSpacing.xxl),
                    EmptyState(
                      icon: Icons.straighten_rounded,
                      title: l.sizeCurveEmptyTitle,
                      message: l.sizeCurveEmptyMessage,
                    ),
                  ],
                )
              : _CurveBody(report: report),
        ),
      ),
    );
  }
}

class _CurveBody extends StatelessWidget {
  const _CurveBody({required this.report});
  final SizeCurveReport report;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final totals = report.totals;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        SuuqSpacing.md,
        SuuqSpacing.md,
        SuuqSpacing.md,
        SuuqSpacing.xxl,
      ),
      children: [
        Text(report.styleName, style: theme.textTheme.titleLarge),
        if (report.brand != null)
          Text(
            report.brand!.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
          ),
        const SizedBox(height: SuuqSpacing.md),
        SectionCard(
          child: Column(
            children: [
              Row(
                children: [
                  _Total(label: l.sizeCurveReceived, value: totals.received),
                  _Total(label: l.sizeCurveSold, value: totals.sold),
                  _Total(label: l.sizeCurveOnHand, value: totals.onHand),
                ],
              ),
              const Divider(height: SuuqSpacing.lg),
              InfoRow(
                label: l.revenue,
                value: context.money(totals.revenue),
                emphasize: true,
              ),
            ],
          ),
        ),
        if (report.sizes.isNotEmpty) ...[
          const SizedBox(height: SuuqSpacing.lg),
          Text(
            l.sizeCurveBySize,
            style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
          ),
          const SizedBox(height: SuuqSpacing.xs),
          _CurveCard(rows: report.sizes, emptyLabel: l.sizeCurveOneSize),
        ],
        if (report.colors.isNotEmpty) ...[
          const SizedBox(height: SuuqSpacing.lg),
          Text(
            l.sizeCurveByColor,
            style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
          ),
          const SizedBox(height: SuuqSpacing.xs),
          _CurveCard(rows: report.colors, emptyLabel: l.sizeCurveNoColor),
        ],
      ],
    );
  }
}

class _Total extends StatelessWidget {
  const _Total({required this.label, required this.value});
  final String label;
  final Decimal value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          Text(
            context.number(value),
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

class _CurveCard extends StatelessWidget {
  const _CurveCard({required this.rows, required this.emptyLabel});

  final List<SizeCurveRow> rows;

  /// Wording for a row whose dimension is absent ("One size" / "No colour").
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    // Bars are scaled to the biggest buy, so the shape of the curve — which
    // sizes were over-bought — is visible at a glance.
    final maxReceived = rows.fold<Decimal>(
      Decimal.zero,
      (a, r) => r.received > a ? r.received : a,
    );
    return SectionCard(
      child: Column(
        children: [
          for (final row in rows)
            _CurveBar(
              row: row,
              maxReceived: maxReceived,
              emptyLabel: emptyLabel,
            ),
        ],
      ),
    );
  }
}

/// One size (or colour): the received bar as the track, the sold part filled.
class _CurveBar extends StatelessWidget {
  const _CurveBar({
    required this.row,
    required this.maxReceived,
    required this.emptyLabel,
  });

  final SizeCurveRow row;
  final Decimal maxReceived;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final receivedFactor = maxReceived == Decimal.zero
        ? 0.0
        : (row.received.toDouble() / maxReceived.toDouble()).clamp(0.0, 1.0);
    final soldFactor = row.received == Decimal.zero
        ? 0.0
        : (row.sold.toDouble() / row.received.toDouble()).clamp(0.0, 1.0);
    final percent = (row.sellThrough.toDouble() * 100).round();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 46,
            child: Text(
              row.label ?? emptyLabel,
              style: theme.textTheme.titleSmall,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: SuuqSpacing.xs),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 14,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FractionallySizedBox(
                      widthFactor: receivedFactor,
                      child: Container(
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(SuuqRadius.sm),
                        ),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: soldFactor,
                            child: Container(
                              decoration: BoxDecoration(
                                color: scheme.primary,
                                borderRadius:
                                    BorderRadius.circular(SuuqRadius.sm),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  l.sizeCurveSoldOfReceived(
                    context.number(row.sold),
                    context.number(row.received),
                  ),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(width: SuuqSpacing.xs),
          SizedBox(
            width: 44,
            child: Text(
              l.sizeCurvePercent('$percent'),
              textAlign: TextAlign.right,
              style: theme.textTheme.titleSmall?.copyWith(
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
