import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../core/storage/app_database.dart';

part 'sync_status_badge.g.dart';

@riverpod
Stream<int> pendingSyncCount(PendingSyncCountRef ref) {
  return ref.watch(appDatabaseProvider).syncQueueDao.watchPendingCount();
}

class SyncStatusBadge extends ConsumerWidget {
  const SyncStatusBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(pendingSyncCountProvider).valueOrNull ?? 0;
    if (count == 0) {
      return const Padding(
        padding: EdgeInsets.only(right: 12),
        child: Icon(Icons.cloud_done_outlined, size: 22),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Row(
        children: [
          const Icon(Icons.cloud_sync, size: 22),
          const SizedBox(width: 4),
          Text('$count', style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
