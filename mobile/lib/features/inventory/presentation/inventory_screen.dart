import 'dart:async';

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
import 'package:suuqii/features/inventory/data/lots_dao.dart';
import 'package:suuqii/features/inventory/data/lots_repository.dart';
import 'package:suuqii/features/inventory/data/products_repository.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/inventory/domain/entities/stock_lot.dart';
import 'package:suuqii/features/inventory/presentation/spoilage_sheet.dart';
import 'package:suuqii/shared/widgets/empty_state.dart';
import 'package:suuqii/shared/widgets/expiry_badge.dart';
import 'package:suuqii/shared/widgets/owner_pin_dialog.dart';
import 'package:suuqii/shared/widgets/product_image.dart';
import 'package:suuqii/shared/widgets/status_pill.dart';

class InventoryScreen extends ConsumerStatefulWidget {
  const InventoryScreen({super.key});

  @override
  ConsumerState<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends ConsumerState<InventoryScreen> {
  final _search = TextEditingController();
  String _query = '';
  bool _lowStockOnly = false;
  bool _expiringOnly = false;

  @override
  void initState() {
    super.initState();
    // Mirror server lots once per screen open so expiry badges reflect
    // batches received on other devices. Failures are swallowed (offline).
    Future.microtask(
      () => ref.read(lotsSyncProvider.notifier).refresh(),
    );
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final canEdit = auth is Authenticated;
    final isOwner = canEdit && auth.role == 'owner';
    final productsAsync = ref.watch(watchProductsProvider(query: _query));
    final expiringAsync = ref.watch(watchExpiringLotsProvider);
    final expiringCount = expiringAsync.valueOrNull?.length ?? 0;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SuuqSpacing.md, SuuqSpacing.xs, SuuqSpacing.md, SuuqSpacing.xs,
            ),
            child: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: l.inventorySearchHint,
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 18),
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                      ),
                isDense: true,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SuuqSpacing.md, 0, SuuqSpacing.md, SuuqSpacing.xs,
            ),
            child: Row(
              children: [
                FilterChip(
                  label: Text(l.lowStock),
                  avatar: Icon(
                    Icons.warning_amber_rounded,
                    size: 16,
                    color: _lowStockOnly
                        ? scheme.onPrimaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                  selected: _lowStockOnly,
                  onSelected: (v) => setState(() {
                    _lowStockOnly = v;
                    if (v) _expiringOnly = false;
                  }),
                ),
                const SizedBox(width: SuuqSpacing.xs),
                FilterChip(
                  label: Text(
                    expiringCount > 0
                        ? '${l.inventoryExpiringChip} ($expiringCount)'
                        : l.inventoryExpiringChip,
                  ),
                  avatar: Icon(
                    Icons.schedule_rounded,
                    size: 16,
                    color: _expiringOnly
                        ? scheme.onPrimaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                  selected: _expiringOnly,
                  onSelected: (v) => setState(() {
                    _expiringOnly = v;
                    if (v) _lowStockOnly = false;
                  }),
                ),
                const Spacer(),
                if (canEdit)
                  TextButton.icon(
                    icon: const Icon(Icons.inventory_rounded, size: 18),
                    onPressed: () =>
                        context.push('/inventory/bulk-restock'),
                    label: Text(l.bulkRestockTitle),
                  ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async {
                await Future.wait([
                  ref.read(productsSyncProvider.notifier).refresh(),
                  ref.read(lotsSyncProvider.notifier).refresh(),
                ]);
              },
              child: _expiringOnly
                  ? _ExpiringList(
                      expiringAsync: expiringAsync,
                      canEdit: canEdit,
                      onMarkSpoiled: (e) => _recordSpoilage(
                        productId: e.lot.productId,
                        productUnit: e.productUnit,
                        isOwner: isOwner,
                        lot: e.lot,
                      ),
                    )
                  : productsAsync.when(
                      loading: () =>
                          const Center(child: CircularProgressIndicator()),
                      error: (e, _) => EmptyState(
                        icon: Icons.error_outline,
                        title: l.inventoryLoadFailedTitle,
                        message: context.errorMessage(e),
                      ),
                      data: (items) {
                        final visible = _lowStockOnly
                            ? items.where((p) => p.isLowStock).toList()
                            : items;
                        if (visible.isEmpty) {
                          return EmptyState(
                            icon: _lowStockOnly
                                ? Icons.check_circle_outline_rounded
                                : Icons.inventory_2_outlined,
                            title: _lowStockOnly
                                ? l.inventoryStockHealthyTitle
                                : l.inventoryEmptyTitle,
                            message: _lowStockOnly
                                ? l.inventoryStockHealthyMessage
                                : l.inventoryEmptyMessage,
                            action: !_lowStockOnly && canEdit
                                ? FilledButton.icon(
                                    icon: const Icon(Icons.add_rounded),
                                    onPressed: () =>
                                        context.push('/inventory/new'),
                                    label: Text(l.inventoryAddProduct),
                                  )
                                : null,
                          );
                        }
                        return ListView.separated(
                          padding: const EdgeInsets.fromLTRB(
                            SuuqSpacing.md, 0, SuuqSpacing.md, 96,
                          ),
                          itemCount: visible.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: SuuqSpacing.xs),
                          itemBuilder: (_, i) => _InventoryRow(
                            product: visible[i],
                            onTap: () =>
                                context.push('/inventory/${visible[i].id}'),
                            onLongPress: canEdit
                                ? () => _showRowActions(visible[i], isOwner)
                                : null,
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(
              onPressed: () => context.push('/inventory/new'),
              icon: const Icon(Icons.add_rounded),
              label: Text(context.l10n.inventoryAddProduct),
            )
          : null,
    );
  }

  /// Long-press context menu on an inventory row: quick spoilage entry
  /// without drilling into the product first.
  Future<void> _showRowActions(Product product, bool isOwner) async {
    final l = context.l10n;
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                product.name,
                style: Theme.of(ctx).textTheme.titleMedium,
              ),
              dense: true,
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.auto_delete_outlined),
              title: Text(l.spoilageTitle),
              onTap: () => Navigator.pop(ctx, 'spoil'),
            ),
            ListTile(
              leading: const Icon(Icons.open_in_new_rounded),
              title: Text(l.inventoryViewDetails),
              onTap: () => Navigator.pop(ctx, 'open'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'open') {
      unawaited(context.push('/inventory/${product.id}'));
    } else if (action == 'spoil') {
      await _recordSpoilage(
        productId: product.id,
        productUnit: product.unit,
        isOwner: isOwner,
      );
    }
  }

  /// Spoilage flow shared by the long-press action and the expiring list's
  /// one-tap "mark spoiled" (pre-filled with the expired lot).
  Future<void> _recordSpoilage({
    required String productId,
    required String productUnit,
    required bool isOwner,
    StockLot? lot,
  }) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final result = await showModalBottomSheet<SpoilageResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SpoilageSheet(
        productId: productId,
        productUnit: productUnit,
        initialLotId: lot?.id,
        initialQuantity: lot?.qtyRemaining,
        initialReason: (lot?.isExpired ?? false) ? 'expired' : null,
      ),
    );
    if (result == null || !mounted) return;

    String? challenge;
    if (!isOwner) {
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
}

/// Lots expiring within 7 days (or already expired), soonest first, with a
/// one-tap "mark spoiled" for expired batches.
class _ExpiringList extends StatelessWidget {
  const _ExpiringList({
    required this.expiringAsync,
    required this.canEdit,
    required this.onMarkSpoiled,
  });
  final AsyncValue<List<ExpiringLot>> expiringAsync;
  final bool canEdit;
  final ValueChanged<ExpiringLot> onMarkSpoiled;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return expiringAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => EmptyState(
        icon: Icons.error_outline,
        title: l.inventoryLoadFailedTitle,
        message: context.errorMessage(e),
      ),
      data: (items) {
        if (items.isEmpty) {
          return EmptyState(
            icon: Icons.check_circle_outline_rounded,
            title: l.inventoryNoExpiringTitle,
            message: l.inventoryNoExpiringMessage,
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(
            SuuqSpacing.md, 0, SuuqSpacing.md, 96,
          ),
          itemCount: items.length,
          separatorBuilder: (_, __) =>
              const SizedBox(height: SuuqSpacing.xs),
          itemBuilder: (_, i) => _ExpiringRow(
            entry: items[i],
            canEdit: canEdit,
            onMarkSpoiled: () => onMarkSpoiled(items[i]),
          ),
        );
      },
    );
  }
}

class _ExpiringRow extends StatelessWidget {
  const _ExpiringRow({
    required this.entry,
    required this.canEdit,
    required this.onMarkSpoiled,
  });
  final ExpiringLot entry;
  final bool canEdit;
  final VoidCallback onMarkSpoiled;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lot = entry.lot;
    final days = lot.daysToExpiry ?? 0;
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(SuuqRadius.md),
      child: InkWell(
        onTap: () => context.push('/inventory/${lot.productId}'),
        borderRadius: BorderRadius.circular(SuuqRadius.md),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(SuuqRadius.md),
            border: Border.all(color: scheme.outlineVariant),
          ),
          padding: const EdgeInsets.all(SuuqSpacing.sm),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.productName,
                      style: theme.textTheme.titleSmall,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l.lotQtyLeft(
                        _fmt(lot.qtyRemaining),
                        entry.productUnit,
                      ),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: SuuqSpacing.xs),
              if (lot.expiryDate != null)
                ExpiryBadge(
                  expiryDate: lot.expiryDate!,
                  daysToExpiry: days,
                ),
              if (canEdit && days < 0) ...[
                const SizedBox(width: SuuqSpacing.xs),
                TextButton(
                  onPressed: onMarkSpoiled,
                  style: TextButton.styleFrom(
                    foregroundColor: scheme.error,
                    visualDensity: VisualDensity.compact,
                  ),
                  child: Text(l.lotMarkSpoiled),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _fmt(Decimal d) {
    final n = d.toDouble();
    if (n == n.roundToDouble()) return n.toInt().toString();
    return n.toStringAsFixed(2);
  }
}

class _InventoryRow extends StatelessWidget {
  const _InventoryRow({required this.product, this.onTap, this.onLongPress});
  final Product product;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(SuuqRadius.md),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(SuuqRadius.md),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(SuuqRadius.md),
            border: Border.all(color: scheme.outlineVariant),
          ),
          padding: const EdgeInsets.all(SuuqSpacing.sm),
          child: Row(
            children: [
              SizedBox(
                width: 56,
                height: 56,
                child: ProductImage(
                  name: product.name,
                  imageUrl: product.imageUrl,
                  radius: SuuqRadius.sm,
                ),
              ),
              const SizedBox(width: SuuqSpacing.sm),
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
                    const SizedBox(height: 2),
                    Text(
                      '${product.category ?? context.l10n.inventoryUncategorized} · ${product.unit}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: SuuqSpacing.sm),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    context.money(product.sellingPrice),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 2),
                  if (product.isLowStock)
                    StatusPill(
                      label: '${product.stock} ${product.unit}',
                      intent: PillIntent.warning,
                    )
                  else
                    Text(
                      '${product.stock} ${product.unit}',
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
