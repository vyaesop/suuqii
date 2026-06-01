import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/core/utils/money.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/expenses/data/expenses_repository.dart';
import 'package:suuqii/features/expenses/domain/entities/expense.dart';
import 'package:suuqii/shared/widgets/owner_pin_dialog.dart';

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
    return Scaffold(
      appBar: AppBar(title: const Text('Expenses')),
      body: RefreshIndicator(
        onRefresh: () => ref.read(expensesSyncProvider.notifier).refresh(),
        child: asyncList.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('$e')),
          data: (items) {
            if (items.isEmpty) {
              return const Center(child: Text('No expenses yet'));
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
                      e.category,
                      e.occurredAt.toLocal().toString().split('.').first,
                    ].join(' · '),
                  ),
                  trailing: Text(
                    formatMoney(e.amount),
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
        label: const Text('Add expense'),
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
    final messenger = ScaffoldMessenger.of(context);
    final result = await showModalBottomSheet<
        ({String title, Decimal amount, String category, String? description})>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _AddSheet(),
    );
    if (result == null) return;

    // expense.create is sensitive — non-owners must authorize with owner PIN.
    final auth = ref.read(authControllerProvider).valueOrNull;
    final isOwner = auth is Authenticated && auth.role == 'owner';
    String? challenge;
    if (!isOwner) {
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
      messenger.showSnackBar(const SnackBar(content: Text('Expense added')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
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
                'Add expense',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _title,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _amount,
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(
                  labelText: 'Amount',
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
                decoration: const InputDecoration(labelText: 'Category'),
                items: expenseCategories
                    .map(
                      (c) => DropdownMenuItem(value: c, child: Text(c)),
                    )
                    .toList(),
                onChanged: (v) => setState(() => _category = v ?? _category),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _description,
                decoration: const InputDecoration(
                  labelText: 'Description (optional)',
                ),
                maxLines: 2,
              ),
              const SizedBox(height: 20),
              FilledButton(
                onPressed: () {
                  if (_title.text.trim().isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Title required')),
                    );
                    return;
                  }
                  final amt = Decimal.tryParse(_amount.text.trim());
                  if (amt == null || amt <= Decimal.zero) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Invalid amount')),
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
                child: const Text('Save'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
