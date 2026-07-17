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

    // Decode at the rendered size, not full resolution: thumbnails are
    // ~44-180 logical px, and decoding a full camera photo per tile is a
    // real memory/jank source on 1-2GB RAM phones.
    final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 2.0;

    return LayoutBuilder(
      builder: (context, constraints) {
        final logicalWidth = size ??
            (constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : _kFallbackLogicalWidth);
        final memCacheWidth =
            (logicalWidth * dpr).round().clamp(_kMinDecodePx, _kMaxDecodePx);
        return ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: CachedNetworkImage(
            imageUrl: imageUrl!,
            width: size,
            height: size,
            fit: BoxFit.cover,
            memCacheWidth: memCacheWidth,
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
      },
    );
  }

  /// Assumed logical width when the parent gives unbounded constraints.
  static const double _kFallbackLogicalWidth = 180;

  /// Decode bounds in physical pixels: floor keeps tiny thumbs legible,
  /// cap bounds memory (640px covers a ~180dp tile on a 3.5x screen).
  static const int _kMinDecodePx = 32;
  static const int _kMaxDecodePx = 640;

  double _hueFromName(String s) {
    if (s.isEmpty) return 200;
    var hash = 0;
    for (final code in s.codeUnits) {
      hash = (hash * 31 + code) & 0x7fffffff;
    }
    return (hash % 360).toDouble();
  }
}
