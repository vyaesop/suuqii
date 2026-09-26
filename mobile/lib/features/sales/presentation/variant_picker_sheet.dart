import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/shop_type/size_presets.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/inventory/presentation/widgets/quantity_input.dart';
import 'package:suuqii/features/sales/presentation/cart_controller.dart';
import 'package:suuqii/shared/widgets/product_image.dart';
import 'package:suuqii/shared/widgets/sheet_handle.dart';

/// Open the picker for one style. Resolves with the variant added on a single
/// tap, or null when dismissed (long-press adds stay open).
Future<Product?> showVariantPicker(
  BuildContext context, {
  required String styleName,
  required String? imageUrl,
  required List<Product> variants,
  String? sizeSet,
  bool allowsOversell = false,
}) {
  return showModalBottomSheet<Product>(
    context: context,
    isScrollControlled: true,
    builder: (_) => VariantPickerSheet(
      styleName: styleName,
      imageUrl: imageUrl,
      variants: variants,
      sizeSet: sizeSet,
      allowsOversell: allowsOversell,
    ),
  );
}

/// Colour rows × size chips with on-hand counts (docs/19 §6.3). A chip at 0
/// is disabled — boutiques keep the hard stock gate. One tap adds the variant
/// and closes; long-press adds and stays open for multi-add.
class VariantPickerSheet extends ConsumerWidget {
  const VariantPickerSheet({
    required this.styleName,
    required this.imageUrl,
    required this.variants,
    this.sizeSet,
    this.allowsOversell = false,
    super.key,
  });

  final String styleName;
  final String? imageUrl;
  final List<Product> variants;
  final String? sizeSet;
  final bool allowsOversell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cart = ref.watch(cartControllerProvider);

    // Rows: colours in first-seen order; a null colour is its own row.
    final colours = <String?>[];
    for (final v in variants) {
      if (!colours.contains(v.color)) colours.add(v.color);
    }
    final sizes = orderSizes(
      variants.map((v) => v.size).whereType<String>(),
      presetKey: sizeSet,
    );
    final prices = variants.map((v) => v.sellingPrice).toSet();

    return SuuqSheet(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 56,
                height: 56,
                child: ProductImage(
                  name: styleName,
                  imageUrl: imageUrl,
                  radius: SuuqRadius.sm,
                ),
              ),
              const SizedBox(width: SuuqSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(styleName, style: theme.textTheme.titleLarge),
                    Text(
                      prices.length == 1
                          ? context.money(prices.first)
                          : l.variantPickerPriceVaries,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: SuuqSpacing.xs),
          Text(
            l.variantPickerHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: SuuqSpacing.md),
          for (final colour in colours) ...[
            if (colour != null)
              Padding(
                padding: const EdgeInsets.only(bottom: SuuqSpacing.xxs),
                child: Text(
                  colour,
                  style: theme.textTheme.labelLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            Wrap(
              spacing: SuuqSpacing.xs,
              runSpacing: SuuqSpacing.xs,
              children: [
                for (final v in _rowVariants(colour, sizes))
                  _VariantChip(
                    variant: v,
                    inCart: cart.qtyFor(v.id),
                    enabled: allowsOversell || v.stock > Decimal.zero,
                    onTap: () {
                      HapticFeedback.selectionClick();
                      ref.read(cartControllerProvider.notifier).addProduct(v);
                      Navigator.pop(context, v);
                    },
                    onLongPress: () {
                      HapticFeedback.mediumImpact();
                      ref.read(cartControllerProvider.notifier).addProduct(v);
                      SuuqSheet.showMessage(
                        context,
                        l.posAddedToCart(v.name),
                        error: false,
                      );
                    },
                  ),
              ],
            ),
            const SizedBox(height: SuuqSpacing.md),
          ],
        ],
      ),
    );
  }

  /// Variants of one colour row in size-run order; size-less variants (free
  /// size) come first.
  List<Product> _rowVariants(String? colour, List<String> sizes) {
    final row = variants.where((v) => v.color == colour).toList();
    final rank = {for (var i = 0; i < sizes.length; i++) sizes[i]: i};
    row.sort((a, b) {
      final ra = a.size == null ? -1 : (rank[a.size] ?? sizes.length);
      final rb = b.size == null ? -1 : (rank[b.size] ?? sizes.length);
      return ra.compareTo(rb);
    });
    return row;
  }
}

class _VariantChip extends StatelessWidget {
  const _VariantChip({
    required this.variant,
    required this.inCart,
    required this.enabled,
    required this.onTap,
    required this.onLongPress,
  });

  final Product variant;
  final Decimal inCart;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final selected = inCart > Decimal.zero;
    final label = variant.size ?? l.variantFreeSize;
    final fg = !enabled
        ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
        : selected
            ? scheme.onPrimaryContainer
            : scheme.onSurface;
    return Semantics(
      button: true,
      enabled: enabled,
      label: l.variantChipSemantics(
        variant.name,
        formatQuantity(variant.stock),
      ),
      child: Material(
        color: selected ? scheme.primaryContainer : scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(SuuqRadius.sm),
        child: InkWell(
          onTap: enabled ? onTap : null,
          onLongPress: enabled ? onLongPress : null,
          borderRadius: BorderRadius.circular(SuuqRadius.sm),
          child: Container(
            constraints: const BoxConstraints(minWidth: 64, minHeight: 56),
            padding: const EdgeInsets.symmetric(
              horizontal: SuuqSpacing.sm,
              vertical: SuuqSpacing.xs,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(SuuqRadius.sm),
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? 1.5 : 1,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: fg,
                    fontWeight: FontWeight.w700,
                    decoration: enabled ? null : TextDecoration.lineThrough,
                  ),
                ),
                Text(
                  selected
                      ? l.variantChipStockInCart(
                          formatQuantity(variant.stock),
                          formatQuantity(inCart),
                        )
                      : formatQuantity(variant.stock),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: variant.isLowStock && enabled ? scheme.error : fg,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
