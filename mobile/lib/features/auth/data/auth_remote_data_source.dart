import 'package:dio/dio.dart';

class AuthRemoteDataSource {
  AuthRemoteDataSource(this._dio);
  final Dio _dio;

  Future<Map<String, dynamic>> login({
    required String phone,
    required String password,
    required String deviceFingerprint,
    String? deviceLabel,
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/v1/auth/login',
      data: {
        'phone': phone,
        'password': password,
        'device_fingerprint': deviceFingerprint,
        if (deviceLabel != null) 'device_label': deviceLabel,
      },
    );
    if (res.statusCode != 200) {
      throw _toError(res);
    }
    return res.data!;
  }

  Future<Map<String, dynamic>> registerShop({
    required String shopName,
    required String ownerName,
    required String phone,
    required String password,
    required String ownerPin,
    required String deviceFingerprint,
    String locale = 'en',
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/v1/auth/register-shop',
      data: {
        'shop_name': shopName,
        'owner_name': ownerName,
        'phone': phone,
        'password': password,
        'owner_pin': ownerPin,
        'device_fingerprint': deviceFingerprint,
        'locale': locale,
      },
    );
    if (res.statusCode != 201 && res.statusCode != 200) {
      throw _toError(res);
    }
    return res.data!;
  }

  Future<String> verifyOwnerPin(String pin) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/v1/auth/owner-pin/verify',
      data: {'pin': pin},
    );
    if (res.statusCode != 200) throw _toError(res);
    return res.data!['challenge_token'] as String;
  }

  Future<List<Map<String, dynamic>>> listShopUsers() async {
    final res = await _dio.get<Map<String, dynamic>>('/v1/auth/users');
    if (res.statusCode != 200) throw _toError(res);
    final raw = res.data!['users'] as List<dynamic>;
    return raw.cast<Map<String, dynamic>>();
  }

  Future<({String code, String expiresAt})> invite({
    required String name,
    required String phone,
    String role = 'cashier',
  }) async {
    final res = await _dio.post<Map<String, dynamic>>(
      '/v1/auth/invite',
      data: {'name': name, 'phone': phone, 'role': role},
    );
    if (res.statusCode != 201 && res.statusCode != 200) {
      throw _toError(res);
    }
    return (
      code: res.data!['invite_code'] as String,
      expiresAt: res.data!['expires_at'] as String,
    );
  }

  AuthException _toError(Response<dynamic> res) {
    final d = res.data;
    if (d is Map && d['detail'] is String) {
      return AuthException(d['detail'] as String, res.statusCode);
    }
    return AuthException('request failed (${res.statusCode})', res.statusCode);
  }
}

class AuthException implements Exception {
  AuthException(this.message, this.status);
  final String message;
  final int? status;
  @override
  String toString() => message;
}
