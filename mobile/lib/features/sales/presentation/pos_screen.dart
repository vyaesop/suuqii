import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/utils/money.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/data/products_repository.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/sales/domain/entities/sale.dart';
import 'package:suuqii/features/sales/presentation/cart_controller.dart';
import 'package:suuqii/features/sales/presentation/cart_review_sheet.dart';
import 'package:suuqii/features/sales/presentation/checkout_sheet.dart';
import 'package:suuqii/features/sales/presentation/receipt_sheet.dart';
import 'package:suuqii/shared/widgets/empty_state.dart';
import 'package:suuqii/shared/widgets/product_image.dart';

const _kProductTileAspectRatio = 0.68;

class PosScreen extends ConsumerStatefulWidget {
  const PosScreen({super.key});

  @override
  ConsumerState<PosScreen> createState() => _PosScreenState();
}

class _PosScreenState extends ConsumerState<PosScreen> {
  final _search = TextEditingController();
  String _query = '';
  String? _category;
  bool _kickedRefresh = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authAsync = ref.watch(authControllerProvider);
    final auth = authAsync.valueOrNull;

    if (authAsync.isLoading) {
      return const _PosFrame(child: _PosLoadingState());
    }

    if (authAsync.hasError) {
      return _PosFrame(
        child: EmptyState(
          icon: Icons.error_outline_rounded,
          title: 'Could not restore your session',
          message: '${authAsync.error}',
        ),
      );
    }

    if (auth is! Authenticated) {
      return const _PosFrame(
        child: EmptyState(
          icon: Icons.lock_outline_rounded,
          title: 'Sign in required',
          message: 'Log in again to load products and continue selling.',
        ),
      );
    }

    if (!_kickedRefresh) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _kickedRefresh) return;
        _kickedRefresh = true;
        ref.read(productsSyncProvider.notifier).refresh();
      });
    }

    final productsAsync = ref.watch(
      watchProductsProvider(query: _query, category: _category),
    );
    final categoriesAsync = ref.watch(watchCategoriesProvider);
    final syncAsync = ref.watch(productsSyncProvider);
    final cart = ref.watch(cartControllerProvider);

    return _PosFrame(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final showCartDock = constraints.maxWidth >= 1100;
          final catalog = Column(
            children: [
              _SearchField(
                controller: _search,
                onChanged: (value) => setState(() => _query = value),
                onClear: _query.isEmpty
                    ? null
                    : () {
                        _search.clear();
                        setState(() => _query = '');
                      },
                onRecentSales: () => context.push('/recent-sales'),
              ),
              categoriesAsync.maybeWhen(
                data: (categories) => categories.isEmpty
                    ? const SizedBox.shrink()
                    : _CategoryChips(
                        categories: categories,
                        selected: _category,
                        onSelect: (value) => setState(() => _category = value),
                      ),
                orElse: () => const SizedBox.shrink(),
              ),
              if (_query.isEmpty && _category == null) const _RecentStrip(),
              Expanded(
                child: productsAsync.when(
                  data: (products) => products.isEmpty
                      ? _EmptyProductsState(
                          query: _query,
                          syncAsync: syncAsync,
                          onRetry: () =>
                              ref.read(productsSyncProvider.notifier).refresh(),
                        )
                      : RefreshIndicator(
                          onRefresh: () =>
                              ref.read(productsSyncProvider.notifier).refresh(),
                          child: LayoutBuilder(
                            builder: (context, innerConstraints) {
                              final crossAxisCount =
                                  innerConstraints.maxWidth >= 760 ? 3 : 2;
                              return GridView.builder(
                                padding: const EdgeInsets.fromLTRB(
                                  SuuqSpacing.md,
                                  SuuqSpacing.xs,
                                  SuuqSpacing.md,
                                  SuuqSpacing.md,
                                ),
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: crossAxisCount,
                                  childAspectRatio: _kProductTileAspectRatio,
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
                  loading: () => const _ProductGridSkeleton(),
                  error: (error, _) => EmptyState(
                    icon: Icons.error_outline,
                    title: "Couldn't load products",
                    message: '$error',
                    action: FilledButton(
                      onPressed: () =>
                          ref.read(productsSyncProvider.notifier).refresh(),
                      child: const Text('Retry'),
                    ),
                  ),
                ),
              ),
            ],
          );

          final body = showCartDock
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: catalog),
                    SizedBox(
                      width: 332,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          0,
                          SuuqSpacing.xs,
                          SuuqSpacing.md,
                          SuuqSpacing.md,
                        ),
                        child: _CartDock(
                          cart: cart,
                          onReviewCart: cart.isEmpty ? null : _reviewCart,
                          onCheckout: cart.isEmpty ? null : _checkout,
                        ),
                      ),
                    ),
                  ],
                )
              : Column(
                  children: [
                    Expanded(child: catalog),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: _CartBar(
                        key: ValueKey(
                          'cart_bar_${cart.isEmpty}_${cart.lineCount}',
                        ),
                        cart: cart,
                        onCheckout: cart.isNotEmpty ? _reviewCart : null,
                      ),
                    ),
                  ],
                );

          return Material(
            color: Theme.of(context).colorScheme.surface,
            child: body,
          );
        },
      ),
    );
  }

  Future<void> _reviewCart() async {
    final proceed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const CartReviewSheet(),
    );
    if ((proceed ?? false) && mounted) {
      await _checkout();
    }
  }

  Future<void> _checkout() async {
    final messenger = ScaffoldMessenger.of(context);
    final snapshot = ref.read(cartControllerProvider);
    if (snapshot.isEmpty) return;

    final result = await showModalBottomSheet<CheckoutResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const CheckoutSheet(),
    );
    if (result == null) return;

    try {
      final saleId = await ref.read(cartControllerProvider.notifier).checkout(
            paymentMethod: result.paymentMethod,
            customerName: result.customerName,
            customerPhone: result.customerPhone,
            dueDate: result.dueDate,
          );
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        builder: (_) => ReceiptSheet(
          cart: snapshot,
          paymentMethod: result.paymentMethod,
          saleId: saleId,
          soldAt: DateTime.now().toUtc(),
          amountTendered: result.amountTendered,
          changeDue: result.changeDue,
          customerName: result.customerName,
          customerPhone: result.customerPhone,
          dueDate: result.dueDate,
        ),
      );
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text('Sale failed: $error')));
    }
  }
}

