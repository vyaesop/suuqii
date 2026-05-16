import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'secure_storage.g.dart';

/// Thin typed wrapper around flutter_secure_storage.
/// Keychain (iOS) / EncryptedSharedPreferences (Android).
class SecureStorage {
  SecureStorage([FlutterSecureStorage? raw])
      : _raw = raw ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );
  final FlutterSecureStorage _raw;

  static const _kRefresh = 'auth.refresh';
  static const _kDeviceFp = 'device.fingerprint';

  Future<String?> readRefresh() => _raw.read(key: _kRefresh);
  Future<void> writeRefresh(String value) => _raw.write(key: _kRefresh, value: value);
  Future<void> clearRefresh() => _raw.delete(key: _kRefresh);

  Future<String?> readDeviceFingerprint() => _raw.read(key: _kDeviceFp);
  Future<void> writeDeviceFingerprint(String value) =>
      _raw.write(key: _kDeviceFp, value: value);

  Future<void> wipeAll() => _raw.deleteAll();
}

@Riverpod(keepAlive: true)
SecureStorage secureStorage(SecureStorageRef ref) => SecureStorage();
