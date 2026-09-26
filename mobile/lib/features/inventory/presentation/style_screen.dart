import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/shop_type/size_presets.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/data/lots_repository.dart';
import 'package:suuqii/features/inventory/data/products_repository.dart';
import 'package:suuqii/features/inventory/data/styles_repository.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/inventory/domain/entities/style.dart';
import 'package:suuqii/features/inventory/presentation/style_sheets.dart';
import 'package:suuqii/features/inventory/presentation/style_wizard_screen.dart';
import 'package:suuqii/features/inventory/presentation/widgets/quantity_input.dart';
import 'package:suuqii/features/inventory/presentation/widgets/variant_matrix.dart';
import 'package:suuqii/shared/widgets/empty_state.dart';
import 'package:suuqii/shared/widgets/owner_pin_dialog.dart';
import 'package:suuqii/shared/widgets/product_image.dart';
import 'package:suuqii/shared/widgets/section_card.dart';
import 'package:suuqii/shared/widgets/status_pill.dart';

/// One style: its matrix with stock per cell (tap → variant detail) and the
/// style-level actions — add sizes/colours, receive a shipment by matrix,
/// edit, delete (docs/19 §6.2, §6.4).
class StyleScreen extends ConsumerWidget {
  const StyleScreen({required this.styleId, super.key});
  final String styleId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final styleAsync = ref.watch(watchStyleProvider(styleId));
    final variantsAsync = ref.watch(watchVariantsProvider(styleId));
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final canEdit = auth is Authenticated;
    final isOwner = canEdit && auth.isOwner;
    // Mark-down is a deliberate owner act (docs/19 §7) and only means
    // anything where prices are negotiated per line.
    final canMarkDown = isOwner && auth.features.hasLinePricing;

