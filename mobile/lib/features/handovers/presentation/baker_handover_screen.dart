import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/features/handovers/data/handovers_repository.dart';
import 'package:suuqii/features/handovers/domain/entities/handover.dart';
import 'package:suuqii/features/inventory/data/products_repository.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';

/// The baker's whole app: what came out of the oven, and how much of it went to
/// the counter.
///
/// One submit, two facts — production (which consumes the flour) and the
/// declared handover (the first of two counts). Deliberately shows no prices:
/// see `Authenticated.canSeeMoney`.
class BakerHandoverScreen extends ConsumerStatefulWidget {
  const BakerHandoverScreen({super.key});

  @override
  ConsumerState<BakerHandoverScreen> createState() =>
      _BakerHandoverScreenState();
}

class _BakerHandoverScreenState extends ConsumerState<BakerHandoverScreen> {
  /// productId → draft entry. Only products the baker actually touched today
  /// appear here, so an untouched product never records a zero bake.
  final _draft = <String, _DraftEntry>{};
  bool _submitting = false;

  @override
  void dispose() {
    for (final e in _draft.values) {
      e.dispose();
    }
    super.dispose();
  }

  _DraftEntry _entryFor(String productId) =>
      _draft.putIfAbsent(productId, _DraftEntry.new);

  int get _lineCount => _draft.values.where((e) => e.hasAnything).length;

  Decimal get _totalHanded => _draft.values.fold(
        Decimal.zero,
        (sum, e) => sum + (e.handed ?? Decimal.zero),
      );

  Future<void> _submit() async {
    final l = context.l10n;
    final products =
        ref.read(watchProductsProvider()).valueOrNull ?? const <Product>[];
    final byId = {for (final p in products) p.id: p};

    final lines = <HandoverDraftLine>[];
    for (final entry in _draft.entries) {
      final e = entry.value;
      if (!e.hasAnything) continue;
      final product = byId[entry.key];
      if (product == null) continue;
      final produced = e.produced ?? Decimal.zero;
      final spoiled = e.spoiled ?? Decimal.zero;
      // Default: everything good went to the counter.
      final handed = e.handed ?? (produced - spoiled);
      if (handed > produced - spoiled) {
        _toast(l.handoverErrorHandedExceedsBaked(product.name));
        return;
      }
      lines.add(
        HandoverDraftLine(
          productId: product.id,
          productName: product.name,
          produced: produced,
          spoiled: spoiled > Decimal.zero ? spoiled : null,
          handed: handed,
        ),
      );
    }
    if (lines.isEmpty) {
      _toast(l.handoverErrorNothingEntered);
      return;
    }

    setState(() => _submitting = true);
    try {
      await ref.read(handoversRepositoryProvider).submitBake(lines: lines);
      if (!mounted) return;
      for (final e in _draft.values) {
        e.dispose();
      }
      setState(_draft.clear);
      _toast(l.handoverSubmitted(lines.length));
    } catch (e) {
      if (mounted) _toast(localizedErrorMessage(l, e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final products = ref.watch(watchProductsProvider());
    final recent =
        ref.watch(recentHandoversProvider).valueOrNull ?? const <Handover>[];

    return products.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text(l.handoverLoadFailedTitle)),
      data: (items) {
        if (items.isEmpty) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(SuuqSpacing.lg),
              child: Text(
                l.handoverNoProducts,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ),
          );
        }
        return Column(
          children: [
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: SuuqSpacing.xl),
                itemCount: items.length + (recent.isEmpty ? 0 : 1),
                itemBuilder: (context, i) {
                  if (i == items.length) {
                    return _RecentStrip(handovers: recent);
                  }
                  final p = items[i];
                  return _ProductRow(
                    product: p,
                    entry: _entryFor(p.id),
                    onChanged: () => setState(() {}),
                  );
                },
              ),
            ),
            _SubmitBar(
              lineCount: _lineCount,
              totalHanded: _totalHanded,
              submitting: _submitting,
              onSubmit: _lineCount == 0 || _submitting ? null : _submit,
            ),
          ],
        );
      },
    );
  }
}

/// Mutable per-product draft. `handed` stays null until the baker overrides it,
/// so the common case (everything good goes out) needs no typing.
class _DraftEntry {
  final producedCtrl = TextEditingController();
  final spoiledCtrl = TextEditingController();
  final handedCtrl = TextEditingController();

  Decimal? get produced => _parse(producedCtrl.text);
  Decimal? get spoiled => _parse(spoiledCtrl.text);
  Decimal? get handed => _parse(handedCtrl.text) ?? _impliedHanded;

  Decimal? get _impliedHanded {
    final p = produced;
    if (p == null) return null;
    return p - (spoiled ?? Decimal.zero);
  }

