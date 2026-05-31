import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:suuqii/core/http/dio_client.dart';
import 'package:suuqii/core/storage/secure_storage.dart';
import 'package:suuqii/features/auth/data/auth_local_data_source.dart';
import 'package:suuqii/features/auth/data/auth_remote_data_source.dart';
import 'package:suuqii/features/auth/data/auth_repository_impl.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';

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
  });
}
