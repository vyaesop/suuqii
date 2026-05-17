import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/utils/money.dart';
import 'package:suuqii/features/inventory/data/products_repository.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/sales/domain/entities/sale.dart';
import 'package:suuqii/features/sales/presentation/cart_controller.dart';
import 'package:suuqii/features/sales/presentation/checkout_sheet.dart';
import 'package:suuqii/shared/widgets/empty_state.dart';
import 'package:suuqii/shared/widgets/product_image.dart';

class PosScreen extends ConsumerStatefulWidget {
  const PosScreen({super.key});

  @override
  ConsumerState<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends ConsumerState<PosScreen> {
  final _search = TextEditingController();
  String _query = '';
  bool _kickedRefresh = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_kickedRefresh) {
        _kickedRefresh = true;
        ref.read(productsSyncProvider.notifier).refresh();
      }
    });
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final productsAsync = ref.watch(watchProductsProvider(query: _query));
    final cart = ref.watch(cartControllerProvider);

    return Scaffold(
      body: Column(
        children: [
          _SearchField(
            controller: _search,
            onChanged: (v) => setState(() => _query = v),
            onClear: _query.isEmpty
                ? null
                : () {
                    _search.clear();
                    setState(() => _query = '');
                  },
          ),
          Expanded(
            child: productsAsync.when(
              data: (products) => products.isEmpty
                  ? EmptyState(
                      icon: Icons.inventory_2_outlined,
                      title: _query.isEmpty
                          ? 'No products yet'
                          : 'No matches for "$_query"',
                      message: _query.isEmpty
                          ? 'Add your first product to start selling.'
                          : null,
                    )
                  : RefreshIndicator(
                      onRefresh: () => ref
                          .read(productsSyncProvider.notifier)
                          .refresh(),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          // Two columns on phones, three on wide screens.
                          final crossAxisCount =
                              constraints.maxWidth >= 600 ? 3 : 2;
                          return GridView.builder(
                            padding: EdgeInsets.fromLTRB(
                              SuuqSpacing.md,
                              SuuqSpacing.xs,
                              SuuqSpacing.md,
                              cart.isNotEmpty ? 132 : SuuqSpacing.md,
                            ),
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: crossAxisCount,
                              childAspectRatio: 0.72,
                              crossAxisSpacing: SuuqSpacing.sm,
                              mainAxisSpacing: SuuqSpacing.sm,
                            ),
                            itemCount: products.length,
                            itemBuilder: (_, i) =>
                                _ProductTile(product: products[i]),
                          );
                        },
                      ),
                    ),
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => EmptyState(
                icon: Icons.error_outline,
                title: "Couldn't load products",
                message: '$e',
              ),
            ),
          ),
        ],
      ),
      bottomSheet:
          cart.isEmpty ? null : _CartBar(cart: cart, onCheckout: _checkout),
    );
  }

  Future<void> _checkout() async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await showModalBottomSheet<CheckoutResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const CheckoutSheet(),
    );
    if (result == null) return;
    try {
      await ref.read(cartControllerProvider.notifier).checkout(
            paymentMethod: result.paymentMethod,
            customerName: result.customerName,
            customerPhone: result.customerPhone,
            dueDate: result.dueDate,
          );
      messenger.showSnackBar(
        const SnackBar(content: Text('Sale recorded')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Sale failed: $e')));
    }
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.onChanged,
    required this.onClear,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SuuqSpacing.md,
        SuuqSpacing.xs,
        SuuqSpacing.md,
        SuuqSpacing.sm,
      ),
      child: SizedBox(
        height: 56,
        child: TextField(
          controller: controller,
          onChanged: onChanged,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          decoration: InputDecoration(
            hintText: 'Search products',
            prefixIcon: Icon(
              Icons.search_rounded,
              size: 24,
              color: scheme.onSurfaceVariant,
            ),
            suffixIcon: onClear == null
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear_rounded, size: 20),
                    onPressed: onClear,
                  ),
            fillColor: scheme.surfaceContainer,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: SuuqSpacing.md,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(999),
              borderSide: BorderSide(color: scheme.outlineVariant),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(999),
              borderSide: BorderSide(color: scheme.outlineVariant),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(999),
              borderSide: BorderSide(color: scheme.primary, width: 1.5),
            ),
          ),
        ),
      ),
    );
  }
}

