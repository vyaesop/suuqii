import 'package:flutter/material.dart';

import 'package:suuqii/app/theme/tokens.dart';

/// Sizes as columns × colours as rows, horizontally scrollable. The three
/// boutique surfaces (wizard preview, receive sheet, style screen) share this
/// so a size run always reads the same way. A null size or colour means the
/// style has no such dimension and that axis collapses to one unlabeled
/// column/row.
class VariantMatrix extends StatelessWidget {
  const VariantMatrix({
    required this.sizes,
    required this.colors,
    required this.cellBuilder,
    this.cellWidth = 72,
    this.labelWidth = 96,
    super.key,
  });

  final List<String?> sizes;
  final List<String?> colors;
  final Widget Function(BuildContext context, String? size, String? color)
      cellBuilder;
  final double cellWidth;
  final double labelWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final showSizeHeader = sizes.any((s) => s != null);
    final showColorLabels = colors.any((c) => c != null);
    final headerStyle = theme.textTheme.labelMedium?.copyWith(
      fontWeight: FontWeight.w700,
      color: scheme.onSurfaceVariant,
    );

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: FixedColumnWidth(cellWidth),
        columnWidths: {
          if (showColorLabels) 0: FixedColumnWidth(labelWidth),
        },
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        children: [
          if (showSizeHeader)
            TableRow(
              children: [
                if (showColorLabels) const SizedBox.shrink(),
                for (final size in sizes)
                  Padding(
                    padding: const EdgeInsets.all(SuuqSpacing.xxs),
                    child: Text(
                      size ?? '',
                      textAlign: TextAlign.center,
                      style: headerStyle,
                    ),
                  ),
              ],
            ),
          for (final color in colors)
            TableRow(
              children: [
                if (showColorLabels)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: SuuqSpacing.xs,
                      vertical: SuuqSpacing.xxs,
                    ),
                    child: Text(
                      color ?? '',
                      style: headerStyle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                for (final size in sizes)
                  Padding(
                    padding: const EdgeInsets.all(SuuqSpacing.xxs),
                    child: cellBuilder(context, size, color),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

/// Key for per-cell state maps: `"32|Blue"`, `"|Blue"`, `"32|"`.
String variantCellKey(String? size, String? color) => '${size ?? ''}|${color ?? ''}';