class _PosFrame extends StatelessWidget {
  const _PosFrame({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: ColoredBox(
        color: scheme.surface,
        child: child,
      ),
    );
  }
}

class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.onChanged,
    required this.onClear,
    required this.onRecentSales,
  });

  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback? onClear;
  final VoidCallback onRecentSales;

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
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 56,
              child: TextField(
                controller: controller,
                onChanged: onChanged,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
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
          ),
          const SizedBox(width: SuuqSpacing.xs),
          SizedBox(
            width: 56,
            height: 56,
            child: IconButton.filledTonal(
              onPressed: onRecentSales,
              tooltip: 'Recent sales',
              icon: const Icon(Icons.receipt_long_rounded),
            ),
          ),
        ],
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
    final qty = ref.watch(
      cartControllerProvider.select((cart) => cart.qtyFor(product.id)),
    );
    final inCart = qty > Decimal.zero;

    return Semantics(
      button: true,
      label: '${product.name}, ${formatMoney(product.sellingPrice)}',
      child: Material(
        color: inCart ? scheme.primaryContainer : scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(SuuqRadius.lg),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(SuuqRadius.lg),
                    border: Border.all(
                      color: inCart ? scheme.primary : scheme.outlineVariant,
                      width: inCart ? 1.5 : 1,
                    ),
                  ),
                ),
              ),
            ),
            InkWell(
              onTap: () => _toggleSelection(context, ref),
              borderRadius: BorderRadius.circular(SuuqRadius.lg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
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
                          '${_formatQty(product.stock)} ${product.unit}',
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
            if (product.isLowStock)
              Positioned(
                top: SuuqSpacing.sm,
                left: SuuqSpacing.sm,
                child: IgnorePointer(
                  child: _StockBadge(label: 'LOW', color: scheme.error),
                ),
              ),
            if (qty > Decimal.zero)
              Positioned(
                top: SuuqSpacing.xs,
                right: SuuqSpacing.xs,
                child: Container(
                  constraints:
                      const BoxConstraints(minWidth: 36, minHeight: 36),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(999),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.15),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Text(
                    'x${_formatQty(qty)}',
                    style: TextStyle(
                      color: scheme.onPrimary,
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            if (qty > Decimal.zero)
              Positioned(
                bottom: SuuqSpacing.xs,
                right: SuuqSpacing.xs,
                child: Material(
                  color: scheme.surface,
                  shape: const CircleBorder(),
                  elevation: 1,
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => _promptCustomQty(context, ref),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        Icons.tune_rounded,
                        size: 16,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _toggleSelection(BuildContext context, WidgetRef ref) {
    final currentQty = ref.read(cartControllerProvider).qtyFor(product.id);
    final messenger = ScaffoldMessenger.of(context);

    if (currentQty > Decimal.zero) {
      HapticFeedback.selectionClick();
      ref.read(cartControllerProvider.notifier).remove(product.id);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('${product.name} removed from cart'),
            duration: const Duration(milliseconds: 900),
          ),
        );
      return;
    }

    final nextQty = currentQty + Decimal.one;

    if (product.stock <= Decimal.zero) {
      HapticFeedback.heavyImpact();
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content:
                Text('${product.name} is out of stock - selling will fail'),
            duration: const Duration(seconds: 2),
          ),
        );
      return;
    }

    if (nextQty > product.stock) {
      HapticFeedback.mediumImpact();
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              'Only ${_formatQty(product.stock)} ${product.unit} '
              'of ${product.name} in stock',
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      return;
    }

    HapticFeedback.selectionClick();
    ref.read(cartControllerProvider.notifier).addProduct(product);

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            _lowStockMessage(product, nextQty) ??
                '${product.name} added to cart',
          ),
          duration: const Duration(milliseconds: 1000),
        ),
      );
  }

  Future<void> _promptCustomQty(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController(
      text: _formatQty(ref.read(cartControllerProvider).qtyFor(product.id)),
    );
    final result = await showDialog<Decimal?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(product.name),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Quantity (${product.unit})',
            helperText: 'In stock: ${_formatQty(product.stock)}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = Decimal.tryParse(
                controller.text.trim().replaceAll(',', '.'),
              );
              Navigator.pop(ctx, value);
            },
            child: const Text('Set'),
          ),
        ],
      ),
    );

    if (result == null) return;
    if (result <= Decimal.zero) {
      ref.read(cartControllerProvider.notifier).remove(product.id);
      return;
    }
    if (result > product.stock) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Only ${_formatQty(product.stock)} ${product.unit} in stock',
          ),
        ),
      );
      return;
    }

    ref.read(cartControllerProvider.notifier).setQty(product.id, result);
    final message =
        _lowStockMessage(product, result) ?? '${product.name} updated in cart';
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(milliseconds: 1000),
          ),
        );
    }
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
  const _CartBar({
    required this.cart,
    required this.onCheckout,
    super.key,
  });

  final Cart cart;
  final VoidCallback? onCheckout;

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
                          _formatQty(cart.itemCount),
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
                      cart.isEmpty
                          ? 'Cart is empty - tap a product to add it'
                          : '${_formatQty(cart.itemCount)} items across '
                              '${cart.lineCount} '
                              '${cart.lineCount == 1 ? "line" : "lines"}',
                      style: TextStyle(
                        color: scheme.onPrimary.withValues(alpha: 0.85),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      cart.isEmpty ? 'ETB 0' : formatMoney(cart.total),
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
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 172),
                child: SizedBox(
                  height: 56,
                  width: double.infinity,
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
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            cart.isEmpty ? 'Add items' : 'Checkout',
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Icon(Icons.arrow_forward_rounded, size: 20),
                        ],
                      ),
                    ),
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

