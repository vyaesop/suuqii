import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/money.dart';
import '../../../l10n/app_localizations.dart';
import '../../inventory/data/products_repository.dart';
import '../../inventory/domain/entities/product.dart';
import '../domain/entities/sale.dart';
import 'cart_controller.dart';
import 'checkout_sheet.dart';

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
    final l = AppLocalizations.of(context);
    final productsAsync = ref.watch(watchProductsProvider(query: _query));
    final cart = ref.watch(cartControllerProvider);
    final theme = Theme.of(context);

    return Scaffold(
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: 'Search products',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                      ),
                filled: true,
                isDense: true,
              ),
            ),
          ),
          Expanded(
            child: productsAsync.when(
              data: (products) => products.isEmpty
                  ? _Empty(query: _query)
                  : RefreshIndicator(
                      onRefresh: () =>
                          ref.read(productsSyncProvider.notifier).refresh(),
                      child: GridView.builder(
                        padding: const EdgeInsets.all(12),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 2,
                          childAspectRatio: 1.4,
                          crossAxisSpacing: 10,
                          mainAxisSpacing: 10,
                        ),
                        itemCount: products.length,
                        itemBuilder: (ctx, i) => _ProductTile(product: products[i]),
                      ),
                    ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('$e')),
            ),
          ),
          if (cart.isNotEmpty)
            Material(
              elevation: 8,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('${cart.itemCount} items',
                                style: theme.textTheme.bodySmall),
                            Text(formatMoney(cart.total),
                                style: theme.textTheme.titleLarge),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: () => _openCart(context),
                        icon: const Icon(Icons.shopping_cart_outlined),
                        label: const Text('Cart'),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.icon(
                        icon: const Icon(Icons.shopping_cart_checkout),
                        onPressed: () => _checkout(context),
                        label: Text(l.checkout),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _openCart(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _CartSheet(),
    );
  }

  Future<void> _checkout(BuildContext context) async {
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sale recorded')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Sale failed: $e')),
        );
      }
    }
  }
}

class _ProductTile extends ConsumerWidget {
  const _ProductTile({required this.product});
  final Product product;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isLow = product.isLowStock;
    return InkWell(
      onTap: () => ref.read(cartControllerProvider.notifier).addProduct(product),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              product.name,
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    formatMoney(product.sellingPrice),
                    style: theme.textTheme.titleLarge,
                  ),
                ),
                if (isLow)
                  Chip(
                    label: Text('${product.stock} ${product.unit}'),
                    visualDensity: VisualDensity.compact,
                    backgroundColor: theme.colorScheme.errorContainer,
                  )
                else
                  Text('${product.stock} ${product.unit}',
                      style: theme.textTheme.bodyMedium),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _CartSheet extends ConsumerWidget {
  const _CartSheet();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.watch(cartControllerProvider);
    final controller = ref.read(cartControllerProvider.notifier);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.95,
      builder: (ctx, scroll) => Column(
        children: [
          const SizedBox(height: 12),
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: Theme.of(ctx).colorScheme.outlineVariant,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(child: Text('Cart', style: Theme.of(ctx).textTheme.titleLarge)),
                TextButton(
                  onPressed: () { controller.clear(); Navigator.pop(ctx); },
                  child: const Text('Clear'),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: scroll,
              itemCount: cart.lines.length,
              itemBuilder: (_, i) {
                final line = cart.lines[i];
                return ListTile(
                  title: Text(line.product.name),
                  subtitle: Text(
                    '${line.qty} ${line.product.unit} × ${formatMoney(line.product.sellingPrice)}',
                  ),
                  trailing: Text(formatMoney(line.lineTotal)),
                  onTap: () => controller.remove(line.product.id),
                );
              },
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              16, 8, 16, MediaQuery.of(ctx).viewInsets.bottom + 16,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Total ${formatMoney(cart.total)}',
                    style: Theme.of(ctx).textTheme.titleLarge,
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

class _Empty extends StatelessWidget {
  const _Empty({required this.query});
  final String query;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.inventory_2_outlined, size: 48),
          const SizedBox(height: 8),
          Text(query.isEmpty ? 'No products yet' : 'No matches for "$query"'),
        ],
      ),
    );
  }
}
