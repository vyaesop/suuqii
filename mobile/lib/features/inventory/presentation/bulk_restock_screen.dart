import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/data/products_repository.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/shared/widgets/empty_state.dart';
import 'package:suuqii/shared/widgets/owner_pin_dialog.dart';
import 'package:suuqii/shared/widgets/product_image.dart';

/// Multi-product restock flow. Owner (or cashier with PIN) adds quantities
/// to many products at once — useful when a supplier delivery arrives and
/// you want one operation instead of N tap-tap-tap stock adjustments.
class BulkRestockScreen extends ConsumerStatefulWidget {
  const BulkRestockScreen({super.key});

  @override
  ConsumerState<BulkRestockScreen> createState() => _BulkRestockScreenState();
}

class _BulkRestockScreenState extends ConsumerState<BulkRestockScreen> {
  /// productId -> qty delta entered so far.
  final Map<String, Decimal> _draft = {};
  final _search = TextEditingController();
  String _query = '';
  String _reason = 'supplier delivery';
  bool _submitting = false;

  static const _reasons = ['supplier delivery', 'restock', 'transfer in'];

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final productsAsync = ref.watch(watchProductsProvider(query: _query));
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lineCount = _draft.values.where((v) => v > Decimal.zero).length;
    final totalUnits = _draft.values.fold<Decimal>(
      Decimal.zero,
      (a, b) => a + b,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Bulk restock')),
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
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear_rounded),
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                      ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SuuqSpacing.md, 0, SuuqSpacing.md, SuuqSpacing.xs,
            ),
            child: DropdownButtonFormField<String>(
              initialValue: _reason,
              decoration: const InputDecoration(labelText: 'Reason'),
              items: _reasons
                  .map((r) => DropdownMenuItem(value: r, child: Text(r)))
                  .toList(),
              onChanged: (v) => setState(() => _reason = v ?? _reason),
            ),
          ),
          Expanded(
            child: productsAsync.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator()),
              error: (e, _) => EmptyState(
                icon: Icons.error_outline,
                title: 'Failed to load',
                message: '$e',
              ),
              data: (products) {
                if (products.isEmpty) {
                  return const EmptyState(
                    icon: Icons.inventory_2_outlined,
                    title: 'No products to restock',
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(
                    SuuqSpacing.md, 0, SuuqSpacing.md, 120,
                  ),
                  itemCount: products.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(height: SuuqSpacing.xs),
                  itemBuilder: (_, i) {
                    final p = products[i];
                    final qty = _draft[p.id] ?? Decimal.zero;
                    return _BulkRow(
                      product: p,
                      qty: qty,
                      onChange: (delta) => _bump(p.id, delta),
                      onSet: (value) => setState(() {
                        if (value <= Decimal.zero) {
                          _draft.remove(p.id);
                        } else {
                          _draft[p.id] = value;
                        }
                      }),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
      bottomSheet: lineCount == 0
          ? null
          : Container(
              decoration: BoxDecoration(
                color: scheme.surface,
                border: Border(top: BorderSide(color: scheme.outlineVariant)),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(SuuqSpacing.md),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '$lineCount '
                              '${lineCount == 1 ? "product" : "products"}',
                              style: theme.textTheme.bodySmall,
                            ),
                            Text(
                              '+${_fmtQty(totalUnits)} units',
                              style:
                                  theme.textTheme.titleLarge?.copyWith(
                                color: scheme.primary,
                                fontWeight: FontWeight.w700,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: SuuqSpacing.sm),
                      SizedBox(
                        height: 52,
                        child: FilledButton.icon(
                          icon: _submitting
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Icon(Icons.check_rounded),
                          onPressed: _submitting ? null : _submit,
                          label: const Text('Apply restock'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  void _bump(String productId, Decimal delta) {
    setState(() {
      final current = _draft[productId] ?? Decimal.zero;
      final next = current + delta;
      if (next <= Decimal.zero) {
        _draft.remove(productId);
      } else {
        _draft[productId] = next;
      }
    });
  }

  Future<void> _submit() async {
    final auth = ref.read(authControllerProvider).valueOrNull;
    final isOwner = auth is Authenticated && auth.role == 'owner';
    final messenger = ScaffoldMessenger.of(context);
    final router = Navigator.of(context);

    String? challenge;
    if (!isOwner) {
      challenge = await requestOwnerChallenge(context, ref);
      if (challenge == null) return;
    }

    setState(() => _submitting = true);
    final entries = _draft.entries
        .where((e) => e.value > Decimal.zero)
        .toList();
    final repo = ref.read(productsRepositoryProvider);
    try {
      for (final entry in entries) {
        await repo.adjustStock(
          productId: entry.key,
          delta: entry.value,
          reason: _reason,
          ownerChallengeToken: challenge,
        );
      }
      messenger.showSnackBar(
        SnackBar(content: Text('Restocked ${entries.length} products')),
      );
      router.pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  static String _fmtQty(Decimal d) {
    final n = d.toDouble();
    if (n == n.roundToDouble()) return n.toInt().toString();
    return n.toStringAsFixed(2);
  }
}

class _BulkRow extends StatelessWidget {
  const _BulkRow({
    required this.product,
    required this.qty,
    required this.onChange,
    required this.onSet,
  });
  final Product product;
  final Decimal qty;
  final ValueChanged<Decimal> onChange;
  final ValueChanged<Decimal> onSet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasQty = qty > Decimal.zero;
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(SuuqRadius.md),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(SuuqRadius.md),
          border: Border.all(
            color: hasQty ? scheme.primary : scheme.outlineVariant,
            width: hasQty ? 1.5 : 1,
          ),
        ),
        padding: const EdgeInsets.all(SuuqSpacing.sm),
        child: Row(
          children: [
            SizedBox(
              width: 48,
              height: 48,
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
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    product.name,
                    style: theme.textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${_fmtQty(product.stock)} ${product.unit} in stock',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            _Stepper(
              qty: qty,
              unit: product.unit,
              onMinus: () => onChange(Decimal.fromInt(-1)),
              onPlus: () => onChange(Decimal.one),
              onTap: () => _showCustom(context, product, onSet),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showCustom(
    BuildContext context,
    Product product,
    ValueChanged<Decimal> onSet,
  ) async {
    final controller = TextEditingController(
      text: qty > Decimal.zero ? _fmtQty(qty) : '',
    );
    final result = await showDialog<Decimal?>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Restock ${product.name}'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType:
              const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'Quantity (${product.unit})',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final v = Decimal.tryParse(controller.text.trim());
              Navigator.pop(ctx, v);
            },
            child: const Text('Set'),
          ),
        ],
      ),
    );
    if (result != null) onSet(result);
  }

  static String _fmtQty(Decimal d) {
    final n = d.toDouble();
    if (n == n.roundToDouble()) return n.toInt().toString();
    return n.toStringAsFixed(2);
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.qty,
    required this.unit,
    required this.onMinus,
    required this.onPlus,
    required this.onTap,
  });
  final Decimal qty;
  final String unit;
  final VoidCallback onMinus;
  final VoidCallback onPlus;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasQty = qty > Decimal.zero;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RoundButton(
          icon: Icons.remove_rounded,
          onPressed: hasQty ? onMinus : null,
        ),
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(SuuqRadius.sm),
          child: Container(
            constraints: const BoxConstraints(minWidth: 48),
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Text(
              hasQty ? _fmtQty(qty) : '0',
              style: theme.textTheme.titleMedium?.copyWith(
                color: hasQty ? scheme.primary : scheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
        _RoundButton(icon: Icons.add_rounded, onPressed: onPlus),
      ],
    );
  }

  static String _fmtQty(Decimal d) {
    final n = d.toDouble();
    if (n == n.roundToDouble()) return n.toInt().toString();
    return n.toStringAsFixed(2);
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.onPressed});
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      width: 38,
      height: 38,
      child: Material(
        color: onPressed == null
            ? scheme.surfaceContainerHighest.withValues(alpha: 0.5)
            : scheme.surfaceContainerHighest,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: Icon(
            icon,
            size: 18,
            color: onPressed == null
                ? scheme.onSurfaceVariant.withValues(alpha: 0.5)
                : scheme.onSurface,
          ),
        ),
      ),
    );
  }
}
