import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:suuqii/core/device/device_id.dart';
import 'package:suuqii/core/env/env.dart';
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
      headers: {'Accept': 'application/json'},
      validateStatus: (s) => s != null && s < 500,
    ),
  );

  d.interceptors.addAll([
    _DeviceInterceptor(ref),
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

class _AuthInterceptor extends Interceptor {
  _AuthInterceptor(this.ref, this._dio);
  final Ref ref;
  final Dio _dio;
  bool _refreshing = false;
  final _waiters = <Completer<void>>[];

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    final tok = ref.read(tokenStoreProvider).access;
    if (tok != null &&
        !options.path.contains('/auth/login') &&
        !options.path.contains('/auth/refresh') &&
        !options.path.contains('/auth/register-shop') &&
        !options.path.contains('/auth/accept-invite')) {
      options.headers['Authorization'] = 'Bearer $tok';
    }
    handler.next(options);
  }

  @override
  Future<void> onError(
      DioException err, ErrorInterceptorHandler handler,) async {
    final status = err.response?.statusCode;
    final path = err.requestOptions.path;
    final isAuthEndpoint = path.contains('/auth/');
    if (status != 401 ||
        isAuthEndpoint ||
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
    } catch (_) {
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

      final raw = Dio(BaseOptions(baseUrl: Env.apiBaseUrl));
      final res = await raw.post<Map<String, dynamic>>(
        '/v1/auth/refresh',
        data: {'refresh': refresh, 'device_fingerprint': fp},
      );
      final data = res.data!;
      ref.read(tokenStoreProvider).access = data['access'] as String;
      await storage.writeRefresh(data['refresh'] as String);
    } finally {
      _refreshing = false;
      for (final w in _waiters) {
        w.complete();
      }
      _waiters.clear();
    }
  }
}
