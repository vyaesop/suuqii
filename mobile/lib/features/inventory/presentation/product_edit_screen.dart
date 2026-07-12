import 'dart:io';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/services/cloudinary_service.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/core/utils/unit_conversion.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/data/lots_repository.dart';
import 'package:suuqii/features/inventory/data/products_repository.dart';
import 'package:suuqii/features/inventory/data/recipes_repository.dart';
import 'package:suuqii/features/inventory/presentation/stock_adjust_sheet.dart';
import 'package:suuqii/features/supplies/data/supplies_repository.dart';
import 'package:suuqii/features/supplies/domain/entities/supply.dart';
import 'package:suuqii/shared/widgets/owner_pin_dialog.dart';
import 'package:suuqii/shared/widgets/product_image.dart';

const _units = <String>['piece', 'kg', 'quintal', 'liter', 'pack', 'm'];

/// Display label for a machine unit value (the value itself is persisted and
/// must stay in English). Falls back to the raw value for user-typed units.
String _unitDisplayLabel(AppLocalizations l, String unit) {
  switch (unit) {
    case 'piece':
      return l.unitPiece;
    case 'kg':
      return l.unitKg;
    case 'g':
      return l.unitG;
    case 'mg':
      return l.unitMg;
    case 'quintal':
      return l.unitQuintal;
    case 'liter':
      return l.unitLiter;
    case 'ml':
      return l.unitMl;
    case 'cup':
      return l.unitCup;
    case 'pack':
      return l.unitPack;
    case 'm':
      return l.unitMeter;
    default:
      return unit;
  }
}

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

  // Bakery recipe state: list of (supply, qty controller, recipe unit) tuples
  final List<({Supply supply, TextEditingController qty, String unit})>
      _recipeLines = [];

  bool _loaded = false;
  bool _busy = false;
  bool _uploading = false;
  double _uploadProgress = 0;

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
    final auth = ref.read(authControllerProvider).valueOrNull;
    final isOwner = auth is Authenticated && auth.isOwner;
    _name.text = p.name;
    _category.text = p.category ?? '';
    // Purchase price is owner-only data. The server already masks it to 0 in
    // cashier list responses, but never pre-fill it for cashiers regardless:
    // the field is hidden for them and the value is omitted from update
    // payloads (see ProductsRepository.update), so '0' can never leak or
    // overwrite the real cost.
    _purchase.text = isOwner ? p.purchasePrice.toString() : '0';
    _selling.text = p.sellingPrice.toString();
    _stock.text = p.stock.toString();
    _threshold.text = p.lowStockThreshold.toString();
    _barcode.text = p.barcode ?? '';
    _imageUrl.text = p.imageUrl ?? '';
    _unit = p.unit;

    // Load existing recipe for bakery shops.
    // getForProduct already enriches items with supply name/unit/cost, so we
    // don't need a separate getAll() call here.
    if (auth is Authenticated && auth.isBakery) {
      final existingRecipe = await ref
          .read(recipesRepositoryProvider)
          .getForProduct(widget.productId!);
      for (final item in existingRecipe) {
        if (item.supplyName == null) continue; // supply deleted, skip
        final supplyUnit = item.supplyUnit ?? 'piece';
        _recipeLines.add((
          supply: Supply(
            id: item.supplyId,
            shopId: item.shopId,
            name: item.supplyName!,
            unit: supplyUnit,
            quantityOnHand: Decimal.zero,
            reorderThreshold: Decimal.zero,
            costPerUnit: item.supplyCostPerUnit ?? Decimal.zero,
          ),
          qty: TextEditingController(
            text: item.quantity.toStringAsFixed(2),
          ),
          unit: item.recipeUnit ?? supplyUnit,
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
    final l = context.l10n;
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final isOwner = auth is Authenticated && auth.role == 'owner';
    final isBakery = auth is Authenticated && auth.isBakery;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isCreating ? l.productEditNewTitle : l.productEditEditTitle,
        ),
        actions: [
          if (!widget.isCreating)
            TextButton.icon(
              onPressed: () => _showStockSheet(context, isOwner: isOwner),
              icon: const Icon(Icons.tune_rounded, size: 18),
              label: Text(l.stockAdjustTitle),
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
                  title: l.productSectionDetails,
                  children: [
                    TextFormField(
                      controller: _name,
                      onChanged: (_) => setState(() {}),
                      decoration:
                          InputDecoration(labelText: l.productNameLabel),
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
                      decoration:
                          InputDecoration(labelText: l.productUnitLabel),
                      items: _units
                          .map(
                            (u) => DropdownMenuItem(
                              value: u,
                              child: Text(_unitDisplayLabel(l, u)),
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
                  title: l.productSectionPricing,
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
                              decoration: InputDecoration(
                                labelText: l.productPurchaseLabel,
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
                            decoration: InputDecoration(
                              labelText: l.productSellingPriceLabel,
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
                    onUnitChanged: (i, newUnit) => setState(() {
                      final old = _recipeLines[i];
                      _recipeLines[i] =
                          (supply: old.supply, qty: old.qty, unit: newUnit);
                    }),
                  ),
                ],
                const SizedBox(height: SuuqSpacing.lg),
                _Section(
                  title: l.productSectionStock,
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
                                  ? l.productInitialStockLabel
                                  : l.productCurrentStockLabel,
                              helperText: widget.isCreating
                                  ? null
                                  : l.productStockHelper,
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
                            decoration: InputDecoration(
                              labelText: l.productLowAtLabel,
                              helperText: l.productLowAtHelper,
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
                  title: l.productSectionImage,
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
                                      ? l.productUploadPhoto
                                      : l.productChangePhoto,
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
                                  label: Text(l.commonRemove),
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
                  title: l.productSectionIdentifiers,
                  children: [
                    TextFormField(
                      controller: _barcode,
                      decoration: InputDecoration(
                        labelText: l.productBarcodeOptionalLabel,
                        prefixIcon: const Icon(
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
            label: Text(
              widget.isCreating ? l.productCreateButton : l.commonSaveChanges,
            ),
          ),
        ),
      ),
    );
  }

  String? _required(String? v) =>
      (v == null || v.trim().isEmpty) ? context.l10n.commonRequired : null;

  String? _decimal(String? v) {
    if (v == null || v.trim().isEmpty) return context.l10n.commonRequired;
    final d = Decimal.tryParse(v.trim());
    if (d == null || d < Decimal.zero) return context.l10n.productInvalidNumber;
    return null;
  }

  Future<void> _addRecipeLine(BuildContext context) async {
    final l = context.l10n;
    final supplies = await ref.read(suppliesRepositoryProvider).getAll();
    if (!context.mounted) return;
    if (supplies.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l.productRecipeAddSuppliesFirst),
        ),
      );
      return;
    }
    final existing = _recipeLines.map((line) => line.supply.id).toSet();
    final available = supplies.where((s) => !existing.contains(s.id)).toList();
    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.productRecipeAllSuppliesAdded)),
      );
      return;
    }

    final picked = await showModalBottomSheet<Supply>(
      context: context,
      builder: (ctx) => _SupplyPickerSheet(supplies: available),
    );
    if (picked == null) return;

    // Default recipe unit to the most-common sub-unit for the supply's unit
    // (e.g. kg supply → default to g so the user enters 100 not 0.1).
    final defaultUnit = compatibleUnits(picked.unit).first;
    setState(() {
      _recipeLines.add((
        supply: picked,
        qty: TextEditingController(text: ''),
        unit: defaultUnit,
      ),);
    });
  }

  Future<void> _pickAndUploadImage() async {
    final l = context.l10n;
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: Text(ctx.l10n.productTakePhoto),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: Text(ctx.l10n.productChooseFromGallery),
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
          SnackBar(content: Text(l.productUploadFailed(localizedErrorMessage(l, e)))),
        );
      }
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  String get _previewName {
    final name = _name.text.trim();
    return name.isEmpty ? context.l10n.productImagePreviewName : name;
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
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final router = GoRouter.of(context);

    // product.create and product.update are blanket-sensitive server-side
    // (SENSITIVE_OPS): any cashier create/edit — even a name or category
    // change — must carry an owner challenge or the sync op is rejected.
    // Collect the PIN upfront so offline edits don't fail hours later.
    final needsPin = !isOwner;
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
              return (
                supplyId: line.supply.id,
                quantity: qty,
                recipeUnit: line.unit,
              );
            })
            .whereType<({String supplyId, Decimal quantity, String recipeUnit})>()
            .toList();
        await ref.read(recipesRepositoryProvider).setRecipe(
              productId: productId,
              lines: lines,
              ownerChallengeToken: challenge,
            );
      }

      router.pop();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(localizedErrorMessage(l, e))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Receive a batch (Add) or apply a manual correction (Remove) from the
  /// edit screen's app-bar action. Mirrors the product-detail flow.
  Future<void> _showStockSheet(
    BuildContext context, {
    required bool isOwner,
  }) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final product =
        await ref.read(productsRepositoryProvider).byId(widget.productId!);
    if (product == null || !context.mounted) return;
    final result = await showModalBottomSheet<StockAdjustResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => StockAdjustSheet(product: product),
    );
    if (result == null) return;

    String? challenge;
    if (!isOwner) {
      if (!context.mounted) return;
      challenge = await requestOwnerChallenge(context, ref);
      if (challenge == null) return;
    }

    try {
      switch (result) {
        case ReceiveStockResult():
          await ref.read(lotsRepositoryProvider).receiveStock(
                productId: widget.productId!,
                quantity: result.quantity,
                unitCost: result.unitCost,
                expiryDate: result.expiryDate,
                spoiledQuantity: result.spoiledQuantity,
                note: result.note,
                ownerChallengeToken: challenge,
              );
          messenger.showSnackBar(
            SnackBar(
              content: Text(l.stockReceiveSuccess('${result.quantity}')),
            ),
          );
        case RemoveStockResult():
          await ref.read(productsRepositoryProvider).adjustStock(
                productId: widget.productId!,
                delta: -result.quantity,
                reason: result.reason,
                ownerChallengeToken: challenge,
              );
          messenger.showSnackBar(
            SnackBar(
              content: Text(l.stockAdjustSuccess('-${result.quantity}')),
            ),
          );
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(localizedErrorMessage(l, e))),
      );
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
    required this.onUnitChanged,
  });

  final List<({Supply supply, TextEditingController qty, String unit})> lines;
  final VoidCallback onAddLine;
  final ValueChanged<int> onRemoveLine;
  final void Function(int index, String unit) onUnitChanged;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context);

    // Total cost converts each recipe qty to the supply's unit before
    // multiplying by cost-per-supply-unit.
    var totalCost = Decimal.zero;
    for (final line in lines) {
      final qty = Decimal.tryParse(line.qty.text.trim()) ?? Decimal.zero;
      final qtyInSupplyUnit = convertUnit(qty, line.unit, line.supply.unit);
      totalCost += qtyInSupplyUnit * line.supply.costPerUnit;
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
                  l.productRecipeTitle,
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              if (lines.isNotEmpty)
                Text(
                  l.productRecipeCost(context.money(totalCost)),
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
                    l.productRecipeEmpty,
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
                  selectedUnit: line.unit,
                  onUnitChanged: (u) => onUnitChanged(i, u),
                  onRemove: () => onRemoveLine(i),
                  showDivider: i < lines.length - 1,
                );
              }),
              const Divider(height: 1),
              TextButton.icon(
                onPressed: onAddLine,
                icon: const Icon(Icons.add, size: 18),
                label: Text(l.productRecipeAddIngredient),
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
    required this.selectedUnit,
    required this.onUnitChanged,
    required this.onRemove,
    required this.showDivider,
  });

  final Supply supply;
  final TextEditingController qtyController;
  final String selectedUnit;
  final ValueChanged<String> onUnitChanged;
  final VoidCallback onRemove;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final units = compatibleUnits(supply.unit);
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
                width: 72,
                child: TextField(
                  controller: qtyController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  textAlign: TextAlign.center,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 8,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 4),
              // Unit selector — compact dropdown showing compatible units.
              DropdownButton<String>(
                value: units.contains(selectedUnit) ? selectedUnit : units.first,
                items: units
                    .map(
                      (u) => DropdownMenuItem(
                        value: u,
                        child: Text(_unitDisplayLabel(context.l10n, u)),
                      ),
                    )
                    .toList(),
                onChanged: (u) {
                  if (u != null) onUnitChanged(u);
                },
                underline: const SizedBox.shrink(),
                isDense: true,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(width: 2),
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
              context.l10n.productRecipePickIngredient,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: SuuqSpacing.xs),
          ...supplies.map(
            (s) => ListTile(
              title: Text(s.name),
              subtitle: Text(
                context.l10n.productSupplyOnHand(
                  s.quantityOnHand.toStringAsFixed(2),
                  s.unit,
                ),
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
            labelText: ctx.l10n.productCategoryOptionalLabel,
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
