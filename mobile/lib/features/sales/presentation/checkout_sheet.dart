import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/utils/money.dart';
import 'package:suuqii/features/debt/data/debts_repository.dart';
import 'package:suuqii/features/sales/domain/entities/sale.dart';
import 'package:suuqii/features/sales/presentation/cart_controller.dart';
import 'package:suuqii/shared/widgets/sheet_handle.dart';

class CheckoutResult {
  CheckoutResult({
    required this.paymentMethod,
    this.amountTendered,
    this.changeDue,
    this.customerName,
    this.customerPhone,
    this.dueDate,
  });

  final PaymentMethod paymentMethod;
  final Decimal? amountTendered;
  final Decimal? changeDue;
  final String? customerName;
  final String? customerPhone;
  final DateTime? dueDate;
}

class CheckoutSheet extends ConsumerStatefulWidget {
  const CheckoutSheet({super.key});

  @override
  ConsumerState<CheckoutSheet> createState() => _CheckoutSheetState();
}

class _CheckoutSheetState extends ConsumerState<CheckoutSheet> {
  PaymentMethod _method = PaymentMethod.cash;
  final _tendered = TextEditingController();
  final _customerName = TextEditingController();
  final _customerPhone = TextEditingController();
  DateTime? _dueDate;

  // Outstanding balance for the currently-entered customer phone.
  Decimal _customerOutstanding = Decimal.zero;
  bool _loadingOutstanding = false;

  @override
  void initState() {
    super.initState();
    _customerPhone.addListener(_onPhoneChanged);
  }

  @override
  void dispose() {
    _tendered.dispose();
    _customerName.dispose();
    _customerPhone.dispose();
    super.dispose();
  }

  void _onPhoneChanged() {
    final phone = _customerPhone.text.trim();
    if (phone.isEmpty) {
      setState(() {
        _customerOutstanding = Decimal.zero;
        _loadingOutstanding = false;
      });
      return;
    }
    // Debounce: only query when user stops typing for a moment.
    _lookupOutstanding(phone);
  }

  Future<void> _lookupOutstanding(String phone) async {
    setState(() => _loadingOutstanding = true);
    try {
      final outstanding =
          await ref.read(debtsRepositoryProvider).outstandingByPhone(phone);
      if (mounted && _customerPhone.text.trim() == phone) {
        setState(() {
          _customerOutstanding = outstanding;
          _loadingOutstanding = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingOutstanding = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cart = ref.watch(cartControllerProvider);
    final total = cart.total;
    final tendered = _parseDecimal(_tendered.text);
    final changeDue = tendered == null ? null : tendered - total;
    final isCash = _method == PaymentMethod.cash;
    final isCredit = _method == PaymentMethod.credit;

    return SuuqSheet(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Checkout',
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: SuuqSpacing.lg),
          Center(
            child: Column(
              children: [
                Text(
                  'TOTAL',
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.4,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  formatMoney(total),
                  style: theme.textTheme.displayMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (cart.discount > Decimal.zero)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      'Subtotal ${formatMoney(cart.subtotal)} - '
                      'discount ${formatMoney(cart.discount)}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                Text(
                  '${_formatQty(cart.itemCount)} '
                  '${cart.itemCount == Decimal.one ? "item" : "items"}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: SuuqSpacing.lg),
          Text(
            'PAYMENT',
            style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
          ),
          const SizedBox(height: SuuqSpacing.xs),
          _PaymentPicker(
            value: _method,
            onChanged: (method) => setState(() {
              _method = method;
              // Reset outstanding lookup when switching away from credit.
              if (method != PaymentMethod.credit) {
                _customerOutstanding = Decimal.zero;
                _loadingOutstanding = false;
              } else if (_customerPhone.text.trim().isNotEmpty) {
                _lookupOutstanding(_customerPhone.text.trim());
              }
            }),
          ),
          const SizedBox(height: SuuqSpacing.lg),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            child: isCash
                ? _CashSection(
                    key: const ValueKey('cash'),
                    controller: _tendered,
                    total: total,
                    changeDue: changeDue,
                    onFillAmount: (value) => setState(
                      () => _tendered.text = _formatDecimal(value),
                    ),
                  )
                : isCredit
                    ? _CreditSection(
                        key: const ValueKey('credit'),
                        customerName: _customerName,
                        customerPhone: _customerPhone,
                        dueDate: _dueDate,
                        customerOutstanding: _customerOutstanding,
                        loadingOutstanding: _loadingOutstanding,
                        saleTotal: total,
                        onPickDueDate: () async {
                          final now = DateTime.now();
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: now.add(const Duration(days: 7)),
                            firstDate: now,
                            lastDate: now.add(const Duration(days: 365)),
                          );
                          if (picked != null) {
                            setState(() => _dueDate = picked);
                          }
                        },
                      )
                    : const _InfoCard(
                        key: ValueKey('mobile'),
                        icon: Icons.phone_iphone_rounded,
                        label:
                            'Mobile money sales are recorded immediately with no cash change due.',
                      ),
          ),
          const SizedBox(height: SuuqSpacing.xl),
          SizedBox(
            height: 64,
            child: FilledButton.icon(
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(SuuqRadius.md),
                ),
                textStyle: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              icon: const Icon(Icons.check_circle_rounded, size: 22),
              onPressed: () {
                if (isCash) {
                  if (tendered == null || tendered <= Decimal.zero) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content:
                            Text('Enter the cash received from the customer'),
                      ),
                    );
                    return;
                  }
                  if (tendered < total) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Customer is short by ${formatMoney(total - tendered)}',
                        ),
                      ),
                    );
                    return;
                  }
                }

                if (isCredit && _customerName.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Customer name required for credit'),
                    ),
                  );
                  return;
                }

