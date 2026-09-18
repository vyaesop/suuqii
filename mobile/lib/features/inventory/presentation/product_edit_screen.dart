import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/shop_type/shop_features.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/core/utils/unit_conversion.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/data/lots_repository.dart';
import 'package:suuqii/features/inventory/data/products_repository.dart';
import 'package:suuqii/features/inventory/data/recipes_repository.dart';
import 'package:suuqii/features/inventory/data/styles_repository.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/inventory/domain/entities/style.dart';
import 'package:suuqii/features/inventory/presentation/stock_adjust_sheet.dart';
import 'package:suuqii/features/inventory/presentation/widgets/category_field.dart';
import 'package:suuqii/features/inventory/presentation/widgets/product_photo_field.dart';
import 'package:suuqii/features/inventory/presentation/widgets/quantity_input.dart';
import 'package:suuqii/features/inventory/presentation/widgets/variant_header.dart';
import 'package:suuqii/features/supplies/data/supplies_repository.dart';
import 'package:suuqii/features/supplies/domain/entities/supply.dart';
import 'package:suuqii/shared/widgets/owner_pin_dialog.dart';

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
  final _minPrice = TextEditingController();
  final _stock = TextEditingController(text: '0');
  final _threshold = TextEditingController(text: '0');
  final _barcode = TextEditingController();
  final _sku = TextEditingController();

  /// Set when the last save attempt found the typed SKU on another product;
  /// cleared as soon as the field changes so the error follows the input.
  String? _skuTakenError;
  String _unit = 'piece';
  String? _imageUrl;

  /// The product being edited (null when creating). Variants keep their
  /// composed name, category and style identity from here — those belong
  /// to the style and are not editable per variant.
  Product? _existing;
  Style? _variantStyle;

  // Bakery recipe state: list of (supply, qty controller, recipe unit) tuples
  final List<({Supply supply, TextEditingController qty, String unit})>
      _recipeLines = [];

  bool _loaded = false;
  bool _busy = false;

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
    _minPrice.dispose();
    _stock.dispose();
    _threshold.dispose();
    _barcode.dispose();
    _sku.dispose();
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
    _existing = p;
    _name.text = p.name;
    _category.text = p.category ?? '';
    // Purchase price is owner-only data. The server already masks it to 0 in
    // cashier list responses, but never pre-fill it for cashiers regardless:
    // the field is hidden for them and the value is omitted from update
    // payloads (see ProductsRepository.update), so '0' can never leak or
    // overwrite the real cost.
    _purchase.text = isOwner ? p.purchasePrice.toString() : '0';
    _selling.text = p.sellingPrice.toString();
    _minPrice.text = p.minSellingPrice?.toString() ?? '';
    _stock.text = p.stock.toString();
    _threshold.text = p.lowStockThreshold.toString();
    _barcode.text = p.barcode ?? '';
    _sku.text = p.sku ?? '';
    _imageUrl = p.imageUrl;
    _unit = p.unit;

    if (p.styleId != null) {
      _variantStyle = await ref.read(stylesRepositoryProvider).byId(p.styleId!);
    }

    // Load existing recipe for shops that produce from ingredients.
    // getForProduct already enriches items with supply name/unit/cost, so we
    // don't need a separate getAll() call here.
    if (auth is Authenticated && auth.features.hasProduction) {
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

    if (mounted) setState(() => _loaded = true);
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
    final features =
        auth is Authenticated ? auth.features : ShopFeatures.regular;
    final isVariant = _existing?.isVariant ?? false;
    // Locked-unit shops never show the picker; the persisted value is the
    // type's default (piece) regardless of what a stale row carries.
    if (features.locksUnit) _unit = features.defaultUnit;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isCreating ? l.productEditNewTitle : l.productEditEditTitle,
        ),
        actions: [
          if (!widget.isCreating)
            TextButton.icon(
              onPressed: () => _showStockSheet(
                context,
                isOwner: isOwner,
                features: features,
              ),
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
                    if (isVariant)
                      // Name, size and colour come from the style; editing
                      // them here would desync the composed name.
                      VariantHeader(
                        product: _existing!,
                        style: _variantStyle,
                        onOpenStyle: _variantStyle == null
                            ? null
                            : () => context
                                .push('/inventory/style/${_variantStyle!.id}'),
                      )
                    else ...[
                      TextFormField(
                        controller: _name,
                        onChanged: (_) => setState(() {}),
                        decoration:
                            InputDecoration(labelText: l.productNameLabel),
                        validator: _required,
                      ),
                      const SizedBox(height: SuuqSpacing.sm),
                      CategoryField(
                        controller: _category,
                        categories: ref
                                .watch(watchCategoriesProvider)
                                .valueOrNull ??
                            const [],
                      ),
                    ],
                    if (!features.locksUnit) ...[
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
                            setState(() => _unit = v ?? features.defaultUnit),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: SuuqSpacing.lg),
                _Section(
                  title: l.productSectionPricing,
                  children: [
                    Row(
                      children: [
                        // Shops that produce from a recipe derive cost from it;
                        // everyone else enters an explicit purchase price
                        // (owner-only).
                        if (isOwner && !features.hasProduction) ...[
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
                    if (features.hasLinePricing) ...[
                      const SizedBox(height: SuuqSpacing.sm),
                      TextFormField(
                        controller: _minPrice,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: InputDecoration(
                          labelText: l.productMinPriceLabel,
                          helperText: l.productMinPriceHelper,
                          prefixText: 'ETB  ',
                        ),
                        validator: _optionalDecimal,
                      ),
                    ],
                  ],
                ),
                if (features.hasProduction) ...[
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
                            keyboardType: quantityKeyboard(
                              integerOnly: features.locksUnit,
                            ),
                            inputFormatters: quantityFormatters(
                              integerOnly: features.locksUnit,
                            ),
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
                            keyboardType: quantityKeyboard(
                              integerOnly: features.locksUnit,
                            ),
                            inputFormatters: quantityFormatters(
                              integerOnly: features.locksUnit,
                            ),
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
                    ProductPhotoField(
                      previewName: _previewName,
                      imageUrl: _imageUrl,
                      onChanged: (url) => setState(() => _imageUrl = url),
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
                    if (features.hasVariants) ...[
                      const SizedBox(height: SuuqSpacing.sm),
                      TextFormField(
                        controller: _sku,
                        textCapitalization: TextCapitalization.characters,
                        onChanged: (_) {
                          if (_skuTakenError == null) return;
                          setState(() => _skuTakenError = null);
                        },
                        // The clash is found asynchronously on save, so the
                        // validator only replays the stored result; editing
                        // the field re-runs it and so clears the message.
                        autovalidateMode: AutovalidateMode.onUserInteraction,
                        validator: (_) => _skuTakenError,
                        decoration: InputDecoration(
                          labelText: l.productSkuOptionalLabel,
                          prefixIcon: const Icon(Icons.tag_rounded, size: 20),
                        ),
                      ),
                    ],
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
            onPressed: _busy
                ? null
                : () => _save(isOwner: isOwner, features: features),
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

  String? _optionalDecimal(String? v) {
    if (v == null || v.trim().isEmpty) return null;
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

  String get _previewName {
    final name = _name.text.trim();
    return name.isEmpty ? context.l10n.productImagePreviewName : name;
  }

  Future<void> _save({
    required bool isOwner,
    required ShopFeatures features,
  }) async {
    if (!_form.currentState!.validate()) return;
    final existing = _existing;
    final isVariant = existing?.isVariant ?? false;
    final selling = Decimal.parse(_selling.text.trim());
    // Recipe shops: cost is derived from the recipe. Others: owner enters it.
    final purchase = features.hasProduction
        ? Decimal.zero
        : Decimal.parse(_purchase.text.isEmpty ? '0' : _purchase.text.trim());
    // A variant's name/category belong to its style and stay as they are.
    final name = isVariant ? existing!.name : _name.text.trim();
    final category = isVariant
        ? existing!.category
        : (_category.text.trim().isEmpty ? null : _category.text.trim());
    final barcode = _barcode.text.trim().isEmpty ? null : _barcode.text.trim();
    final sku = !features.hasVariants || _sku.text.trim().isEmpty
        ? null
        : _sku.text.trim().toUpperCase();
    final minPrice = !features.hasLinePricing || _minPrice.text.trim().isEmpty
        ? null
        : Decimal.parse(_minPrice.text.trim());
    final unit = features.locksUnit ? features.defaultUnit : _unit;
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);

    // A duplicate SKU comes back from the server as `sku_collision`, which
    // rejects the whole event; catch it here while the field is still on
    // screen instead of dead-lettering the edit hours later.
    if (sku != null &&
        await ref.read(productsRepositoryProvider).isSkuTaken(
              sku,
              excludingProductId: widget.productId,
            )) {
      if (!mounted) return;
      setState(() => _skuTakenError = l.errSkuCollision);
      _form.currentState!.validate();
      return;
    }
    if (!mounted) return;
    final router = GoRouter.of(context);

    // product.create and product.update are blanket-sensitive server-side
    // (SENSITIVE_OPS): any cashier create/edit — even a name or category
    // change — must carry an owner challenge or the sync op is rejected.
    // Collect the PIN upfront so offline edits don't fail hours later.
    final needsPin = !isOwner;
    String? challenge;
    if (needsPin) {
      // The SKU lookup above is async, so the tree may be gone by now.
      if (!mounted) return;
      challenge = await requestOwnerChallenge(context, ref);
      if (challenge == null) return;
    }

    setState(() => _busy = true);
    try {
      final repo = ref.read(productsRepositoryProvider);
      String productId;
      if (widget.isCreating) {
        final created = await repo.create(
          name: name,
          category: category,
          purchasePrice: purchase,
          sellingPrice: selling,
          stock: Decimal.parse(_stock.text.trim()),
          lowStockThreshold: Decimal.parse(_threshold.text.trim()),
          unit: unit,
          barcode: barcode,
          imageUrl: _imageUrl,
          sku: sku,
          minSellingPrice: minPrice,
          ownerChallengeToken: challenge,
        );
        productId = created.id;
      } else {
        await repo.update(
          id: widget.productId!,
          name: name,
          category: category,
          purchasePrice: purchase,
          sellingPrice: selling,
          lowStockThreshold: Decimal.parse(_threshold.text.trim()),
          unit: unit,
          barcode: barcode,
          imageUrl: _imageUrl,
          sku: sku,
          minSellingPrice: minPrice,
          ownerChallengeToken: challenge,
        );
        productId = widget.productId!;
      }

      // Save recipe for shops that produce from ingredients.
      if (features.hasProduction) {
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
    required ShopFeatures features,
  }) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final product =
        await ref.read(productsRepositoryProvider).byId(widget.productId!);
    if (product == null || !context.mounted) return;
    final result = await showModalBottomSheet<StockAdjustResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => StockAdjustSheet(
        product: product,
        showExpiry: features.tracksExpiry,
        integerOnly: features.locksUnit,
      ),
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
