import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/storage/app_database.dart';

part 'sync_status_badge.g.dart';

@riverpod
Stream<int> pendingSyncCount(PendingSyncCountRef ref) {
  return ref.watch(appDatabaseProvider).syncQueueDao.watchPendingCount();
}

/// A small chip in the app bar. "All synced" when idle, "N pending" with a
/// gentle pulse when there's outstanding work.
class SyncStatusBadge extends ConsumerWidget {
  const SyncStatusBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(pendingSyncCountProvider).valueOrNull ?? 0;
    final scheme = Theme.of(context).colorScheme;
    final pending = count > 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: SuuqSpacing.xs),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: pending
              ? scheme.primaryContainer
              : scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: pending ? scheme.primary : scheme.outlineVariant,
            width: pending ? 1 : 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              pending ? Icons.sync_rounded : Icons.cloud_done_rounded,
              size: 14,
              color: pending
                  ? scheme.onPrimaryContainer
                  : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              pending ? '$count' : 'Synced',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: pending
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
