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
    this.returnWindowDays = 7,
  });

  factory ShopSettings.fromJson(Map<String, dynamic> j) => ShopSettings(
        name: j['name'] as String,
        currency: j['currency'] as String,
        locale: j['locale'] as String,
        shopType: j['shop_type'] as String,
        debtThreshold: j['debt_threshold'] as String,
        expenseApprovalThreshold: j['expense_approval_threshold'] as String,
        returnWindowDays: (j['return_window_days'] as num?)?.toInt() ?? 7,
      );

  final String name;
  final String currency;
  final String locale;
  final String shopType;
  final String debtThreshold;
  final String expenseApprovalThreshold;

  /// Days after a sale within which returns are routine (docs/19 §13.4).
  final int returnWindowDays;
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
    int? returnWindowDays,
  }) async {
    final res = await _dio.patch<Map<String, dynamic>>(
      '/v1/shops/settings',
      data: {
        if (name != null) 'name': name,
        if (locale != null) 'locale': locale,
        if (debtThreshold != null) 'debt_threshold': debtThreshold,
        if (expenseApprovalThreshold != null)
          'expense_approval_threshold': expenseApprovalThreshold,
        if (returnWindowDays != null) 'return_window_days': returnWindowDays,
      },
    );
    return ShopSettings.fromJson(res.data!);
  }
}
