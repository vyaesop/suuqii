import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/http/dio_client.dart';
import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/shared/widgets/empty_state.dart';
import 'package:suuqii/shared/widgets/section_card.dart';
import 'package:suuqii/shared/widgets/status_pill.dart';

class _OpenShift {
  _OpenShift({
    required this.id,
    required this.userId,
    required this.openedAt,
    required this.openHours,
    required this.forceCloseable,
  });

  factory _OpenShift.fromJson(Map<String, dynamic> j) => _OpenShift(
        id: j['id'] as String,
        userId: j['user_id'] as String,
        openedAt: DateTime.parse(j['opened_at'] as String),
        openHours: (j['open_hours'] as num).toDouble(),
        forceCloseable: j['force_closeable'] as bool,
      );

  final String id;
  final String userId;
  final DateTime openedAt;
  final double openHours;
  final bool forceCloseable;
}

final _openShiftsProvider =
    FutureProvider.autoDispose<List<_OpenShift>>((ref) async {
  final dio = ref.watch(dioProvider);
  final res = await dio.get<Map<String, dynamic>>('/v1/shifts/open');
  final items = (res.data!['items'] as List).cast<Map<String, dynamic>>();
  return items.map(_OpenShift.fromJson).toList();
});

class OpenShiftsScreen extends ConsumerWidget {
  const OpenShiftsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final async = ref.watch(_openShiftsProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l.settingsOpenShifts)),
      body: RefreshIndicator(
        onRefresh: () async => ref.refresh(_openShiftsProvider.future),
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => EmptyState(
            icon: Icons.error_outline,
            title: l.openShiftsLoadFailedTitle,
            message: context.errorMessage(e),
          ),
          data: (shifts) {
            if (shifts.isEmpty) {
              return EmptyState(
                icon: Icons.check_circle_outline_rounded,
                title: l.openShiftsEmptyTitle,
                message: l.openShiftsEmptyMessage,
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(
                SuuqSpacing.md,
                SuuqSpacing.md,
                SuuqSpacing.md,
                SuuqSpacing.lg,
              ),
              itemCount: shifts.length,
              separatorBuilder: (_, __) =>
                  const SizedBox(height: SuuqSpacing.xs),
              itemBuilder: (_, i) => _OpenShiftTile(
                shift: shifts[i],
                onForceClose: () => _forceClose(context, ref, shifts[i]),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _forceClose(
    BuildContext context,
    WidgetRef ref,
    _OpenShift shift,
  ) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ctx.l10n.openShiftsForceCloseTitle),
        content: Text(
          ctx.l10n.openShiftsForceCloseBody(
            shift.openHours.toStringAsFixed(1),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(ctx.l10n.commonCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(ctx.l10n.openShiftsForceCloseCta),
          ),
        ],
      ),
    );
    if (!(confirm ?? false)) return;

    try {
      final dio = ref.read(dioProvider);
      await dio.post<Map<String, dynamic>>(
        '/v1/shifts/${shift.id}/force-close',
      );
      messenger.showSnackBar(
        SnackBar(content: Text(l.openShiftsClosedSnack)),
      );
      // ignore: unused_result
      ref.refresh(_openShiftsProvider);
    } on DioException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(localizedErrorMessage(l, e))),
      );
    }
  }
}

class _OpenShiftTile extends StatelessWidget {
  const _OpenShiftTile({required this.shift, required this.onForceClose});
  final _OpenShift shift;
  final VoidCallback onForceClose;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final stale = shift.forceCloseable;
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: stale
                      ? scheme.errorContainer
                      : scheme.primaryContainer,
                  borderRadius: BorderRadius.circular(SuuqRadius.sm),
                ),
                child: Icon(
                  Icons.timelapse_rounded,
                  color: stale ? scheme.error : scheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: SuuqSpacing.sm),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.openShiftsHoursOpen(
                        shift.openHours.toStringAsFixed(1),
                      ),
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: stale ? scheme.error : null,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      l.openShiftsSince(
                        context.dateTimeShort(shift.openedAt.toLocal()),
                      ),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (stale)
                StatusPill(
                  label: l.openShiftsPillStale,
                  intent: PillIntent.danger,
                )
              else
                StatusPill(label: l.openShiftsPillOpen),
            ],
          ),
          if (stale) ...[
            const SizedBox(height: SuuqSpacing.sm),
            Row(
              children: [
                const Spacer(),
                OutlinedButton.icon(
                  icon: const Icon(Icons.flag_rounded, size: 18),
                  onPressed: onForceClose,
                  label: Text(l.openShiftsForceCloseCta),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
