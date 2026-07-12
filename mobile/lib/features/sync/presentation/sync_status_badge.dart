import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/storage/app_database.dart';

part 'sync_status_badge.g.dart';

@riverpod
Stream<int> pendingSyncCount(PendingSyncCountRef ref) {
  return ref.watch(appDatabaseProvider).syncQueueDao.watchPendingCount();
}

/// Events the server rejected or that exhausted their retries — data that
/// will never sync without attention.
@riverpod
Stream<int> deadLetterSyncCount(DeadLetterSyncCountRef ref) {
  return ref.watch(appDatabaseProvider).syncQueueDao.watchDeadLetterCount();
}

@riverpod
Stream<List<SyncEventRow>> deadLetterSyncEvents(DeadLetterSyncEventsRef ref) {
  return ref.watch(appDatabaseProvider).syncQueueDao.watchDeadLettered();
}

/// A small chip in the app bar. "All synced" when idle, "N pending" with a
/// gentle pulse when there's outstanding work, and a red error badge when
/// events were rejected/failed (tap for details).
class SyncStatusBadge extends ConsumerWidget {
  const SyncStatusBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(pendingSyncCountProvider).valueOrNull ?? 0;
    final deadCount = ref.watch(deadLetterSyncCountProvider).valueOrNull ?? 0;
    final scheme = Theme.of(context).colorScheme;
    final pending = count > 0;
    final broken = deadCount > 0;

    final bg = broken
        ? scheme.errorContainer
        : pending
            ? scheme.primaryContainer
            : scheme.surfaceContainer;
    final border = broken
        ? scheme.error
        : pending
            ? scheme.primary
            : scheme.outlineVariant;
    final fg = broken
        ? scheme.onErrorContainer
        : pending
            ? scheme.onPrimaryContainer
            : scheme.onSurfaceVariant;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: SuuqSpacing.xs),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: broken ? () => _showDeadLetterDetails(context, ref) : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                broken
                    ? Icons.sync_problem_rounded
                    : pending
                        ? Icons.sync_rounded
                        : Icons.cloud_done_rounded,
                size: 14,
                color: fg,
              ),
              const SizedBox(width: 6),
              Text(
                broken
                    ? '$deadCount'
                    : pending
                        ? '$count'
                        : context.l10n.syncSynced,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showDeadLetterDetails(BuildContext context, WidgetRef ref) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Consumer(
        builder: (ctx, ref, _) {
          final events =
              ref.watch(deadLetterSyncEventsProvider).valueOrNull ?? [];
          return AlertDialog(
            title: Text(ctx.l10n.syncProblemsTitle),
            content: SizedBox(
              width: double.maxFinite,
              child: events.isEmpty
                  ? Text(ctx.l10n.syncNoDetails)
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: events.length,
                      itemBuilder: (_, i) {
                        final e = events[i];
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(e.op),
                          subtitle: Text(e.lastError ?? e.status),
                        );
                      },
                    ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(ctx.l10n.commonClose),
              ),
            ],
          );
        },
      ),
    );
  }
}
