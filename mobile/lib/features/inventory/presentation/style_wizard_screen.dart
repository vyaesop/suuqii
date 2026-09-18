import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/shop_type/size_presets.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/data/products_repository.dart';
import 'package:suuqii/features/inventory/data/styles_repository.dart';
import 'package:suuqii/features/inventory/domain/entities/style.dart';
import 'package:suuqii/features/inventory/presentation/widgets/category_field.dart';
import 'package:suuqii/features/inventory/presentation/widgets/product_photo_field.dart';
import 'package:suuqii/features/inventory/presentation/widgets/style_form_fields.dart';
import 'package:suuqii/features/inventory/presentation/widgets/variant_matrix.dart';
import 'package:suuqii/shared/widgets/owner_pin_dialog.dart';

/// Create a style with its whole size × colour matrix in one go
/// (docs/19-boutique-shop-type.md §6.2). One scrolling screen: identity,
/// prices, size preset, colours, then a preview grid with optional starting
/// quantities. Saving emits one `style.create` plus a `stock.receive` per
/// non-zero cell, all in one local transaction.
class StyleWizardScreen extends ConsumerStatefulWidget {
  const StyleWizardScreen({super.key});

  @override
  ConsumerState<StyleWizardScreen> createState() => _StyleWizardScreenState();
}

