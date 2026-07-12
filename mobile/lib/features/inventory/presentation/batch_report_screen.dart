import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/features/inventory/data/lots_repository.dart';
import 'package:suuqii/shared/widgets/empty_state.dart';
import 'package:suuqii/shared/widgets/expiry_badge.dart';
import 'package:suuqii/shared/widgets/section_card.dart';

/// Owner-only per-batch economics (GET /v1/reports/batches): what each lot
/// cost, what it sold for, what spoiled, what's left. This is the screen that
/// separates the 10-birr sodas from the 13-birr ones.
class BatchReportScreen extends ConsumerWidget {
  const BatchReportScreen({this.productId, super.key});

  /// When set, the report is scoped to one product (entry from the product
  /// detail "View batches" button). Null = all products.
  final String? productId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final reportAsync = ref.watch(batchReportProvider(productId: productId));

    return Scaffold(
      appBar: AppBar(title: Text(l.batchReportTitle)),
      body: RefreshIndicator(
        onRefresh: () async =>
            ref.refresh(batchReportProvider(productId: productId).future),
        child: reportAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => ListView(
            children: [
              const SizedBox(height: SuuqSpacing.xxl),
              EmptyState(
                icon: Icons.error_outline,
                title: l.inventoryLoadFailedTitle,
                message: context.errorMessage(e),
              ),
            ],
          ),
          data: (entries) {
            if (entries.isEmpty) {
              return ListView(
                children: [
                  const SizedBox(height: SuuqSpacing.xxl),
                  EmptyState(
                    icon: Icons.receipt_long_outlined,
                    title: l.batchReportEmptyTitle,
                    message: l.batchReportEmptyMessage,
                  ),
                ],
              );
            }
            // Group lots per product, preserving server order (newest
            // receipts first) inside each group.
            final grouped = <String, List<BatchReportEntry>>{};
            for (final e in entries) {
              grouped.putIfAbsent(e.productId, () => []).add(e);
            }
            final groups = grouped.values.toList();
            return ListView.builder(
              padding: const EdgeInsets.fromLTRB(
                SuuqSpacing.md,
                SuuqSpacing.sm,
                SuuqSpacing.md,
                SuuqSpacing.xxl,
              ),
              itemCount: groups.length,
              itemBuilder: (_, i) => _ProductGroup(
                entries: groups[i],
                showName: productId == null,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _ProductGroup extends StatelessWidget {
  const _ProductGroup({required this.entries, required this.showName});
  final List<BatchReportEntry> entries;
  final bool showName;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: SuuqSpacing.xs),
          child: Text(
            entries.first.productName.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
          ),
        ),
        for (final e in entries) ...[
          _BatchCard(entry: e),
          const SizedBox(height: SuuqSpacing.sm),
        ],
        const SizedBox(height: SuuqSpacing.sm),
      ],
    );
  }
}

class _BatchCard extends StatelessWidget {
  const _BatchCard({required this.entry});
  final BatchReportEntry entry;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final positiveMargin = entry.margin >= Decimal.zero;

    int? daysToExpiry;
    final expiry = entry.expiryDate;
    if (expiry != null) {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      daysToExpiry = DateTime(expiry.year, expiry.month, expiry.day)
          .difference(today)
          .inDays;
    }

    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l.lotReceivedOn(
                    context.dateShort(entry.receivedAt.toLocal()),
                  ),
                  style: theme.textTheme.titleSmall,
                ),
              ),
              if (expiry != null && daysToExpiry != null)
                ExpiryBadge(expiryDate: expiry, daysToExpiry: daysToExpiry),
            ],
          ),
          if (entry.note != null && entry.note!.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(entry.note!, style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: SuuqSpacing.sm),
          Row(
            children: [
              _Cell(
                label: l.batchColCost,
                value: context.money(entry.unitCost),
              ),
              _Cell(label: l.batchColSold, value: _qty(entry.qtySold)),
              _Cell(
                label: l.batchColSpoiled,
                value: _qty(entry.qtySpoiled),
                emphasize: entry.qtySpoiled > Decimal.zero,
              ),
              _Cell(label: l.batchColLeft, value: _qty(entry.qtyRemaining)),
            ],
          ),
          const Divider(height: SuuqSpacing.lg),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.batchColRevenue, style: theme.textTheme.bodySmall),
                    Text(
                      context.money(entry.revenue),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
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
                    Text(l.batchColMargin, style: theme.textTheme.bodySmall),
                    Text(
                      context.money(entry.margin),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: positiveMargin ? scheme.primary : scheme.error,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _qty(Decimal d) {
    final n = d.toDouble();
    if (n == n.roundToDouble()) return n.toInt().toString();
    return n.toStringAsFixed(2);
  }
}

class _Cell extends StatelessWidget {
  const _Cell({
    required this.label,
    required this.value,
    this.emphasize = false,
  });
  final String label;
  final String value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          Text(
            value,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: emphasize ? theme.colorScheme.error : null,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
