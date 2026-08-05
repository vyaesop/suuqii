import 'package:decimal/decimal.dart';

/// Server default for both shop thresholds (Shop.debt_threshold and
/// Shop.expense_approval_threshold): 500.00 birr as a decimal string.
const String kDefaultThreshold = '500.00';

sealed class AuthState {
  const AuthState();
}

final class Unknown extends AuthState {
  const Unknown();
}

final class Unauthenticated extends AuthState {
  const Unauthenticated();
}

final class Authenticated extends AuthState {
  const Authenticated({
    required this.userId,
    required this.shopId,
    required this.role,
    required this.userName,
    required this.shopName,
    required this.accessToken,
    this.shopType = 'regular',
    this.debtThreshold = kDefaultThreshold,
    this.expenseApprovalThreshold = kDefaultThreshold,
  });

  final String userId;
  final String shopId;
  final String role;
  final String userName;
  final String shopName;
  final String accessToken;
  final String shopType;

  /// Shop.debt_threshold as a decimal string (e.g. "500.00"). Credit sales
  /// pushing a customer's outstanding balance above this need owner approval.
  final String debtThreshold;

  /// Shop.expense_approval_threshold as a decimal string. Cashier expenses
  /// above this need the owner PIN.
  final String expenseApprovalThreshold;

  /// [debtThreshold] parsed for domain checks; falls back to the server
  /// default when the stored string is malformed.
  Decimal get debtThresholdValue =>
      Decimal.tryParse(debtThreshold) ?? Decimal.parse(kDefaultThreshold);

  /// [expenseApprovalThreshold] parsed for domain checks.
  Decimal get expenseApprovalThresholdValue =>
      Decimal.tryParse(expenseApprovalThreshold) ??
      Decimal.parse(kDefaultThreshold);

  Authenticated copyWith({
    String? shopName,
    String? debtThreshold,
    String? expenseApprovalThreshold,
  }) =>
      Authenticated(
        userId: userId,
        shopId: shopId,
        role: role,
        userName: userName,
        shopName: shopName ?? this.shopName,
        accessToken: accessToken,
        shopType: shopType,
        debtThreshold: debtThreshold ?? this.debtThreshold,
        expenseApprovalThreshold:
            expenseApprovalThreshold ?? this.expenseApprovalThreshold,
      );

  bool get isBakery => shopType == 'bakery';

  /// Owners see the full app; cashiers get the restricted surface described
  /// in docs/17-roles.md (owner-only routes hidden, sensitive ops PIN-gated).
  bool get isOwner => role == 'owner';

  /// Bakers produce and hand over. They never see money — mirrors
  /// `ROLE_CAPS[BAKER]` in backend/app/core/capabilities.py.
  bool get isBaker => role == 'baker';

  /// May take payment. False for bakers, which is why they get no POS tab.
  bool get canSell => isOwner || role == 'cashier';

  /// May see revenue, cost or margin anywhere in the UI.
  bool get canSeeMoney => canSell;

  /// May declare a handover to the counter (bakers, and owners covering).
  bool get canCreateHandover => isBaker || isOwner;

  /// May count in a handover. Deliberately disjoint from
  /// [canCreateHandover] for bakers: one person doing both collapses the two
  /// independent counts and the control is worth nothing. The server enforces
  /// this too — the UI is not a boundary.
  bool get canAcceptHandover => canSell;

  /// Landing route after login, by role.
  String get homeRoute => isBaker ? '/handover' : '/pos';
}
