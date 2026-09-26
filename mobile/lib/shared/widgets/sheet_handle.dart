import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
/// drag handle, safe-area, keyboard padding, a content slot, and a message
/// line for [showMessage].
class SuuqSheet extends StatefulWidget {
  const SuuqSheet({required this.child, super.key, this.padding});
  final Widget child;
  final EdgeInsetsGeometry? padding;

  static final Expando<_SuuqSheetState> _byRoute = Expando();

  /// Tells the user something from inside a sheet — typically why its
  /// primary button refused.
  ///
  /// Use this instead of a snackbar in any sheet. Sheets opened from tab
  /// screens sit *under* the shell Scaffold's snackbars, so a snackbar lands
  /// right on the sheet's bottom buttons and swallows the next tap (the
  /// "can't tap Confirm / New sale" reports). The message shows pinned under
  /// the grab handle instead.
  ///
  /// [context] may be any context inside the sheet's route, including the
  /// one of the widget that builds the [SuuqSheet]. Outside a [SuuqSheet]
  /// this falls back to a snackbar. [error] picks the styling: a refusal
  /// (default) or a neutral confirmation such as "copied".
  static void showMessage(
    BuildContext context,
    String message, {
    bool error = true,
  }) {
    final route = ModalRoute.of(context);
    final sheet = route == null ? null : _byRoute[route];
    if (sheet != null && sheet.mounted) {
      sheet._show(message, error: error);
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  State<SuuqSheet> createState() => _SuuqSheetState();
}

class _SuuqSheetState extends State<SuuqSheet> {
  ModalRoute<Object?>? _route;
  String? _message;
  bool _error = true;
  Timer? _clear;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != _route) {
      _unregister();
      _route = route;
      if (route != null) SuuqSheet._byRoute[route] = this;
    }
  }

  @override
  void dispose() {
    _clear?.cancel();
    _unregister();
    super.dispose();
  }

  void _unregister() {
    final route = _route;
    if (route != null && SuuqSheet._byRoute[route] == this) {
      SuuqSheet._byRoute[route] = null;
    }
  }

  void _show(String message, {required bool error}) {
    unawaited(
      error ? HapticFeedback.mediumImpact() : HapticFeedback.selectionClick(),
    );
    setState(() {
      _message = message;
      _error = error;
    });
    _clear?.cancel();
    _clear = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _message = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final message = _message;
    final bg = _error ? scheme.errorContainer : scheme.secondaryContainer;
    final fg = _error ? scheme.onErrorContainer : scheme.onSecondaryContainer;
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
              // The message floats over the top of the content rather than
              // taking a row of its own: growing the sheet would shove the
              // form down under the finger that is about to tap again.
              child: Stack(
                children: [
                  SingleChildScrollView(
                    padding: widget.padding ??
                        const EdgeInsets.fromLTRB(
                          SuuqSpacing.lg,
                          SuuqSpacing.sm,
                          SuuqSpacing.lg,
                          SuuqSpacing.lg,
                        ),
                    child: widget.child,
                  ),
                  Positioned(
                    top: SuuqSpacing.xs,
                    left: SuuqSpacing.lg,
                    right: SuuqSpacing.lg,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 150),
                      child: message == null
                          ? const SizedBox.shrink()
                          : Semantics(
                              key: ValueKey(message),
                              liveRegion: true,
                              child: Material(
                                color: bg,
                                elevation: 2,
                                borderRadius:
                                    BorderRadius.circular(SuuqRadius.sm),
                                child: InkWell(
                                  borderRadius:
                                      BorderRadius.circular(SuuqRadius.sm),
                                  onTap: () => setState(() => _message = null),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: SuuqSpacing.md,
                                      vertical: SuuqSpacing.sm,
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          _error
                                              ? Icons.error_outline_rounded
                                              : Icons
                                                  .check_circle_outline_rounded,
                                          size: 20,
                                          color: fg,
                                        ),
                                        const SizedBox(width: SuuqSpacing.sm),
                                        Expanded(
                                          child: Text(
                                            message,
                                            style: TextStyle(
                                              color: fg,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