class _CartDock extends StatelessWidget {
  const _CartDock({
    required this.cart,
    required this.onReviewCart,
    required this.onCheckout,
  });

  final Cart cart;
  final VoidCallback? onReviewCart;
  final VoidCallback? onCheckout;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(SuuqRadius.lg),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(SuuqSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Cart',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: SuuqSpacing.xs),
            if (cart.isEmpty)
              const Expanded(
                child: EmptyState(
                  icon: Icons.shopping_cart_outlined,
                  title: 'Cart is empty',
                  message: 'Tap a product tile to start a sale.',
                ),
              )
            else ...[
              Text(
                '${_formatQty(cart.itemCount)} items across '
                '${cart.lineCount} '
                '${cart.lineCount == 1 ? "line" : "lines"}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 2),
              Text(
                formatMoney(cart.total),
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (cart.discount > Decimal.zero)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Discount applied: ${formatMoney(cart.discount)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: SuuqSpacing.md),
              Expanded(
                child: ListView.separated(
                  itemCount: cart.lines.length,
                  separatorBuilder: (_, __) =>
                      Divider(height: 1, color: scheme.outlineVariant),
                  itemBuilder: (_, i) {
                    final line = cart.lines[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: SuuqSpacing.sm,
                      ),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 44,
                            height: 44,
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
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall,
                                ),
                                Text(
                                  '${_formatQty(line.qty)} ${line.product.unit}',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: SuuqSpacing.sm),
                          Text(
                            formatMoney(line.lineTotal),
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
            const SizedBox(height: SuuqSpacing.sm),
            OutlinedButton.icon(
              onPressed: onReviewCart,
              icon: const Icon(Icons.edit_note_rounded),
              label: const Text('Review cart'),
            ),
            const SizedBox(height: SuuqSpacing.xs),
            SizedBox(
              height: 56,
              child: FilledButton.icon(
                onPressed: onCheckout,
                icon: const Icon(Icons.arrow_forward_rounded),
                label: const Text('Checkout'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentStrip extends ConsumerWidget {
  const _RecentStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final recentAsync = ref.watch(watchRecentProductsProvider);
    return recentAsync.maybeWhen(
      data: (products) {
        if (products.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(
            SuuqSpacing.md,
            SuuqSpacing.xs,
            0,
            SuuqSpacing.xs,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'RECENT',
                style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: 80,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(right: SuuqSpacing.md),
                  itemCount: products.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(width: SuuqSpacing.xs),
                  itemBuilder: (_, i) => _RecentTile(product: products[i]),
                ),
              ),
            ],
          ),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }
}

class _RecentTile extends ConsumerWidget {
  const _RecentTile({required this.product});

  final Product product;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final qty = ref.watch(
      cartControllerProvider.select((cart) => cart.qtyFor(product.id)),
    );
    final inCart = qty > Decimal.zero;
    return Material(
      color: inCart ? scheme.primaryContainer : scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(SuuqRadius.md),
      child: InkWell(
        onTap: () {
          if (qty > Decimal.zero) {
            HapticFeedback.selectionClick();
            ref.read(cartControllerProvider.notifier).remove(product.id);
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(
                  content: Text('${product.name} removed from cart'),
                  duration: const Duration(milliseconds: 900),
                ),
              );
            return;
          }

          final nextQty = qty + Decimal.one;
          if (nextQty > product.stock) {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
              SnackBar(
                content: Text(
                  'Only ${_formatQty(product.stock)} ${product.unit} of '
                  '${product.name} in stock',
                ),
              ),
            );
            return;
          }

          HapticFeedback.selectionClick();
          ref.read(cartControllerProvider.notifier).addProduct(product);
          final message = _lowStockMessage(product, nextQty) ??
              '${product.name} added to cart';
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              SnackBar(
                content: Text(message),
                duration: const Duration(milliseconds: 1000),
              ),
            );
        },
        borderRadius: BorderRadius.circular(SuuqRadius.md),
        child: Container(
          width: 140,
          padding: const EdgeInsets.symmetric(
            horizontal: SuuqSpacing.sm,
            vertical: SuuqSpacing.xs,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(SuuqRadius.md),
            border: Border.all(
              color: inCart ? scheme.primary : scheme.outlineVariant,
              width: inCart ? 1.5 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (inCart)
                Container(
                  margin: const EdgeInsets.only(bottom: 6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    'x${_formatQty(qty)}',
                    style: TextStyle(
                      color: scheme.onPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                    ),
                  ),
                ),
              Text(
                product.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: 2),
              Text(
                formatMoney(product.sellingPrice),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CategoryChips extends StatelessWidget {
  const _CategoryChips({
    required this.categories,
    required this.selected,
    required this.onSelect,
  });

  final List<String> categories;
  final String? selected;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: SuuqSpacing.md),
        children: [
          ChoiceChip(
            label: const Text('All'),
            selected: selected == null,
            onSelected: (_) => onSelect(null),
          ),
          const SizedBox(width: SuuqSpacing.xs),
          for (final category in categories) ...[
            ChoiceChip(
              label: Text(category),
              selected: selected == category,
              onSelected: (selected) => onSelect(selected ? category : null),
            ),
            const SizedBox(width: SuuqSpacing.xs),
          ],
        ],
      ),
    );
  }
}

class _ProductGridSkeleton extends StatelessWidget {
  const _ProductGridSkeleton();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GridView.builder(
      padding: const EdgeInsets.all(SuuqSpacing.md),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: _kProductTileAspectRatio,
        crossAxisSpacing: SuuqSpacing.sm,
        mainAxisSpacing: SuuqSpacing.sm,
      ),
      itemCount: 6,
      itemBuilder: (_, __) => DecoratedBox(
        decoration: BoxDecoration(
          color: scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(SuuqRadius.lg),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Padding(
          padding: const EdgeInsets.all(SuuqSpacing.sm),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(SuuqRadius.md),
                  ),
                ),
              ),
              const SizedBox(height: SuuqSpacing.sm),
              Container(
                height: 14,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 6),
              Container(
                height: 18,
                width: 80,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyProductsState extends StatelessWidget {
  const _EmptyProductsState({
    required this.query,
    required this.syncAsync,
    required this.onRetry,
  });

  final String query;
  final AsyncValue<void> syncAsync;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    if (syncAsync.isLoading) {
      return const _ProductGridSkeleton();
    }

    if (syncAsync.hasError) {
      return EmptyState(
        icon: Icons.cloud_off_rounded,
        title: 'Products did not load',
        message:
            'The local product list is empty, and the refresh failed: ${syncAsync.error}',
        action: FilledButton.icon(
          icon: const Icon(Icons.refresh_rounded),
          onPressed: onRetry,
          label: const Text('Retry'),
        ),
      );
    }

    if (query.isNotEmpty) {
      return EmptyState(
        icon: Icons.search_off_rounded,
        title: 'No matches for "$query"',
        message: 'Clear search to see all products available for selling.',
      );
    }

    return EmptyState(
      icon: Icons.inventory_2_outlined,
      title: 'No products available to sell',
      message:
          'Add products in Inventory or retry loading from the server, then they will appear here.',
      action: FilledButton.icon(
        icon: const Icon(Icons.refresh_rounded),
        onPressed: onRetry,
        label: const Text('Load products'),
      ),
    );
  }
}

class _PosLoadingState extends StatelessWidget {
  const _PosLoadingState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            SuuqSpacing.md,
            SuuqSpacing.md,
            SuuqSpacing.md,
            SuuqSpacing.xs,
          ),
          child: Row(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: SuuqSpacing.sm),
              Text(
                'Loading sell screen...',
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
        const Expanded(child: _ProductGridSkeleton()),
      ],
    );
  }
}

String _formatQty(Decimal value) {
  final n = value.toDouble();
  if (n == n.roundToDouble()) return n.toInt().toString();
  return n.toStringAsFixed(2);
}

String? _lowStockMessage(Product product, Decimal nextQty) {
  final remaining = product.stock - nextQty;
  if (remaining < Decimal.zero) return null;

  if (remaining == Decimal.zero) {
    return 'Last ${_formatQty(product.stock)} ${product.unit} of ${product.name} added';
  }

  final threshold = product.lowStockThreshold;
  final crossedThreshold = threshold > Decimal.zero &&
      product.stock > threshold &&
      remaining <= threshold;
  if (!crossedThreshold) return null;

  return 'Low stock: ${product.name} will have '
      '${_formatQty(remaining)} ${product.unit} left after this sale';
}
