import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/sales/domain/entities/sale_return.dart';

part 'exchange_controller.g.dart';

/// The exchange the POS is currently settling, or null in ordinary selling.
///
/// Set by the return sheet when the cashier picks **Exchange**, read by the
/// cart bar (banner), the review sheet (no extra discount — the credit *is*
/// the discount) and the checkout sheet (customer pays / refund), cleared by
/// a successful checkout or an explicit cancel. Kept alive: the sheet lives
/// on the sale-detail route and the POS on another, so an autoDispose
/// provider would forget the exchange during navigation.
@Riverpod(keepAlive: true)
class ExchangeMode extends _$ExchangeMode {
  @override
  ExchangeContext? build() {
    // keepAlive outlives logout and shop switching, both of which wipe the
    // local database — an exchange carried into another shop would settle
    // against a sale id that no longer exists there (`not_found` on every
    // checkout). Watching the session's shop id rebuilds, and so clears,
    // this provider exactly then; selecting only the id keeps an unrelated
    // auth change (a renamed shop) from dropping an exchange in progress.
    ref.watch(
      authControllerProvider.select((auth) {
        final value = auth.valueOrNull;
        return value is Authenticated ? value.shopId : null;
      }),
    );
    return null;
  }

  ExchangeContext? get current => state;

  /// Enter exchange mode for [context]; assign null (or [clear]) to leave.
  set current(ExchangeContext? context) => state = context;

  void clear() => state = null;
}
