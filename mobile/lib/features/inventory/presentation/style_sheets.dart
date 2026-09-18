import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/shop_type/size_presets.dart';
import 'package:suuqii/features/inventory/data/products_repository.dart';
import 'package:suuqii/features/inventory/data/styles_repository.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/inventory/domain/entities/style.dart';
import 'package:suuqii/features/inventory/presentation/style_wizard_screen.dart';
import 'package:suuqii/features/inventory/presentation/widgets/category_field.dart';
import 'package:suuqii/features/inventory/presentation/widgets/product_photo_field.dart';
import 'package:suuqii/features/inventory/presentation/widgets/quantity_input.dart';
import 'package:suuqii/features/inventory/presentation/widgets/style_form_fields.dart';
import 'package:suuqii/features/inventory/presentation/widgets/variant_matrix.dart';
import 'package:suuqii/shared/widgets/sheet_handle.dart';

// ---------------------------------------------------------------------------
// Receive shipment by matrix (docs/19 §6.4)
// ---------------------------------------------------------------------------

class StyleReceiveLine {
  const StyleReceiveLine({required this.productId, required this.quantity});
  final String productId;
  final Decimal quantity;
}

class StyleReceiveResult {
  const StyleReceiveResult({
    required this.lines,
    required this.unitCost,
    this.note,
  });
  final List<StyleReceiveLine> lines;

  /// One landed cost for the whole shipment — that is how the invoice reads.
  final Decimal unitCost;
  final String? note;
}

Future<StyleReceiveResult?> showStyleReceiveSheet(
  BuildContext context, {
  required Style style,
  required List<Product> variants,
}) {
  return showModalBottomSheet<StyleReceiveResult>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _StyleReceiveSheet(style: style, variants: variants),
  );
}

class _StyleReceiveSheet extends StatefulWidget {
  const _StyleReceiveSheet({required this.style, required this.variants});
  final Style style;
  final List<Product> variants;

  @override
  State<_StyleReceiveSheet> createState() => _StyleReceiveSheetState();
}

class _StyleReceiveSheetState extends State<_StyleReceiveSheet> {
  final Map<String, TextEditingController> _qty = {};
  late final TextEditingController _cost;
  final _note = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Prefill with the style's last cost (0 for cashiers — costs are masked;
    // they type the invoice figure themselves).
    final last = widget.style.defaultPurchasePrice;
    _cost = TextEditingController(
      text: last > Decimal.zero ? last.toStringAsFixed(2) : '',
    );
    for (final v in widget.variants) {
      _qty[v.id] = TextEditingController();
    }
  }

  @override
  void dispose() {
    for (final c in _qty.values) {
      c.dispose();
    }
    _cost.dispose();
    _note.dispose();
    super.dispose();
  }

  int get _total => _qty.values
      .map((c) => int.tryParse(c.text.trim()) ?? 0)
      .fold(0, (a, b) => a + b);

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final sizes = orderSizes(
      widget.variants.map((v) => v.size).whereType<String>(),
      presetKey: widget.style.sizeSet,
    );
    final colors = <String?>[];
    for (final v in widget.variants) {
      if (!colors.contains(v.color)) colors.add(v.color);
    }
    final byCell = {
      for (final v in widget.variants) variantCellKey(v.size, v.color): v,
    };

    return SuuqSheet(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.receiveSheetTitle, style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(l.receiveSheetHint, style: theme.textTheme.bodySmall),
          const SizedBox(height: SuuqSpacing.md),
          VariantMatrix(
            sizes: sizes.isEmpty ? const [null] : sizes,
            colors: colors.isEmpty ? const [null] : colors,
            cellBuilder: (_, size, color) {
              final v = byCell[variantCellKey(size, color)];
              if (v == null) return const SizedBox(height: 44);
              return QuantityCell(
                controller: _qty[v.id]!,
                hint: formatQuantity(v.stock),
              );
            },
          ),
          const SizedBox(height: SuuqSpacing.md),
          TextField(
            controller: _cost,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: l.stockReceiveUnitCostLabel,
              prefixText: 'ETB  ',
            ),
          ),
          const SizedBox(height: SuuqSpacing.sm),
          TextField(
            controller: _note,
            textCapitalization: TextCapitalization.sentences,
            decoration: InputDecoration(
              labelText: l.stockReceiveNoteLabel,
              hintText: l.receiveSheetNoteHint,
            ),
          ),
          const SizedBox(height: SuuqSpacing.lg),
          FilledButton(
            onPressed: () {
              final lines = <StyleReceiveLine>[
                for (final v in widget.variants)
                  if ((int.tryParse(_qty[v.id]!.text.trim()) ?? 0) > 0)
                    StyleReceiveLine(
                      productId: v.id,
                      quantity: Decimal.fromInt(
                        int.parse(_qty[v.id]!.text.trim()),
                      ),
                    ),
              ];
              if (lines.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l.receiveSheetNothing)),
                );
                return;
              }
              final cost = Decimal.tryParse(_cost.text.trim()) ?? Decimal.zero;
              final note = _note.text.trim();
              Navigator.pop(
                context,
                StyleReceiveResult(
                  lines: lines,
                  unitCost: cost < Decimal.zero ? Decimal.zero : cost,
                  note: note.isEmpty ? null : note,
                ),
              );
            },
            child: Text(l.receiveSheetApply(_total)),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Add sizes / colours to an existing style
