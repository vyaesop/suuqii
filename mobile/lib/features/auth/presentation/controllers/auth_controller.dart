import 'dart:async';

import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:suuqii/core/device/device_id.dart';
import 'package:suuqii/core/http/dio_client.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/providers.dart';
import 'package:suuqii/features/sync/data/sync_worker.dart';

part 'auth_controller.g.dart';

/// Thrown when logout / shop-switch would wipe local data while unsynced
/// events are still queued. UI catches this to ask for explicit confirmation
/// before retrying with `force: true`.
class PendingSyncException implements Exception {
  PendingSyncException(this.pendingCount);

  final int pendingCount;

  @override
  String toString() =>
      '$pendingCount unsynced record(s) would be discarded';
}

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
    bool force = false,
  }) async {
    // Capture previous shop before clearing state — once we set AsyncLoading
    // state.valueOrNull becomes null and the shop-switch check never fires.
    // state is normally Unauthenticated here (fresh login), so never cast.
    final prev = state.valueOrNull;
    final prevShopId = prev is Authenticated ? prev.shopId : null;
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
        // Never silently destroy unsynced events from the previous shop.
        // No flush here: we already hold the new shop's tokens, so pushing
        // the old shop's queue now would send it with the wrong credentials.
        final pending =
            await ref.read(appDatabaseProvider).syncQueueDao.pendingCount();
        if (pending > 0 && !force) {
          throw PendingSyncException(pending);
        }
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

  /// Applies owner-edited shop settings to the in-memory auth state and its
  /// persistence, so offline checks (credit limit, expense PIN gate) pick the
  /// new thresholds up immediately without a re-login.
  Future<void> applyShopSettings({
    String? shopName,
    String? debtThreshold,
    String? expenseApprovalThreshold,
  }) async {
    final current = state.valueOrNull;
    if (current is! Authenticated) return;
    final repo = await ref.read(authRepositoryProvider.future);
    await repo.saveShopSettings(
      shopName: shopName,
      debtThreshold: debtThreshold,
      expenseApprovalThreshold: expenseApprovalThreshold,
    );
    state = AsyncData(
      current.copyWith(
        shopName: shopName,
        debtThreshold: debtThreshold,
        expenseApprovalThreshold: expenseApprovalThreshold,
      ),
    );
  }

  Future<void> logout({bool force = false}) async {
    // Try to drain the queue first; if events remain, block the logout
    // (unless forced) instead of silently discarding local-only records.
    final pending = await _flushPendingSync();
    if (pending > 0 && !force) {
      throw PendingSyncException(pending);
    }
    final repo = await ref.read(authRepositoryProvider.future);
    await repo.logout();
    ref.read(tokenStoreProvider).access = null;
    await ref.read(appDatabaseProvider).clearAllShopData();
    state = const AsyncData(Unauthenticated());
  }

  /// Move this device to another shop the account belongs to.
  ///
  /// Unlike the shop-change path in [login], the old shop's queue is drained
  /// *first* — we still hold that shop's credentials at this point, so its
  /// pending events can still be pushed. Once the new tokens arrive they would
  /// be sent under the wrong shop.
  Future<Authenticated> switchShop(
    String shopId, {
    bool force = false,
  }) async {
    final current = state.valueOrNull;
    if (current is! Authenticated) {
      throw StateError('Not signed in');
    }
    if (current.shopId == shopId) return current;

    final pending = await _flushPendingSync();
    if (pending > 0 && !force) {
      throw PendingSyncException(pending);
    }

    state = const AsyncLoading();
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      final fp = await ref.read(deviceFingerprintProvider.future);
      final auth = await repo.switchShop(
        shopId: shopId,
        deviceFingerprint: fp,
        userName: current.userName,
      );
      // Wipe before publishing the new state: the local store holds one shop
      // at a time, and any screen rebuilding against the new session must not
      // see the previous shop's products or sales.
      await ref.read(appDatabaseProvider).clearAllShopData();
      state = AsyncData(auth);
      return auth;
    } catch (error, stackTrace) {
      state = AsyncError(error, stackTrace);
      rethrow;
    }
  }

  /// Kicks the sync worker and waits briefly for the queue to drain.
  /// Returns the number of events still pending afterwards.
  Future<int> _flushPendingSync() async {
    final dao = ref.read(appDatabaseProvider).syncQueueDao;
    if (await dao.pendingCount() == 0) return 0;
    try {
      await ref
          .read(syncWorkerProvider)
          .kick()
          .timeout(const Duration(seconds: 10));
    } on TimeoutException {
      // Offline or slow network — fall through and report what's left.
    }
    return dao.pendingCount();
  }
}
