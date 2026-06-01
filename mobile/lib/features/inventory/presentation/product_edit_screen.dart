import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/services/cloudinary_service.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/data/products_repository.dart';
import 'package:suuqii/features/inventory/data/recipes_repository.dart';
import 'package:suuqii/features/inventory/presentation/stock_adjust_sheet.dart';
import 'package:suuqii/features/supplies/data/supplies_repository.dart';
import 'package:suuqii/features/supplies/domain/entities/supply.dart';
import 'package:suuqii/shared/widgets/owner_pin_dialog.dart';
import 'package:suuqii/shared/widgets/product_image.dart';

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
  final _imageUrl = TextEditingController();
  String _unit = 'piece';

  // Bakery recipe state: list of (supply, qty controller) pairs
  final List<({Supply supply, TextEditingController qty})> _recipeLines = [];

  bool _loaded = false;
  bool _busy = false;
  bool _uploading = false;
  double _uploadProgress = 0;
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
    _imageUrl.dispose();
    for (final line in _recipeLines) {
      line.qty.dispose();
    }
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
    _imageUrl.text = p.imageUrl ?? '';
    _unit = p.unit;
    _originalSelling = p.sellingPrice;

    // Load existing recipe for bakery shops.
    // getForProduct already enriches items with supply name/unit/cost, so we
    // don't need a separate getAll() call here.
    final auth = ref.read(authControllerProvider).valueOrNull;
    if (auth is Authenticated && auth.isBakery) {
      final existingRecipe = await ref
          .read(recipesRepositoryProvider)
          .getForProduct(widget.productId!);
      for (final item in existingRecipe) {
        if (item.supplyName == null) continue; // supply deleted, skip
        _recipeLines.add((
          supply: Supply(
            id: item.supplyId,
            shopId: item.shopId,
            name: item.supplyName!,
            unit: item.supplyUnit ?? 'piece',
            quantityOnHand: Decimal.zero,
            reorderThreshold: Decimal.zero,
            costPerUnit: item.supplyCostPerUnit ?? Decimal.zero,
          ),
          qty: TextEditingController(
            text: item.quantity.toStringAsFixed(2),
          ),
        ),);
      }
    }

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
    final isBakery = auth is Authenticated && auth.isBakery;

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
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(labelText: 'Name'),
                      validator: _required,
                    ),
                    const SizedBox(height: SuuqSpacing.sm),
                    _CategoryField(
                      controller: _category,
                      categories: ref
                              .watch(watchCategoriesProvider)
                              .valueOrNull ??
                          const [],
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
                        // Bakery shops derive cost from recipe; regular shops
                        // use an explicit purchase price (owner-only).
                        if (isOwner && !isBakery) ...[
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
                        ],
                        Expanded(
                          child: TextFormField(
                            controller: _selling,
                            keyboardType: const TextInputType
                                .numberWithOptions(decimal: true),
                            decoration: const InputDecoration(
                              labelText: 'Selling price',
                              prefixText: 'ETB  ',
                            ),
                            validator: _decimal,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                if (isBakery) ...[
                  const SizedBox(height: SuuqSpacing.lg),
                  _RecipeSection(
                    lines: _recipeLines,
                    onAddLine: () => _addRecipeLine(context),
                    onRemoveLine: (i) {
                      _recipeLines[i].qty.dispose();
                      setState(() => _recipeLines.removeAt(i));
                    },
                  ),
                ],
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
                  title: 'Image',
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        GestureDetector(
                          onTap: _uploading ? null : _pickAndUploadImage,
                          child: Stack(
                            children: [
                              ProductImage(
                                name: _previewName,
                                imageUrl: _normalizedImageUrl,
                                size: 84,
                              ),
                              if (_uploading)
                                Positioned.fill(
                                  child: ClipRRect(
                                    borderRadius: BorderRadius.circular(
                                      SuuqRadius.md,
                                    ),
                                    child: ColoredBox(
                                      color: Colors.black54,
                                      child: Center(
                                        child: CircularProgressIndicator(
                                          value: _uploadProgress > 0
                                              ? _uploadProgress
                                              : null,
                                          color: Colors.white,
                                          strokeWidth: 2,
                                        ),
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
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              OutlinedButton.icon(
                                onPressed:
                                    _uploading ? null : _pickAndUploadImage,
                                icon: const Icon(
                                  Icons.upload_rounded,
                                  size: 18,
                                ),
                                label: Text(
                                  _normalizedImageUrl == null
                                      ? 'Upload photo'
                                      : 'Change photo',
                                ),
                              ),
                              if (_normalizedImageUrl != null) ...[
                                const SizedBox(height: SuuqSpacing.xs),
                                TextButton.icon(
                                  onPressed: () =>
                                      setState(() => _imageUrl.text = ''),
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 16,
                                  ),
                                  label: const Text('Remove'),
                                  style: TextButton.styleFrom(
                                    foregroundColor:
                                        Theme.of(context).colorScheme.error,
                                  ),
                                ),
                              ],
                            ],
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
            onPressed: _busy ? null : () => _save(isOwner: isOwner, isBakery: isBakery),
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

  Future<void> _addRecipeLine(BuildContext context) async {
    final supplies = await ref.read(suppliesRepositoryProvider).getAll();
    if (!context.mounted) return;
    if (supplies.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Add supplies first before building a recipe'),
        ),
      );
      return;
    }
    final existing = _recipeLines.map((l) => l.supply.id).toSet();
    final available = supplies.where((s) => !existing.contains(s.id)).toList();
    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All supplies already added')),
      );
      return;
    }

    final picked = await showModalBottomSheet<Supply>(
      context: context,
      builder: (ctx) => _SupplyPickerSheet(supplies: available),
    );
    if (picked == null) return;

    setState(() {
      _recipeLines.add((
        supply: picked,
        qty: TextEditingController(text: '1'),
      ),);
    });
  }

  Future<void> _pickAndUploadImage() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Take a photo'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    final picked = await ImagePicker().pickImage(
      source: source,
      imageQuality: 85,
    );
    if (picked == null) return;

    setState(() {
      _uploading = true;
      _uploadProgress = 0;
    });

    try {
      final url = await CloudinaryService().uploadImage(
        File(picked.path),
        onProgress: (sent, total) =>
            setState(() => _uploadProgress = sent / total),
      );
      setState(() => _imageUrl.text = url);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  String get _previewName {
    final name = _name.text.trim();
    return name.isEmpty ? 'Preview' : name;
  }

  String? get _normalizedImageUrl {
    final value = _imageUrl.text.trim();
    return value.isEmpty ? null : value;
  }

  Future<void> _save({
    required bool isOwner,
    required bool isBakery,
  }) async {
    if (!_form.currentState!.validate()) return;
    final selling = Decimal.parse(_selling.text.trim());
    // Bakery: cost is derived from recipe. Regular: owner enters purchase price.
    final purchase = isBakery
        ? Decimal.zero
        : Decimal.parse(_purchase.text.isEmpty ? '0' : _purchase.text.trim());
    final category = _category.text.trim().isEmpty
        ? null
        : _category.text.trim();
    final barcode = _barcode.text.trim().isEmpty ? null : _barcode.text.trim();
    final imageUrl = _normalizedImageUrl;
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);

    final priceChanged = !widget.isCreating &&
        _originalSelling != null &&
        _originalSelling != selling;
    final needsPin = !isOwner && (widget.isCreating || priceChanged);
    String? challenge;
    if (needsPin) {
      challenge = await requestOwnerChallenge(context, ref);
      if (challenge == null) return;
    }

    setState(() => _busy = true);
    try {
      final repo = ref.read(productsRepositoryProvider);
      String productId;
      if (widget.isCreating) {
        final created = await repo.create(
          name: _name.text.trim(),
          category: category,
          purchasePrice: purchase,
          sellingPrice: selling,
          stock: Decimal.parse(_stock.text.trim()),
          lowStockThreshold: Decimal.parse(_threshold.text.trim()),
          unit: _unit,
          barcode: barcode,
          imageUrl: imageUrl,
          ownerChallengeToken: challenge,
        );
        productId = created.id;
      } else {
        await repo.update(
          id: widget.productId!,
          name: _name.text.trim(),
          category: category,
          purchasePrice: purchase,
          sellingPrice: selling,
          lowStockThreshold: Decimal.parse(_threshold.text.trim()),
          unit: _unit,
          barcode: barcode,
          imageUrl: imageUrl,
          ownerChallengeToken: challenge,
        );
        productId = widget.productId!;
      }

      // Save recipe for bakery shops
      if (isBakery) {
        final lines = _recipeLines
            .map((line) {
              final qty = Decimal.tryParse(line.qty.text.trim());
              if (qty == null || qty <= Decimal.zero) return null;
              return (supplyId: line.supply.id, quantity: qty);
            })
            .whereType<({String supplyId, Decimal quantity})>()
            .toList();
        await ref.read(recipesRepositoryProvider).setRecipe(
              productId: productId,
              lines: lines,
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
      builder: (_) => const StockAdjustSheet(),
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

// ---------------------------------------------------------------------------
// Recipe section widget
// ---------------------------------------------------------------------------

class _RecipeSection extends StatelessWidget {
  const _RecipeSection({
    required this.lines,
    required this.onAddLine,
    required this.onRemoveLine,
  });

  final List<({Supply supply, TextEditingController qty})> lines;
  final VoidCallback onAddLine;
  final ValueChanged<int> onRemoveLine;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    var totalCost = Decimal.zero;
    for (final line in lines) {
      final qty = Decimal.tryParse(line.qty.text.trim()) ?? Decimal.zero;
      totalCost += qty * line.supply.costPerUnit;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: SuuqSpacing.xs),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'RECIPE',
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              if (lines.isNotEmpty)
                Text(
                  'Cost: ETB ${totalCost.toStringAsFixed(2)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: scheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(SuuqRadius.md),
          ),
          child: Column(
            children: [
              if (lines.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(SuuqSpacing.md),
                  child: Text(
                    'No ingredients added yet.\nAdd supplies to calculate cost automatically.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ...lines.asMap().entries.map((entry) {
                final i = entry.key;
                final line = entry.value;
                return _RecipeLine(
                  supply: line.supply,
                  qtyController: line.qty,
                  onRemove: () => onRemoveLine(i),
                  showDivider: i < lines.length - 1,
                );
              }),
              const Divider(height: 1),
              TextButton.icon(
                onPressed: onAddLine,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add ingredient'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RecipeLine extends StatelessWidget {
  const _RecipeLine({
    required this.supply,
    required this.qtyController,
    required this.onRemove,
    required this.showDivider,
  });

  final Supply supply;
  final TextEditingController qtyController;
  final VoidCallback onRemove;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: SuuqSpacing.sm,
            vertical: SuuqSpacing.xs,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  supply.name,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
              SizedBox(
                width: 80,
                child: TextField(
                  controller: qtyController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    isDense: true,
                    suffixText: supply.unit,
                    border: const OutlineInputBorder(),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: SuuqSpacing.xs),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                onPressed: onRemove,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ],
          ),
        ),
        if (showDivider) const Divider(height: 1),
      ],
    );
  }
}

class _SupplyPickerSheet extends StatelessWidget {
  const _SupplyPickerSheet({required this.supplies});
  final List<Supply> supplies;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              SuuqSpacing.lg, SuuqSpacing.md, SuuqSpacing.lg, 0,
            ),
            child: Text(
              'Pick an ingredient',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: SuuqSpacing.xs),
          ...supplies.map(
            (s) => ListTile(
              title: Text(s.name),
              subtitle: Text(
                '${s.quantityOnHand.toStringAsFixed(2)} ${s.unit} on hand',
              ),
              onTap: () => Navigator.pop(context, s),
            ),
          ),
          const SizedBox(height: SuuqSpacing.sm),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Section header widget (shared with the rest of the screen)
// ---------------------------------------------------------------------------

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

/// Category field with autocomplete from previously-used categories.
///
/// Allows free-form text entry while surfacing existing categories as
/// suggestions so the product list stays consistent without forcing a
/// predefined taxonomy on the user.
class _CategoryField extends StatelessWidget {
  const _CategoryField({
    required this.controller,
    required this.categories,
  });

  final TextEditingController controller;
  final List<String> categories;

  @override
  Widget build(BuildContext context) {
    return Autocomplete<String>(
      initialValue: TextEditingValue(text: controller.text),
      optionsBuilder: (value) {
        final q = value.text.trim().toLowerCase();
        // Show all categories when the field is empty; otherwise filter.
        if (q.isEmpty) return categories;
        return categories.where((c) => c.toLowerCase().contains(q));
      },
      fieldViewBuilder: (ctx, autoCtrl, focusNode, onSubmit) {
        return TextFormField(
          controller: autoCtrl,
          focusNode: focusNode,
          textCapitalization: TextCapitalization.sentences,
          onChanged: (v) => controller.text = v,
          onFieldSubmitted: (_) => onSubmit(),
          decoration: InputDecoration(
            labelText: 'Category (optional)',
            suffixIcon: categories.isNotEmpty
                ? const Icon(Icons.expand_more, size: 18)
                : null,
          ),
        );
      },
      onSelected: (value) => controller.text = value,
      optionsViewBuilder: (ctx, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(SuuqRadius.md),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (_, i) {
                  final option = options.elementAt(i);
                  return ListTile(
                    dense: true,
                    title: Text(option),
                    onTap: () => onSelected(option),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
