import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/sales/data/sales_repository.dart';
import 'package:suuqii/features/sales/presentation/receipt_share.dart';
import 'package:suuqii/features/sales/presentation/sale_detail_screen.dart';
import 'package:suuqii/shared/widgets/empty_state.dart';
import 'package:suuqii/shared/widgets/owner_pin_dialog.dart';
import 'package:suuqii/shared/widgets/section_card.dart';

class RecentSalesScreen extends ConsumerWidget {
  const RecentSalesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final salesAsync = ref.watch(watchRecentSalesProvider);
    final auth = ref.watch(authControllerProvider).valueOrNull;
    // Boutique: the per-line return sheet on the detail screen replaces the
    // whole-sale refund button (docs/19 §6.5).
    final hasReturns = auth is Authenticated && auth.features.hasReturns;

    return Scaffold(
      appBar: AppBar(title: Text(l.recentSalesTitle)),
      body: salesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.error_outline,
          title: l.recentSalesLoadFailed,
          message: context.errorMessage(e),
        ),
        data: (sales) {
          if (sales.isEmpty) {
            return EmptyState(
              icon: Icons.point_of_sale_outlined,
              title: l.recentSalesEmptyTitle,
              message: l.recentSalesEmptyMessage,
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(
              SuuqSpacing.md,
              SuuqSpacing.md,
              SuuqSpacing.md,
              SuuqSpacing.lg,
            ),
            itemCount: sales.length,
            separatorBuilder: (_, __) =>
                const SizedBox(height: SuuqSpacing.xs),
            itemBuilder: (ctx, i) => _SaleTile(
              sale: sales[i],
              onTap: () => ctx.push('/recent-sales/${sales[i].id}'),
              onShare: () => _share(context, ref, sales[i]),
              onRefund: hasReturns
                  ? () => ctx.push('/recent-sales/${sales[i].id}')
                  : () => _refund(context, ref, sales[i]),
              refundLabel: hasReturns ? l.recentSalesReturn : l.recentSalesRefund,
            ),
          );
        },
      ),
    );
  }

  /// Re-composes the plain-text receipt for [sale] from the local snapshot
  /// and opens the system share sheet (WhatsApp/Telegram/SMS).
  Future<void> _share(
    BuildContext context,
    WidgetRef ref,
    RecentSale sale,
  ) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final auth = ref.read(authControllerProvider).valueOrNull;
    final shopName = auth is Authenticated ? auth.shopName : null;

    final data = await ref.read(salesRepositoryProvider).receiptData(sale.id);
    if (data == null) {
      messenger.showSnackBar(
        SnackBar(content: Text(l.recentSalesErrNotFound)),
      );
      return;
    }
    if (!context.mounted) return;
    await shareSaleReceiptData(context, data, shopName: shopName);
  }

  Future<void> _refund(
    BuildContext context,
    WidgetRef ref,
    RecentSale sale,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final l = context.l10n;
    final auth = ref.read(authControllerProvider).valueOrNull;
    final isOwner = auth is Authenticated && auth.role == 'owner';

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final dl = ctx.l10n;
        return AlertDialog(
          title: Text(dl.recentSalesRefundConfirmTitle),
          content: Text(
            dl.recentSalesRefundConfirmBody(ctx.money(sale.total)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(dl.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(dl.recentSalesRefund),
            ),
          ],
        );
      },
    );
    if (!(confirm ?? false)) return;

    String? challenge;
    if (!isOwner) {
      if (!context.mounted) return;
      challenge = await requestOwnerChallenge(context, ref);
      if (challenge == null) return;
    }

    try {
      await ref.read(salesRepositoryProvider).refund(
            saleId: sale.id,
            ownerChallengeToken: challenge,
          );
      messenger.showSnackBar(
        SnackBar(content: Text(l.recentSalesRefundRecorded)),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(l.recentSalesRefundFailed(_refundErrorMessage(l, e))),
        ),
      );
    }
  }
}

/// Maps [StateError]s thrown by the sales repository during refund to
/// localized messages; falls back to [localizedErrorMessage] otherwise.
String _refundErrorMessage(AppLocalizations l, Object error) {
  if (error is StateError) {
    if (error.message == 'Sale not found') return l.recentSalesErrNotFound;
    if (error.message == 'Sale already refunded') {
      return l.recentSalesErrAlreadyRefunded;
    }
    if (error.message == 'Sale partially returned') {
      return l.errSalePartiallyReturned;
    }
  }
  return localizedErrorMessage(l, error);
}

class _SaleTile extends StatelessWidget {
  const _SaleTile({
    required this.sale,
    required this.onTap,
    required this.onShare,
    required this.onRefund,
    required this.refundLabel,
  });
  final RecentSale sale;
  final VoidCallback onTap;
  final VoidCallback onShare;
  final VoidCallback onRefund;
  final String refundLabel;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final paymentLabel = switch (sale.paymentMethod) {
      'cash' => l.paymentCash,
      'mobile_money' => l.paymentMobile,
      'credit' => l.paymentCredit,
      _ => sale.paymentMethod,
    };
    final paymentIcon = switch (sale.paymentMethod) {
      'cash' => Icons.payments_rounded,
      'mobile_money' => Icons.phone_iphone_rounded,
      'credit' => Icons.access_time_rounded,
      _ => Icons.point_of_sale_rounded,
    };
    final pill = saleStatusPill(l, sale.status);

    return SectionCard(
      onTap: onTap,
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
                  color: sale.isRefunded
                      ? scheme.errorContainer
                      : scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(SuuqRadius.sm),
                ),
                child: Icon(
                  paymentIcon,
                  size: 18,
                  color: sale.isRefunded
                      ? scheme.error
                      : scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: SuuqSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      context.money(sale.total),
                      style: theme.textTheme.titleMedium?.copyWith(
                        decoration: sale.isRefunded
                            ? TextDecoration.lineThrough
                            : null,
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    Text(
                      l.recentSalesSummary(
                        paymentLabel,
                        sale.itemCount,
                        context.dateTimeShort(sale.occurredAt.toLocal()),
                      ),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.share_rounded, size: 20),
                tooltip: l.receiptShare,
                onPressed: onShare,
              ),
              if (sale.isRefunded)
                pill!
              else ...[
                if (pill != null) ...[
                  pill,
                  const SizedBox(width: SuuqSpacing.xs),
                ],
                OutlinedButton.icon(
                  icon: const Icon(Icons.undo_rounded, size: 16),
                  onPressed: onRefund,
                  label: Text(refundLabel),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