    return Scaffold(
      appBar: AppBar(
        title: Text(l.styleScreenTitle),
        actions: [
          if (canEdit)
            PopupMenuButton<_StyleAction>(
              onSelected: (action) => _run(
                context,
                ref,
                action,
                isOwner: isOwner,
                style: styleAsync.valueOrNull,
                variants: variantsAsync.valueOrNull ?? const [],
              ),
              itemBuilder: (_) => [
                if (canMarkDown)
                  PopupMenuItem(
                    value: _StyleAction.markDown,
                    child: ListTile(
                      leading: const Icon(Icons.trending_down_rounded),
                      title: Text(l.styleMarkDown),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                PopupMenuItem(
                  value: _StyleAction.edit,
                  child: ListTile(
                    leading: const Icon(Icons.edit_outlined),
                    title: Text(l.styleEdit),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: _StyleAction.delete,
                  child: ListTile(
                    leading: Icon(
                      Icons.delete_outline,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    title: Text(l.styleDelete),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
        ],
      ),
      body: styleAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.error_outline,
          title: l.inventoryLoadFailedTitle,
          message: context.errorMessage(e),
        ),
        data: (style) {
          if (style == null) {
            return EmptyState(
              icon: Icons.search_off_rounded,
              title: l.styleNotFound,
            );
          }
          final variants = variantsAsync.valueOrNull ?? const <Product>[];
          return _StyleBody(
            style: style,
            variants: variants,
            isOwner: isOwner,
            canEdit: canEdit,
            onAddVariants: () => _run(
              context,
              ref,
              _StyleAction.addVariants,
              isOwner: isOwner,
              style: style,
              variants: variants,
            ),
            onReceive: () => _run(
              context,
              ref,
              _StyleAction.receive,
              isOwner: isOwner,
              style: style,
              variants: variants,
            ),
          );
        },
      ),
    );
  }

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    _StyleAction action, {
    required bool isOwner,
    required Style? style,
    required List<Product> variants,
  }) async {
    if (style == null) return;
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);
    final repo = ref.read(stylesRepositoryProvider);

    // Every style.* op is PIN-gated for cashiers (docs/19 §7). The sheet
    // collects the input first so a cancelled PIN costs nothing.
    Future<String?> challengeIfNeeded() async {
      if (isOwner) return null;
      if (!context.mounted) return null;
      return requestOwnerChallenge(context, ref);
    }

    try {
      switch (action) {
        case _StyleAction.addVariants:
          final result = await showAddVariantsSheet(
            context,
            style: style,
            existing: variants,
          );
          if (result == null || result.isEmpty) return;
          final challenge = await challengeIfNeeded();
          if (!isOwner && challenge == null) return;
          final added = await repo.addVariants(
            styleId: style.id,
            variants: result,
            ownerChallengeToken: challenge,
          );
          messenger.showSnackBar(
            SnackBar(content: Text(l.addVariantsAdded(added.length))),
          );
        case _StyleAction.receive:
          final result = await showStyleReceiveSheet(
            context,
            style: style,
            variants: variants,
          );
          if (result == null || result.lines.isEmpty) return;
          final challenge = await challengeIfNeeded();
          if (!isOwner && challenge == null) return;
          final lots = ref.read(lotsRepositoryProvider);
          for (final line in result.lines) {
            await lots.receiveStock(
              productId: line.productId,
              quantity: line.quantity,
              unitCost: result.unitCost,
              note: result.note,
              ownerChallengeToken: challenge,
            );
          }
          messenger.showSnackBar(
            SnackBar(
              content: Text(l.receiveSheetSuccess(result.lines.length)),
            ),
          );
        case _StyleAction.edit:
          final result = await showStyleEditSheet(
            context,
            style: style,
            isOwner: isOwner,
          );
          if (result == null) return;
          final challenge = await challengeIfNeeded();
          if (!isOwner && challenge == null) return;
          await repo.updateStyle(
            id: style.id,
            name: result.name,
            brand: result.brand,
            category: result.category,
            segment: result.segment,
            imageUrl: result.imageUrl,
            defaultSellingPrice: result.defaultSellingPrice,
            defaultPurchasePrice: result.defaultPurchasePrice,
            sizeSet: style.sizeSet,
            skuPrefix: result.skuPrefix,
            applyPriceToVariants: result.applyPriceToVariants,
            ownerChallengeToken: challenge,
          );
          messenger.showSnackBar(SnackBar(content: Text(l.styleSaved)));
        case _StyleAction.markDown:
          if (!isOwner) return;
          final newPrice = await _promptMarkDown(context, style);
          if (newPrice == null) return;
          if (!context.mounted) return;
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(ctx.l10n.styleMarkDownConfirmTitle),
              content: Text(
                ctx.l10n.styleMarkDownConfirmBody(
                  ctx.money(style.defaultSellingPrice),
                  ctx.money(newPrice),
                  variants.length,
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(ctx.l10n.commonCancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(ctx.l10n.styleMarkDown),
                ),
              ],
            ),
          );
          if (confirmed != true) return;
          // `apply_price_to_variants` makes the server audit `style.markdown`
          // with old/new price, so the leakage report can tell clearance
          // from haggling (docs/19 §6.6).
          await repo.updateStyle(
            id: style.id,
            name: style.name,
            brand: style.brand,
            category: style.category,
            segment: style.segment,
            imageUrl: style.imageUrl,
            defaultSellingPrice: newPrice,
            defaultPurchasePrice: style.defaultPurchasePrice,
            sizeSet: style.sizeSet,
            skuPrefix: style.skuPrefix,
            applyPriceToVariants: true,
          );
          if (!context.mounted) return;
          messenger.showSnackBar(
            SnackBar(
              content: Text(l.styleMarkDownApplied(context.money(newPrice))),
            ),
          );
        case _StyleAction.delete:
          if (variants.any((v) => v.stock > Decimal.zero)) {
            messenger.showSnackBar(
              SnackBar(content: Text(l.styleDeleteHasStock)),
            );
            return;
          }
          final confirmed = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(ctx.l10n.styleDeleteConfirmTitle),
              content: Text(ctx.l10n.styleDeleteConfirmBody),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text(ctx.l10n.commonCancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(ctx.l10n.commonDelete),
                ),
              ],
            ),
          );
          if (confirmed != true) return;
          final challenge = await challengeIfNeeded();
          if (!isOwner && challenge == null) return;
          await repo.deleteStyle(style.id, ownerChallengeToken: challenge);
          messenger.showSnackBar(SnackBar(content: Text(l.styleDeleted)));
          router.pop();
      }
    } on StyleHasStockException {
      messenger.showSnackBar(SnackBar(content: Text(l.styleDeleteHasStock)));
    } on VariantCapException {
      messenger.showSnackBar(
        SnackBar(content: Text(l.styleVariantCapError(maxVariantsPerStyle))),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(localizedErrorMessage(l, e))),
      );
    }
  }

  /// New default selling price for a mark-down, or null when cancelled or
  /// not a valid non-negative amount.
  Future<Decimal?> _promptMarkDown(BuildContext context, Style style) async {
    final controller = TextEditingController(
      text: style.defaultSellingPrice.toString(),
    );
    final result = await showDialog<Decimal?>(
      context: context,
      builder: (ctx) {
        final dl = ctx.l10n;
        // Validation shows on the field: a snackbar would paint on the shell
        // Scaffold behind this dialog's barrier, where nobody sees it.
        String? error;
        return StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            title: Text(dl.styleMarkDownTitle),
            content: TextField(
              controller: controller,
              autofocus: true,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) {
                if (error != null) setState(() => error = null);
              },
              decoration: InputDecoration(
                labelText: dl.styleMarkDownNewPrice,
                prefixText: 'ETB  ',
                helperText: dl.styleMarkDownCurrent(
                  ctx.money(style.defaultSellingPrice),
                ),
                errorText: error,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(dl.commonCancel),
              ),
              FilledButton(
                onPressed: () {
                  final value = Decimal.tryParse(
                    controller.text.trim().replaceAll(',', '.'),
                  );
                  if (value == null || value < Decimal.zero) {
                    setState(() => error = dl.styleMarkDownInvalid);
                    return;
                  }
                  Navigator.pop(ctx, value);
                },
                child: Text(dl.posSetButton),
              ),
            ],
          ),
        );
      },
    );
    return result;
  }
}

