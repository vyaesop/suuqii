import 'package:flutter/material.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/ethiopic.dart';

/// Category field with autocomplete from previously-used categories.
///
/// Allows free-form text entry while surfacing existing categories as
/// suggestions so the product list stays consistent without forcing a
/// predefined taxonomy on the user. Shared by the product form and the style
/// wizard.
class CategoryField extends StatelessWidget {
  const CategoryField({
    required this.controller,
    required this.categories,
    super.key,
  });

  final TextEditingController controller;
  final List<String> categories;

  @override
  Widget build(BuildContext context) {
    return Autocomplete<String>(
      initialValue: TextEditingValue(text: controller.text),
      optionsBuilder: (value) {
        // foldForSearch so Amharic homophone spellings match (ጸጉር/ፀጉር).
        final q = foldForSearch(value.text.trim());
        // Show all categories when the field is empty; otherwise filter.
        if (q.isEmpty) return categories;
        return categories.where((c) => foldForSearch(c).contains(q));
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
