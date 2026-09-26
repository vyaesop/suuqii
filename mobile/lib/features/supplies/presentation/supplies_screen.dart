import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/supplies/data/supplies_repository.dart';
import 'package:suuqii/features/supplies/domain/entities/supply.dart';
import 'package:suuqii/shared/widgets/expiry_badge.dart';
import 'package:suuqii/shared/widgets/owner_pin_dialog.dart';
import 'package:suuqii/shared/widgets/sheet_handle.dart';

const _supplyUnits = [
  'piece',
  'kg',
  'quintal',
  'g',
  'liter',
  'ml',
  'cup',
  'pack',
];

/// Display label for a machine unit value (the value itself is persisted and
/// must stay in English). Falls back to the raw value for unknown units.
String _unitDisplayLabel(AppLocalizations l, String unit) {
  switch (unit) {
    case 'piece':
      return l.unitPiece;
    case 'kg':
      return l.unitKg;
    case 'g':
      return l.unitG;
    case 'mg':
      return l.unitMg;
    case 'quintal':
      return l.unitQuintal;
    case 'liter':
      return l.unitLiter;
    case 'ml':
      return l.unitMl;
    case 'cup':
      return l.unitCup;
    case 'pack':
      return l.unitPack;
    case 'm':
      return l.unitMeter;
    default:
      return unit;
  }
}

class SuppliesScreen extends ConsumerWidget {
  const SuppliesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final asyncList = ref.watch(watchSuppliesProvider);
    final lowAsync = ref.watch(watchLowSuppliesProvider);
    final auth = ref.watch(authControllerProvider).valueOrNull;
    // Cost-per-unit is financially sensitive; cashiers see quantities only
    // (same masking rule as product purchase prices in docs/17-roles.md).
    final isOwner = auth is Authenticated && auth.isOwner;

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async {},
        child: asyncList.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text(context.errorMessage(e))),
          data: (items) {
            final lowCount = lowAsync.valueOrNull?.length ?? 0;
            return CustomScrollView(
              slivers: [
                if (lowCount > 0)
                  SliverToBoxAdapter(
                    child: _LowStockBanner(count: lowCount),
                  ),
                if (items.isEmpty)
                  SliverFillRemaining(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.inventory_2_outlined, size: 48),
                          const SizedBox(height: 12),
                          Text(l.suppliesEmptyTitle),
                          const SizedBox(height: 4),
                          Text(
                            l.suppliesEmptyMessage,
                            style: const TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  SliverList.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (ctx, i) => _SupplyTile(
                      supply: items[i],
                      showCost: isOwner,
                      onTap: () => _showEdit(ctx, ref, supply: items[i]),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: Text(l.suppliesAddButton),
        onPressed: () => _showEdit(context, ref),
      ),
    );
  }

  Future<void> _showEdit(
    BuildContext context,
    WidgetRef ref, {
    Supply? supply,
  }) async {
    final l = context.l10n;
    final auth = ref.read(authControllerProvider).valueOrNull;
    final isOwner = auth is Authenticated && auth.role == 'owner';

    String? challenge;
    if (!isOwner) {
      if (!context.mounted) return;
      challenge = await requestOwnerChallenge(context, ref);
      if (challenge == null) return;
    }

    if (!context.mounted) return;
    final result = await showModalBottomSheet<_SupplyFormResult>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SupplyFormSheet(supply: supply),
    );
    if (result == null || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    try {
      final repo = ref.read(suppliesRepositoryProvider);
      if (supply == null) {
        await repo.create(
          name: result.name,
          unit: result.unit,
          quantityOnHand: result.quantityOnHand,
          reorderThreshold: result.reorderThreshold,
          costPerUnit: result.costPerUnit,
          expiryDate: result.expiryDate,
          ownerChallengeToken: challenge,
        );
        messenger.showSnackBar(SnackBar(content: Text(l.suppliesAdded)));
      } else {
        await repo.update(
          id: supply.id,
          name: result.name,
          unit: result.unit,
          quantityOnHand: result.quantityOnHand,
          reorderThreshold: result.reorderThreshold,
          costPerUnit: result.costPerUnit,
          expiryDate: result.expiryDate,
          ownerChallengeToken: challenge,
        );
        messenger.showSnackBar(SnackBar(content: Text(l.suppliesUpdated)));
      }
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text(localizedErrorMessage(l, e))),
      );
    }
  }
}

