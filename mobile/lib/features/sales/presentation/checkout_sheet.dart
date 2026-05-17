import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/utils/money.dart';
import 'package:suuqii/features/sales/domain/entities/sale.dart';
import 'package:suuqii/features/sales/presentation/cart_controller.dart';
import 'package:suuqii/shared/widgets/sheet_handle.dart';

class CheckoutResult {
  CheckoutResult({
    required this.paymentMethod,
    this.customerName,
    this.customerPhone,
    this.dueDate,
  });
  final PaymentMethod paymentMethod;
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
  final _customerName = TextEditingController();
  final _customerPhone = TextEditingController();
  DateTime? _dueDate;

  @override
  void dispose() {
    _customerName.dispose();
    _customerPhone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cart = ref.watch(cartControllerProvider);
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
          // Big total readout
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
                  formatMoney(cart.total),
                  style: theme.textTheme.displayMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  '${cart.itemCount} ${cart.itemCount == 1 ? "item" : "items"}',
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
            onChanged: (m) => setState(() => _method = m),
          ),
          if (isCredit) ...[
            const SizedBox(height: SuuqSpacing.lg),
            Text(
              'CUSTOMER',
              style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
            ),
            const SizedBox(height: SuuqSpacing.xs),
            TextField(
              controller: _customerName,
              decoration: const InputDecoration(
                labelText: 'Customer name',
                prefixIcon: Icon(Icons.person_outline_rounded, size: 20),
              ),
            ),
            const SizedBox(height: SuuqSpacing.sm),
            TextField(
              controller: _customerPhone,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Phone (optional)',
                prefixIcon: Icon(Icons.phone_iphone_rounded, size: 20),
              ),
            ),
            const SizedBox(height: SuuqSpacing.sm),
            OutlinedButton.icon(
              icon: const Icon(Icons.event_rounded, size: 18),
              onPressed: () async {
                final now = DateTime.now();
                final picked = await showDatePicker(
                  context: context,
                  initialDate: now.add(const Duration(days: 7)),
                  firstDate: now,
                  lastDate: now.add(const Duration(days: 365)),
                );
                if (picked != null) setState(() => _dueDate = picked);
              },
              label: Text(
                _dueDate == null
                    ? 'Due date (optional)'
                    : 'Due ${_dueDate!.toIso8601String().split('T').first}',
              ),
            ),
          ],
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
                    customerName:
                        isCredit ? _customerName.text.trim() : null,
                    customerPhone:
                        isCredit ? _customerPhone.text.trim() : null,
                    dueDate: _dueDate,
                  ),
                );
              },
              label: Text('Confirm — ${formatMoney(cart.total)}'),
            ),
          ),
        ],
      ),
    );
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
    );
  }
}
