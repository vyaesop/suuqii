import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:suuqii/core/device/device_id.dart';
import 'package:suuqii/core/env/app_version.dart';
import 'package:suuqii/core/env/env.dart';
import 'package:suuqii/core/http/update_required.dart';
import 'package:suuqii/core/storage/secure_storage.dart';

part 'dio_client.g.dart';

/// Holds the current access token in memory (RAM only).
/// Refresh token lives in [SecureStorage]; access never persists.
class TokenStore {
  String? access;
}

@Riverpod(keepAlive: true)
TokenStore tokenStore(TokenStoreRef ref) => TokenStore();

@Riverpod(keepAlive: true)
Dio dio(DioRef ref) {
  final d = Dio(
    BaseOptions(
      baseUrl: Env.apiBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 30),
      headers: {
        'Accept': 'application/json',
        // Resolved from PackageInfo before the container is built (see
        // main.dart), so it is already available when this client is created.
        'X-App-Version': ref.watch(appVersionProvider),
      },
      // 4xx must throw so the _AuthInterceptor.onError 401 refresh/retry
      // path actually runs. Callers that need to read 4xx bodies inline
      // pass a per-request validateStatus or catch DioException.
      validateStatus: (s) => s != null && s < 400,
    ),
  );

  d.interceptors.addAll([
    _DeviceInterceptor(ref),
    _UpgradeRequiredInterceptor(ref),
    _AuthInterceptor(ref, d),
  ]);

  return d;
}

class _DeviceInterceptor extends Interceptor {
  _DeviceInterceptor(this.ref);
  final Ref ref;

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    final fp = await ref.read(deviceFingerprintProvider.future);
    options.headers['X-Device-Id'] = fp;
    handler.next(options);
  }
}

/// Flips the global [UpdateRequired] flag when the backend answers any call
/// with HTTP 426 (Upgrade Required); the router then blocks the app behind
/// the update screen. The error still propagates to the caller.
class _UpgradeRequiredInterceptor extends Interceptor {
  _UpgradeRequiredInterceptor(this.ref);
  final Ref ref;

  @override
  void onError(DioException err, ErrorInterceptorHandler handler) {
    if (err.response?.statusCode == 426) {
      ref.read(updateRequiredProvider.notifier).markRequired();
    }
    handler.next(err);
  }
}

class _AuthInterceptor extends Interceptor {
  _AuthInterceptor(this.ref, this._dio);
  final Ref ref;
  final Dio _dio;
  bool _refreshing = false;
  final _waiters = <Completer<void>>[];

  @override
  Future<void> onRequest(
    RequestOptions options,
    RequestInterceptorHandler handler,
  ) async {
    if (_isAuthEndpoint(options.path)) {
      handler.next(options);
      return;
    }

    var tok = ref.read(tokenStoreProvider).access;
    if (tok == null) {
      try {
        await _ensureRefreshed();
        tok = ref.read(tokenStoreProvider).access;
      } catch (_) {
        // No remembered session available. Let the request proceed without
        // auth so callers can surface a normal unauthenticated state.
      }
    }

    if (tok != null) {
      options.headers['Authorization'] = 'Bearer $tok';
    }
    handler.next(options);
  }

  @override
  Future<void> onError(
    DioException err,
    ErrorInterceptorHandler handler,
  ) async {
    final status = err.response?.statusCode;
    final path = err.requestOptions.path;
    final isAuthEndpoint = _isAuthEndpoint(path);
    // The owner-PIN check answers a wrong PIN with 401 too. That is not an
    // expired session: refreshing and replaying it would submit the same
    // wrong PIN twice and burn two of the owner's lockout attempts per typo.
    // An expired token on that call still refreshes as usual.
    final data = err.response?.data;
    final isWrongPin = path.contains('/auth/owner-pin') &&
        data is Map &&
        '${data['detail']}'.startsWith('wrong pin');
    if (status != 401 ||
        isAuthEndpoint ||
        isWrongPin ||
        err.requestOptions.extra['retried'] == true) {
      return handler.next(err);
    }

    try {
      await _ensureRefreshed();
      final newToken = ref.read(tokenStoreProvider).access;
      if (newToken == null) return handler.next(err);
      final req = err.requestOptions;
      req.headers['Authorization'] = 'Bearer $newToken';
      req.extra['retried'] = true;
      final response = await _dio.fetch<dynamic>(req);
      handler.resolve(response);
    } catch (e) {
      // Refresh (or the retried request) failed — let the original 401
      // propagate so callers can surface an unauthenticated state.
      debugPrint('token refresh after 401 failed: $e');
      handler.next(err);
    }
  }

  Future<void> _ensureRefreshed() async {
    if (_refreshing) {
      final c = Completer<void>();
      _waiters.add(c);
      return c.future;
    }
    _refreshing = true;
    try {
      final storage = ref.read(secureStorageProvider);
      final refresh = await storage.readRefresh();
      if (refresh == null) throw StateError('no refresh token');
      final fp = await ref.read(deviceFingerprintProvider.future);

      final raw = Dio(
        BaseOptions(
          baseUrl: Env.apiBaseUrl,
          headers: {'X-App-Version': ref.read(appVersionProvider)},
        ),
      );
      final res = await raw.post<Map<String, dynamic>>(
        '/v1/auth/refresh',
        data: {'refresh': refresh, 'device_fingerprint': fp},
      );
      final data = res.data!;
      ref.read(tokenStoreProvider).access = data['access'] as String;
      await storage.writeRefresh(data['refresh'] as String);
      for (final w in _waiters) {
        w.complete();
      }
    } catch (e, st) {
      // Waiters must fail too — completing them successfully would let
      // queued requests proceed with a stale/absent token.
      debugPrint('token refresh failed: $e');
      for (final w in _waiters) {
        w.completeError(e, st);
      }
      rethrow;
    } finally {
      _refreshing = false;
      _waiters.clear();
    }
  }

  bool _isAuthEndpoint(String path) {
    return path.contains('/auth/login') ||
        path.contains('/auth/refresh') ||
        path.contains('/auth/register-shop') ||
        path.contains('/auth/accept-invite');
  }
}
