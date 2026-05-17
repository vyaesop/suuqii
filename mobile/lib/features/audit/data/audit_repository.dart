import 'package:dio/dio.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:suuqii/core/http/dio_client.dart';

part 'audit_repository.g.dart';

class AuditEntry {
  const AuditEntry({
    required this.id,
    required this.action,
    required this.entityType,
    required this.entityId,
    required this.createdAt,
    this.userId,
    this.deviceId,
    this.oldValue,
    this.newValue,
  });

  final String id;
  final String action;
  final String entityType;
  final String entityId;
  final String? userId;
  final String? deviceId;
  final Map<String, dynamic>? oldValue;
  final Map<String, dynamic>? newValue;
  final DateTime createdAt;
}

class AuditRepository {
  AuditRepository(this._dio);
  final Dio _dio;

  Future<List<AuditEntry>> list({
    String? action,
    String? userId,
    int limit = 100,
  }) async {
    final res = await _dio.get<Map<String, dynamic>>(
      '/v1/audit',
      queryParameters: {
        if (action != null) 'action': action,
        if (userId != null) 'user_id': userId,
        'limit': limit,
      },
    );
    final items =
        (res.data?['items'] as List? ?? <dynamic>[]).cast<Map<String, dynamic>>();
    return items.map(_fromJson).toList();
  }

  AuditEntry _fromJson(Map<String, dynamic> j) => AuditEntry(
        id: j['id'] as String,
        action: j['action'] as String,
        entityType: j['entity_type'] as String,
        entityId: j['entity_id'] as String,
        userId: j['user_id'] as String?,
        deviceId: j['device_id'] as String?,
        oldValue: j['old'] as Map<String, dynamic>?,
        newValue: j['new'] as Map<String, dynamic>?,
        createdAt: DateTime.parse(j['created_at'] as String),
      );
}

@Riverpod(keepAlive: true)
AuditRepository auditRepository(AuditRepositoryRef ref) =>
    AuditRepository(ref.watch(dioProvider));

@riverpod
Future<List<AuditEntry>> auditEntries(
  AuditEntriesRef ref, {
  String? action,
}) {
  return ref.watch(auditRepositoryProvider).list(action: action);
}
