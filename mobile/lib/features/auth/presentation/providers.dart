import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/http/dio_client.dart';
import '../../../core/storage/secure_storage.dart';
import '../data/auth_local_data_source.dart';
import '../data/auth_remote_data_source.dart';
import '../data/auth_repository_impl.dart';

part 'providers.g.dart';

@Riverpod(keepAlive: true)
Future<SharedPreferences> sharedPrefs(SharedPrefsRef ref) =>
    SharedPreferences.getInstance();

@Riverpod(keepAlive: true)
Future<AuthRepository> authRepository(AuthRepositoryRef ref) async {
  return AuthRepository(
    remote: AuthRemoteDataSource(ref.watch(dioProvider)),
    local: AuthLocalDataSource(
      ref.watch(secureStorageProvider),
      await ref.watch(sharedPrefsProvider.future),
    ),
    tokens: ref.watch(tokenStoreProvider),
  );
}