                Navigator.pop(
                  context,
                  CheckoutResult(
                    paymentMethod: _method,
                    amountTendered: isCash ? tendered : null,
                    changeDue:
                        isCash && changeDue != null && changeDue > Decimal.zero
                            ? changeDue
                            : Decimal.zero,
                    customerName: isCredit ? _customerName.text.trim() : null,
                    customerPhone: isCredit ? _customerPhone.text.trim() : null,
                    dueDate: _dueDate,
                  ),
                );
              },
              label: Text('Confirm - ${formatMoney(total)}'),
            ),
          ),
        ],
      ),
    );
  }

  Decimal? _parseDecimal(String raw) {
    final normalized = raw.trim().replaceAll(',', '.');
    if (normalized.isEmpty) return null;
    return Decimal.tryParse(normalized);
  }

  String _formatQty(Decimal value) {
    final n = value.toDouble();
    if (n == n.roundToDouble()) return n.toInt().toString();
    return n.toStringAsFixed(2);
  }

  String _formatDecimal(Decimal value) {
    final n = value.toDouble();
    if (n == n.roundToDouble()) return n.toInt().toString();
    return n.toStringAsFixed(2);
  }
}

class _PaymentPicker extends StatelessWidget {
  const _PaymentPicker({required this.value, required this.onChanged});

  final PaymentMethod value;
  final ValueChanged<PaymentMethod> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        _PaymentOption(
          icon: Icons.payments_rounded,
          label: 'Cash',
          selected: value == PaymentMethod.cash,
          onTap: () => onChanged(PaymentMethod.cash),
        ),
        const SizedBox(width: SuuqSpacing.xs),
        _PaymentOption(
          icon: Icons.phone_iphone_rounded,
          label: 'Mobile',
          selected: value == PaymentMethod.mobileMoney,
          onTap: () => onChanged(PaymentMethod.mobileMoney),
        ),
        const SizedBox(width: SuuqSpacing.xs),
        _PaymentOption(
          icon: Icons.access_time_rounded,
          label: 'Credit',
          selected: value == PaymentMethod.credit,
          onTap: () => onChanged(PaymentMethod.credit),
        ),
      ],
    );
  }
}

