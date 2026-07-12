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
  });

  final String userId;
  final String shopId;
  final String role;
  final String userName;
  final String shopName;
  final String accessToken;
  final String shopType;

  bool get isBakery => shopType == 'bakery';

  /// Owners see the full app; cashiers get the restricted surface described
  /// in docs/17-roles.md (owner-only routes hidden, sensitive ops PIN-gated).
  bool get isOwner => role == 'owner';
}
