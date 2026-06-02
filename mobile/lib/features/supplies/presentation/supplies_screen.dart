import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/utils/money.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/supplies/data/supplies_repository.dart';
import 'package:suuqii/features/supplies/domain/entities/supply.dart';
import 'package:suuqii/shared/widgets/owner_pin_dialog.dart';

const _supplyUnits = ['piece', 'kg', 'quintal', 'g', 'liter', 'ml', 'cup', 'pack'];

class SuppliesScreen extends ConsumerWidget {
  const SuppliesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final asyncList = ref.watch(watchSuppliesProvider);
    final lowAsync = ref.watch(watchLowSuppliesProvider);

    return Scaffold(
      body: RefreshIndicator(
        onRefresh: () async {},
        child: asyncList.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
          data: (items) {
            final lowCount = lowAsync.valueOrNull?.length ?? 0;
            return CustomScrollView(
              slivers: [
                if (lowCount > 0)
                  SliverToBoxAdapter(
                    child: _LowStockBanner(count: lowCount),
                  ),
                if (items.isEmpty)
                  const SliverFillRemaining(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.inventory_2_outlined, size: 48),
                          SizedBox(height: 12),
                          Text('No supplies yet'),
                          SizedBox(height: 4),
                          Text(
                            'Add your ingredients to track costs',
                            style: TextStyle(fontSize: 12),
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
        label: const Text('Add supply'),
        onPressed: () => _showEdit(context, ref),
      ),
    );
  }

  Future<void> _showEdit(
    BuildContext context,
    WidgetRef ref, {
    Supply? supply,
  }) async {
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
          ownerChallengeToken: challenge,
        );
        messenger.showSnackBar(const SnackBar(content: Text('Supply added')));
      } else {
        await repo.update(
          id: supply.id,
          name: result.name,
          unit: result.unit,
          quantityOnHand: result.quantityOnHand,
          reorderThreshold: result.reorderThreshold,
          costPerUnit: result.costPerUnit,
          ownerChallengeToken: challenge,
        );
        messenger.showSnackBar(const SnackBar(content: Text('Supply updated')));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
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
          Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer, size: 20),
          const SizedBox(width: SuuqSpacing.sm),
          Expanded(
            child: Text(
              '$count ${count == 1 ? 'supply is' : 'supplies are'} running low',
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
  const _SupplyTile({required this.supply, required this.onTap});
  final Supply supply;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isLow = supply.isLow;
    return ListTile(
      onTap: onTap,
      leading: CircleAvatar(
        backgroundColor: isLow ? scheme.errorContainer : scheme.primaryContainer,
        child: Icon(
          Icons.egg_alt_outlined,
          size: 20,
          color: isLow ? scheme.onErrorContainer : scheme.onPrimaryContainer,
        ),
      ),
      title: Row(
        children: [
          Expanded(child: Text(supply.name)),
          if (isLow)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'Low',
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
        '${supply.quantityOnHand.toStringAsFixed(2)} ${supply.unit}'
        '  ·  ${formatMoney(supply.costPerUnit)} per ${supply.unit}',
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
  });
  final String name;
  final String unit;
  final Decimal quantityOnHand;
  final Decimal reorderThreshold;
  final Decimal costPerUnit;
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
    }
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
    final theme = Theme.of(context);
    final isEdit = widget.supply != null;
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(SuuqSpacing.lg),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                isEdit ? 'Edit supply' : 'New supply',
                style: theme.textTheme.titleLarge,
              ),
              const SizedBox(height: SuuqSpacing.md),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name'),
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: SuuqSpacing.sm),
              DropdownButtonFormField<String>(
                initialValue: _unit,
                decoration: const InputDecoration(labelText: 'Unit'),
                items: _supplyUnits
                    .map((u) => DropdownMenuItem(value: u, child: Text(u)))
                    .toList(),
                onChanged: (v) => setState(() => _unit = v ?? _unit),
              ),
              const SizedBox(height: SuuqSpacing.sm),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _qty,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: 'On hand',
                        suffixText: _unit,
                      ),
                    ),
                  ),
                  const SizedBox(width: SuuqSpacing.sm),
                  Expanded(
                    child: TextField(
                      controller: _reorder,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: 'Alert below',
                        suffixText: _unit,
                        helperText: 'Low-stock threshold',
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
                  labelText: 'Cost per $_unit',
                  prefixText: 'ETB  ',
                ),
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: SuuqSpacing.lg),
              FilledButton(
                onPressed: _submit,
                child: Text(isEdit ? 'Save changes' : 'Add supply'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _submit() {
    if (_name.text.trim().isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Name required')));
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
      ),
    );
  }
}
