import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/shop_type/shop_features.dart';
import 'package:suuqii/core/shop_type/shop_type_ui.dart';
import 'package:suuqii/core/utils/ethiopic.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/data/lots_dao.dart';
import 'package:suuqii/features/inventory/data/lots_repository.dart';
import 'package:suuqii/features/inventory/data/products_repository.dart';
import 'package:suuqii/features/inventory/data/styles_repository.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/inventory/domain/entities/stock_lot.dart';
import 'package:suuqii/features/inventory/domain/entities/style.dart';
import 'package:suuqii/features/inventory/presentation/spoilage_sheet.dart';
import 'package:suuqii/features/inventory/presentation/widgets/quantity_input.dart';
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
    // Mirror server lots (and styles, on variant shops) once per screen open
    // so badges reflect batches received on other devices. Failures are
    // swallowed (offline).
    Future.microtask(() {
      ref.read(lotsSyncProvider.notifier).refresh();
      ref.read(stylesSyncProvider.notifier).refresh();
    });
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
    final features = canEdit ? auth.features : ShopFeatures.regular;
    final productsAsync = ref.watch(watchProductsProvider(query: _query));
    // Expiry is a no-op dimension for shops that do not track it; skip the
    // stream entirely rather than showing an always-empty chip.
    final expiringAsync = features.tracksExpiry
        ? ref.watch(watchExpiringLotsProvider)
        : const AsyncValue<List<ExpiringLot>>.data([]);
    final expiringCount = expiringAsync.valueOrNull?.length ?? 0;
    final stylesAsync = features.hasVariants
        ? ref.watch(watchStyleSummariesProvider)
        : const AsyncValue<List<StyleSummary>>.data([]);
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
                if (features.tracksExpiry) ...[
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
                ],
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
                  ref.read(stylesSyncProvider.notifier).refresh(),
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
                        features: features,
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
                      data: (items) => _ProductList(
                        items: items,
                        styles: stylesAsync.valueOrNull ?? const [],
                        query: _query,
                        lowStockOnly: _lowStockOnly,
                        features: features,
                        canEdit: canEdit,
                        onAdd: () => _add(features, canEdit),
                        onRowLongPress: canEdit
                            ? (p) => _showRowActions(p, isOwner, features)
                            : null,
                      ),
                    ),
            ),
          ),
        ],
      ),
      floatingActionButton: canEdit
          ? FloatingActionButton.extended(
              onPressed: () => _add(features, canEdit),
              icon: const Icon(Icons.add_rounded),
              label: Text(
                features.hasVariants
                    ? l.inventoryNewStyle
                    : l.inventoryAddProduct,
              ),
            )
          : null,
    );
  }

  /// FAB: variant shops choose between a style (the common case) and a
  /// plain product (accessories sold as one item).
  Future<void> _add(ShopFeatures features, bool canEdit) async {
    if (!canEdit) return;
    if (!features.hasVariants) {
      unawaited(context.push('/inventory/new'));
      return;
    }
    final l = context.l10n;
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.checkroom_rounded),
              title: Text(l.inventoryNewStyle),
              subtitle: Text(l.inventoryNewStyleHint),
              onTap: () => Navigator.pop(ctx, 'style'),
            ),
            ListTile(
              leading: const Icon(Icons.add_box_outlined),
              title: Text(l.inventoryAddProduct),
              subtitle: Text(l.inventoryNewProductHint),
              onTap: () => Navigator.pop(ctx, 'product'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    unawaited(
      context.push(choice == 'style' ? '/inventory/new-style' : '/inventory/new'),
    );
  }

  /// Long-press context menu on an inventory row: quick spoilage entry
  /// without drilling into the product first.
  Future<void> _showRowActions(
    Product product,
    bool isOwner,
    ShopFeatures features,
  ) async {
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
              title: Text(features.spoilageActionTitle(l)),
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
        features: features,
      );
    }
  }

  /// Spoilage flow shared by the long-press action and the expiring list's
  /// one-tap "mark spoiled" (pre-filled with the expired lot).
  Future<void> _recordSpoilage({
    required String productId,
    required String productUnit,
    required bool isOwner,
    required ShopFeatures features,
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
        title: features.spoilageActionTitle(l),
        integerOnly: features.locksUnit,
        damagedLostWording: features.isDamagedLostWording,
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
      messenger.showSnackBar(
        SnackBar(content: Text(features.spoilageSuccess(l))),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(localizedErrorMessage(l, e))),
      );
    }
  }
}

/// The main list. On variant shops the default view is styles first (with
/// variant count, total stock and a broken-run pill) followed by the
/// unstyled products; searching or filtering by low stock falls back to the
/// flat product list so "jeans 32" and a low-stock variant are still found.
class _ProductList extends StatelessWidget {
  const _ProductList({
    required this.items,
    required this.styles,
    required this.query,
    required this.lowStockOnly,
    required this.features,
    required this.canEdit,
    required this.onAdd,
    required this.onRowLongPress,
  });

