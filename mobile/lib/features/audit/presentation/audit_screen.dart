import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/features/audit/data/audit_repository.dart';

class AuditScreen extends ConsumerStatefulWidget {
  const AuditScreen({super.key});

  @override
  ConsumerState<AuditScreen> createState() => _AuditScreenState();
}

class _AuditScreenState extends ConsumerState<AuditScreen> {
  String? _filter;

  List<(String?, String)> _actionFilters(AppLocalizations l) => [
        (null, l.commonAll),
        ('products.update', l.auditFilterProductEdit),
        ('products.insert', l.auditFilterProductAdd),
        ('sales.update', l.auditFilterSaleChange),
        ('sales.delete', l.auditFilterSaleDelete),
        ('debts.update', l.auditFilterDebtChange),
        ('shifts.update', l.auditFilterShiftClose),
      ];

  @override
  Widget build(BuildContext context) {
    final entries = ref.watch(auditEntriesProvider(action: _filter));
    final l = context.l10n;
    final filters = _actionFilters(l);
    return Scaffold(
      appBar: AppBar(title: Text(l.auditLogTitle)),
      body: Column(
        children: [
          SizedBox(
            height: 56,
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              scrollDirection: Axis.horizontal,
              itemCount: filters.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final (value, label) = filters[i];
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
                error: (e, _) => Center(child: Text(context.errorMessage(e))),
                data: (items) {
                  if (items.isEmpty) {
                    return ListView(
                      children: [
                        const SizedBox(height: 80),
                        Center(child: Text(l.auditEmpty)),
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
    final l = context.l10n;
    return ExpansionTile(
      leading: CircleAvatar(child: Icon(_iconFor(entry.action), size: 18)),
      title: Text(_actionLabel(l, entry.action)),
      subtitle: Text(
        '${_entityLabel(l, entry.entityType)} · '
        '${context.dateTimeShort(entry.createdAt.toLocal())}',
      ),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: [
        if (entry.oldValue != null) ...[
          Text(
            l.auditBefore,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          _JsonBlock(entry.oldValue!),
        ],
        if (entry.newValue != null) ...[
          const SizedBox(height: 6),
          Text(
            l.auditAfter,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          _JsonBlock(entry.newValue!),
        ],
      ],
    );
  }

  /// Localized display text for a machine audit action code; unknown codes
  /// fall back to the raw code.
  static String _actionLabel(AppLocalizations l, String action) =>
      switch (action) {
        'products.update' => l.auditActionProductsUpdate,
        'products.insert' => l.auditActionProductsInsert,
        'sales.update' => l.auditActionSalesUpdate,
        'sales.delete' => l.auditActionSalesDelete,
        'debts.update' => l.auditActionDebtsUpdate,
        'shifts.update' => l.auditActionShiftsUpdate,
        _ => action,
      };

  /// Localized display text for a machine entity-type value; unknown values
  /// fall back to the raw value.
  static String _entityLabel(AppLocalizations l, String entityType) =>
      switch (entityType) {
        'products' => l.auditEntityProducts,
        'sales' => l.auditEntitySales,
        'debts' => l.auditEntityDebts,
        'shifts' => l.auditEntityShifts,
        'expenses' => l.auditEntityExpenses,
        _ => entityType,
      };

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
