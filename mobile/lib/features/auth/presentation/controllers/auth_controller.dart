import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../../core/device/device_id.dart';
import '../../../../core/http/dio_client.dart';
import '../../domain/entities/auth_state.dart';
import '../providers.dart';

part 'auth_controller.g.dart';

@Riverpod(keepAlive: true)
class AuthController extends _$AuthController {
  @override
  Future<AuthState> build() async {
    final repo = await ref.watch(authRepositoryProvider.future);
    final resumed = repo.resume();
    if (resumed == null) return const Unauthenticated();
    // We have a remembered profile; the dio interceptor will refresh the
    // access token on the first authenticated request that gets a 401.
    return resumed;
  }

  Future<void> login({
    required String phone,
    required String password,
    String? deviceLabel,
  }) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final repo = await ref.read(authRepositoryProvider.future);
      final fp = await ref.read(deviceFingerprintProvider.future);
      return repo.login(
        phone: phone,
        password: password,
        deviceFingerprint: fp,
        deviceLabel: deviceLabel,
      );
    });
  }

  Future<void> registerShop({
    required String shopName,
    required String ownerName,
    required String phone,
    required String password,
    required String ownerPin,
    String locale = 'en',
  }) async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final repo = await ref.read(authRepositoryProvider.future);
      return repo.registerShop(
        shopName: shopName,
        ownerName: ownerName,
        phone: phone,
        password: password,
        ownerPin: ownerPin,
        locale: locale,
      );
    });
  }

  Future<void> logout() async {
    final repo = await ref.read(authRepositoryProvider.future);
    await repo.logout();
    ref.read(tokenStoreProvider).access = null;
    state = const AsyncData(Unauthenticated());
  }
}