  final List<Product> items;
  final List<StyleSummary> styles;
  final String query;
  final bool lowStockOnly;
  final ShopFeatures features;
  final bool canEdit;
  final VoidCallback onAdd;
  final void Function(Product)? onRowLongPress;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final grouped = features.hasVariants && !lowStockOnly;
    final needle = foldForSearch(query.trim());
    final visibleStyles = !grouped
        ? const <StyleSummary>[]
        : needle.isEmpty
            ? styles
            : styles
                .where((s) => foldForSearch(s.style.name).contains(needle))
                .toList();
    // With a query, variants whose composed name matched are listed flat so
    // a size search lands on the exact row; without one, they live under
    // their style.
    final visibleProducts = lowStockOnly
        ? items.where((p) => p.isLowStock).toList()
        : grouped && needle.isEmpty
            ? items.where((p) => !p.isVariant).toList()
            : items;

    if (visibleStyles.isEmpty && visibleProducts.isEmpty) {
      return EmptyState(
        icon: lowStockOnly
            ? Icons.check_circle_outline_rounded
            : Icons.inventory_2_outlined,
        title: lowStockOnly
            ? l.inventoryStockHealthyTitle
            : l.inventoryEmptyTitle,
        message: lowStockOnly
            ? l.inventoryStockHealthyMessage
            : l.inventoryEmptyMessage,
        action: !lowStockOnly && canEdit
            ? FilledButton.icon(
                icon: const Icon(Icons.add_rounded),
                onPressed: onAdd,
                label: Text(
                  features.hasVariants
                      ? l.inventoryNewStyle
                      : l.inventoryAddProduct,
                ),
              )
            : null,
      );
    }

    final styleById = {for (final s in styles) s.style.id: s.style};
    return ListView(
      padding: const EdgeInsets.fromLTRB(SuuqSpacing.md, 0, SuuqSpacing.md, 96),
      children: [
        if (visibleStyles.isNotEmpty) ...[
          _Header(l.inventoryStylesHeader),
          for (final s in visibleStyles) ...[
            _StyleRow(
              summary: s,
              onTap: () => context.push('/inventory/style/${s.style.id}'),
            ),
            const SizedBox(height: SuuqSpacing.xs),
          ],
          if (visibleProducts.isNotEmpty)
            _Header(l.inventoryProductsHeader),
        ],
        for (final p in visibleProducts) ...[
          _InventoryRow(
            product: p,
            styleImageUrl: p.styleId == null ? null : styleById[p.styleId]?.imageUrl,
            hideUnit: features.locksUnit,
            onTap: () => context.push('/inventory/${p.id}'),
            onLongPress:
                onRowLongPress == null ? null : () => onRowLongPress!(p),
          ),
          const SizedBox(height: SuuqSpacing.xs),
        ],
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, SuuqSpacing.sm, 4, SuuqSpacing.xs),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              letterSpacing: 1.2,
            ),
      ),
    );
  }
}

/// One style in the inventory list: image, name, "N variants · Σ stock",
/// and a warning pill when the size run is broken.
class _StyleRow extends StatelessWidget {
  const _StyleRow({required this.summary, required this.onTap});
  final StyleSummary summary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = summary.style;
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(SuuqRadius.md),
      child: InkWell(
        onTap: onTap,
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
                  name: style.name,
                  imageUrl: style.imageUrl,
                  radius: SuuqRadius.sm,
                ),
              ),
              const SizedBox(width: SuuqSpacing.sm),
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
                    const SizedBox(height: 2),
                    Text(
                      l.inventoryStyleSummary(
                        summary.variantCount,
                        formatQuantity(summary.stockTotal),
                      ),
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
                    context.money(style.defaultSellingPrice),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 2),
                  if (summary.hasBrokenRun)
                    StatusPill(
                      label: l.inventorySizesMissing,
                      intent: PillIntent.warning,
                    )
                  else if (summary.stockTotal <= Decimal.zero &&
                      summary.variantCount > 0)
                    StatusPill(
                      label: l.inventorySoldOut,
                      intent: PillIntent.danger,
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
                        formatQuantity(lot.qtyRemaining),
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
}

class _InventoryRow extends StatelessWidget {
  const _InventoryRow({
    required this.product,
    required this.hideUnit,
    this.styleImageUrl,
    this.onTap,
    this.onLongPress,
  });
  final Product product;

  /// Locked-unit shops count pieces; the unit suffix is noise there.
  final bool hideUnit;

  /// Fallback image for a variant without its own photo.
  final String? styleImageUrl;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final stockText = hideUnit
        ? formatQuantity(product.stock)
        : '${product.stock} ${product.unit}';
    final subtitle = [
      product.category ?? context.l10n.inventoryUncategorized,
      if (!hideUnit) product.unit,
      if (product.sku != null) product.sku!,
    ].join(' · ');
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
                  imageUrl: product.imageUrl ?? styleImageUrl,
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
                      subtitle,
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
                    context.money(product.sellingPrice),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(height: 2),
                  if (product.isLowStock)
                    StatusPill(
                      label: stockText,
                      intent: PillIntent.warning,
                    )
                  else
                    Text(
                      stockText,
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
