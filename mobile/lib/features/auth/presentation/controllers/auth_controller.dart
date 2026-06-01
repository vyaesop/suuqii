import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:suuqii/core/device/device_id.dart';
import 'package:suuqii/core/http/dio_client.dart';
import 'package:suuqii/core/storage/app_database.dart';
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
    // Capture previous shop before clearing state — once we set AsyncLoading
    // state.valueOrNull becomes null and the shop-switch check never fires.
    final prevShopId = (state.valueOrNull as Authenticated?)?.shopId;
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
      // Clear local cache if switching to a different shop so stale data
      // from the previous session never leaks through.
      if (prevShopId != null && prevShopId != auth.shopId) {
        await ref.read(appDatabaseProvider).clearAllShopData();
      }
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
    String shopType = 'regular',
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
        shopType: shopType,
      );
      // New account always starts with a clean local database.
      await ref.read(appDatabaseProvider).clearAllShopData();
      state = AsyncData(auth);
      return auth;
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      rethrow;
    }
  }

  Future<Authenticated> acceptInvite({
    required String phone,
    required String inviteCode,
    required String password,
  }) async {
    state = const AsyncLoading();
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      final fp = await ref.read(deviceFingerprintProvider.future);
      final auth = await repo.acceptInvite(
        phone: phone,
        inviteCode: inviteCode,
        password: password,
        deviceFingerprint: fp,
      );
      await ref.read(appDatabaseProvider).clearAllShopData();
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
    await ref.read(appDatabaseProvider).clearAllShopData();
    state = const AsyncData(Unauthenticated());
  }
}
