import 'package:flutter/material.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/inventory/domain/entities/style.dart';
import 'package:suuqii/shared/widgets/product_image.dart';
import 'package:suuqii/shared/widgets/section_card.dart';

/// Read-only identity card for a variant: style name, size and colour. Shown
/// on product edit/detail instead of editable name/category fields, because
/// those are owned by the style (docs/19 §6.1). Tap → the style screen.
class VariantHeader extends StatelessWidget {
  const VariantHeader({
    required this.product,
    required this.style,
    this.onOpenStyle,
    super.key,
  });

  final Product product;

  /// Null when the style has not been mirrored yet; the header then falls
  /// back to the variant's composed name.
  final Style? style;
  final VoidCallback? onOpenStyle;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final styleName = style?.name ?? product.name;
    return SectionCard(
      onTap: onOpenStyle,
      child: Row(
        children: [
          SizedBox(
            width: 56,
            height: 56,
            child: ProductImage(
              name: styleName,
              imageUrl: product.imageUrl ?? style?.imageUrl,
              radius: SuuqRadius.sm,
            ),
          ),
          const SizedBox(width: SuuqSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.variantHeaderStyle,
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 1,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                Text(styleName, style: theme.textTheme.titleMedium),
                const SizedBox(height: SuuqSpacing.xs),
                Wrap(
                  spacing: SuuqSpacing.xs,
                  runSpacing: SuuqSpacing.xxs,
                  children: [
                    if (product.size != null)
                      _Tag(label: l.variantSize(product.size!)),
                    if (product.color != null)
                      _Tag(label: l.variantColor(product.color!)),
                    if (product.sku != null) _Tag(label: product.sku!),
                  ],
                ),
              ],
            ),
          ),
          if (onOpenStyle != null)
            Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  const _Tag({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}
