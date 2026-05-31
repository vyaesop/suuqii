import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:suuqii/core/device/device_id.dart';
import 'package:suuqii/core/http/dio_client.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/providers.dart';

part 'auth_controller.g.dart';

@Riverpod(keepAlive: true)
class AuthController extends _$AuthController {
  @override
  Future<AuthState> build() async {
    final repo = await ref.watch(authRepositoryProvider.future);
    final resumed = await repo.resume();
    if (resumed == null) return const Unauthenticated();
    // We have a remembered profile; the dio interceptor will refresh the
    // access token on the first authenticated request that gets a 401.
    return resumed;
  }

  Future<Authenticated> login({
    required String phone,
    required String password,
    String? deviceLabel,
  }) async {
    state = const AsyncLoading();
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      final fp = await ref.read(deviceFingerprintProvider.future);
      final auth = await repo.login(
        phone: phone,
        password: password,
        deviceFingerprint: fp,
        deviceLabel: deviceLabel,
      );
      state = AsyncData(auth);
      return auth;
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      rethrow;
    }
  }

  Future<Authenticated> registerShop({
    required String shopName,
    required String ownerName,
    required String phone,
    required String password,
    required String ownerPin,
    String locale = 'en',
  }) async {
    state = const AsyncLoading();
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      final fp = await ref.read(deviceFingerprintProvider.future);
      final auth = await repo.registerShop(
        shopName: shopName,
        ownerName: ownerName,
        phone: phone,
        password: password,
        ownerPin: ownerPin,
        deviceFingerprint: fp,
        locale: locale,
      );
      state = AsyncData(auth);
      return auth;
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      rethrow;
    }
  }

  Future<void> logout() async {
    final repo = await ref.read(authRepositoryProvider.future);
    await repo.logout();
    ref.read(tokenStoreProvider).access = null;
    state = const AsyncData(Unauthenticated());
  }
}
