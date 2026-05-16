import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:uuid/uuid.dart';

import '../storage/secure_storage.dart';

part 'device_id.g.dart';

/// Stable per-install fingerprint. Generated once, persisted in secure storage,
/// reused for the life of the install. Reinstall → new id (intentional).
@Riverpod(keepAlive: true)
Future<String> deviceFingerprint(DeviceFingerprintRef ref) async {
  final storage = ref.watch(secureStorageProvider);
  final existing = await storage.readDeviceFingerprint();
  if (existing != null && existing.isNotEmpty) return existing;
  final fp = const Uuid().v4();
  await storage.writeDeviceFingerprint(fp);
  return fp;
}
