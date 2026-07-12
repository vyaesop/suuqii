import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/sales/domain/entities/sale.dart';
import 'package:suuqii/features/sales/presentation/cart_controller.dart';
import 'package:suuqii/shared/widgets/product_image.dart';

/// Cart review and edit. Replaces the quick cart shortcut with an
/// intermediate step where the cashier can change quantities, remove
/// lines, or add a discount before the final checkout sheet.
class CartReviewSheet extends ConsumerWidget {
  const CartReviewSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final cart = ref.watch(cartControllerProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (cart.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (Navigator.canPop(context)) Navigator.pop(context);
      });
      return const SizedBox.shrink();
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: SuuqSpacing.xs),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                SuuqSpacing.md,
                SuuqSpacing.xs,
                SuuqSpacing.md,
                SuuqSpacing.sm,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l.cartTitle,
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.delete_outline_rounded, size: 18),
                    onPressed: () => _confirmClear(context, ref),
                    label: Text(l.cartClear),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: SuuqSpacing.md),
                itemCount: cart.lines.length,
                separatorBuilder: (_, __) => Divider(
                  height: 1,
                  color: scheme.outlineVariant,
                ),
                itemBuilder: (_, i) {
                  final line = cart.lines[i];
                  return Dismissible(
                    key: ValueKey('cart_line_${line.product.id}'),
                    direction: DismissDirection.endToStart,
                    background: Container(
                      alignment: Alignment.centerRight,
                      padding: const EdgeInsets.only(right: SuuqSpacing.md),
                      color: scheme.errorContainer,
                      child: Icon(
                        Icons.delete_rounded,
                        color: scheme.error,
                      ),
                    ),
                    onDismissed: (_) => ref
                        .read(cartControllerProvider.notifier)
                        .remove(line.product.id),
                    child: _CartLineTile(line: line),
                  );
                },
              ),
            ),
            Container(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: scheme.outlineVariant)),
              ),
              padding: const EdgeInsets.fromLTRB(
                SuuqSpacing.md,
                SuuqSpacing.md,
                SuuqSpacing.md,
                SuuqSpacing.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(
                        l.posCartItemsSummary(
                          _qtyAsNum(cart.itemCount),
                          cart.lineCount,
                        ),
                        style: theme.textTheme.bodySmall,
                      ),
                      const Spacer(),
                      Text(
                        context.money(cart.subtotal),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  InkWell(
                    onTap: () => _editDiscount(context, ref, cart),
                    borderRadius: BorderRadius.circular(SuuqRadius.sm),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Icon(
                            Icons.local_offer_outlined,
                            size: 16,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            cart.discount > Decimal.zero
                                ? l.cartDiscount
                                : l.cartAddDiscount,
                            style: theme.textTheme.bodySmall,
                          ),
                          const Spacer(),
                          if (cart.discount > Decimal.zero)
                            Text(
                              l.cartMinusAmount(context.money(cart.discount)),
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: scheme.error,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            )
                          else
                            Icon(
                              Icons.add_rounded,
                              size: 16,
                              color: scheme.onSurfaceVariant,
                            ),
                        ],
                      ),
                    ),
                  ),
                  Divider(color: scheme.outlineVariant, height: SuuqSpacing.md),
                  Row(
                    children: [
                      Text(l.total, style: theme.textTheme.bodyMedium),
                      const Spacer(),
                      Text(
                        context.money(cart.total),
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: SuuqSpacing.sm),
                  SizedBox(
                    height: 56,
                    child: FilledButton.icon(
                      icon: const Icon(Icons.arrow_forward_rounded),
                      onPressed: () => Navigator.pop(context, true),
                      label: Text(l.cartContinueToCheckout),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editDiscount(
    BuildContext context,
    WidgetRef ref,
    Cart cart,
  ) async {
    final controller = TextEditingController(
      text: cart.discount > Decimal.zero ? cart.discount.toString() : '',
    );
    final result = await showDialog<Decimal?>(
      context: context,
      builder: (ctx) {
        final dl = ctx.l10n;
        return AlertDialog(
          title: Text(dl.cartDiscount),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: dl.cartAmountLabel,
              prefixText: 'ETB  ',
              helperText: dl.cartSubtotalHelper(ctx.money(cart.subtotal)),
            ),
          ),
          actions: [
            if (cart.discount > Decimal.zero)
              TextButton(
                onPressed: () => Navigator.pop(ctx, Decimal.zero),
                child: Text(dl.cartClear),
              ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(dl.commonCancel),
            ),
            FilledButton(
              onPressed: () {
                final value = Decimal.tryParse(
                  controller.text.trim().replaceAll(',', '.'),
                );
                Navigator.pop(ctx, value ?? Decimal.zero);
              },
              child: Text(dl.posSetButton),
            ),
          ],
        );
      },
    );

    if (result == null) return;
    if (result > cart.subtotal) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n
                .cartDiscountExceedsSubtotal(context.money(cart.subtotal)),
          ),
        ),
      );
      return;
    }
    ref.read(cartControllerProvider.notifier).setDiscount(result);
  }

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final dl = ctx.l10n;
        return AlertDialog(
          title: Text(dl.cartClearConfirmTitle),
          content: Text(dl.cartClearConfirmBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(dl.cartKeep),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(dl.cartClear),
            ),
          ],
        );
      },
    );
    if (confirm ?? false) {
      ref.read(cartControllerProvider.notifier).clear();
      if (context.mounted) Navigator.pop(context);
    }
  }
}

