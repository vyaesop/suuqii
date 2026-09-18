import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/l10n.dart';

/// Section header + children, the same look as the product form's sections.
class StyleFormSection extends StatelessWidget {
  const StyleFormSection({
    required this.title,
    required this.children,
    this.trailing,
    super.key,
  });
  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: SuuqSpacing.xs),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title.toUpperCase(),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        letterSpacing: 1.2,
                      ),
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
        ),
        ...children,
      ],
    );
  }
}

/// Selling price, cost (owner only) and optional floor price for a style.
class StylePriceFields extends StatelessWidget {
  const StylePriceFields({
    required this.selling,
    required this.cost,
    required this.minPrice,
    required this.showCost,
    this.showMinPrice = true,
    super.key,
  });

  final TextEditingController selling;
  final TextEditingController cost;
  final TextEditingController minPrice;

  /// Cost is owner-only data (masked for cashiers on the wire too).
  final bool showCost;

  /// The floor lives per variant; the style edit sheet hides it.
  final bool showMinPrice;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    String? decimal(String? v) {
      if (v == null || v.trim().isEmpty) return l.commonRequired;
      final d = double.tryParse(v.trim());
      if (d == null || d < 0) return l.productInvalidNumber;
      return null;
    }

    String? optionalDecimal(String? v) {
      if (v == null || v.trim().isEmpty) return null;
      final d = double.tryParse(v.trim());
      if (d == null || d < 0) return l.productInvalidNumber;
      return null;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (showCost) ...[
              Expanded(
                child: TextFormField(
                  controller: cost,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: l.productPurchaseLabel,
                    prefixText: 'ETB  ',
                  ),
                  validator: optionalDecimal,
                ),
              ),
              const SizedBox(width: SuuqSpacing.sm),
            ],
            Expanded(
              child: TextFormField(
                controller: selling,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: l.productSellingPriceLabel,
                  prefixText: 'ETB  ',
                ),
                validator: decimal,
              ),
            ),
          ],
        ),
        if (showMinPrice) ...[
          const SizedBox(height: SuuqSpacing.sm),
          TextFormField(
            controller: minPrice,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: l.productMinPriceLabel,
              helperText: l.productMinPriceHelper,
              prefixText: 'ETB  ',
            ),
            validator: optionalDecimal,
          ),
        ],
      ],
    );
  }
}

/// Free-text colour entry rendered as removable chips. Ethiopic input is
/// welcome ("ቀይ", "ጥቁር") — search folding already handles it.
class ColorChipsField extends StatelessWidget {
  const ColorChipsField({
    required this.colors,
    required this.input,
    required this.onAdd,
    required this.onRemove,
    super.key,
  });

  final List<String> colors;
  final TextEditingController input;
  final ValueChanged<String> onAdd;
  final ValueChanged<String> onRemove;

  void _submit() {
    final value = input.text.trim();
    if (value.isEmpty || colors.contains(value)) {
      input.clear();
      return;
    }
    onAdd(value);
    input.clear();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: input,
          textCapitalization: TextCapitalization.words,
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: l.styleColorLabel,
            hintText: l.styleColorHint,
            suffixIcon: IconButton(
              icon: const Icon(Icons.add_rounded),
              tooltip: l.commonAdd,
              onPressed: _submit,
            ),
          ),
        ),
        if (colors.isNotEmpty) ...[
          const SizedBox(height: SuuqSpacing.xs),
          Wrap(
            spacing: SuuqSpacing.xs,
            runSpacing: SuuqSpacing.xs,
            children: [
              for (final color in colors)
                InputChip(
                  label: Text(color),
                  onDeleted: () => onRemove(color),
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// Compact whole-number cell for the matrix grids (starting qty, receive).
class QuantityCell extends StatelessWidget {
  const QuantityCell({required this.controller, this.hint, super.key});
  final TextEditingController controller;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      textAlign: TextAlign.center,
      decoration: InputDecoration(
        isDense: true,
        hintText: hint ?? '0',
        contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        border: const OutlineInputBorder(),
      ),
    );
  }
}
