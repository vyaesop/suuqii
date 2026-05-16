import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/money.dart';
import '../../../l10n/app_localizations.dart';
import '../domain/entities/sale.dart';
import 'cart_controller.dart';

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
    final l = AppLocalizations.of(context);
    final cart = ref.watch(cartControllerProvider);
    final theme = Theme.of(context);
    final isCredit = _method == PaymentMethod.credit;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(l.total, style: theme.textTheme.bodyLarge),
              Text(formatMoney(cart.total), style: theme.textTheme.displaySmall),
              const SizedBox(height: 20),
              SegmentedButton<PaymentMethod>(
                segments: [
                  ButtonSegment(value: PaymentMethod.cash,
                      label: Text(l.paymentCash), icon: const Icon(Icons.payments)),
                  ButtonSegment(value: PaymentMethod.mobileMoney,
                      label: Text(l.paymentMobile), icon: const Icon(Icons.phone_android)),
                  ButtonSegment(value: PaymentMethod.credit,
                      label: Text(l.paymentCredit), icon: const Icon(Icons.access_time)),
                ],
                selected: {_method},
                onSelectionChanged: (s) => setState(() => _method = s.first),
              ),
              if (isCredit) ...[
                const SizedBox(height: 20),
                TextField(
                  controller: _customerName,
                  decoration: const InputDecoration(labelText: 'Customer name'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _customerPhone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Phone (optional)'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  icon: const Icon(Icons.event),
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
                  label: Text(_dueDate == null
                      ? 'Due date (optional)'
                      : 'Due ${_dueDate!.toIso8601String().split('T').first}'),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton.icon(
                icon: const Icon(Icons.check),
                onPressed: () {
                  if (isCredit && _customerName.text.trim().isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Customer name required for credit')),
                    );
                    return;
                  }
                  Navigator.pop(
                    context,
                    CheckoutResult(
                      paymentMethod: _method,
                      customerName: isCredit ? _customerName.text.trim() : null,
                      customerPhone: isCredit ? _customerPhone.text.trim() : null,
                      dueDate: _dueDate,
                    ),
                  );
                },
                label: const Text('Confirm sale'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
