import 'package:flutter/material.dart';

import 'package:suuqii/app/theme/tokens.dart';

/// The little grab handle at the top of every modal bottom sheet.
class SheetHandle extends StatelessWidget {
  const SheetHandle({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: SuuqSpacing.xs),
      child: Center(
        child: Container(
          width: 36,
          height: 4,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.outlineVariant,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ),
    );
  }
}

/// A bottom sheet scaffold that gives every sheet the same dressing:
/// drag handle, safe-area, keyboard padding, and a content slot.
class SuuqSheet extends StatelessWidget {
  const SuuqSheet({required this.child, super.key, this.padding});
  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SheetHandle(),
            Flexible(
              child: SingleChildScrollView(
                padding: padding ??
                    const EdgeInsets.fromLTRB(
                      SuuqSpacing.lg, SuuqSpacing.sm,
                      SuuqSpacing.lg, SuuqSpacing.lg,
                    ),
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