// ---------------------------------------------------------------------------

Future<List<VariantDraft>?> showAddVariantsSheet(
  BuildContext context, {
  required Style style,
  required List<Product> existing,
}) {
  return showModalBottomSheet<List<VariantDraft>>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _AddVariantsSheet(style: style, existing: existing),
  );
}

class _AddVariantsSheet extends StatefulWidget {
  const _AddVariantsSheet({required this.style, required this.existing});
  final Style style;
  final List<Product> existing;

  @override
  State<_AddVariantsSheet> createState() => _AddVariantsSheetState();
}

class _AddVariantsSheetState extends State<_AddVariantsSheet> {
  late final Set<String> _existingSizes;
  late final List<String> _existingColors;
  late final bool _hasSizeAxis;
  late final bool _hasColorAxis;
  final Set<String> _newSizes = {};
  final List<String> _newColors = [];
  final _customSize = TextEditingController();
  final _colorInput = TextEditingController();

  @override
  void initState() {
    super.initState();
    _existingSizes =
        widget.existing.map((v) => v.size).whereType<String>().toSet();
    _existingColors = [];
    for (final v in widget.existing) {
      final c = v.color;
      if (c != null && !_existingColors.contains(c)) _existingColors.add(c);
    }
    _hasSizeAxis = _existingSizes.isNotEmpty;
    _hasColorAxis = _existingColors.isNotEmpty;
  }

  @override
  void dispose() {
    _customSize.dispose();
    _colorInput.dispose();
    super.dispose();
  }

  /// Sizes still missing from the style's preset run, plus any custom ones
  /// typed here.
  List<String> get _offeredSizes {
    final preset = sizePresetByKey(widget.style.sizeSet);
    final fromPreset = preset?.sizes ?? const <String>[];
    final extra = _newSizes.where((s) => !fromPreset.contains(s));
    return [
      ...fromPreset.where((s) => !_existingSizes.contains(s)),
      ...extra,
    ];
  }

