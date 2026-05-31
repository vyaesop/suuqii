import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/http/dio_client.dart';
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
    final async = ref.watch(_openShiftsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Open shifts')),
      body: RefreshIndicator(
        onRefresh: () async => ref.refresh(_openShiftsProvider.future),
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => EmptyState(
            icon: Icons.error_outline,
            title: "Couldn't load",
            message: '$e',
          ),
          data: (shifts) {
            if (shifts.isEmpty) {
              return const EmptyState(
                icon: Icons.check_circle_outline_rounded,
                title: 'No open shifts',
                message: 'Everyone has closed out cleanly.',
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
    final messenger = ScaffoldMessenger.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Force-close shift?'),
        content: Text(
          'This shift has been open ${shift.openHours.toStringAsFixed(1)} '
          'hours. Force-closing sets declared cash to the expected amount '
          '(zero variance) and logs the action in the audit trail. '
          'Use this only when the cashier is unreachable.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Force-close'),
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
      messenger.showSnackBar(const SnackBar(content: Text('Shift closed')));
      // ignore: unused_result
      ref.refresh(_openShiftsProvider);
    } on DioException catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Failed: ${e.response?.data ?? e.message}')),
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
                      '${shift.openHours.toStringAsFixed(1)}h open',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: stale ? scheme.error : null,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      'Since ${_formatDateTime(shift.openedAt.toLocal())}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (stale)
                const StatusPill(label: 'STALE', intent: PillIntent.danger)
              else
                const StatusPill(label: 'OPEN'),
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
                  label: const Text('Force-close'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  static String _formatDateTime(DateTime d) {
    String p(int n) => n < 10 ? '0$n' : '$n';
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }
}
