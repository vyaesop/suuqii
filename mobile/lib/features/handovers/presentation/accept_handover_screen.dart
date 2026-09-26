import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/handovers/data/handovers_repository.dart';
import 'package:suuqii/features/handovers/domain/entities/handover.dart';
import 'package:suuqii/shared/widgets/sheet_handle.dart';

/// The counter's side: what the baker says they handed over, waiting to be
/// counted.
///
/// The counts are entered blind by default — the baker's number is hidden
/// behind a tap. Showing it first turns an independent count into a
/// confirmation, which is exactly the failure the whole feature exists to stop.
class AcceptHandoverScreen extends ConsumerWidget {
  const AcceptHandoverScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final pending = ref.watch(pendingHandoversProvider);
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final myUserId = auth is Authenticated ? auth.userId : null;

    return RefreshIndicator(
      onRefresh: () => ref.read(handoversSyncProvider.notifier).refresh(),
      child: pending.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text(l.handoverLoadFailedTitle)),
        data: (items) {
          if (items.isEmpty) {
            return ListView(
              children: [
                Padding(
                  padding: const EdgeInsets.all(SuuqSpacing.xl),
                  child: Column(
                    children: [
                      Icon(
                        Icons.inbox_rounded,
                        size: 48,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                      const SizedBox(height: SuuqSpacing.md),
                      Text(
                        l.handoverNothingPending,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ],
                  ),
                ),
              ],
            );
          }
          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: SuuqSpacing.sm),
            itemCount: items.length,
            itemBuilder: (context, i) => _PendingTile(
              handover: items[i],
              // A baker covering the counter must not confirm their own count.
              isOwnHandover: items[i].fromUserId == myUserId,
            ),
          );
        },
      ),
    );
  }
}

class _PendingTile extends ConsumerWidget {
  const _PendingTile({required this.handover, required this.isOwnHandover});

  final Handover handover;
  final bool isOwnHandover;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.symmetric(
        horizontal: SuuqSpacing.md,
        vertical: SuuqSpacing.xs,
      ),
      child: ListTile(
        title: Text(context.dateTimeShort(handover.occurredAt.toLocal())),
        subtitle: Text(
          isOwnHandover
              ? l.handoverCannotCountOwn
              : l.handoverPendingLines(handover.lines.length),
          style: isOwnHandover ? TextStyle(color: scheme.error) : null,
        ),
        trailing: isOwnHandover
            ? Icon(Icons.block_rounded, color: scheme.error)
            : const Icon(Icons.chevron_right_rounded),
        enabled: !isOwnHandover,
        onTap: isOwnHandover
            ? null
            : () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => _CountSheet(handover: handover),
                ),
      ),
    );
  }
}

class _CountSheet extends ConsumerStatefulWidget {
  const _CountSheet({required this.handover});
  final Handover handover;

  @override
  ConsumerState<_CountSheet> createState() => _CountSheetState();
}

class _CountSheetState extends ConsumerState<_CountSheet> {
  final _controllers = <String, TextEditingController>{};
  final _noteCtrl = TextEditingController();

  /// Product ids whose declared quantity the counter has chosen to reveal.
  final _revealed = <String>{};
  bool _submitting = false;

  @override
  void initState() {
    super.initState();
    for (final line in widget.handover.lines) {
      _controllers[line.productId] = TextEditingController();
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    _noteCtrl.dispose();
    super.dispose();
  }

  Map<String, Decimal>? _collect() {
    final out = <String, Decimal>{};
    for (final line in widget.handover.lines) {
      final raw = _controllers[line.productId]!.text.trim();
      if (raw.isEmpty) return null;
      final v = Decimal.tryParse(raw);
      if (v == null || v < Decimal.zero) return null;
      out[line.productId] = v;
    }
    return out;
  }

  Future<void> _submit() async {
    final l = context.l10n;
    final counts = _collect();
    if (counts == null) {
      SuuqSheet.showMessage(context, l.handoverErrorCountEveryLine);
      return;
    }
    setState(() => _submitting = true);
    try {
      await ref.read(handoversRepositoryProvider).acceptHandover(
            handoverId: widget.handover.id,
            countsByProductId: counts,
            note: _noteCtrl.text.trim().isEmpty ? null : _noteCtrl.text.trim(),
          );
      if (!mounted) return;
      final gaps = widget.handover.lines.where(
        (line) => counts[line.productId] != line.qtyHanded,
      );
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            gaps.isEmpty
                ? l.handoverAcceptedMatched
                : l.handoverAcceptedDisputed(gaps.length),
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(localizedErrorMessage(l, e))),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return SuuqSheet(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            l.handoverCountTitle,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: SuuqSpacing.xs),
          Text(
            l.handoverCountBlindHint,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: SuuqSpacing.md),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final line in widget.handover.lines)
                  Padding(
                    padding:
                        const EdgeInsets.only(bottom: SuuqSpacing.sm),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            line.productName,
                            style: Theme.of(context).textTheme.bodyLarge,
                          ),
                        ),
                        SizedBox(
                          width: 92,
                          child: TextField(
                            controller: _controllers[line.productId],
                            keyboardType:
                                const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            textAlign: TextAlign.center,
                            decoration: InputDecoration(
                              labelText: l.handoverCountedLabel,
                              isDense: true,
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 72,
                          child: _revealed.contains(line.productId)
                              ? Text(
                                  l.handoverDeclaredValue(
                                    line.qtyHanded.toString(),
                                  ),
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context).textTheme.bodySmall,
                                )
                              : TextButton(
                                  onPressed: () => setState(
                                    () => _revealed.add(line.productId),
                                  ),
                                  child: Text(l.handoverReveal),
                                ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: SuuqSpacing.sm),
          TextField(
            controller: _noteCtrl,
            decoration: InputDecoration(labelText: l.handoverNoteLabel),
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: SuuqSpacing.lg),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            child: _submitting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(l.handoverConfirmCount),
          ),
        ],
      ),
    );
  }
}
