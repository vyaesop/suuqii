import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/data/products_repository.dart';
import 'package:suuqii/shared/widgets/owner_pin_dialog.dart';
import 'package:suuqii/shared/widgets/sheet_handle.dart';

const _units = <String>['piece', 'kg', 'liter', 'pack', 'm'];

class ProductEditScreen extends ConsumerStatefulWidget {
  const ProductEditScreen({super.key, this.productId});
  final String? productId;
  bool get isCreating => productId == null;

  @override
  ConsumerState<ProductEditScreen> createState() => _ProductEditScreenState();
}

class _ProductEditScreenState extends ConsumerState<ProductEditScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _category = TextEditingController();
  final _purchase = TextEditingController();
  final _selling = TextEditingController();
  final _stock = TextEditingController(text: '0');
  final _threshold = TextEditingController(text: '0');
  final _barcode = TextEditingController();
  String _unit = 'piece';

  bool _loaded = false;
  bool _busy = false;
  Decimal? _originalSelling;

  @override
  void initState() {
    super.initState();
    if (widget.isCreating) _loaded = true;
  }

  @override
  void dispose() {
    _name.dispose();
    _category.dispose();
    _purchase.dispose();
    _selling.dispose();
    _stock.dispose();
    _threshold.dispose();
    _barcode.dispose();
    super.dispose();
  }

  Future<void> _ensureLoaded() async {
    if (_loaded) return;
    final p = await ref
        .read(productsRepositoryProvider)
        .byId(widget.productId!);
    if (!mounted || p == null) return;
    _name.text = p.name;
    _category.text = p.category ?? '';
    _purchase.text = p.purchasePrice.toString();
    _selling.text = p.sellingPrice.toString();
    _stock.text = p.stock.toString();
    _threshold.text = p.lowStockThreshold.toString();
    _barcode.text = p.barcode ?? '';
    _unit = p.unit;
    _originalSelling = p.sellingPrice;
    setState(() => _loaded = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      _ensureLoaded();
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final isOwner = auth is Authenticated && auth.role == 'owner';

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isCreating ? 'New product' : 'Edit product'),
        actions: [
          if (!widget.isCreating)
            TextButton.icon(
              onPressed: () => _showStockSheet(context, isOwner: isOwner),
              icon: const Icon(Icons.tune_rounded, size: 18),
              label: const Text('Adjust stock'),
            ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(
            SuuqSpacing.lg, SuuqSpacing.sm, SuuqSpacing.lg, 100,
          ),
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Section(
                  title: 'Details',
                  children: [
                    TextFormField(
                      controller: _name,
                      decoration: const InputDecoration(labelText: 'Name'),
                      validator: _required,
                    ),
                    const SizedBox(height: SuuqSpacing.sm),
                    TextFormField(
                      controller: _category,
                      decoration: const InputDecoration(
                        labelText: 'Category (optional)',
                      ),
                    ),
                    const SizedBox(height: SuuqSpacing.sm),
                    DropdownButtonFormField<String>(
                      initialValue: _unit,
                      decoration: const InputDecoration(labelText: 'Unit'),
                      items: _units
                          .map(
                            (u) => DropdownMenuItem(
                              value: u,
                              child: Text(u),
                            ),
                          )
                          .toList(),
                      onChanged: (v) =>
                          setState(() => _unit = v ?? 'piece'),
                    ),
                  ],
                ),
                const SizedBox(height: SuuqSpacing.lg),
                _Section(
                  title: 'Pricing',
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _purchase,
                            keyboardType: const TextInputType
                                .numberWithOptions(decimal: true),
                            decoration: const InputDecoration(
                              labelText: 'Purchase',
                              prefixText: 'ETB  ',
                            ),
                            validator: _decimal,
                          ),
                        ),
                        const SizedBox(width: SuuqSpacing.sm),
                        Expanded(
                          child: TextFormField(
                            controller: _selling,
                            keyboardType: const TextInputType
                                .numberWithOptions(decimal: true),
                            decoration: const InputDecoration(
                              labelText: 'Selling',
                              prefixText: 'ETB  ',
                            ),
                            validator: _decimal,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: SuuqSpacing.lg),
                _Section(
                  title: 'Stock',
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _stock,
                            enabled: widget.isCreating,
                            keyboardType: const TextInputType
                                .numberWithOptions(decimal: true),
                            decoration: InputDecoration(
                              labelText: widget.isCreating
                                  ? 'Initial stock'
                                  : 'Current stock',
                              helperText: widget.isCreating
                                  ? null
                                  : 'Use Adjust stock to change',
                            ),
                            validator: _decimal,
                          ),
                        ),
                        const SizedBox(width: SuuqSpacing.sm),
                        Expanded(
                          child: TextFormField(
                            controller: _threshold,
                            keyboardType: const TextInputType
                                .numberWithOptions(decimal: true),
                            decoration: const InputDecoration(
                              labelText: 'Low at',
                              helperText: 'Alert below this',
                            ),
                            validator: _decimal,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: SuuqSpacing.lg),
                _Section(
                  title: 'Identifiers',
                  children: [
                    TextFormField(
                      controller: _barcode,
                      decoration: const InputDecoration(
                        labelText: 'Barcode (optional)',
                        prefixIcon: Icon(
                          Icons.qr_code_scanner_rounded,
                          size: 20,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(SuuqSpacing.md),
          child: FilledButton.icon(
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.check_rounded),
            onPressed: _busy ? null : () => _save(isOwner: isOwner),
            label: Text(widget.isCreating ? 'Create product' : 'Save changes'),
          ),
        ),
      ),
    );
  }

  String? _required(String? v) =>
      (v == null || v.trim().isEmpty) ? 'Required' : null;

  String? _decimal(String? v) {
    if (v == null || v.trim().isEmpty) return 'Required';
    final d = Decimal.tryParse(v.trim());
    if (d == null || d < Decimal.zero) return 'Invalid number';
    return null;
  }

  Future<void> _save({required bool isOwner}) async {
    if (!_form.currentState!.validate()) return;
    final selling = Decimal.parse(_selling.text.trim());
    final purchase = Decimal.parse(_purchase.text.trim());
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);

    final priceChanged =
        _originalSelling != null && _originalSelling != selling;
    String? challenge;
    if (!isOwner && priceChanged) {
      challenge = await requestOwnerChallenge(context, ref);
      if (challenge == null) return;
    }

    setState(() => _busy = true);
    try {
      final repo = ref.read(productsRepositoryProvider);
      if (widget.isCreating) {
        await repo.create(
          name: _name.text.trim(),
          category: _category.text.trim().isEmpty
              ? null
              : _category.text.trim(),
          purchasePrice: purchase,
          sellingPrice: selling,
          stock: Decimal.parse(_stock.text.trim()),
          lowStockThreshold: Decimal.parse(_threshold.text.trim()),
          unit: _unit,
          barcode: _barcode.text.trim().isEmpty
              ? null
              : _barcode.text.trim(),
          ownerChallengeToken: challenge,
        );
      } else {
        await repo.update(
          id: widget.productId!,
          name: _name.text.trim(),
          category: _category.text.trim().isEmpty
              ? null
              : _category.text.trim(),
          purchasePrice: purchase,
          sellingPrice: selling,
          lowStockThreshold: Decimal.parse(_threshold.text.trim()),
          unit: _unit,
          barcode: _barcode.text.trim().isEmpty
              ? null
              : _barcode.text.trim(),
          ownerChallengeToken: challenge,
        );
      }
      router.pop();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showStockSheet(
    BuildContext context, {
    required bool isOwner,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await showModalBottomSheet<({Decimal delta, String reason})>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _StockAdjustSheet(),
    );
    if (result == null) return;

    String? challenge;
    if (!isOwner) {
      if (!context.mounted) return;
      challenge = await requestOwnerChallenge(context, ref);
      if (challenge == null) return;
    }

    try {
      await ref.read(productsRepositoryProvider).adjustStock(
            productId: widget.productId!,
            delta: result.delta,
            reason: result.reason,
            ownerChallengeToken: challenge,
          );
      messenger.showSnackBar(
        SnackBar(content: Text('Stock adjusted by ${result.delta}')),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: SuuqSpacing.xs),
          child: Text(
            title.toUpperCase(),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  letterSpacing: 1.2,
                ),
          ),
        ),
        ...children,
      ],
    );
  }
}