  bool get hasAnything =>
      produced != null || spoiled != null || _parse(handedCtrl.text) != null;

  static Decimal? _parse(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return null;
    final v = Decimal.tryParse(t);
    if (v == null || v < Decimal.zero) return null;
    return v;
  }

  void dispose() {
    producedCtrl.dispose();
    spoiledCtrl.dispose();
    handedCtrl.dispose();
  }
}

class _ProductRow extends StatelessWidget {
  const _ProductRow({
    required this.product,
    required this.entry,
    required this.onChanged,
  });

  final Product product;
  final _DraftEntry entry;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final active = entry.hasAnything;

    return Container(
      margin: const EdgeInsets.fromLTRB(
        SuuqSpacing.md,
        SuuqSpacing.xs,
        SuuqSpacing.md,
        0,
      ),
      padding: const EdgeInsets.all(SuuqSpacing.md),
      decoration: BoxDecoration(
        color: active ? scheme.primaryContainer.withValues(alpha: 0.25) : null,
        border: Border.all(
          color: active ? scheme.primary : scheme.outlineVariant,
        ),
        borderRadius: BorderRadius.circular(SuuqRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            product.name,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: SuuqSpacing.sm),
          Row(
            children: [
              Expanded(
                child: _QtyField(
                  controller: entry.producedCtrl,
                  label: l.handoverBakedLabel,
                  suffix: product.unit,
                  onChanged: onChanged,
                ),
              ),
              const SizedBox(width: SuuqSpacing.sm),
              Expanded(
                child: _QtyField(
                  controller: entry.spoiledCtrl,
                  label: l.handoverSpoiledLabel,
                  suffix: product.unit,
                  onChanged: onChanged,
                ),
              ),
              const SizedBox(width: SuuqSpacing.sm),
              Expanded(
                child: _QtyField(
                  controller: entry.handedCtrl,
                  label: l.handoverHandedLabel,
                  suffix: product.unit,
                  hint: entry._impliedHanded?.toString(),
                  onChanged: onChanged,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _QtyField extends StatelessWidget {
  const _QtyField({
    required this.controller,
    required this.label,
    required this.suffix,
    required this.onChanged,
    this.hint,
  });

  final TextEditingController controller;
  final String label;
  final String suffix;
  final String? hint;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      textAlign: TextAlign.center,
      decoration: InputDecoration(
        labelText: label,
        // The implied "handed" value shows as a hint so the baker sees what
        // will be recorded without having to type it.
        hintText: hint,
        isDense: true,
      ),
      onChanged: (_) => onChanged(),
    );
  }
}

class _SubmitBar extends StatelessWidget {
  const _SubmitBar({
    required this.lineCount,
    required this.totalHanded,
    required this.submitting,
    required this.onSubmit,
  });

  final int lineCount;
  final Decimal totalHanded;
  final bool submitting;
  final VoidCallback? onSubmit;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.all(SuuqSpacing.md),
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(top: BorderSide(color: scheme.outlineVariant)),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    l.handoverLineCount(lineCount),
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  Text(
                    l.handoverTotalUnits(totalHanded.toString()),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
            ),
            FilledButton(
              onPressed: onSubmit,
              child: submitting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(l.handoverSubmit),
            ),
          ],
        ),
      ),
    );
  }
}

/// The baker's own recent handovers and how they were reconciled. Seeing a
/// dispute land is the feedback loop that makes counting careful.
class _RecentStrip extends StatelessWidget {
  const _RecentStrip({required this.handovers});
  final List<Handover> handovers;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        SuuqSpacing.md,
        SuuqSpacing.lg,
        SuuqSpacing.md,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.handoverRecentTitle,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: SuuqSpacing.xs),
          for (final h in handovers.take(8))
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                switch (h.status) {
                  HandoverStatus.accepted => Icons.check_circle_rounded,
                  HandoverStatus.disputed => Icons.error_rounded,
                  HandoverStatus.pending => Icons.schedule_rounded,
                },
                color: switch (h.status) {
                  HandoverStatus.accepted => scheme.primary,
                  HandoverStatus.disputed => scheme.error,
                  HandoverStatus.pending => scheme.onSurfaceVariant,
                },
              ),
              title: Text(context.dateTimeShort(h.occurredAt.toLocal())),
              subtitle: Text(
                switch (h.status) {
                  HandoverStatus.pending =>
                    l.handoverStatusPending(h.totalHanded.toString()),
                  HandoverStatus.accepted =>
                    l.handoverStatusAccepted(h.totalHanded.toString()),
                  HandoverStatus.disputed =>
                    l.handoverStatusDisputed(h.grossVariance.toString()),
                },
              ),
            ),
        ],
      ),
    );
  }
}
