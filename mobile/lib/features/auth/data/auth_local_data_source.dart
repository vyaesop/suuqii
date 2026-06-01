import 'package:shared_preferences/shared_preferences.dart';

import 'package:suuqii/core/storage/secure_storage.dart';

/// Local persistence for the auth state across app restarts.
/// - Refresh token → secure storage (Keychain / EncryptedSharedPreferences)
/// - User & shop metadata → shared_preferences (non-sensitive)
class AuthLocalDataSource {
  AuthLocalDataSource(this._secure, this._prefs);
  final SecureStorage _secure;
  final SharedPreferences _prefs;

  static const _kUserId = 'auth.user_id';
  static const _kShopId = 'auth.shop_id';
  static const _kRole = 'auth.role';
  static const _kUserName = 'auth.user_name';
  static const _kShopName = 'auth.shop_name';
  static const _kShopType = 'auth.shop_type';

  Future<void> saveTokens({required String refresh}) async {
    await _secure.writeRefresh(refresh);
  }

  Future<String?> readRefresh() => _secure.readRefresh();

  Future<void> saveProfile({
    required String userId,
    required String shopId,
    required String role,
    String? userName,
    String? shopName,
    String? shopType,
  }) async {
    await _prefs.setString(_kUserId, userId);
    await _prefs.setString(_kShopId, shopId);
    await _prefs.setString(_kRole, role);
    if (userName != null) await _prefs.setString(_kUserName, userName);
    if (shopName != null) await _prefs.setString(_kShopName, shopName);
    if (shopType != null) await _prefs.setString(_kShopType, shopType);
  }

  ({
    String userId,
    String shopId,
    String role,
    String userName,
    String shopName,
    String shopType,
  })? readProfile() {
    final uid = _prefs.getString(_kUserId);
    final sid = _prefs.getString(_kShopId);
    final role = _prefs.getString(_kRole);
    if (uid == null || sid == null || role == null) return null;
    return (
      userId: uid,
      shopId: sid,
      role: role,
      userName: _prefs.getString(_kUserName) ?? '',
      shopName: _prefs.getString(_kShopName) ?? '',
      shopType: _prefs.getString(_kShopType) ?? 'regular',
    );
  }

  Future<void> clear() async {
    await _secure.clearRefresh();
    await _prefs.remove(_kUserId);
    await _prefs.remove(_kShopId);
    await _prefs.remove(_kRole);
    await _prefs.remove(_kUserName);
    await _prefs.remove(_kShopName);
    await _prefs.remove(_kShopType);
  }
}