class _PaymentOption extends StatelessWidget {
  const _PaymentOption({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Semantics(
        button: true,
        selected: selected,
        label: '$label payment',
        child: Material(
          color: selected ? scheme.primary : scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(SuuqRadius.md),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(SuuqRadius.md),
            child: Ink(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(SuuqRadius.md),
                border: Border.all(
                  color: selected ? scheme.primary : scheme.outlineVariant,
                  width: selected ? 1.5 : 1,
                ),
              ),
              padding: const EdgeInsets.symmetric(vertical: SuuqSpacing.lg),
              child: Column(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected
                          ? scheme.onPrimary.withValues(alpha: 0.18)
                          : scheme.surfaceContainerHighest,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      icon,
                      color:
                          selected ? scheme.onPrimary : scheme.onSurfaceVariant,
                      size: 22,
                    ),
                  ),
                  const SizedBox(height: SuuqSpacing.xs),
                  Text(
                    label,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: selected ? scheme.onPrimary : scheme.onSurface,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CashSection extends StatelessWidget {
  const _CashSection({
    required this.controller,
    required this.total,
    required this.changeDue,
    required this.onFillAmount,
    super.key,
  });

  final TextEditingController controller;
  final Decimal total;
  final Decimal? changeDue;
  final ValueChanged<Decimal> onFillAmount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final showPositiveChange = changeDue != null && changeDue! >= Decimal.zero;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'CASH',
          style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
        ),
        const SizedBox(height: SuuqSpacing.xs),
        TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: 'Tendered amount',
            prefixIcon: Icon(Icons.payments_rounded, size: 20),
            helperText: 'Enter how much cash the customer handed over.',
          ),
        ),
        const SizedBox(height: SuuqSpacing.sm),
        Wrap(
          spacing: SuuqSpacing.xs,
          runSpacing: SuuqSpacing.xs,
          children: [
            for (final amount in _cashSuggestions(total))
              ActionChip(
                label: Text(formatMoney(amount)),
                onPressed: () => onFillAmount(amount),
              ),
          ],
        ),
        const SizedBox(height: SuuqSpacing.sm),
        Container(
          padding: const EdgeInsets.all(SuuqSpacing.md),
          decoration: BoxDecoration(
            color: changeDue == null
                ? scheme.surfaceContainer
                : showPositiveChange
                    ? scheme.primaryContainer
                    : scheme.errorContainer,
            borderRadius: BorderRadius.circular(SuuqRadius.md),
          ),
          child: Row(
            children: [
              Icon(
                changeDue == null
                    ? Icons.calculate_outlined
                    : showPositiveChange
                        ? Icons.reply_rounded
                        : Icons.warning_amber_rounded,
                color: changeDue == null
                    ? scheme.onSurfaceVariant
                    : showPositiveChange
                        ? scheme.onPrimaryContainer
                        : scheme.onErrorContainer,
              ),
              const SizedBox(width: SuuqSpacing.sm),
              Expanded(
                child: Text(
                  switch (changeDue) {
                    null =>
                      'Change will appear after you enter the cash received.',
                    final value when value < Decimal.zero =>
                      'Short by ${formatMoney(value.abs())}',
                    final value => 'Change due ${formatMoney(value)}',
                  },
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: changeDue == null
                        ? scheme.onSurfaceVariant
                        : showPositiveChange
                            ? scheme.onPrimaryContainer
                            : scheme.onErrorContainer,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  List<Decimal> _cashSuggestions(Decimal total) {
    final ceil = total.toDouble().ceil();
    final next50 = ((ceil + 49) ~/ 50) * 50;
    final next100 = ((ceil + 99) ~/ 100) * 100;
    final values = <String, Decimal>{
      total.toString(): total,
      if (next50 > 0) '$next50': Decimal.parse(next50.toString()),
      if (next100 > 0) '$next100': Decimal.parse(next100.toString()),
    };
    return values.values.toList(growable: false);
  }
}

class _CreditSection extends StatelessWidget {
  const _CreditSection({
    required this.customerName,
    required this.customerPhone,
    required this.dueDate,
    required this.onPickDueDate,
    required this.customerOutstanding,
    required this.loadingOutstanding,
    required this.saleTotal,
    super.key,
  });

  final TextEditingController customerName;
  final TextEditingController customerPhone;
  final DateTime? dueDate;
  final Future<void> Function() onPickDueDate;
  final Decimal customerOutstanding;
  final bool loadingOutstanding;
  final Decimal saleTotal;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasOutstanding = customerOutstanding > Decimal.zero;
    final cumulativeAfterSale = customerOutstanding + saleTotal;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'CUSTOMER',
          style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
        ),
        const SizedBox(height: SuuqSpacing.xs),
        TextField(
          controller: customerName,
          decoration: const InputDecoration(
            labelText: 'Customer name',
            prefixIcon: Icon(Icons.person_outline_rounded, size: 20),
          ),
        ),
        const SizedBox(height: SuuqSpacing.sm),
        TextField(
          controller: customerPhone,
          keyboardType: TextInputType.phone,
          decoration: const InputDecoration(
            labelText: 'Phone (optional)',
            prefixIcon: Icon(Icons.phone_iphone_rounded, size: 20),
          ),
        ),
        const SizedBox(height: SuuqSpacing.sm),
        OutlinedButton.icon(
          icon: const Icon(Icons.event_rounded, size: 18),
          onPressed: onPickDueDate,
          label: Text(
            dueDate == null
                ? 'Due date (optional)'
                : 'Due ${dueDate!.toIso8601String().split('T').first}',
          ),
        ),
        const SizedBox(height: SuuqSpacing.sm),
        // Outstanding balance card — shown once phone is entered.
        if (loadingOutstanding)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: SuuqSpacing.xs),
            child: LinearProgressIndicator(),
          )
        else if (hasOutstanding) ...[
          Container(
            padding: const EdgeInsets.all(SuuqSpacing.md),
            decoration: BoxDecoration(
              color: scheme.errorContainer,
              borderRadius: BorderRadius.circular(SuuqRadius.md),
              border: Border.all(color: scheme.error.withValues(alpha: 0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 18,
                      color: scheme.onErrorContainer,
                    ),
                    const SizedBox(width: SuuqSpacing.xs),
                    Text(
                      'Existing outstanding balance',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onErrorContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                _BalanceRow(
                  label: 'Current outstanding',
                  amount: customerOutstanding,
                  color: scheme.onErrorContainer,
                  theme: theme,
                ),
                _BalanceRow(
                  label: 'This sale',
                  amount: saleTotal,
                  color: scheme.onErrorContainer,
                  theme: theme,
                ),
                Divider(
                  color: scheme.onErrorContainer.withValues(alpha: 0.3),
                  height: SuuqSpacing.md,
                ),
                _BalanceRow(
                  label: 'Total after sale',
                  amount: cumulativeAfterSale,
                  color: scheme.onErrorContainer,
                  theme: theme,
                  bold: true,
                ),
                const SizedBox(height: 4),
                Text(
                  'Owner approval may be required if cumulative balance exceeds the shop limit.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onErrorContainer.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
        ] else ...[
          const _InfoCard(
            icon: Icons.verified_user_outlined,
            label: 'Large credit sales may require owner approval when synced.',
          ),
        ],
      ],
    );
  }
}

class _BalanceRow extends StatelessWidget {
  const _BalanceRow({
    required this.label,
    required this.amount,
    required this.color,
    required this.theme,
    this.bold = false,
  });

  final String label;
  final Decimal amount;
  final Color color;
  final ThemeData theme;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = theme.textTheme.bodyMedium?.copyWith(
      color: color,
      fontWeight: bold ? FontWeight.w700 : FontWeight.normal,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text(formatMoney(amount), style: style),
        ],
      ),
    );
  }
}

class _InfoCard extends StatelessWidget {
  const _InfoCard({
    required this.icon,
    required this.label,
    super.key,
  });

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(SuuqSpacing.md),
      decoration: BoxDecoration(
        color: scheme.surfaceContainer,
        borderRadius: BorderRadius.circular(SuuqRadius.md),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: SuuqSpacing.sm),
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}
