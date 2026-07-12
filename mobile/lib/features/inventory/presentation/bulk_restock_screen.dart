import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/data/lots_repository.dart';
import 'package:suuqii/features/inventory/data/products_repository.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/shared/widgets/empty_state.dart';
import 'package:suuqii/shared/widgets/owner_pin_dialog.dart';
import 'package:suuqii/shared/widgets/product_image.dart';

/// One pending receive line: quantity plus optional per-line unit cost and
/// expiry date. Cost defaults to the product's last cost at submit time.
class _RestockLine {
  _RestockLine({required this.qty, this.unitCost, this.expiryDate});
  final Decimal qty;
  final Decimal? unitCost;
  final DateTime? expiryDate;

  _RestockLine copyWith({Decimal? qty}) => _RestockLine(
        qty: qty ?? this.qty,
        unitCost: unitCost,
        expiryDate: expiryDate,
      );
}

/// Multi-product receive flow. Owner (or cashier with PIN) receives a
/// supplier delivery as proper batches — each line becomes a stock lot with
/// its own cost and expiry, one operation instead of N stock adjustments.
class BulkRestockScreen extends ConsumerStatefulWidget {
  const BulkRestockScreen({super.key});

  @override
  ConsumerState<BulkRestockScreen> createState() => _BulkRestockScreenState();
}

class _BulkRestockScreenState extends ConsumerState<BulkRestockScreen> {
  /// productId -> pending line.
  final Map<String, _RestockLine> _draft = {};
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
    final l = context.l10n;
    final productsAsync = ref.watch(watchProductsProvider(query: _query));
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lineCount =
        _draft.values.where((v) => v.qty > Decimal.zero).length;
    final totalUnits = _draft.values.fold<Decimal>(
      Decimal.zero,
      (a, b) => a + b.qty,
    );

