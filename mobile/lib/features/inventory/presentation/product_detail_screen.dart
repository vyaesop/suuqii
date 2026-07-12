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
import 'package:suuqii/features/inventory/data/lots_repository.dart';
import 'package:suuqii/features/inventory/data/products_repository.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/inventory/domain/entities/stock_lot.dart';
import 'package:suuqii/features/inventory/presentation/production_sheet.dart';
import 'package:suuqii/features/inventory/presentation/spoilage_sheet.dart';
import 'package:suuqii/features/inventory/presentation/stock_adjust_sheet.dart';
import 'package:suuqii/shared/widgets/empty_state.dart';
import 'package:suuqii/shared/widgets/expiry_badge.dart';
import 'package:suuqii/shared/widgets/owner_pin_dialog.dart';
import 'package:suuqii/shared/widgets/product_image.dart';
import 'package:suuqii/shared/widgets/section_card.dart';
import 'package:suuqii/shared/widgets/status_pill.dart';

class ProductDetailScreen extends ConsumerWidget {
  const ProductDetailScreen({required this.productId, super.key});
  final String productId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final productAsync = ref.watch(watchProductProvider(productId));
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final canEdit = auth is Authenticated;
    final isOwner = canEdit && auth.role == 'owner';
    final isBakery = canEdit && auth.isBakery;

    return Scaffold(
      appBar: AppBar(
        title: Text(l.productDetailTitle),
        actions: [
          if (canEdit)
            IconButton(
              icon: const Icon(Icons.auto_delete_outlined),
              tooltip: l.spoilageTitle,
              onPressed: () => _recordSpoilage(context, ref, isOwner: isOwner),
            ),
          if (canEdit)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: l.commonEdit,
              onPressed: () => context.push('/inventory/edit/$productId'),
            ),
        ],
      ),
      body: productAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.error_outline,
          title: l.inventoryLoadFailedTitle,
          message: context.errorMessage(e),
        ),
        data: (product) {
          if (product == null) {
            return EmptyState(
              icon: Icons.search_off_rounded,
              title: l.productNotFoundTitle,
            );
          }
          return _DetailBody(
            product: product,
            isOwner: isOwner,
            onMarkLotSpoiled: (lot) => _recordSpoilage(
              context,
              ref,
              isOwner: isOwner,
              lot: lot,
            ),
          );
        },
      ),
      floatingActionButton: canEdit
          ? (isBakery
              ? FloatingActionButton.extended(
                  icon: const Icon(Icons.bakery_dining_outlined),
                  onPressed: () => _recordProduction(
                    context,
                    ref,
                    isOwner: isOwner,
                  ),
                  label: Text(l.productionTitle),
                )
              : FloatingActionButton.extended(
                  icon: const Icon(Icons.tune_rounded),
                  onPressed: () =>
                      _adjustStock(context, ref, isOwner: isOwner),
                  label: Text(l.stockAdjustTitle),
                ))
          : null,
    );
  }

  /// Receive a batch (Add segment) or apply a manual correction (Remove
  /// segment). Both are PIN-sensitive for cashiers.
  Future<void> _adjustStock(
    BuildContext context,
    WidgetRef ref, {
    required bool isOwner,
  }) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final product =
        await ref.read(productsRepositoryProvider).byId(productId);
    if (product == null || !context.mounted) return;
    final result = await showModalBottomSheet<StockAdjustResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => StockAdjustSheet(product: product),
    );
    if (result == null) return;

    String? challenge;
    if (!isOwner) {
      if (!context.mounted) return;
      challenge = await requestOwnerChallenge(context, ref);
      if (challenge == null) return;
    }

    try {
      switch (result) {
        case ReceiveStockResult():
          await ref.read(lotsRepositoryProvider).receiveStock(
                productId: productId,
                quantity: result.quantity,
                unitCost: result.unitCost,
                expiryDate: result.expiryDate,
                spoiledQuantity: result.spoiledQuantity,
                note: result.note,
                ownerChallengeToken: challenge,
              );
          messenger.showSnackBar(
            SnackBar(
              content: Text(l.stockReceiveSuccess('${result.quantity}')),
            ),
          );
        case RemoveStockResult():
          await ref.read(productsRepositoryProvider).adjustStock(
                productId: productId,
                delta: -result.quantity,
                reason: result.reason,
                ownerChallengeToken: challenge,
              );
          messenger.showSnackBar(
            SnackBar(content: Text(l.stockAdjustSuccess('-${result.quantity}'))),
          );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(localizedErrorMessage(l, e))),
      );
    }
  }

  /// Record spoilage — quantity, reason, optional specific batch. When [lot]
  /// is given (one-tap from an expired batch) the sheet is pre-filled.
  Future<void> _recordSpoilage(
    BuildContext context,
    WidgetRef ref, {
    required bool isOwner,
    StockLot? lot,
  }) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final product =
        await ref.read(productsRepositoryProvider).byId(productId);
    if (product == null || !context.mounted) return;
    final result = await showModalBottomSheet<SpoilageResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SpoilageSheet(
        productId: productId,
        productUnit: product.unit,
        initialLotId: lot?.id,
        initialQuantity: lot?.qtyRemaining,
        initialReason: (lot?.isExpired ?? false) ? 'expired' : null,
      ),
    );
    if (result == null) return;

    String? challenge;
    if (!isOwner) {
      if (!context.mounted) return;
      challenge = await requestOwnerChallenge(context, ref);
      if (challenge == null) return;
    }

    try {
      await ref.read(lotsRepositoryProvider).recordSpoilage(
            productId: productId,
            quantity: result.quantity,
            reason: result.reason,
            lotId: result.lotId,
            ownerChallengeToken: challenge,
          );
      messenger.showSnackBar(SnackBar(content: Text(l.spoilageSuccess)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(localizedErrorMessage(l, e))),
      );
    }
  }

  /// Bakery: record a production run (produced + spoiled + expiry).
  Future<void> _recordProduction(
    BuildContext context,
    WidgetRef ref, {
    required bool isOwner,
  }) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final product =
        await ref.read(productsRepositoryProvider).byId(productId);
    if (product == null || !context.mounted) return;
    final result = await showModalBottomSheet<ProductionResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ProductionSheet(productUnit: product.unit),
    );
    if (result == null) return;

    String? challenge;
    if (!isOwner) {
      if (!context.mounted) return;
      challenge = await requestOwnerChallenge(context, ref);
      if (challenge == null) return;
    }

    try {
      await ref.read(lotsRepositoryProvider).recordProduction(
            productId: productId,
            quantityProduced: result.produced,
            quantitySpoiled: result.spoiled,
            expiryDate: result.expiryDate,
            note: result.note,
            ownerChallengeToken: challenge,
          );
      messenger.showSnackBar(SnackBar(content: Text(l.productionSuccess)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(localizedErrorMessage(l, e))),
      );
    }
  }
}

