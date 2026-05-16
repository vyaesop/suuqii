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
  });

  final String userId;
  final String shopId;
  final String role;
  final String userName;
  final String shopName;
  final String accessToken;
}
