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
  static const _kDebtThreshold = 'auth.debt_threshold';
  static const _kExpenseApprovalThreshold = 'auth.expense_approval_threshold';
  static const _kReturnWindowDays = 'auth.return_window_days';

  /// Mirrors the server default for both shop thresholds.
  static const _kDefaultThreshold = '500.00';

  /// Mirrors the server default for Shop.return_window_days.
  static const _kDefaultReturnWindowDays = 7;

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
    String? debtThreshold,
    String? expenseApprovalThreshold,
    int? returnWindowDays,
  }) async {
    await _prefs.setString(_kUserId, userId);
    await _prefs.setString(_kShopId, shopId);
    await _prefs.setString(_kRole, role);
    if (userName != null) await _prefs.setString(_kUserName, userName);
    if (shopName != null) await _prefs.setString(_kShopName, shopName);
    if (shopType != null) await _prefs.setString(_kShopType, shopType);
    if (debtThreshold != null) {
      await _prefs.setString(_kDebtThreshold, debtThreshold);
    }
    if (expenseApprovalThreshold != null) {
      await _prefs.setString(
        _kExpenseApprovalThreshold,
        expenseApprovalThreshold,
      );
    }
    if (returnWindowDays != null) {
      await _prefs.setInt(_kReturnWindowDays, returnWindowDays);
    }
  }

  /// Updates only the shop-settings fields (owner edited them in-app),
  /// leaving the rest of the persisted profile untouched.
  Future<void> saveShopSettings({
    String? shopName,
    String? debtThreshold,
    String? expenseApprovalThreshold,
    int? returnWindowDays,
  }) async {
    if (shopName != null) await _prefs.setString(_kShopName, shopName);
    if (debtThreshold != null) {
      await _prefs.setString(_kDebtThreshold, debtThreshold);
    }
    if (expenseApprovalThreshold != null) {
      await _prefs.setString(
        _kExpenseApprovalThreshold,
        expenseApprovalThreshold,
      );
    }
    if (returnWindowDays != null) {
      await _prefs.setInt(_kReturnWindowDays, returnWindowDays);
    }
  }

  ({
    String userId,
    String shopId,
    String role,
    String userName,
    String shopName,
    String shopType,
    String debtThreshold,
    String expenseApprovalThreshold,
    int returnWindowDays,
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
      debtThreshold: _prefs.getString(_kDebtThreshold) ?? _kDefaultThreshold,
      expenseApprovalThreshold:
          _prefs.getString(_kExpenseApprovalThreshold) ?? _kDefaultThreshold,
      returnWindowDays:
          _prefs.getInt(_kReturnWindowDays) ?? _kDefaultReturnWindowDays,
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
    await _prefs.remove(_kDebtThreshold);
    await _prefs.remove(_kExpenseApprovalThreshold);
    await _prefs.remove(_kReturnWindowDays);
  }
}