enum _StyleAction { addVariants, receive, edit, delete, markDown }

class _StyleBody extends StatelessWidget {
  const _StyleBody({
    required this.style,
    required this.variants,
    required this.isOwner,
    required this.canEdit,
    required this.onAddVariants,
    required this.onReceive,
  });

  final Style style;
  final List<Product> variants;
  final bool isOwner;
  final bool canEdit;
  final VoidCallback onAddVariants;
  final VoidCallback onReceive;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final stockTotal = variants.fold(Decimal.zero, (a, v) => a + v.stock);
    // "Sizes missing" is the low-stock rule, not the zero-stock one (docs/19
    // §13.4) — the same `stock <= low_stock_threshold` the summary query and
    // the server use, so the style list and this screen never disagree.
    final sizesOut = variants.where((v) => v.isLowStock).length;
    final brokenRun =
        sizesOut > 0 && sizesOut < variants.length && stockTotal > Decimal.zero;

    final sizes = orderSizes(
      variants.map((v) => v.size).whereType<String>(),
      presetKey: style.sizeSet,
    );
    final colors = <String?>[];
    for (final v in variants) {
      if (!colors.contains(v.color)) colors.add(v.color);
    }
    final byCell = {
      for (final v in variants) variantCellKey(v.size, v.color): v,
    };
    final sizeAxis = sizes.isEmpty ? const <String?>[null] : sizes;
    final colorAxis = colors.isEmpty ? const <String?>[null] : colors;

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
                child: ProductImage(name: style.name, imageUrl: style.imageUrl),
              ),
              const SizedBox(width: SuuqSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      [
                        if (style.brand != null) style.brand!,
                        if (style.category != null) style.category!,
                        if (style.segment != null)
                          segmentLabel(l, style.segment!),
                      ].join(' · ').toUpperCase(),
                      style: theme.textTheme.labelSmall?.copyWith(
                        letterSpacing: 1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(style.name, style: theme.textTheme.titleLarge),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text(
                          context.money(style.defaultSellingPrice),
                          style: theme.textTheme.headlineSmall?.copyWith(
                            color: scheme.primary,
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(width: SuuqSpacing.xs),
                        if (brokenRun)
                          StatusPill(
                            label: l.styleBrokenRunPill,
                            intent: PillIntent.warning,
                          ),
                      ],
                    ),
                    if (style.skuPrefix != null)
                      Text(
                        l.styleSkuPrefixShown(style.skuPrefix!),
                        style: theme.textTheme.bodySmall,
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: SuuqSpacing.md),
        Row(
          children: [
            Expanded(
              child: InfoTile(
                label: l.styleTotalStock,
                value: formatQuantity(stockTotal),
              ),
            ),
            const SizedBox(width: SuuqSpacing.sm),
            Expanded(
              child: InfoTile(
                label: l.styleVariants,
                value: '${variants.length}',
              ),
            ),
            if (isOwner) ...[
              const SizedBox(width: SuuqSpacing.sm),
              Expanded(
                child: InfoTile(
                  label: l.productPurchaseLabel,
                  value: context.money(style.defaultPurchasePrice),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: SuuqSpacing.lg),
        Text(
          l.styleMatrixTitle.toUpperCase(),
          style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
        ),
        const SizedBox(height: SuuqSpacing.xs),
        if (variants.isEmpty)
          SectionCard(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: SuuqSpacing.md),
                child: Text(l.styleMatrixEmpty),
              ),
            ),
          )
        else
          SectionCard(
            padding: const EdgeInsets.all(SuuqSpacing.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                VariantMatrix(
                  sizes: sizeAxis,
                  colors: colorAxis,
                  cellBuilder: (_, size, color) {
                    final v = byCell[variantCellKey(size, color)];
                    return _StockCell(
                      variant: v,
                      onTap: v == null
                          ? null
                          : () => context.push('/inventory/${v.id}'),
                    );
                  },
                ),
                const SizedBox(height: SuuqSpacing.xs),
                Text(
                  l.styleMatrixTapHint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        if (isOwner) ...[
          const SizedBox(height: SuuqSpacing.lg),
          // The buying grid for this style (docs/19 §14.1) — owner-only,
          // like every other report.
          OutlinedButton.icon(
            onPressed: () =>
                context.push('/reports/size-curve?style=${style.id}'),
            icon: const Icon(Icons.insights_rounded),
            label: Text(l.sizeCurveTitle),
          ),
        ],
        if (canEdit) ...[
          const SizedBox(height: SuuqSpacing.lg),
          FilledButton.icon(
            onPressed: onReceive,
            icon: const Icon(Icons.local_shipping_outlined),
            label: Text(l.styleReceiveShipment),
          ),
          const SizedBox(height: SuuqSpacing.xs),
          OutlinedButton.icon(
            onPressed: onAddVariants,
            icon: const Icon(Icons.grid_on_rounded),
            label: Text(l.styleAddVariants),
          ),
        ],
      ],
    );
  }
}

/// One stock cell: the on-hand count, red at zero, amber at the threshold.
class _StockCell extends StatelessWidget {
  const _StockCell({required this.variant, required this.onTap});
  final Product? variant;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final v = variant;
    final Color bg;
    final Color fg;
    if (v == null) {
      bg = scheme.surfaceContainerHighest.withValues(alpha: 0.4);
      fg = scheme.onSurfaceVariant.withValues(alpha: 0.4);
    } else if (v.stock <= Decimal.zero) {
      bg = scheme.errorContainer;
      fg = scheme.error;
    } else if (v.isLowStock) {
      bg = scheme.tertiaryContainer;
      fg = scheme.onTertiaryContainer;
    } else {
      bg = scheme.primaryContainer;
      fg = scheme.onPrimaryContainer;
    }
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(SuuqRadius.sm),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(SuuqRadius.sm),
        child: SizedBox(
          height: 44,
          child: Center(
            child: Text(
              v == null ? '—' : formatQuantity(v.stock),
              style: theme.textTheme.titleMedium?.copyWith(
                color: fg,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small label/value card for the style header stats.
class InfoTile extends StatelessWidget {
  const InfoTile({required this.label, required this.value, super.key});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      padding: const EdgeInsets.all(SuuqSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: theme.textTheme.bodySmall),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