  /// New cells = (new sizes × all colours) ∪ (all sizes × new colours),
  /// deduplicated. A style without a size axis keeps size null, and likewise
  /// for colour.
  List<VariantDraft> get _drafts {
    final sizes = <String?>[
      if (_hasSizeAxis || _newSizes.isNotEmpty) ...[
        ..._existingSizes,
        ..._newSizes,
      ] else
        null,
    ];
    final colors = <String?>[
      if (_hasColorAxis || _newColors.isNotEmpty) ...[
        ..._existingColors,
        ..._newColors,
      ] else
        null,
    ];
    final live = widget.existing
        .map((v) => variantCellKey(v.size, v.color))
        .toSet();
    return [
      for (final color in colors)
        for (final size in sizes)
          if (!live.contains(variantCellKey(size, color)))
            VariantDraft(size: size, color: color),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final drafts = _drafts;
    return SuuqSheet(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.addVariantsTitle, style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(l.addVariantsSizesHint, style: theme.textTheme.bodySmall),
          const SizedBox(height: SuuqSpacing.md),
          Wrap(
            spacing: SuuqSpacing.xs,
            runSpacing: SuuqSpacing.xs,
            children: [
              for (final size in _existingSizes)
                FilterChip(label: Text(size), selected: true, onSelected: null),
              for (final size in _offeredSizes)
                FilterChip(
                  label: Text(size),
                  selected: _newSizes.contains(size),
                  onSelected: (on) => setState(() {
                    if (on) {
                      _newSizes.add(size);
                    } else {
                      _newSizes.remove(size);
                    }
                  }),
                ),
            ],
          ),
          const SizedBox(height: SuuqSpacing.sm),
          TextField(
            controller: _customSize,
            onSubmitted: (_) => _addCustomSize(),
            decoration: InputDecoration(
              labelText: l.styleCustomSizesLabel,
              hintText: l.styleCustomSizesHint,
              suffixIcon: IconButton(
                icon: const Icon(Icons.add_rounded),
                onPressed: _addCustomSize,
              ),
            ),
          ),
          const SizedBox(height: SuuqSpacing.md),
          Text(
            l.styleColorsLabel.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
          ),
          const SizedBox(height: SuuqSpacing.xs),
          if (_existingColors.isNotEmpty)
            Wrap(
              spacing: SuuqSpacing.xs,
              runSpacing: SuuqSpacing.xs,
              children: [
                for (final c in _existingColors)
                  FilterChip(label: Text(c), selected: true, onSelected: null),
              ],
            ),
          const SizedBox(height: SuuqSpacing.xs),
          ColorChipsField(
            colors: _newColors,
            input: _colorInput,
            onAdd: (c) => setState(() {
              if (!_existingColors.contains(c)) _newColors.add(c);
            }),
            onRemove: (c) => setState(() => _newColors.remove(c)),
          ),
          const SizedBox(height: SuuqSpacing.lg),
          FilledButton(
            onPressed: drafts.isEmpty
                ? null
                : () => Navigator.pop(context, drafts),
            child: Text(
              drafts.isEmpty
                  ? l.addVariantsNone
                  : l.addVariantsApply(drafts.length),
            ),
          ),
        ],
      ),
    );
  }

  void _addCustomSize() {
    for (final s in parseCustomSizes(_customSize.text)) {
      if (!_existingSizes.contains(s)) _newSizes.add(s);
    }
    _customSize.clear();
    setState(() {});
  }
}

// ---------------------------------------------------------------------------
// Edit style
// ---------------------------------------------------------------------------

class StyleEditResult {
  const StyleEditResult({
    required this.name,
    required this.defaultSellingPrice,
    required this.defaultPurchasePrice,
    required this.applyPriceToVariants,
    this.brand,
    this.category,
    this.segment,
    this.imageUrl,
    this.skuPrefix,
  });
  final String name;
  final String? brand;
  final String? category;
  final String? segment;
  final String? imageUrl;
  final Decimal defaultSellingPrice;
  final Decimal defaultPurchasePrice;
  final String? skuPrefix;

  /// Mark-down: push the new default price to every live variant.
  final bool applyPriceToVariants;
}

Future<StyleEditResult?> showStyleEditSheet(
  BuildContext context, {
  required Style style,
  required bool isOwner,
}) {
  return showModalBottomSheet<StyleEditResult>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _StyleEditSheet(style: style, isOwner: isOwner),
  );
}

class _StyleEditSheet extends ConsumerStatefulWidget {
  const _StyleEditSheet({required this.style, required this.isOwner});
  final Style style;
  final bool isOwner;

  @override
  ConsumerState<_StyleEditSheet> createState() => _StyleEditSheetState();
}

