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

  Object _toError(Response res) {
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
