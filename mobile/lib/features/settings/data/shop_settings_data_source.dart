import 'package:dio/dio.dart';

/// Shop-level settings, owner-only (GET/PATCH /v1/shops/settings).
/// Thresholds travel as decimal strings, matching the TokenBundle.
class ShopSettings {
  const ShopSettings({
    required this.name,
    required this.currency,
    required this.locale,
    required this.shopType,
    required this.debtThreshold,
    required this.expenseApprovalThreshold,
  });

  factory ShopSettings.fromJson(Map<String, dynamic> j) => ShopSettings(
        name: j['name'] as String,
        currency: j['currency'] as String,
        locale: j['locale'] as String,
        shopType: j['shop_type'] as String,
        debtThreshold: j['debt_threshold'] as String,
        expenseApprovalThreshold: j['expense_approval_threshold'] as String,
      );

  final String name;
  final String currency;
  final String locale;
  final String shopType;
  final String debtThreshold;
  final String expenseApprovalThreshold;
}

class ShopSettingsDataSource {
  ShopSettingsDataSource(this._dio);
  final Dio _dio;

  Future<ShopSettings> fetch() async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/shops/settings');
    return ShopSettings.fromJson(res.data!);
  }

  /// PATCHes only the provided fields; returns the updated settings.
  Future<ShopSettings> update({
    String? name,
    String? locale,
    String? debtThreshold,
    String? expenseApprovalThreshold,
  }) async {
    final res = await _dio.patch<Map<String, dynamic>>(
      '/v1/shops/settings',
      data: {
        if (name != null) 'name': name,
        if (locale != null) 'locale': locale,
        if (debtThreshold != null) 'debt_threshold': debtThreshold,
        if (expenseApprovalThreshold != null)
          'expense_approval_threshold': expenseApprovalThreshold,
      },
    );
    return ShopSettings.fromJson(res.data!);
  }
}
