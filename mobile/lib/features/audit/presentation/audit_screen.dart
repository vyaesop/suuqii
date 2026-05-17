import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/features/audit/data/audit_repository.dart';

class AuditScreen extends ConsumerStatefulWidget {
  const AuditScreen({super.key});

  @override
  ConsumerState<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends ConsumerState<AuditScreen> {
  String? _filter;

  static const _actionFilters = <(String?, String)>[
    (null, 'All'),
    ('products.update', 'Product edit'),
    ('products.insert', 'Product add'),
    ('sales.update', 'Sale change'),
    ('sales.delete', 'Sale delete'),
    ('debts.update', 'Debt change'),
    ('shifts.update', 'Shift close'),
  ];

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(auditEntriesProvider(action: _filter));
    return Scaffold(
      appBar: AppBar(title: const Text('Audit log')),
      body: Column(
        children: [
          SizedBox(
            height: 56,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              scrollDirection: Axis.horizontal,
              itemCount: _actionFilters.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final (value, label) = _actionFilters[i];
                final selected = _filter == value;
                return Center(
                  child: ChoiceChip(
                    label: Text(label),
                    selected: selected,
                    onSelected: (_) => setState(() => _filter = value),
                  ),
                );
              },
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async =>
                  ref.refresh(auditEntriesProvider(action: _filter)),
              child: entries.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('$e')),
                data: (items) {
                  if (items.isEmpty) {
                    return ListView(
                      children: const [
                        SizedBox(height: 80),
                        Center(child: Text('No audit entries')),
                      ],
                    );
                  }
                  return ListView.separated(
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) => _AuditTile(entry: items[i]),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AuditTile extends StatelessWidget {
  const _AuditTile({required this.entry});
  final AuditEntry entry;

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      leading: CircleAvatar(child: Icon(_iconFor(entry.action), size: 18)),
      title: Text(entry.action),
      subtitle: Text(
        '${entry.entityType} · ${entry.createdAt.toLocal().toString().split('.').first}',
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: [
        if (entry.oldValue != null) ...[
          const Text(
            'Before',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          _JsonBlock(entry.oldValue!),
        ],
        if (entry.newValue != null) ...[
          const SizedBox(height: 6),
          const Text(
            'After',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          _JsonBlock(entry.newValue!),
        ],
      ],
    );
  }

  IconData _iconFor(String action) {
    if (action.startsWith('products')) return Icons.inventory_2_outlined;
    if (action.startsWith('sales')) return Icons.point_of_sale_outlined;
    if (action.startsWith('debts')) return Icons.account_balance_wallet_outlined;
    if (action.startsWith('shifts')) return Icons.access_time;
    if (action.startsWith('expenses')) return Icons.receipt_long_outlined;
    return Icons.history;
  }
}

class _JsonBlock extends StatelessWidget {
  const _JsonBlock(this.data);
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        const JsonEncoder.withIndent('  ').convert(data),
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
    );
  }
}
