import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/connectivity/connectivity_provider.dart';
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
    final l = context.l10n;
    final count = ref.watch(pendingSyncCountProvider).valueOrNull ?? 0;
    final deadCount = ref.watch(deadLetterSyncCountProvider).valueOrNull ?? 0;
    // Assume online until connectivity reports, so the badge never flashes
    // an offline state at startup (or in tests without the plugin).
    final online = ref.watch(onlineStatusProvider).valueOrNull ?? true;
    final scheme = Theme.of(context).colorScheme;
    final pending = count > 0;
    final broken = deadCount > 0;
    // Being offline is expected for this app, not a problem: show a neutral
    // cloud-off state. Real sync failures (dead letters) still win.
    final offline = !online && !broken;

    final bg = broken
        ? scheme.errorContainer
        : offline || !pending
            ? scheme.surfaceContainer
            : scheme.primaryContainer;
    final border = broken
        ? scheme.error
        : offline || !pending
            ? scheme.outlineVariant
            : scheme.primary;
    final fg = broken
        ? scheme.onErrorContainer
        : offline || !pending
            ? scheme.onSurfaceVariant
            : scheme.onPrimaryContainer;

    final icon = broken
        ? Icons.sync_problem_rounded
        : offline
            ? Icons.cloud_off_rounded
            : pending
                ? Icons.sync_rounded
                : Icons.cloud_done_rounded;
    final label = broken
        ? '$deadCount'
        : offline
            ? (pending ? '$count' : l.syncOffline)
            : pending
                ? '$count'
                : l.syncSynced;
    final semanticLabel = broken
        ? l.syncProblemsTitle
        : offline
            ? l.syncOffline
            : pending
                ? l.syncPending(count)
                : l.syncSynced;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: SuuqSpacing.xs),
      child: Semantics(
        label: semanticLabel,
        button: broken,
        excludeSemantics: true,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: broken ? () => _showDeadLetterDetails(context, ref) : null,
          // Keep the visible chip compact but give the tap/focus target the
          // minimum 48dp accessible size.
          child: Container(
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
            alignment: Alignment.center,
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
                  Icon(icon, size: 14, color: fg),
                  const SizedBox(width: 6),
                  Text(
                    label,
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
                        final l = ctx.l10n;
                        final theme = Theme.of(ctx);
                        final raw = e.lastError;
                        return ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Text(_opLabel(l, e.op)),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(_errorExplanation(l, e)),
                              // Keep the raw server error visible (smaller)
                              // so support can still diagnose the exact cause.
                              if (raw != null && raw.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    raw,
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: theme.colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                            ],
                          ),
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

  /// Friendly, localized name for a sync-queue op ('sale.create',
  /// 'debt.payment.create', ...). Falls back to the raw op so new ops
  /// are never hidden.
  String _opLabel(AppLocalizations l, String op) {
    if (op.startsWith('sale.')) return l.syncOpSale;
    if (op.startsWith('product.') || op.startsWith('recipe.')) {
      return l.syncOpProduct;
    }
    if (op.startsWith('debt.payment')) return l.syncOpDebtPayment;
    if (op == 'debt.writeoff') return l.syncOpDebtWriteoff;
    if (op.startsWith('stock.') ||
        op.startsWith('inventory.') ||
        op.startsWith('production.')) {
      return l.syncOpStock;
    }
    if (op.startsWith('expense.')) return l.syncOpExpense;
    if (op.startsWith('shift.')) return l.syncOpShift;
    if (op.startsWith('supply.')) return l.syncOpSupply;
    return op;
  }

  /// Short localized explanation of why an event dead-lettered, derived from
  /// its status and the raw `lastError` heuristically (e.g. "http 409: ...").
  String _errorExplanation(AppLocalizations l, SyncEventRow e) {
    // Conflicts were resolved in the server's favour — explain that in the
    // user's language instead of echoing the raw server detail.
    if (e.status == 'conflict') return l.syncConflictKeptServer;
    final err = (e.lastError ?? '').toLowerCase();
    if (err.contains('owner pin') || err.contains('owner_pin')) {
      return l.syncErrorPinRequired;
    }
    if (err.startsWith('gave up after')) return l.syncErrorGaveUp;
    if (e.status == 'rejected' || err.contains('http 4')) {
      return l.syncErrorRejected;
    }
    return l.syncErrorFailed;
  }
}