class _DetailBody extends ConsumerWidget {
  const _DetailBody({
    required this.product,
    required this.isOwner,
    required this.onMarkLotSpoiled,
  });
  final Product product;
  final bool isOwner;
  final ValueChanged<StockLot> onMarkLotSpoiled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final logsAsync = ref.watch(watchInventoryLogProvider(product.id));
    final lotsAsync = ref.watch(watchProductLotsProvider(product.id));

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        SuuqSpacing.md,
        SuuqSpacing.md,
        SuuqSpacing.md,
        96,
      ),
      children: [
        SectionCard(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 88,
                height: 88,
                child: ProductImage(
                  name: product.name,
                  imageUrl: product.imageUrl,
                ),
              ),
              const SizedBox(width: SuuqSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (product.category != null)
                      Text(
                        product.category!.toUpperCase(),
                        style: theme.textTheme.labelSmall?.copyWith(
                          letterSpacing: 1,
                        ),
                      ),
                    const SizedBox(height: 2),
                    Text(
                      product.name,
                      style: theme.textTheme.titleLarge,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text(
                          context.money(product.sellingPrice),
                          style: theme.textTheme.headlineSmall?.copyWith(
                            color: scheme.primary,
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [
                              FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                        const SizedBox(width: SuuqSpacing.xs),
                        if (product.isLowStock)
                          StatusPill(
                            label: l.productLowPill,
                            intent: PillIntent.warning,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: SuuqSpacing.md),
        // Stat grid
        Row(
          children: [
            Expanded(
              child: _Stat(
                icon: Icons.inventory_2_outlined,
                label: l.productInStockLabel,
                value: '${_fmtNum(product.stock)} ${product.unit}',
                emphasize: product.isLowStock,
              ),
            ),
            const SizedBox(width: SuuqSpacing.sm),
            Expanded(
              child: _Stat(
                icon: Icons.warning_amber_rounded,
                label: l.productLowAtLabel,
                value:
                    '${_fmtNum(product.lowStockThreshold)} ${product.unit}',
              ),
            ),
          ],
        ),
        if (isOwner) ...[
          const SizedBox(height: SuuqSpacing.sm),
          _Stat(
            icon: Icons.shopping_cart_outlined,
            label: l.productPurchasePriceLabel,
            value: context.money(product.purchasePrice),
          ),
        ],
        if (product.barcode != null && product.barcode!.isNotEmpty) ...[
          const SizedBox(height: SuuqSpacing.sm),
          _Stat(
            icon: Icons.qr_code_scanner_rounded,
            label: l.productBarcodeLabel,
            value: product.barcode!,
          ),
        ],
        const SizedBox(height: SuuqSpacing.lg),
        // Open batches (lots): received date, remaining, expiry badge; cost
        // is financially sensitive and owner-only.
        Row(
          children: [
            Expanded(
              child: Text(
                l.productBatchesTitle.toUpperCase(),
                style:
                    theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
              ),
            ),
            if (isOwner)
              TextButton(
                onPressed: () =>
                    context.push('/reports/batches?product=${product.id}'),
                child: Text(l.productViewBatches),
              ),
          ],
        ),
        const SizedBox(height: SuuqSpacing.xs),
        lotsAsync.when(
          loading: () => const SizedBox.shrink(),
          error: (e, _) => Text(context.errorMessage(e)),
          data: (lots) {
            if (lots.isEmpty) {
              return SectionCard(
                child: Center(
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: SuuqSpacing.md),
                    child: Text(
                      l.productNoBatches,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ),
              );
            }
            return SectionCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < lots.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    _LotTile(
                      lot: lots[i],
                      unit: product.unit,
                      isOwner: isOwner,
                      onMarkSpoiled: () => onMarkLotSpoiled(lots[i]),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
        const SizedBox(height: SuuqSpacing.lg),
        Text(
          l.productStockHistoryTitle,
          style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
        ),
        const SizedBox(height: SuuqSpacing.xs),
        logsAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(SuuqSpacing.md),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Text(context.errorMessage(e)),
          data: (logs) {
            if (logs.isEmpty) {
              return SectionCard(
                child: Center(
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: SuuqSpacing.md),
                    child: Text(
                      l.productNoMovements,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ),
              );
            }
            return SectionCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  for (var i = 0; i < logs.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    _MovementTile(movement: logs[i], unit: product.unit),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  static String _fmtNum(Decimal d) {
    final n = d.toDouble();
    if (n == n.roundToDouble()) return n.toInt().toString();
    return n.toStringAsFixed(2);
  }
}

class _LotTile extends StatelessWidget {
  const _LotTile({
    required this.lot,
    required this.unit,
    required this.isOwner,
    required this.onMarkSpoiled,
  });
  final StockLot lot;
  final String unit;
  final bool isOwner;
  final VoidCallback onMarkSpoiled;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final days = lot.daysToExpiry;
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
                  l.lotReceivedOn(
                    context.dateShort(lot.receivedAt.toLocal()),
                  ),
                  style: theme.textTheme.titleSmall,
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    l.lotQtyLeft(_fmt(lot.qtyRemaining), unit),
                    if (isOwner) context.money(lot.unitCost),
                    if (lot.note != null && lot.note!.isNotEmpty) lot.note!,
                  ].join(' · '),
                  style: theme.textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: SuuqSpacing.xs),
          if (lot.expiryDate != null && days != null) ...[
            ExpiryBadge(expiryDate: lot.expiryDate!, daysToExpiry: days),
            if (days < 0) ...[
              const SizedBox(width: SuuqSpacing.xs),
              TextButton(
                onPressed: onMarkSpoiled,
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                  visualDensity: VisualDensity.compact,
                ),
                child: Text(l.lotMarkSpoiled),
              ),
            ],
          ],
        ],
      ),
    );
  }

  static String _fmt(Decimal d) {
    final n = d.toDouble();
    if (n == n.roundToDouble()) return n.toInt().toString();
    return n.toStringAsFixed(2);
  }
}

class _Stat extends StatelessWidget {
  const _Stat({
    required this.icon,
    required this.label,
    required this.value,
    this.emphasize = false,
  });
  final IconData icon;
  final String label;
  final String value;
  final bool emphasize;

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
              color: emphasize
                  ? scheme.errorContainer
                  : scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(SuuqRadius.sm),
            ),
            child: Icon(
              icon,
              size: 18,
              color: emphasize ? scheme.error : scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: SuuqSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.bodySmall),
                Text(
                  value,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: emphasize ? scheme.error : null,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MovementTile extends StatelessWidget {
  const _MovementTile({required this.movement, required this.unit});
  final InventoryMovement movement;
  final String unit;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final positive = movement.quantityDelta > Decimal.zero;
    final (icon, label) = _iconAndLabelFor(l, movement.movement);
    final color = positive ? scheme.primary : scheme.error;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: SuuqSpacing.md,
        vertical: SuuqSpacing.sm,
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: positive
                  ? scheme.primaryContainer
                  : scheme.errorContainer,
              borderRadius: BorderRadius.circular(SuuqRadius.sm),
            ),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: SuuqSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.titleSmall),
                Text(
                  [
                    if (movement.reason != null)
                      _reasonLabel(l, movement.reason!),
                    context.dateTimeShort(movement.createdAt.toLocal()),
                  ].join(' · '),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Text(
            '${positive ? "+" : ""}${_fmtNum(movement.quantityDelta)} $unit',
            style: theme.textTheme.titleMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  (IconData, String) _iconAndLabelFor(AppLocalizations l, String movement) {
    switch (movement) {
      case 'restock':
        return (Icons.arrow_downward_rounded, l.productMovementRestock);
      case 'receive':
        return (Icons.arrow_downward_rounded, l.productMovementReceive);
      case 'sale':
        return (Icons.point_of_sale_rounded, l.productMovementSale);
      case 'refund':
        return (Icons.undo_rounded, l.productMovementRefund);
      case 'adjustment':
        return (Icons.tune_rounded, l.productMovementAdjustment);
      case 'spoilage':
        return (Icons.auto_delete_outlined, l.productMovementSpoilage);
      case 'production':
        return (Icons.bakery_dining_outlined, l.productMovementProduction);
      default:
        return (Icons.swap_horiz_rounded, movement);
    }
  }

  /// Display label for a machine reason code; falls back to the raw value
  /// for reasons we don't recognise (free-form/legacy data).
  String _reasonLabel(AppLocalizations l, String reason) {
    switch (reason) {
      case 'restock':
        return l.stockAdjustReasonRestock;
      case 'supplier delivery':
        return l.stockAdjustReasonSupplierDelivery;
      case 'transfer in':
        return l.stockAdjustReasonTransferIn;
      case 'count correction':
        return l.stockAdjustReasonCountCorrection;
      case 'waste':
        return l.stockAdjustReasonWaste;
      case 'damaged':
        return l.stockAdjustReasonDamaged;
      case 'theft':
        return l.stockAdjustReasonTheft;
      case 'transfer out':
        return l.stockAdjustReasonTransferOut;
      case 'expired':
        return l.spoilageReasonExpired;
      case 'day-old':
        return l.spoilageReasonDayOld;
      case 'other':
        return l.spoilageReasonOther;
      case 'spoiled on receive':
        return l.spoilageOnReceiveReason;
      case 'spoiled in production':
        return l.spoilageInProductionReason;
      default:
        return reason;
    }
  }

  String _fmtNum(Decimal d) {
    final n = d.toDouble().abs();
    if (n == n.roundToDouble()) return n.toInt().toString();
    return n.toStringAsFixed(2);
  }
}
