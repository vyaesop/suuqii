import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/utils/money.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/data/products_repository.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/shared/widgets/empty_state.dart';
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

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final canEdit = auth is Authenticated;
    final productsAsync = ref.watch(watchProductsProvider(query: _query));
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
                hintText: 'Search products',
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
                  label: const Text('Low stock'),
                  avatar: Icon(
                    Icons.warning_amber_rounded,
                    size: 16,
                    color: _lowStockOnly
                        ? scheme.onPrimaryContainer
                        : scheme.onSurfaceVariant,
                  ),
                  selected: _lowStockOnly,
                  onSelected: (v) => setState(() => _lowStockOnly = v),
                ),
                const Spacer(),
                if (canEdit)
                  TextButton.icon(
                    icon: const Icon(Icons.inventory_rounded, size: 18),
                    onPressed: () =>
                        context.push('/inventory/bulk-restock'),
                    label: const Text('Bulk restock'),
                  ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () =>
                  ref.read(productsSyncProvider.notifier).refresh(),
              child: productsAsync.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => EmptyState(
                  icon: Icons.error_outline,
                  title: 'Failed to load',
                  message: '$e',
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
                          ? 'Stock is healthy'
                          : 'No products yet',
                      message: _lowStockOnly
                          ? 'Nothing below its low-stock threshold.'
                          : 'Add your first product to get started.',
                      action: !_lowStockOnly && canEdit
                          ? FilledButton.icon(
                              icon: const Icon(Icons.add_rounded),
                              onPressed: () => context.push('/inventory/new'),
                              label: const Text('Add product'),
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
              label: const Text('Add product'),
            )
          : null,
    );
  }
}

class _InventoryRow extends StatelessWidget {
  const _InventoryRow({required this.product, this.onTap});
  final Product product;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);
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
                      '${product.category ?? "Uncategorised"} · ${product.unit}',
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
                    formatMoney(product.sellingPrice),
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
