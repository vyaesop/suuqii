import 'package:flutter/material.dart';

/// Clears snackbars whenever a modal bottom sheet opens.
///
/// Tab screens live inside the go_router ShellRoute, so their sheets open on
/// the shell's nested navigator while the root ScaffoldMessenger paints
/// snackbars on the shell Scaffold — on top of its body. A floating snackbar
/// left over from the screen underneath ("Added to cart", "Exchange
/// recorded") therefore sits over the sheet's bottom buttons and swallows
/// the taps meant for "New sale", "Confirm" and the like.
///
/// One instance per navigator: a [NavigatorObserver] can only be attached to
/// a single [Navigator].
class SheetSnackBarObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is! ModalBottomSheetRoute) return;
    final context = navigator?.context;
    if (context == null) return;
    // Pushes can happen mid-build (declarative pages); clearing calls
    // setState on the messenger, so defer it to after the frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      context.findAncestorStateOfType<ScaffoldMessengerState>()
          ?.clearSnackBars();
    });
  }
}