class _StockAdjustSheet extends StatefulWidget {
  const _StockAdjustSheet();
  @override
  State<_StockAdjustSheet> createState() => _StockAdjustSheetState();
}

class _StockAdjustSheetState extends State<_StockAdjustSheet> {
  final _qty = TextEditingController();
  String _movement = 'restock';
  String _reason = 'restock';

  static const _reasonsByMovement = {
    'restock': ['restock', 'supplier delivery', 'transfer in'],
    'adjustment': [
      'count correction',
      'waste',
      'damaged',
      'theft',
      'transfer out',
    ],
  };

  @override
  void initState() {
    super.initState();
    _reason = _reasonsByMovement[_movement]!.first;
  }

  @override
  void dispose() {
    _qty.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SuuqSheet(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Adjust stock',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: SuuqSpacing.md),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'restock',
                label: Text('Add'),
                icon: Icon(Icons.add_rounded),
              ),
              ButtonSegment(
                value: 'adjustment',
                label: Text('Remove'),
                icon: Icon(Icons.remove_rounded),
              ),
            ],
            selected: {_movement},
            onSelectionChanged: (s) => setState(() {
              _movement = s.first;
              _reason = _reasonsByMovement[_movement]!.first;
            }),
          ),
          const SizedBox(height: SuuqSpacing.md),
          TextField(
            controller: _qty,
            keyboardType:
                const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Quantity'),
            style: const TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: SuuqSpacing.sm),
          DropdownButtonFormField<String>(
            initialValue: _reason,
            decoration: const InputDecoration(labelText: 'Reason'),
            items: _reasonsByMovement[_movement]!
                .map(
                  (r) => DropdownMenuItem(value: r, child: Text(r)),
                )
                .toList(),
            onChanged: (v) => setState(() => _reason = v ?? _reason),
          ),
          const SizedBox(height: SuuqSpacing.lg),
          FilledButton(
            onPressed: () {
              final n = Decimal.tryParse(_qty.text.trim());
              if (n == null || n <= Decimal.zero) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Enter a positive number')),
                );
                return;
              }
              final signed = _movement == 'restock' ? n : -n;
              Navigator.pop(context, (delta: signed, reason: _reason));
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }
}
