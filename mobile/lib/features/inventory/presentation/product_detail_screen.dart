import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/utils/money.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/data/products_repository.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/inventory/presentation/stock_adjust_sheet.dart';
import 'package:suuqii/shared/widgets/empty_state.dart';
import 'package:suuqii/shared/widgets/owner_pin_dialog.dart';
import 'package:suuqii/shared/widgets/product_image.dart';
import 'package:suuqii/shared/widgets/section_card.dart';
import 'package:suuqii/shared/widgets/status_pill.dart';

class ProductDetailScreen extends ConsumerWidget {
  const ProductDetailScreen({required this.productId, super.key});
  final String productId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final productAsync = ref.watch(watchProductProvider(productId));
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final canEdit = auth is Authenticated;
    final isOwner = canEdit && auth.role == 'owner';

    return Scaffold(
      appBar: AppBar(
        title: const Text('Product'),
        actions: [
          if (canEdit)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit',
              onPressed: () => context.push('/inventory/edit/$productId'),
            ),
        ],
      ),
      body: productAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.error_outline,
          title: 'Failed to load',
          message: '$e',
        ),
        data: (product) {
          if (product == null) {
            return const EmptyState(
              icon: Icons.search_off_rounded,
              title: 'Product not found',
            );
          }
          return _DetailBody(product: product, isOwner: isOwner);
        },
      ),
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(
              icon: const Icon(Icons.tune_rounded),
              onPressed: () => _adjustStock(context, ref, isOwner: isOwner),
              label: const Text('Adjust stock'),
            )
          : null,
    );
  }

  Future<void> _adjustStock(
    BuildContext context,
    WidgetRef ref, {
    required bool isOwner,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await showModalBottomSheet<({Decimal delta, String reason})>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const StockAdjustSheet(),
    );
    if (result == null) return;

    String? challenge;
    if (!isOwner) {
      if (!context.mounted) return;
      challenge = await requestOwnerChallenge(context, ref);
      if (challenge == null) return;
    }

    try {
      await ref.read(productsRepositoryProvider).adjustStock(
            productId: productId,
            delta: result.delta,
            reason: result.reason,
            ownerChallengeToken: challenge,
          );
      messenger.showSnackBar(
        SnackBar(content: Text('Stock adjusted by ${result.delta}')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }
}

class _DetailBody extends ConsumerWidget {
  const _DetailBody({required this.product, required this.isOwner});
  final Product product;
  final bool isOwner;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final logsAsync = ref.watch(watchInventoryLogProvider(product.id));

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
                          formatMoney(product.sellingPrice),
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
                          const StatusPill(
                            label: 'LOW',
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
                label: 'In stock',
                value: '${_fmtNum(product.stock)} ${product.unit}',
                emphasize: product.isLowStock,
              ),
            ),
            const SizedBox(width: SuuqSpacing.sm),
            Expanded(
              child: _Stat(
                icon: Icons.warning_amber_rounded,
                label: 'Low at',
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
            label: 'Purchase price',
            value: formatMoney(product.purchasePrice),
          ),
        ],
        if (product.barcode != null && product.barcode!.isNotEmpty) ...[
          const SizedBox(height: SuuqSpacing.sm),
          _Stat(
            icon: Icons.qr_code_scanner_rounded,
            label: 'Barcode',
            value: product.barcode!,
          ),
        ],
        const SizedBox(height: SuuqSpacing.lg),
        Text(
          'STOCK HISTORY',
          style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
        ),
        const SizedBox(height: SuuqSpacing.xs),
        logsAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(SuuqSpacing.md),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (e, _) => Text('$e'),
          data: (logs) {
            if (logs.isEmpty) {
              return SectionCard(
                child: Center(
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(vertical: SuuqSpacing.md),
                    child: Text(
                      'No movements yet',
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
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final positive = movement.quantityDelta > Decimal.zero;
    final (icon, label) = _iconAndLabelFor(movement.movement);
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
                    if (movement.reason != null) movement.reason!,
                    _formatDateTime(movement.createdAt.toLocal()),
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

  (IconData, String) _iconAndLabelFor(String movement) {
    switch (movement) {
      case 'restock':
        return (Icons.arrow_downward_rounded, 'Restock');
      case 'sale':
        return (Icons.point_of_sale_rounded, 'Sale');
      case 'refund':
        return (Icons.undo_rounded, 'Refund');
      case 'adjustment':
        return (Icons.tune_rounded, 'Adjustment');
      default:
        return (Icons.swap_horiz_rounded, movement);
    }
  }

  String _fmtNum(Decimal d) {
    final n = d.toDouble().abs();
    if (n == n.roundToDouble()) return n.toInt().toString();
    return n.toStringAsFixed(2);
  }

  String _formatDateTime(DateTime d) {
    String p(int n) => n < 10 ? '0$n' : '$n';
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }
}
