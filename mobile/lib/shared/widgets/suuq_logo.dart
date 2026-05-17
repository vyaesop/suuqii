import 'package:flutter/material.dart';

/// Tiny SVG-less wordmark: a square forest-green tile with the letter "s"
/// and the wordmark beside it. Quiet, recognisable.
class SuuqLogo extends StatelessWidget {
  const SuuqLogo({super.key, this.size = 32});
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: scheme.primary,
            borderRadius: BorderRadius.circular(size * 0.28),
          ),
          alignment: Alignment.center,
          child: Text(
            's',
            style: TextStyle(
              color: scheme.onPrimary,
              fontSize: size * 0.65,
              fontWeight: FontWeight.w700,
              height: 1,
            ),
          ),
        ),
        SizedBox(width: size * 0.32),
        Text(
          'suuqii',
          style: TextStyle(
            color: scheme.onSurface,
            fontSize: size * 0.72,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.5,
          ),
        ),
      ],
    );
  }
}

/// Background glyph for empty/large surfaces — a faint version of the tile.
class SuuqMark extends StatelessWidget {
  const SuuqMark({super.key, this.size = 56});
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(size * 0.26),
      ),
      alignment: Alignment.center,
      child: Text(
        's',
        style: TextStyle(
          color: scheme.onPrimary,
          fontSize: size * 0.6,
          fontWeight: FontWeight.w700,
          height: 1,
        ),
      ),
    );
  }
}
