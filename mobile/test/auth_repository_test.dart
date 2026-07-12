import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suuqii/core/http/dio_client.dart';
import 'package:suuqii/core/storage/secure_storage.dart';
import 'package:suuqii/features/auth/data/auth_local_data_source.dart';
import 'package:suuqii/features/auth/data/auth_remote_data_source.dart';
import 'package:suuqii/features/auth/data/auth_repository_impl.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';

/// Returns a canned TokenBundle instead of hitting the network.
class _FakeRemote extends AuthRemoteDataSource {
  _FakeRemote(this.bundle) : super(Dio());
  final Map<String, dynamic> bundle;

  @override
  Future<Map<String, dynamic>> login({
    required String phone,
    required String password,
    required String deviceFingerprint,
    String? deviceLabel,
  }) async =>
      bundle;
}

class _FakeSecureStorage extends SecureStorage {
  _FakeSecureStorage({this.refresh});

  String? refresh;

  @override
  Future<String?> readRefresh() async => refresh;

  @override
  Future<void> writeRefresh(String value) async {
    refresh = value;
  }

  @override
  Future<void> clearRefresh() async {
    refresh = null;
  }
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('resume requires both refresh token and saved profile', () async {
    final prefs = await SharedPreferences.getInstance();
    final local = AuthLocalDataSource(_FakeSecureStorage(), prefs);
    await local.saveProfile(
      userId: 'u1',
      shopId: 's1',
      role: 'owner',
      userName: 'Owner',
      shopName: 'Shop',
    );

    final repo = AuthRepository(
      remote: AuthRemoteDataSource(Dio()),
      local: local,
      tokens: TokenStore(),
    );

    expect(await repo.resume(), isNull);
    expect(local.readProfile(), isNull);
  });

  test('resume restores authenticated profile when refresh token exists',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final local = AuthLocalDataSource(
      _FakeSecureStorage(refresh: 'refresh-token'),
      prefs,
    );
    await local.saveProfile(
      userId: 'u1',
      shopId: 's1',
      role: 'owner',
      userName: 'Owner',
      shopName: 'Shop',
    );

    final repo = AuthRepository(
      remote: AuthRemoteDataSource(Dio()),
      local: local,
      tokens: TokenStore(),
    );

    final resumed = await repo.resume();
    expect(resumed, isA<Authenticated>());
    expect(resumed?.userId, 'u1');
    expect(resumed?.shopId, 's1');
    expect(resumed?.role, 'owner');
    expect(resumed?.shopName, 'Shop');
    // No thresholds ever persisted → server defaults.
    expect(resumed?.debtThreshold, '500.00');
    expect(resumed?.expenseApprovalThreshold, '500.00');
  });

  test('login parses shop thresholds from the TokenBundle and persists them',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final storage = _FakeSecureStorage();
    final local = AuthLocalDataSource(storage, prefs);
    final repo = AuthRepository(
      remote: _FakeRemote({
        'access': 'a',
        'refresh': 'r',
        'user_id': 'u1',
        'shop_id': 's1',
        'role': 'owner',
        'shop_type': 'regular',
        'debt_threshold': '750.00',
        'expense_approval_threshold': '120.50',
      }),
      local: local,
      tokens: TokenStore(),
    );

    final auth = await repo.login(
      phone: '0911',
      password: 'pw',
      deviceFingerprint: 'fp',
    );
    expect(auth.debtThreshold, '750.00');
    expect(auth.expenseApprovalThreshold, '120.50');
    expect(auth.debtThresholdValue.toString(), '750');
    expect(auth.expenseApprovalThresholdValue.toString(), '120.5');

    // Persisted: a resumed session keeps the shop's thresholds.
    final resumed = await repo.resume();
    expect(resumed?.debtThreshold, '750.00');
    expect(resumed?.expenseApprovalThreshold, '120.50');
  });

  test('login falls back to 500.00 when the bundle omits thresholds',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final local = AuthLocalDataSource(_FakeSecureStorage(), prefs);
    final repo = AuthRepository(
      remote: _FakeRemote({
        'access': 'a',
        'refresh': 'r',
        'user_id': 'u1',
        'shop_id': 's1',
        'role': 'cashier',
      }),
      local: local,
      tokens: TokenStore(),
    );

    final auth = await repo.login(
      phone: '0911',
      password: 'pw',
      deviceFingerprint: 'fp',
    );
    expect(auth.debtThreshold, '500.00');
    expect(auth.expenseApprovalThreshold, '500.00');
  });
}