class _StyleWizardScreenState extends ConsumerState<StyleWizardScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _brand = TextEditingController();
  final _category = TextEditingController();
  final _selling = TextEditingController();
  final _cost = TextEditingController();
  final _minPrice = TextEditingController();
  final _skuPrefix = TextEditingController();
  final _threshold = TextEditingController(text: '1');
  final _customSizes = TextEditingController();
  final _colorInput = TextEditingController();
  final _openingCost = TextEditingController();

  String? _segment;
  String? _imageUrl;
  SizePreset _preset = letterSizes;

  /// Sizes the owner kept from the preset (they deselect what they did not
  /// buy). Reset when the preset changes.
  late Set<String> _selectedSizes = _preset.sizes.toSet();
  final List<String> _colors = [];

  /// Starting quantity per cell, keyed by [variantCellKey]. Controllers are
  /// created lazily and kept across matrix changes so typed values survive
  /// adding a colour.
  final Map<String, TextEditingController> _qty = {};
  bool _busy = false;

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
      _threshold,
      _customSizes,
      _colorInput,
      _openingCost,
      ..._qty.values,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// The size axis: preset selection in run order, custom sizes as typed,
  /// or a single null entry for a free-size style (no size dimension).
  List<String?> get _sizes {
    if (_preset.key == customSizes.key) {
      final parsed = parseCustomSizes(_customSizes.text);
      return parsed.isEmpty ? const [null] : parsed;
    }
    if (!_preset.hasFixedSizes) return const [null];
    final kept = _preset.sizes.where(_selectedSizes.contains).toList();
    return kept.isEmpty ? const [null] : kept;
  }

  /// The colour axis, or a single null entry when the style is not split by
  /// colour.
  List<String?> get _colorAxis => _colors.isEmpty ? const [null] : _colors;

  int get _variantCount => _sizes.length * _colorAxis.length;

  /// A matrix the server would refuse (`invalid_payload`), which the
  /// reconciler answers by soft-deleting the style and every variant — so the
  /// count is flagged and saving is blocked here instead.
  bool get _overCap => _variantCount > maxVariantsPerStyle;

  TextEditingController _qtyController(String? size, String? color) =>
      _qty.putIfAbsent(
        variantCellKey(size, color),
        TextEditingController.new,
      );

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final isOwner = auth is Authenticated && auth.isOwner;
    final categories =
        ref.watch(watchCategoriesProvider).valueOrNull ?? const <String>[];

    return Scaffold(
      appBar: AppBar(title: Text(l.styleWizardTitle)),
      body: SafeArea(
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              SuuqSpacing.lg,
              SuuqSpacing.sm,
              SuuqSpacing.lg,
              100,
            ),
            children: [
              StyleFormSection(
                title: l.productSectionDetails,
                children: [
                  TextFormField(
                    controller: _name,
                    onChanged: (_) => setState(() {}),
                    textCapitalization: TextCapitalization.sentences,
                    decoration: InputDecoration(labelText: l.productNameLabel),
                    validator: _required,
                  ),
                  const SizedBox(height: SuuqSpacing.sm),
                  TextFormField(
                    controller: _brand,
                    textCapitalization: TextCapitalization.words,
                    decoration: InputDecoration(labelText: l.styleBrandLabel),
                  ),
                  const SizedBox(height: SuuqSpacing.sm),
                  CategoryField(controller: _category, categories: categories),
                  const SizedBox(height: SuuqSpacing.sm),
                  SegmentChips(
                    value: _segment,
                    onChanged: (v) => setState(() => _segment = v),
                  ),
                ],
              ),
              const SizedBox(height: SuuqSpacing.lg),
              StyleFormSection(
                title: l.productSectionPricing,
                children: [
                  StylePriceFields(
                    selling: _selling,
                    cost: _cost,
                    minPrice: _minPrice,
                    showCost: isOwner,
                  ),
                  const SizedBox(height: SuuqSpacing.sm),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _skuPrefix,
                          textCapitalization: TextCapitalization.characters,
                          maxLength: 8,
                          decoration: InputDecoration(
                            labelText: l.styleSkuPrefixLabel,
                            helperText: l.styleSkuPrefixHelper,
                            counterText: '',
                          ),
                        ),
                      ),
                      const SizedBox(width: SuuqSpacing.sm),
                      Expanded(
                        child: TextFormField(
                          controller: _threshold,
                          keyboardType: TextInputType.number,
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
              StyleFormSection(
                title: l.styleSizeSetLabel,
                children: [
                  Wrap(
                    spacing: SuuqSpacing.xs,
                    runSpacing: SuuqSpacing.xs,
                    children: [
                      for (final preset in sizePresets)
                        ChoiceChip(
                          label: Text(sizePresetLabel(l, preset.key)),
                          selected: _preset.key == preset.key,
                          onSelected: (_) => setState(() {
                            _preset = preset;
                            _selectedSizes = preset.sizes.toSet();
                          }),
                        ),
                    ],
                  ),
                  if (_preset.hasFixedSizes) ...[
                    const SizedBox(height: SuuqSpacing.sm),
                    Text(
                      l.styleSizesDeselectHint,
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: SuuqSpacing.xs),
                    Wrap(
                      spacing: SuuqSpacing.xs,
                      runSpacing: SuuqSpacing.xs,
                      children: [
                        for (final size in _preset.sizes)
                          FilterChip(
                            label: Text(size),
                            selected: _selectedSizes.contains(size),
                            onSelected: (on) => setState(() {
                              if (on) {
                                _selectedSizes.add(size);
                              } else {
                                _selectedSizes.remove(size);
                              }
                            }),
                          ),
                      ],
                    ),
                  ],
                  if (_preset.key == customSizes.key) ...[
                    const SizedBox(height: SuuqSpacing.sm),
                    TextFormField(
                      controller: _customSizes,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        labelText: l.styleCustomSizesLabel,
                        hintText: l.styleCustomSizesHint,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: SuuqSpacing.lg),
              StyleFormSection(
                title: l.styleColorsLabel,
                children: [
                  ColorChipsField(
                    colors: _colors,
                    input: _colorInput,
                    onAdd: (c) => setState(() => _colors.add(c)),
                    onRemove: (c) => setState(() => _colors.remove(c)),
                  ),
                ],
              ),
              const SizedBox(height: SuuqSpacing.lg),
              StyleFormSection(
                title: l.productSectionImage,
                children: [
                  ProductPhotoField(
                    previewName: _name.text.trim().isEmpty
                        ? l.productImagePreviewName
                        : _name.text.trim(),
                    imageUrl: _imageUrl,
                    onChanged: (url) => setState(() => _imageUrl = url),
                  ),
                ],
              ),
              const SizedBox(height: SuuqSpacing.lg),
              StyleFormSection(
                title: l.stylePreviewTitle,
                trailing: Text(
                  l.styleVariantCount(_variantCount),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: _overCap
                        ? theme.colorScheme.error
                        : theme.colorScheme.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                children: [
                  Text(
                    _overCap
                        ? l.styleVariantCapError(maxVariantsPerStyle)
                        : l.stylePreviewHint,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: _overCap ? theme.colorScheme.error : null,
                    ),
                  ),
                  const SizedBox(height: SuuqSpacing.xs),
                  VariantMatrix(
                    sizes: _sizes,
                    colors: _colorAxis,
                    cellBuilder: (_, size, color) => QuantityCell(
                      controller: _qtyController(size, color),
                    ),
                  ),
                  const SizedBox(height: SuuqSpacing.sm),
                  TextFormField(
                    controller: _openingCost,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(
                      labelText: l.styleOpeningCostLabel,
                      helperText: l.styleOpeningCostHelper,
                      prefixText: 'ETB  ',
                    ),
                    validator: _optionalDecimal,
                  ),
                ],
              ),
            ],
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
            label: Text(l.styleCreateButton),
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

  Future<void> _save({required bool isOwner}) async {
    if (!_form.currentState!.validate()) return;
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    if (_overCap) {
      messenger.showSnackBar(
        SnackBar(content: Text(l.styleVariantCapError(maxVariantsPerStyle))),
      );
      return;
    }
    final router = GoRouter.of(context);

    final drafts = <VariantDraft>[
      for (final color in _colorAxis)
        for (final size in _sizes)
          VariantDraft(
            size: size,
            color: color,
            openingQty: Decimal.tryParse(
              _qty[variantCellKey(size, color)]?.text.trim() ?? '',
            ),
          ),
    ];
    final cost = isOwner
        ? Decimal.tryParse(_cost.text.trim()) ?? Decimal.zero
        : Decimal.zero;
    final openingCost = Decimal.tryParse(_openingCost.text.trim());

    // style.create is sensitive server-side: cashiers need the owner PIN
    // upfront so the queued event carries the challenge (same as new product).
    String? challenge;
    if (!isOwner) {
      challenge = await requestOwnerChallenge(context, ref);
      if (challenge == null) return;
    }

    setState(() => _busy = true);
    try {
      final style = await ref.read(stylesRepositoryProvider).createStyle(
            name: _name.text,
            brand: _brand.text,
            category: _category.text,
            segment: _segment,
            imageUrl: _imageUrl,
            defaultSellingPrice: Decimal.parse(_selling.text.trim()),
            defaultPurchasePrice: cost,
            minSellingPrice: Decimal.tryParse(_minPrice.text.trim()),
            sizeSet: _preset.key,
            skuPrefix: _skuPrefix.text,
            lowStockThreshold: Decimal.parse(_threshold.text.trim()),
            variants: drafts,
            // A cashier cannot see cost, so the opening lots are valued at
            // whatever they typed on the invoice (0 if nothing), never at a
            // masked default.
            openingUnitCost: openingCost ?? (isOwner ? cost : Decimal.zero),
            ownerChallengeToken: challenge,
          );
      messenger.showSnackBar(
        SnackBar(content: Text(l.styleCreated(style.name))),
      );
      router.pop();
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(localizedErrorMessage(l, e))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// Display label for a size preset key.
String sizePresetLabel(AppLocalizations l, String key) => switch (key) {
      'letter' => l.sizePresetLetter,
      'numeric' => l.sizePresetNumeric,
      'waist' => l.sizePresetWaist,
      'shoe_eu' => l.sizePresetShoeEu,
      'kids_age' => l.sizePresetKidsAge,
      'free' => l.sizePresetFree,
      _ => l.sizePresetCustom,
    };

/// Display label for a style segment value.
String segmentLabel(AppLocalizations l, String segment) => switch (segment) {
      'men' => l.styleSegmentMen,
      'women' => l.styleSegmentWomen,
      'kids' => l.styleSegmentKids,
      'unisex' => l.styleSegmentUnisex,
      _ => segment,
    };

/// Segment chips shared by the wizard and the edit sheet.
class SegmentChips extends StatelessWidget {
  const SegmentChips({required this.value, required this.onChanged, super.key});
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Wrap(
      spacing: SuuqSpacing.xs,
      runSpacing: SuuqSpacing.xs,
      children: [
        for (final segment in styleSegments)
          ChoiceChip(
            label: Text(segmentLabel(l, segment)),
            selected: value == segment,
            onSelected: (on) => onChanged(on ? segment : null),
          ),
      ],
    );
  }
}