class _CartLineTile extends ConsumerWidget {
  const _CartLineTile({required this.line});

  final CartLine line;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final isBakery = ref.watch(authControllerProvider).valueOrNull is Authenticated &&
        (ref.watch(authControllerProvider).valueOrNull! as Authenticated).isBakery;
    final stock = line.product.stock;
    final atStockLimit = !isBakery && line.qty >= stock;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SuuqSpacing.sm),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            height: 48,
            child: ProductImage(
              name: line.product.name,
              imageUrl: line.product.imageUrl,
              radius: SuuqRadius.sm,
            ),
          ),
          const SizedBox(width: SuuqSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  line.product.name,
                  style: theme.textTheme.titleSmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  context.l10n.cartPricePerUnit(
                    context.money(line.product.sellingPrice),
                    line.product.unit,
                  ),
                  style: theme.textTheme.bodySmall,
                ),
                Text(
                  context.money(line.lineTotal),
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: scheme.primary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: SuuqSpacing.xs),
          _QtyStepper(
            qty: line.qty,
            onMinus: () => ref
                .read(cartControllerProvider.notifier)
                .setQty(line.product.id, line.qty - Decimal.one),
            onPlus: atStockLimit
                ? null
                : () => ref
                    .read(cartControllerProvider.notifier)
                    .setQty(line.product.id, line.qty + Decimal.one),
            onTapQty: () => _editQty(context, ref, isBakery: isBakery),
          ),
        ],
      ),
    );
  }

  Future<void> _editQty(
    BuildContext context,
    WidgetRef ref, {
    required bool isBakery,
  }) async {
    final controller = TextEditingController(text: _fmtQty(line.qty));
    final result = await showDialog<Decimal?>(
      context: context,
      builder: (ctx) {
        final dl = ctx.l10n;
        return AlertDialog(
          title: Text(line.product.name),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: dl.posQuantityLabel(line.product.unit),
              helperText: isBakery
                  ? null
                  : dl.posInStockHelper(_fmtQty(line.product.stock)),
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
                Navigator.pop(ctx, value);
              },
              child: Text(dl.posSetButton),
            ),
          ],
        );
      },
    );

    if (result == null) return;
    if (result <= Decimal.zero) {
      ref.read(cartControllerProvider.notifier).remove(line.product.id);
      return;
    }
    if (!isBakery && result > line.product.stock) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.posOnlyQtyInStock(
              _fmtQty(line.product.stock),
              line.product.unit,
            ),
          ),
        ),
      );
      return;
    }
    ref.read(cartControllerProvider.notifier).setQty(line.product.id, result);
  }

  static String _fmtQty(Decimal value) {
    final n = value.toDouble();
    if (n == n.roundToDouble()) return n.toInt().toString();
    return n.toStringAsFixed(2);
  }
}

class _QtyStepper extends StatelessWidget {
  const _QtyStepper({
    required this.qty,
    required this.onMinus,
    required this.onPlus,
    required this.onTapQty,
  });

  final Decimal qty;
  final VoidCallback? onMinus;
  final VoidCallback? onPlus;
  final VoidCallback onTapQty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(SuuqRadius.sm),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _RoundIconBtn(icon: Icons.remove_rounded, onPressed: onMinus),
          InkWell(
            onTap: onTapQty,
            borderRadius: BorderRadius.circular(4),
            child: Container(
              constraints: const BoxConstraints(minWidth: 48),
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              child: Text(
                _fmtQty(qty),
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          _RoundIconBtn(icon: Icons.add_rounded, onPressed: onPlus),
        ],
      ),
    );
  }

  static String _fmtQty(Decimal value) {
    final n = value.toDouble();
    if (n == n.roundToDouble()) return n.toInt().toString();
    return n.toStringAsFixed(2);
  }
}

class _RoundIconBtn extends StatelessWidget {
  const _RoundIconBtn({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 36,
      height: 36,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(SuuqRadius.sm),
        child: Icon(
          icon,
          size: 18,
          color: onPressed == null
              ? scheme.onSurfaceVariant.withValues(alpha: 0.4)
              : scheme.onSurface,
        ),
      ),
    );
  }
}

/// Whole quantities as int (renders "3"), fractional as double ("2.5") —
/// for ICU plural placeholders.
num _qtyAsNum(Decimal value) {
  final n = value.toDouble();
  return n == n.roundToDouble() ? n.toInt() : n;
}