class _ProductTile extends ConsumerWidget {
  const _ProductTile({required this.product});
  final Product product;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    final inCart = ref.watch(
      cartControllerProvider.select(
        (c) => c.lines.any((l) => l.product.id == product.id),
      ),
    );
    final qty = ref.watch(
      cartControllerProvider.select((c) {
        for (final l in c.lines) {
          if (l.product.id == product.id) return l.qty;
        }
        return null;
      }),
    );

    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(SuuqRadius.lg),
      child: InkWell(
        onTap: () =>
            ref.read(cartControllerProvider.notifier).addProduct(product),
        borderRadius: BorderRadius.circular(SuuqRadius.lg),
        child: Ink(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(SuuqRadius.lg),
            border: Border.all(
              color: inCart ? scheme.primary : scheme.outlineVariant,
              width: inCart ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Image area
              Stack(
                children: [
                  AspectRatio(
                    aspectRatio: 1,
                    child: Padding(
                      padding: const EdgeInsets.all(SuuqSpacing.xs),
                      child: ProductImage(
                        name: product.name,
                        imageUrl: product.imageUrl,
                      ),
                    ),
                  ),
                  if (product.isLowStock)
                    Positioned(
                      top: SuuqSpacing.sm,
                      left: SuuqSpacing.sm,
                      child: _StockBadge(
                        label: 'LOW',
                        color: scheme.error,
                      ),
                    ),
                  if (qty != null)
                    Positioned(
                      top: SuuqSpacing.sm,
                      right: SuuqSpacing.sm,
                      child: Container(
                        width: 28,
                        height: 28,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          '$qty',
                          style: TextStyle(
                            color: scheme.onPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              // Text area
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  SuuqSpacing.sm,
                  SuuqSpacing.xs,
                  SuuqSpacing.sm,
                  SuuqSpacing.sm,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      product.name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      formatMoney(product.sellingPrice),
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_fmtStock(product.stock.toDouble())} ${product.unit}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: product.isLowStock
                            ? scheme.error
                            : scheme.onSurfaceVariant,
                        fontWeight:
                            product.isLowStock ? FontWeight.w600 : null,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _fmtStock(double n) {
    if (n == n.roundToDouble()) return n.toInt().toString();
    return n.toStringAsFixed(1);
  }
}

class _StockBadge extends StatelessWidget {
  const _StockBadge({required this.label, required this.color});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: 10,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _CartBar extends StatelessWidget {
  const _CartBar({required this.cart, required this.onCheckout});
  final Cart cart;
  final VoidCallback onCheckout;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(SuuqRadius.lg),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 18,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            SuuqSpacing.md,
            SuuqSpacing.md,
            SuuqSpacing.md,
            SuuqSpacing.sm,
          ),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheme.onPrimary.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(SuuqRadius.md),
                ),
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Icon(
                      Icons.shopping_basket_rounded,
                      color: scheme.onPrimary,
                      size: 24,
                    ),
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: scheme.onPrimary,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          '${cart.itemCount}',
                          style: TextStyle(
                            color: scheme.primary,
                            fontWeight: FontWeight.w800,
                            fontSize: 10,
                            height: 1.1,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: SuuqSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      cart.itemCount == 1
                          ? '1 item in cart'
                          : '${cart.itemCount} items in cart',
                      style: TextStyle(
                        color: scheme.onPrimary.withValues(alpha: 0.85),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      formatMoney(cart.total),
                      style: theme.textTheme.headlineSmall?.copyWith(
                        color: scheme.onPrimary,
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: SuuqSpacing.sm),
              SizedBox(
                height: 56,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: scheme.onPrimary,
                    foregroundColor: scheme.primary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: SuuqSpacing.lg,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(SuuqRadius.md),
                    ),
                  ),
                  onPressed: onCheckout,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Checkout',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(width: 6),
                      Icon(Icons.arrow_forward_rounded, size: 20),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
