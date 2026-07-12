import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/expenses/data/expenses_repository.dart';
import 'package:suuqii/features/expenses/domain/entities/expense.dart';
import 'package:suuqii/shared/widgets/owner_pin_dialog.dart';

/// Localized display name for a machine expense category value.
String _categoryLabel(AppLocalizations l, String category) =>
    switch (category) {
      'rent' => l.expenseCategoryRent,
      'transport' => l.expenseCategoryTransport,
      'utilities' => l.expenseCategoryUtilities,
      'salary' => l.expenseCategorySalary,
      'supplies' => l.expenseCategorySupplies,
      'other' => l.expenseCategoryOther,
      _ => category,
    };

class ExpensesScreen extends ConsumerStatefulWidget {
  const ExpensesScreen({super.key});

  @override
  ConsumerState<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends ConsumerState<ExpensesScreen> {
  bool _kicked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_kicked) {
        _kicked = true;
        ref.read(expensesSyncProvider.notifier).refresh();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final asyncList = ref.watch(watchExpensesProvider);
    final l = context.l10n;
    return Scaffold(
      appBar: AppBar(title: Text(l.expenses)),
      body: RefreshIndicator(
        onRefresh: () => ref.read(expensesSyncProvider.notifier).refresh(),
        child: asyncList.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text(context.errorMessage(e))),
          data: (items) {
            if (items.isEmpty) {
              return Center(child: Text(l.expenseEmpty));
            }
            return ListView.separated(
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (_, i) {
                final e = items[i];
                return ListTile(
                  leading: CircleAvatar(
                    child: Icon(_iconFor(e.category), size: 20),
                  ),
                  title: Text(e.title),
                  subtitle: Text(
                    [
                      _categoryLabel(l, e.category),
                      context.dateTimeShort(e.occurredAt.toLocal()),
                    ].join(' · '),
                  ),
                  trailing: Text(
                    context.money(e.amount),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                );
              },
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: Text(l.expenseAddTitle),
        onPressed: () => _showAdd(context),
      ),
    );
  }

  IconData _iconFor(String category) => switch (category) {
        'rent' => Icons.home_outlined,
        'transport' => Icons.local_shipping_outlined,
        'utilities' => Icons.bolt_outlined,
        'salary' => Icons.payments_outlined,
        'supplies' => Icons.inventory_2_outlined,
        _ => Icons.receipt_long_outlined,
      };

  Future<void> _showAdd(BuildContext context) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final result = await showModalBottomSheet<
        ({String title, Decimal amount, String category, String? description})>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _AddSheet(),
    );
    if (result == null) return;

    // expense.create is threshold-sensitive (docs/17-roles.md): cashiers can
    // record small expenses freely; only amounts above the shop's approval
    // threshold need the owner PIN. Matches the server-side check in
    // sync_service so offline entries don't fail later.
    final auth = ref.read(authControllerProvider).valueOrNull;
    final isOwner = auth is Authenticated && auth.isOwner;
    final threshold = auth is Authenticated
        ? auth.expenseApprovalThresholdValue
        : defaultExpenseApprovalThreshold;
    String? challenge;
    if (!isOwner && result.amount > threshold) {
      if (!context.mounted) return;
      challenge = await requestOwnerChallenge(context, ref);
      if (challenge == null) return;
    }

    try {
      await ref.read(expensesRepositoryProvider).add(
            title: result.title,
            amount: result.amount,
            category: result.category,
            description: result.description,
            ownerChallengeToken: challenge,
          );
      messenger.showSnackBar(SnackBar(content: Text(l.expenseAdded)));
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(l.expenseActionFailed(localizedErrorMessage(l, e))),
        ),
      );
    }
  }
}

class _AddSheet extends StatefulWidget {
  const _AddSheet();

  @override
  State<_AddSheet> createState() => _AddSheetState();
}

class _AddSheetState extends State<_AddSheet> {
  final _title = TextEditingController();
  final _amount = TextEditingController();
  final _description = TextEditingController();
  String _category = expenseCategories.first;

  @override
  void dispose() {
    _title.dispose();
    _amount.dispose();
    _description.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l.expenseAddTitle,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _title,
                decoration: InputDecoration(labelText: l.expenseTitleLabel),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _amount,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: l.expenseAmountLabel,
                  prefixText: 'ETB  ',
                ),
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _category,
                decoration: InputDecoration(labelText: l.expenseCategoryLabel),
                items: expenseCategories
                    .map(
                      (c) => DropdownMenuItem(
                        value: c,
                        child: Text(_categoryLabel(l, c)),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _category = v ?? _category),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _description,
                decoration: InputDecoration(
                  labelText: l.expenseDescriptionOptional,
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () {
                  if (_title.text.trim().isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l.expenseTitleRequired)),
                    );
                    return;
                  }
                  final amt = Decimal.tryParse(_amount.text.trim());
                  if (amt == null || amt <= Decimal.zero) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l.expenseInvalidAmount)),
                    );
                    return;
                  }
                  Navigator.pop(
                    context,
                    (
                      title: _title.text.trim(),
                      amount: amt,
                      category: _category,
                      description: _description.text.trim().isEmpty
                          ? null
                          : _description.text.trim(),
                    ),
                  );
                },
                child: Text(l.commonSave),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
