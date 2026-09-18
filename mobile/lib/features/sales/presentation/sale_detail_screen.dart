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
import 'package:suuqii/features/sales/data/sale_returns_dao.dart';
import 'package:suuqii/features/sales/data/sales_repository.dart';
import 'package:suuqii/features/sales/domain/entities/sale_return.dart';
import 'package:suuqii/features/sales/presentation/cart_controller.dart';
import 'package:suuqii/features/sales/presentation/exchange_controller.dart';
import 'package:suuqii/features/sales/presentation/receipt_share.dart';
import 'package:suuqii/features/sales/presentation/return_sheet.dart';
import 'package:suuqii/shared/widgets/empty_state.dart';
import 'package:suuqii/shared/widgets/owner_pin_dialog.dart';
import 'package:suuqii/shared/widgets/section_card.dart';
import 'package:suuqii/shared/widgets/status_pill.dart';

/// What actually changed hands in one past sale: every line with quantity
/// and price, the totals, payment method and time — the drill-down behind
/// a recent-sales row. For shops with returns (docs/19 §6.5) it is also
/// where a return or exchange starts.
class SaleDetailScreen extends ConsumerWidget {
  const SaleDetailScreen({required this.saleId, super.key});
  final String saleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final saleAsync = ref.watch(saleReceiptProvider(saleId));
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final hasReturns =
        auth is Authenticated && auth.features.hasReturns && auth.canSell;