class _StyleEditSheetState extends ConsumerState<_StyleEditSheet> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.style.name);
  late final _brand = TextEditingController(text: widget.style.brand ?? '');
  late final _category =
      TextEditingController(text: widget.style.category ?? '');
  late final _selling = TextEditingController(
    text: widget.style.defaultSellingPrice.toString(),
  );
  late final _cost = TextEditingController(
    text: widget.isOwner ? widget.style.defaultPurchasePrice.toString() : '',
  );
  final _minPrice = TextEditingController();
  late final _skuPrefix =
      TextEditingController(text: widget.style.skuPrefix ?? '');
  late String? _segment = widget.style.segment;
  late String? _imageUrl = widget.style.imageUrl;
  bool _applyPrice = false;

  @override
  void dispose() {
    for (final c in [
      _name,
      _brand,
      _category,
      _selling,
      _cost,
      _minPrice,
      _skuPrefix,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final categories =
        ref.watch(watchCategoriesProvider).valueOrNull ?? const <String>[];
    return SuuqSheet(
      child: Form(
        key: _form,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.styleEditTitle, style: theme.textTheme.titleLarge),
            const SizedBox(height: SuuqSpacing.md),
            TextFormField(
              controller: _name,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(labelText: l.productNameLabel),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? l.commonRequired : null,
            ),
            const SizedBox(height: SuuqSpacing.sm),
            TextFormField(
              controller: _brand,
              decoration: InputDecoration(labelText: l.styleBrandLabel),
            ),
            const SizedBox(height: SuuqSpacing.sm),
            CategoryField(controller: _category, categories: categories),
            const SizedBox(height: SuuqSpacing.sm),
            SegmentChips(
              value: _segment,
              onChanged: (v) => setState(() => _segment = v),
            ),
            const SizedBox(height: SuuqSpacing.md),
            // The per-variant floor lives on each product; the style sheet
            // only edits the shared prices, so the floor field is hidden here.
            StylePriceFields(
              selling: _selling,
              cost: _cost,
              minPrice: _minPrice,
              showCost: widget.isOwner,
              showMinPrice: false,
            ),
            // Mark-down is owner-only server-side (`_style_update` answers
            // `forbidden`), so a cashier must not be offered a switch whose
            // effect would revert at the next sync.
            if (widget.isOwner)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l.styleApplyPriceToVariants),
                subtitle: Text(l.styleApplyPriceHelper),
                value: _applyPrice,
                onChanged: (v) => setState(() => _applyPrice = v),
              ),
            const SizedBox(height: SuuqSpacing.sm),
            TextFormField(
              controller: _skuPrefix,
              textCapitalization: TextCapitalization.characters,
              maxLength: 8,
              decoration: InputDecoration(
                labelText: l.styleSkuPrefixLabel,
                helperText: l.styleSkuPrefixHelper,
                counterText: '',
              ),
            ),
            const SizedBox(height: SuuqSpacing.md),
            ProductPhotoField(
              previewName: _name.text.trim().isEmpty
                  ? l.productImagePreviewName
                  : _name.text.trim(),
              imageUrl: _imageUrl,
              onChanged: (url) => setState(() => _imageUrl = url),
            ),
            const SizedBox(height: SuuqSpacing.lg),
            FilledButton(
              onPressed: () {
                if (!_form.currentState!.validate()) return;
                Navigator.pop(
                  context,
                  StyleEditResult(
                    name: _name.text.trim(),
                    brand: _brand.text.trim(),
                    category: _category.text.trim(),
                    segment: _segment,
                    imageUrl: _imageUrl,
                    defaultSellingPrice: Decimal.parse(_selling.text.trim()),
                    defaultPurchasePrice: widget.isOwner
                        ? (Decimal.tryParse(_cost.text.trim()) ?? Decimal.zero)
                        : widget.style.defaultPurchasePrice,
                    skuPrefix: _skuPrefix.text.trim(),
                    applyPriceToVariants: widget.isOwner && _applyPrice,
                  ),
                );
              },
              child: Text(l.commonSaveChanges),
            ),
          ],
        ),
      ),
    );
  }
}
