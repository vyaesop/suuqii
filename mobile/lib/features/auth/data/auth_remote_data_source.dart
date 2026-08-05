import 'package:dio/dio.dart';

import 'package:suuqii/features/auth/domain/entities/shop_option.dart';

class AuthRemoteDataSource {
  AuthRemoteDataSource(this._dio);
  final Dio _dio;

  /// Runs [send] and converts 4xx DioExceptions (thrown now that the shared
  /// Dio only accepts <400) into typed [AuthException]s with the server's
  /// error detail. Network-level errors are rethrown untouched.
  Future<Response<Map<String, dynamic>>> _request(
    Future<Response<Map<String, dynamic>>> Function() send,
  ) async {
    try {
      return await send();
    } on DioException catch (e) {
      final res = e.response;
      if (res != null) throw _toError(res);
      rethrow;
    }
  }

  Future<Map<String, dynamic>> login({
    required String phone,
    required String password,
    required String deviceFingerprint,
    String? deviceLabel,
  }) async {
    final res = await _request(
      () => _dio.post<Map<String, dynamic>>(
        '/v1/auth/login',
        data: {
          'phone': phone,
          'password': password,
          'device_fingerprint': deviceFingerprint,
          if (deviceLabel != null) 'device_label': deviceLabel,
        },
      ),
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
    String shopType = 'regular',
  }) async {
    final res = await _request(
      () => _dio.post<Map<String, dynamic>>(
        '/v1/auth/register-shop',
        data: {
          'shop_name': shopName,
          'owner_name': ownerName,
          'phone': phone,
          'password': password,
          'owner_pin': ownerPin,
          'device_fingerprint': deviceFingerprint,
          'locale': locale,
          'shop_type': shopType,
        },
      ),
    );
    if (res.statusCode != 201 && res.statusCode != 200) {
      throw _toError(res);
    }
    return res.data!;
  }

  Future<String> verifyOwnerPin(String pin) async {
    final res = await _request(
      () => _dio.post<Map<String, dynamic>>(
        '/v1/auth/owner-pin/verify',
        data: {'pin': pin},
      ),
    );
    if (res.statusCode != 200) throw _toError(res);
    return res.data!['challenge_token'] as String;
  }

  Future<Map<String, dynamic>> acceptInvite({
    required String phone,
    required String inviteCode,
    required String password,
    required String deviceFingerprint,
    String? deviceLabel,
  }) async {
    final res = await _request(
      () => _dio.post<Map<String, dynamic>>(
        '/v1/auth/accept-invite',
        data: {
          'phone': phone,
          'invite_code': inviteCode,
          'password': password,
          'device_fingerprint': deviceFingerprint,
          if (deviceLabel != null) 'device_label': deviceLabel,
        },
      ),
    );
    if (res.statusCode != 200 && res.statusCode != 201) throw _toError(res);
    return res.data!;
  }

  Future<List<Map<String, dynamic>>> listShopUsers() async {
    final res = await _request(
      () => _dio.get<Map<String, dynamic>>('/v1/auth/users'),
    );
    if (res.statusCode != 200) throw _toError(res);
    final raw = res.data!['users'] as List<dynamic>;
    return raw.cast<Map<String, dynamic>>();
  }

  /// Owner-only: blocks the user from logging in and revokes their device
  /// sessions. Returns how many sessions were revoked.
  Future<int> deactivateUser(String userId) async {
    final res = await _request(
      () => _dio.post<Map<String, dynamic>>(
        '/v1/auth/users/$userId/deactivate',
      ),
    );
    if (res.statusCode != 200) throw _toError(res);
    return (res.data!['sessions_revoked'] as num?)?.toInt() ?? 0;
  }

  /// Owner-only: lets a previously deactivated user log in again.
  Future<void> activateUser(String userId) async {
    final res = await _request(
      () => _dio.post<Map<String, dynamic>>('/v1/auth/users/$userId/activate'),
    );
    if (res.statusCode != 200) throw _toError(res);
  }

  /// Owner-only: all device sessions for the shop.
  Future<List<Map<String, dynamic>>> listDevices() async {
    final res = await _request(
      () => _dio.get<Map<String, dynamic>>('/v1/auth/devices'),
    );
    if (res.statusCode != 200) throw _toError(res);
    final raw = res.data!['items'] as List<dynamic>;
    return raw.cast<Map<String, dynamic>>();
  }

  /// Owner-only: signs the device session out remotely.
  Future<void> revokeDevice(String sessionId) async {
    final res = await _request(
      () => _dio.post<Map<String, dynamic>>(
        '/v1/auth/devices/$sessionId/revoke',
      ),
    );
    if (res.statusCode != 200) throw _toError(res);
  }

  /// One shop this account may act in.
  ///
  /// A single-shop account gets exactly one of these, which is why the
  /// switcher UI hides itself below two.
  Future<List<ShopOption>> myShops() async {
    final res = await _request(
      () => _dio.get<Map<String, dynamic>>('/v1/shops/mine'),
    );
    if (res.statusCode != 200) throw _toError(res);
    final items = (res.data?['shops'] as List? ?? []).cast<Map<String, dynamic>>();
    return items.map(ShopOption.fromJson).toList();
  }

  /// Re-issue this device's tokens against another shop. The caller must wipe
  /// the local database afterwards — it holds one shop's data at a time.
  Future<Map<String, dynamic>> switchShop({
    required String shopId,
    required String deviceFingerprint,
  }) async {
    final res = await _request(
      () => _dio.post<Map<String, dynamic>>(
        '/v1/auth/switch-shop',
        data: {'shop_id': shopId, 'device_fingerprint': deviceFingerprint},
      ),
    );
    if (res.statusCode != 200) throw _toError(res);
    return res.data!;
  }

  /// Open an additional shop owned by this account (e.g. a bakery alongside a
  /// regular shop). Does not switch to it.
  Future<ShopOption> createShop({
    required String name,
    required String shopType,
    String locale = 'en',
  }) async {
    final res = await _request(
      () => _dio.post<Map<String, dynamic>>(
        '/v1/shops',
        data: {'name': name, 'shop_type': shopType, 'locale': locale},
      ),
    );
    if (res.statusCode != 201 && res.statusCode != 200) throw _toError(res);
    return ShopOption.fromJson(res.data!);
  }

  Future<({String code, String expiresAt})> invite({
    required String name,
    required String phone,
    String role = 'cashier',
  }) async {
    final res = await _request(
      () => _dio.post<Map<String, dynamic>>(
        '/v1/auth/invite',
        data: {'name': name, 'phone': phone, 'role': role},
      ),
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
    if (d is Map) {
      final detail = d['detail'];
      if (detail is String) {
        return AuthException(detail, res.statusCode);
      }
      // FastAPI returns a list of validation errors for 422 responses.
      if (detail is List && detail.isNotEmpty) {
        final first = detail.first;
        if (first is Map) {
          final raw = first['msg'] as String? ?? 'Validation error';
          // Strip Pydantic's "Value error, " prefix for cleaner UX.
          final msg = raw.startsWith('Value error, ')
              ? raw.substring('Value error, '.length)
              : raw;
          return AuthException(msg, res.statusCode);
        }
      }
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