    return Scaffold(
      appBar: AppBar(title: Text(l.saleDetailTitle)),
      body: saleAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.error_outline,
          title: l.recentSalesLoadFailed,
          message: context.errorMessage(e),
        ),
        data: (data) {
          if (data == null) {
            return EmptyState(
              icon: Icons.search_off_rounded,
              title: l.recentSalesErrNotFound,
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(SuuqSpacing.md),
                  children: [
                    _HeaderCard(data: data),
                    const SizedBox(height: SuuqSpacing.lg),
                    Text(
                      l.receiptItemsCaps,
                      style:
                          Theme.of(context).textTheme.labelSmall?.copyWith(
                                letterSpacing: 1.2,
                              ),
                    ),
                    const SizedBox(height: SuuqSpacing.xs),
                    SectionCard(
                      padding: EdgeInsets.zero,
                      child: Column(
                        children: [
                          for (var i = 0; i < data.items.length; i++) ...[
                            if (i > 0) const Divider(height: 1),
                            _ItemTile(item: data.items[i]),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: SuuqSpacing.lg),
                    SectionCard(
                      child: Column(
                        children: [
                          InfoRow(
                            label: l.receiptSubtotal,
                            value: context.money(data.subtotal),
                          ),
                          if (data.discount > Decimal.zero)
                            InfoRow(
                              label: l.cartDiscount,
                              value: '-${context.money(data.discount)}',
                            ),
                          const Divider(),
                          InfoRow(
                            label: l.total,
                            value: context.money(data.total),
                            emphasize: true,
                          ),
                        ],
                      ),
                    ),
                    if (data.returns.isNotEmpty) ...[
                      const SizedBox(height: SuuqSpacing.lg),
                      Text(
                        l.saleDetailReturnsCaps,
                        style:
                            Theme.of(context).textTheme.labelSmall?.copyWith(
                                  letterSpacing: 1.2,
                                ),
                      ),
                      const SizedBox(height: SuuqSpacing.xs),
                      for (final r in data.returns) ...[
                        _ReturnCard(ret: r),
                        const SizedBox(height: SuuqSpacing.xs),
                      ],
                    ],
                    const SizedBox(height: SuuqSpacing.sm),
                    Center(
                      child: Text(
                        l.receiptSaleNumber(data.id.substring(0, 8)),
                        style:
                            Theme.of(context).textTheme.bodySmall?.copyWith(
                          letterSpacing: 1,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(SuuqSpacing.md),
                  child: Row(
                    children: [
                      if (hasReturns && data.canReturn) ...[
                        Expanded(
                          child: FilledButton.icon(
                            icon: const Icon(Icons.undo_rounded, size: 18),
                            label: Text(l.returnButton),
                            onPressed: () => _startReturn(context, ref, data),
                          ),
                        ),
                        const SizedBox(width: SuuqSpacing.sm),
                      ],
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.share_rounded, size: 18),
                          label: Text(l.receiptShare),
                          onPressed: () => _share(context, ref, data),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _share(
    BuildContext context,
    WidgetRef ref,
    SaleReceiptData data,
  ) {
    final auth = ref.read(authControllerProvider).valueOrNull;
    final shopName = auth is Authenticated ? auth.shopName : null;
    return shareSaleReceiptData(context, data, shopName: shopName);
  }

  /// Return / exchange flow (docs/19 §6.5). The sheet collects everything
  /// first so a cancelled PIN costs nothing; an exchange hands the credit to
  /// the POS instead of writing anything here.
  Future<void> _startReturn(
    BuildContext context,
    WidgetRef ref,
    SaleReceiptData data,
  ) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final repo = ref.read(salesRepositoryProvider);
    final auth = ref.read(authControllerProvider).valueOrNull;
    final isOwner = auth is Authenticated && auth.isOwner;

    final ReturnCreditCalculator calculator;
    try {
      calculator = await repo.returnCalculator(data.id);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(localizedErrorMessage(l, e))),
      );
      return;
    }
    if (!context.mounted) return;
    final result = await showReturnSheet(
      context,
      sale: data,
      calculator: calculator,
      // Cashiers are PIN-gated for every return; the window is the owner's
      // own rule, so only the owner is warned about bending it.
      outsideWindow: isOwner && repo.isOutsideReturnWindow(data.occurredAt),
      returnWindowDays: repo.returnWindowDays,
    );
    if (result == null) return;

    if (result.isExchange) {
      ref.read(exchangeModeProvider.notifier).current = ExchangeContext(
        originalSaleId: data.id,
        items: result.items,
        reason: result.reason,
        note: result.note,
        credit: result.credit,
        itemNames: {for (final i in data.items) i.id: i.name},
      );
      ref.read(cartControllerProvider.notifier).clear();
      router.go('/pos');
      return;
    }

    String? challenge;
    if (!isOwner) {
      if (!context.mounted) return;
      challenge = await requestOwnerChallenge(context, ref);
      if (challenge == null) return;
    }
    try {
      await repo.submitReturn(
        saleId: data.id,
        items: result.items,
        refundAmount: result.refundAmount!,
        refundMethod: result.refundMethod,
        reason: result.reason,
        note: result.note,
        ownerChallengeToken: challenge,
      );
      ref.invalidate(saleReceiptProvider(data.id));
      messenger.showSnackBar(SnackBar(content: Text(l.returnRecorded)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(l.returnFailed(returnErrorMessage(l, e)))),
      );
    }
  }
}

/// Maps repository refusals ([SaleReturnException]) to localized messages;
/// falls back to [localizedErrorMessage] otherwise.
String returnErrorMessage(AppLocalizations l, Object error) {
  if (error is SaleReturnException) {
    return switch (error.code) {
      'not_found' => l.recentSalesErrNotFound,
      'already_refunded' => l.recentSalesErrAlreadyRefunded,
      'return_exceeds_sold' => l.errReturnExceedsSold,
      'owner_pin_required' => l.ownerPinRequired,
      _ => l.errInvalidPayload,
    };
  }
  return localizedErrorMessage(l, error);
}

/// Status pill for a sale, or null for an ordinary completed one.
StatusPill? saleStatusPill(AppLocalizations l, String status) => switch (status) {
      'refunded' => StatusPill(
          label: l.recentSalesRefundedCaps,
          intent: PillIntent.danger,
        ),
      'partially_returned' => StatusPill(
          label: l.recentSalesPartiallyReturnedCaps,
          intent: PillIntent.warning,
        ),
      _ => null,
    };

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.data});
  final SaleReceiptData data;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final paymentLabel = switch (data.paymentMethod) {
      'cash' => l.paymentCash,
      'mobile_money' => l.paymentMobile,
      'credit' => l.paymentCredit,
      _ => data.paymentMethod,
    };
    final paymentIcon = switch (data.paymentMethod) {
      'cash' => Icons.payments_rounded,
      'mobile_money' => Icons.phone_iphone_rounded,
      'credit' => Icons.access_time_rounded,
      _ => Icons.point_of_sale_rounded,
    };
    final pill = saleStatusPill(l, data.status);
    return SectionCard(
      padding: const EdgeInsets.all(SuuqSpacing.lg),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: data.isRefunded
                  ? scheme.errorContainer
                  : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(SuuqRadius.sm),
            ),
            child: Icon(
              paymentIcon,
              size: 20,
              color:
                  data.isRefunded ? scheme.error : scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: SuuqSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.money(data.total),
                  style: theme.textTheme.titleLarge?.copyWith(
                    decoration:
                        data.isRefunded ? TextDecoration.lineThrough : null,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                Text(paymentLabel, style: theme.textTheme.bodyMedium),
                Text(
                  context.dateTimeShort(data.occurredAt.toLocal()),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          if (pill != null) pill,
        ],
      ),
    );
  }
}

class _ItemTile extends StatelessWidget {
  const _ItemTile({required this.item});
  final SaleReceiptItem item;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final muted = item.isFullyReturned;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: SuuqSpacing.md,
        vertical: SuuqSpacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: muted ? scheme.onSurfaceVariant : null,
                    decoration: muted ? TextDecoration.lineThrough : null,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  l.saleDetailQtyPrice(
                    receiptQtyText(item.quantity),
                    context.money(item.unitPrice),
                  ),
                  style: theme.textTheme.bodySmall,
                ),
                if (item.hasLineDiscount)
                  Text(
                    l.priceWas(context.money(item.listPrice!)),
                    style: theme.textTheme.bodySmall?.copyWith(
                      decoration: TextDecoration.lineThrough,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                if (item.returnedQuantity > 0)
                  Text(
                    muted
                        ? l.returnFullyReturned
                        : l.returnAlreadyReturned(
                            receiptQtyText(item.returnedQuantity),
                          ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.error,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: SuuqSpacing.sm),
          Text(
            context.money(item.lineTotal),
            style: theme.textTheme.titleSmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReturnCard extends StatelessWidget {
  const _ReturnCard({required this.ret});
  final SaleReturnView ret;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  context.dateTimeShort(ret.occurredAt.toLocal()),
                  style: theme.textTheme.bodySmall,
                ),
              ),
              if (ret.reason != null)
                Text(
                  returnReasonLabel(l, ret.reason!),
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ),
          const SizedBox(height: SuuqSpacing.xs),
          for (final item in ret.items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l.saleDetailReturnLine(
                        receiptQtyText(item.quantity),
                        item.productName,
                      ),
                      style: theme.textTheme.bodyMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (item.condition == ReturnCondition.damaged)
                    Padding(
                      padding: const EdgeInsets.only(right: SuuqSpacing.xs),
                      child: Text(
                        l.returnConditionDamaged,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.error,
                        ),
                      ),
                    ),
                  Text(
                    '-${context.money(item.creditTotal)}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          const Divider(),
          Text(
            ret.isExchange
                ? l.saleDetailReturnExchange(
                    ret.exchangeSaleId!.substring(0, 8),
                  )
                : l.saleDetailReturnCredit(context.money(ret.credit)),
            style: theme.textTheme.bodySmall,
          ),
          if (ret.refundAmount > Decimal.zero)
            Text(
              l.saleDetailReturnRefunded(context.money(ret.refundAmount)),
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          if (ret.note != null && ret.note!.isNotEmpty)
            Text(ret.note!, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}
