import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/features/settings/presentation/employees_screen.dart';
import 'package:suuqii/shared/widgets/empty_state.dart';
import 'package:suuqii/shared/widgets/status_pill.dart';

final _devicesProvider = FutureProvider.autoDispose<List<_DeviceSession>>(
  (ref) async {
    final api = ref.watch(authApiProvider);
    final rows = await api.listDevices();
    return rows.map(_DeviceSession.fromJson).toList();
  },
);

class _DeviceSession {
  _DeviceSession({
    required this.sessionId,
    required this.userName,
    required this.userRole,
    required this.revoked,
    this.deviceLabel,
    this.lastSeenAt,
  });

  factory _DeviceSession.fromJson(Map<String, dynamic> j) => _DeviceSession(
        sessionId: j['session_id'] as String,
        userName: j['user_name'] as String,
        userRole: j['user_role'] as String,
        revoked: j['revoked'] as bool,
        deviceLabel: j['device_label'] as String?,
        lastSeenAt: DateTime.tryParse(
          (j['last_seen_at'] as String?) ?? (j['created_at'] as String? ?? ''),
        ),
      );

  final String sessionId;
  final String userName;
  final String userRole;
  final bool revoked;
  final String? deviceLabel;
  final DateTime? lastSeenAt;
}

/// Owner-only: every device session for the shop, with a remote sign-out
/// (revoke) action. Reached from the Employees screen.
class DevicesScreen extends ConsumerWidget {
  const DevicesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final async = ref.watch(_devicesProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l.devicesTitle)),
      body: RefreshIndicator(
        onRefresh: () async => ref.refresh(_devicesProvider.future),
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => EmptyState(
            icon: Icons.error_outline,
            title: l.devicesLoadFailedTitle,
            message: context.errorMessage(e),
          ),
          data: (list) {
            if (list.isEmpty) {
              return EmptyState(
                icon: Icons.devices_rounded,
                title: l.devicesEmptyTitle,
                message: l.devicesEmptyMessage,
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.all(SuuqSpacing.md),
              itemCount: list.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(height: SuuqSpacing.xs),
              itemBuilder: (_, i) => _DeviceRow(
                session: list[i],
                onRevoke: (s) => _revoke(context, ref, s),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _revoke(
    BuildContext context,
    WidgetRef ref,
    _DeviceSession s,
  ) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.devicesRevokeTitle),
        content: Text(l.devicesRevokeBody(s.userName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.commonCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.devicesRevoke),
          ),
        ],
      ),
    );
    if (!(confirmed ?? false)) return;
    try {
      await ref.read(authApiProvider).revokeDevice(s.sessionId);
      messenger.showSnackBar(SnackBar(content: Text(l.devicesRevoked)));
    } catch (err) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(l.employeesActionFailed(localizedErrorMessage(l, err))),
        ),
      );
    }
    // ignore: unused_result
    ref.refresh(_devicesProvider);
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.session, required this.onRevoke});
  final _DeviceSession session;
  final void Function(_DeviceSession) onRevoke;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lastSeen = session.lastSeenAt;
    return Material(
      color: scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(SuuqRadius.md),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(SuuqRadius.md),
          border: Border.all(color: scheme.outlineVariant),
        ),
        padding: const EdgeInsets.all(SuuqSpacing.md),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(SuuqRadius.sm),
              ),
              child: Icon(
                Icons.phone_iphone_rounded,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: SuuqSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(session.userName, style: theme.textTheme.titleSmall),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (session.deviceLabel != null &&
                          session.deviceLabel!.isNotEmpty)
                        session.deviceLabel!,
                      if (lastSeen != null)
                        l.devicesLastSeen(
                          _relative(l, lastSeen.toLocal()),
                        ),
                    ].join(' · '),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: SuuqSpacing.sm),
            if (session.revoked)
              StatusPill(label: l.devicesPillRevoked)
            else
              TextButton(
                style: TextButton.styleFrom(foregroundColor: scheme.error),
                onPressed: () => onRevoke(session),
                child: Text(l.devicesRevoke),
              ),
          ],
        ),
      ),
    );
  }

  /// Compact relative time, reusing the dashboard's "x ago" strings.
  static String _relative(AppLocalizations l, DateTime when) {
    final diff = DateTime.now().difference(when);
    if (diff.inMinutes < 1) return l.dashboardJustNow;
    if (diff.inMinutes < 60) return l.dashboardMinutesAgo(diff.inMinutes);
    if (diff.inHours < 24) return l.dashboardHoursAgo(diff.inHours);
    return l.dashboardDaysAgo(diff.inDays);
  }
}
