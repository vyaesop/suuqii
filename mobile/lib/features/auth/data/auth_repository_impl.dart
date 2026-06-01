import 'package:suuqii/core/http/dio_client.dart';
import 'package:suuqii/features/auth/data/auth_local_data_source.dart';
import 'package:suuqii/features/auth/data/auth_remote_data_source.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';

class AuthRepository {
  AuthRepository({
    required this.remote,
    required this.local,
    required this.tokens,
  });
  final AuthRemoteDataSource remote;
  final AuthLocalDataSource local;
  final TokenStore tokens;

  Future<Authenticated> login({
    required String phone,
    required String password,
    required String deviceFingerprint,
    String? deviceLabel,
  }) async {
    final res = await remote.login(
      phone: phone,
      password: password,
      deviceFingerprint: deviceFingerprint,
      deviceLabel: deviceLabel,
    );
    return _applyBundle(res, phone);
  }

  Future<Authenticated> registerShop({
    required String shopName,
    required String ownerName,
    required String phone,
    required String password,
    required String ownerPin,
    required String deviceFingerprint,
    String locale = 'en',
    String shopType = 'regular',
  }) async {
    final res = await remote.registerShop(
      shopName: shopName,
      ownerName: ownerName,
      phone: phone,
      password: password,
      ownerPin: ownerPin,
      deviceFingerprint: deviceFingerprint,
      locale: locale,
      shopType: shopType,
    );
    return _applyBundle(res, phone, shopName: shopName, userName: ownerName);
  }

  Future<Authenticated?> resume() async {
    final refresh = await local.readRefresh();
    final p = local.readProfile();
    if (refresh == null || p == null) {
      if (refresh != null || p != null) {
        await local.clear();
      }
      return null;
    }
    return Authenticated(
      userId: p.userId,
      shopId: p.shopId,
      role: p.role,
      userName: p.userName,
      shopName: p.shopName,
      shopType: p.shopType,
      accessToken: '',
    );
  }

  Future<Authenticated> acceptInvite({
    required String phone,
    required String inviteCode,
    required String password,
    required String deviceFingerprint,
  }) async {
    final res = await remote.acceptInvite(
      phone: phone,
      inviteCode: inviteCode,
      password: password,
      deviceFingerprint: deviceFingerprint,
    );
    // Server now returns shop_name in the bundle; pass it through so invited
    // cashiers see the correct shop name after every app restart.
    final shopName = res['shop_name'] as String?;
    return _applyBundle(res, phone, shopName: shopName);
  }

  Future<String> verifyOwnerPin(String pin) => remote.verifyOwnerPin(pin);

  Future<void> logout() async {
    tokens.access = null;
    await local.clear();
  }

  Future<Authenticated> _applyBundle(
    Map<String, dynamic> bundle,
    String phone, {
    String? shopName,
    String? userName,
  }) async {
    final access = bundle['access'] as String;
    final refresh = bundle['refresh'] as String;
    final userId = bundle['user_id'] as String;
    final shopId = bundle['shop_id'] as String;
    final role = bundle['role'] as String;
    final shopType = (bundle['shop_type'] as String?) ?? 'regular';

    tokens.access = access;
    await local.saveTokens(refresh: refresh);
    await local.saveProfile(
      userId: userId,
      shopId: shopId,
      role: role,
      userName: userName,
      shopName: shopName,
      shopType: shopType,
    );
    return Authenticated(
      userId: userId,
      shopId: shopId,
      role: role,
      userName: userName ?? phone,
      shopName: shopName ?? '',
      shopType: shopType,
      accessToken: access,
    );
  }
}