class _LowStockBanner extends StatelessWidget {
  const _LowStockBanner({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.all(SuuqSpacing.md),
      padding: const EdgeInsets.symmetric(
        horizontal: SuuqSpacing.md,
        vertical: SuuqSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(SuuqRadius.md),
      ),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            color: scheme.onErrorContainer,
            size: 20,
          ),
          const SizedBox(width: SuuqSpacing.sm),
          Expanded(
            child: Text(
              context.l10n.suppliesRunningLow(count),
              style: TextStyle(
                color: scheme.onErrorContainer,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SupplyTile extends StatelessWidget {
  const _SupplyTile({
    required this.supply,
    required this.showCost,
    required this.onTap,
  });
  final Supply supply;
  final bool showCost;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isLow = supply.isLow;
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor:
            isLow ? scheme.errorContainer : scheme.primaryContainer,
        child: Icon(
          Icons.egg_alt_outlined,
          size: 20,
          color: isLow ? scheme.onErrorContainer : scheme.onPrimaryContainer,
        ),
      ),
      title: Row(
        children: [
          Expanded(child: Text(supply.name)),
          if (supply.expiryDate != null && supply.expiresWithin(7)) ...[
            ExpiryBadge(
              expiryDate: supply.expiryDate!,
              daysToExpiry: supply.daysToExpiry ?? 0,
            ),
            const SizedBox(width: SuuqSpacing.xs),
          ],
          if (isLow)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                context.l10n.suppliesLowBadge,
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onErrorContainer,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
      subtitle: Text(
        showCost
            ? context.l10n.suppliesTileSubtitle(
                supply.quantityOnHand.toStringAsFixed(2),
                supply.unit,
                context.money(supply.costPerUnit),
              )
            : context.l10n.suppliesTileSubtitleNoCost(
                supply.quantityOnHand.toStringAsFixed(2),
                supply.unit,
              ),
      ),
      trailing: const Icon(Icons.chevron_right_rounded, size: 18),
    );
  }
}

class _SupplyFormResult {
  const _SupplyFormResult({
    required this.name,
    required this.unit,
    required this.quantityOnHand,
    required this.reorderThreshold,
    required this.costPerUnit,
    this.expiryDate,
  });
  final String name;
  final String unit;
  final Decimal quantityOnHand;
  final Decimal reorderThreshold;
  final Decimal costPerUnit;
  final DateTime? expiryDate;
}

class _SupplyFormSheet extends StatefulWidget {
  const _SupplyFormSheet({this.supply});
  final Supply? supply;

  @override
  State<_SupplyFormSheet> createState() => _SupplyFormSheetState();
}

class _SupplyFormSheetState extends State<_SupplyFormSheet> {
  final _name = TextEditingController();
  final _qty = TextEditingController(text: '0');
  final _reorder = TextEditingController(text: '0');
  final _cost = TextEditingController(text: '0');
  String _unit = 'piece';
  DateTime? _expiry;

  @override
  void initState() {
    super.initState();
    if (widget.supply != null) {
      final s = widget.supply!;
      _name.text = s.name;
      _qty.text = s.quantityOnHand.toStringAsFixed(2);
      _reorder.text = s.reorderThreshold.toStringAsFixed(2);
      _cost.text = s.costPerUnit.toStringAsFixed(2);
      _unit = s.unit;
      _expiry = s.expiryDate;
    }
  }

  Future<void> _pickExpiry() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _expiry ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (picked != null) setState(() => _expiry = picked);
  }

  @override
  void dispose() {
    _name.dispose();
    _qty.dispose();
    _reorder.dispose();
    _cost.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final isEdit = widget.supply != null;
    return SuuqSheet(
      padding: const EdgeInsets.all(SuuqSpacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            isEdit ? l.suppliesEditTitle : l.suppliesNewTitle,
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: SuuqSpacing.md),
          TextField(
            controller: _name,
            decoration: InputDecoration(labelText: l.suppliesNameLabel),
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: SuuqSpacing.sm),
          DropdownButtonFormField<String>(
            initialValue: _unit,
            decoration: InputDecoration(labelText: l.suppliesUnitLabel),
            items: _supplyUnits
                .map(
                  (u) => DropdownMenuItem(
                    value: u,
                    child: Text(_unitDisplayLabel(l, u)),
                  ),
                )
                .toList(),
            onChanged: (v) => setState(() => _unit = v ?? _unit),
          ),
          const SizedBox(height: SuuqSpacing.sm),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _qty,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: l.suppliesOnHandLabel,
                    suffixText: _unit,
                  ),
                ),
              ),
              const SizedBox(width: SuuqSpacing.sm),
              Expanded(
                child: TextField(
                  controller: _reorder,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(
                    labelText: l.suppliesAlertBelowLabel,
                    suffixText: _unit,
                    helperText: l.suppliesAlertBelowHelper,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: SuuqSpacing.sm),
          TextField(
            controller: _cost,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: l.suppliesCostPerUnitLabel(_unit),
              prefixText: 'ETB  ',
            ),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: SuuqSpacing.sm),
          InkWell(
            onTap: _pickExpiry,
            borderRadius: BorderRadius.circular(SuuqRadius.sm),
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: l.stockReceiveExpiryLabel,
                suffixIcon: _expiry == null
                    ? const Icon(Icons.event_rounded)
                    : IconButton(
                        icon: const Icon(Icons.clear_rounded, size: 18),
                        onPressed: () => setState(() => _expiry = null),
                      ),
              ),
              child: Text(
                _expiry == null
                    ? l.stockReceiveNoExpiry
                    : context.dateShort(_expiry!),
              ),
            ),
          ),
          const SizedBox(height: SuuqSpacing.lg),
          FilledButton(
            onPressed: _submit,
            child: Text(
              isEdit ? l.commonSaveChanges : l.suppliesAddButton,
            ),
          ),
        ],
      ),
    );
  }

  void _submit() {
    if (_name.text.trim().isEmpty) {
      SuuqSheet.showMessage(context, context.l10n.suppliesNameRequired);
      return;
    }
    final qty = Decimal.tryParse(_qty.text.trim()) ?? Decimal.zero;
    final reorder = Decimal.tryParse(_reorder.text.trim()) ?? Decimal.zero;
    final cost = Decimal.tryParse(_cost.text.trim()) ?? Decimal.zero;

    Navigator.pop(
      context,
      _SupplyFormResult(
        name: _name.text.trim(),
        unit: _unit,
        quantityOnHand: qty,
        reorderThreshold: reorder,
        costPerUnit: cost,
        expiryDate: _expiry,
      ),
    );
  }
}
