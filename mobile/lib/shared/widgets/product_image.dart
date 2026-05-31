import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'package:suuqii/app/theme/tokens.dart';

/// Square product thumbnail. Falls back to a colored badge with the
/// product's initial when no image is available or loading fails.
class ProductImage extends StatelessWidget {
  const ProductImage({
    required this.name,
    this.imageUrl,
    this.size,
    this.radius = SuuqRadius.md,
    super.key,
  });

  final String name;
  final String? imageUrl;
  final double? size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hue = _hueFromName(name);
    final bg = HSLColor.fromAHSL(1, hue, 0.18, 0.86).toColor();
    final fg = HSLColor.fromAHSL(1, hue, 0.42, 0.32).toColor();

    final fallback = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(radius),
      ),
      alignment: Alignment.center,
      child: Text(
        name.isEmpty ? '?' : name.characters.first.toUpperCase(),
        style: TextStyle(
          color: fg,
          fontWeight: FontWeight.w700,
          fontSize: (size ?? 56) * 0.42,
        ),
      ),
    );

    if (imageUrl == null || imageUrl!.isEmpty) return fallback;

    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: CachedNetworkImage(
        imageUrl: imageUrl!,
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorWidget: (_, __, ___) => fallback,
        placeholder: (_, __) => Container(
          width: size,
          height: size,
          color: scheme.surfaceContainerHighest,
          alignment: Alignment.center,
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }

  double _hueFromName(String s) {
    if (s.isEmpty) return 200;
    var hash = 0;
    for (final code in s.codeUnits) {
      hash = (hash * 31 + code) & 0x7fffffff;
    }
    return (hash % 360).toDouble();
  }
}