    return Scaffold(
      appBar: AppBar(title: Text(l.bulkRestockTitle)),
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
              decoration: InputDecoration(labelText: l.stockAdjustReasonLabel),
              items: _reasons
                  .map(
                    (r) => DropdownMenuItem(
                      value: r,
                      child: Text(_reasonLabel(l, r)),
                    ),
                  )
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
                title: l.inventoryLoadFailedTitle,
                message: context.errorMessage(e),
              ),
              data: (products) {
                if (products.isEmpty) {
                  return EmptyState(
                    icon: Icons.inventory_2_outlined,
                    title: l.bulkRestockEmptyTitle,
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
                    final line = _draft[p.id];
                    return _BulkRow(
                      product: p,
                      line: line,
                      onChange: (delta) => _bump(p.id, delta),
                      onSet: (result) => setState(() {
                        if (result == null ||
                            result.qty <= Decimal.zero) {
                          _draft.remove(p.id);
                        } else {
                          _draft[p.id] = result;
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
                              l.bulkRestockLineCount(lineCount),
                              style: theme.textTheme.bodySmall,
                            ),
                            Text(
                              l.bulkRestockTotalUnits(_fmtQty(totalUnits)),
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
                          label: Text(l.bulkRestockApply),
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
      final current = _draft[productId];
      final next = (current?.qty ?? Decimal.zero) + delta;
      if (next <= Decimal.zero) {
        _draft.remove(productId);
      } else if (current == null) {
        _draft[productId] = _RestockLine(qty: next);
      } else {
        _draft[productId] = current.copyWith(qty: next);
      }
    });
  }

  /// Display label for a machine reason value (the value itself is persisted
  /// and must stay in English).
  String _reasonLabel(AppLocalizations l, String reason) {
    switch (reason) {
      case 'restock':
        return l.stockAdjustReasonRestock;
      case 'supplier delivery':
        return l.stockAdjustReasonSupplierDelivery;
      case 'transfer in':
        return l.stockAdjustReasonTransferIn;
      default:
        return reason;
    }
  }

  Future<void> _submit() async {
    final l = context.l10n;
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
        .where((e) => e.value.qty > Decimal.zero)
        .toList();
    final lotsRepo = ref.read(lotsRepositoryProvider);
    final productsRepo = ref.read(productsRepositoryProvider);
    try {
      for (final entry in entries) {
        final line = entry.value;
        // Per-line cost when entered, otherwise the product's last cost.
        var cost = line.unitCost;
        if (cost == null) {
          final product = await productsRepo.byId(entry.key);
          cost = product?.purchasePrice ?? Decimal.zero;
        }
        await lotsRepo.receiveStock(
          productId: entry.key,
          quantity: line.qty,
          unitCost: cost,
          expiryDate: line.expiryDate,
          note: _reason,
          ownerChallengeToken: challenge,
        );
      }
      messenger.showSnackBar(
        SnackBar(content: Text(l.bulkRestockSuccess(entries.length))),
      );
      router.pop();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(localizedErrorMessage(l, e))),
      );
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
    required this.line,
    required this.onChange,
    required this.onSet,
  });
  final Product product;
  final _RestockLine? line;
  final ValueChanged<Decimal> onChange;
  final ValueChanged<_RestockLine?> onSet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final qty = line?.qty ?? Decimal.zero;
    final hasQty = qty > Decimal.zero;
    final details = <String>[
      if (line?.unitCost != null) context.money(line!.unitCost!),
      if (line?.expiryDate != null) context.dateShort(line!.expiryDate!),
    ];
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
                    details.isEmpty
                        ? context.l10n.bulkRestockInStock(
                            _fmtQty(product.stock),
                            product.unit,
                          )
                        : details.join(' · '),
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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

  /// Line editor: quantity + optional unit cost (prefilled with the last
  /// cost) + optional expiry date for this batch.
  Future<void> _showCustom(
    BuildContext context,
    Product product,
    ValueChanged<_RestockLine?> onSet,
  ) async {
    final qty = line?.qty ?? Decimal.zero;
    final qtyController = TextEditingController(
      text: qty > Decimal.zero ? _fmtQty(qty) : '',
    );
    final prefillCost = line?.unitCost ?? product.purchasePrice;
    final costController = TextEditingController(
      text: prefillCost > Decimal.zero ? prefillCost.toStringAsFixed(2) : '',
    );
    var expiry = line?.expiryDate;
    final result = await showDialog<_RestockLine?>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text(ctx.l10n.bulkRestockDialogTitle(product.name)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: qtyController,
                autofocus: true,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: ctx.l10n.bulkRestockQuantityLabel(product.unit),
                ),
              ),
              const SizedBox(height: SuuqSpacing.sm),
              TextField(
                controller: costController,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: ctx.l10n.stockReceiveUnitCostLabel,
                  prefixText: 'ETB  ',
                ),
              ),
              const SizedBox(height: SuuqSpacing.sm),
              InkWell(
                onTap: () async {
                  final now = DateTime.now();
                  final picked = await showDatePicker(
                    context: ctx,
                    initialDate: expiry ?? now,
                    firstDate: DateTime(now.year, now.month, now.day),
                    lastDate: DateTime(now.year + 5),
                  );
                  if (picked != null) setState(() => expiry = picked);
                },
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: ctx.l10n.stockReceiveExpiryLabel,
                    suffixIcon: expiry == null
                        ? const Icon(Icons.event_rounded)
                        : IconButton(
                            icon: const Icon(Icons.clear_rounded, size: 18),
                            onPressed: () => setState(() => expiry = null),
                          ),
                  ),
                  child: Text(
                    expiry == null
                        ? ctx.l10n.stockReceiveNoExpiry
                        : ctx.dateShort(expiry!),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(ctx.l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () {
                final v = Decimal.tryParse(qtyController.text.trim());
                if (v == null || v <= Decimal.zero) {
                  Navigator.pop(ctx);
                  return;
                }
                Navigator.pop(
                  ctx,
                  _RestockLine(
                    qty: v,
                    unitCost:
                        Decimal.tryParse(costController.text.trim()),
                    expiryDate: expiry,
                  ),
                );
              },
              child: Text(ctx.l10n.bulkRestockSet),
            ),
          ],
        ),
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
