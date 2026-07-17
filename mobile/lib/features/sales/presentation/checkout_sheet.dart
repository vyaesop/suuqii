import 'dart:async';

import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/formats.dart';
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
  Timer? _phoneDebounce;

  @override
  void initState() {
    super.initState();
    _customerPhone.addListener(_onPhoneChanged);
    // Recompute change-due live while the cashier types the tendered cash.
    _tendered.addListener(_onTenderedChanged);
    // Exact-cash fast path: pre-fill the tendered amount with the exact
    // total, fully selected so any typing replaces it. A minimum cash sale
    // needs zero extra input — "Confirm" works immediately.
    final total = ref.read(cartControllerProvider).total;
    if (total > Decimal.zero) _prefillExact(total);
  }

  @override
  void dispose() {
    _phoneDebounce?.cancel();
    _tendered.dispose();
    _customerName.dispose();
    _customerPhone.dispose();
    super.dispose();
  }

  void _onTenderedChanged() {
    if (mounted) setState(() {});
  }

  void _prefillExact(Decimal total) {
    final text = _formatDecimal(total);
    _tendered.value = TextEditingValue(
      text: text,
      selection: TextSelection(baseOffset: 0, extentOffset: text.length),
    );
  }

  void _onPhoneChanged() {
    _phoneDebounce?.cancel();
    final phone = _customerPhone.text.trim();
    if (phone.isEmpty) {
      setState(() {
        _customerOutstanding = Decimal.zero;
        _loadingOutstanding = false;
      });
      return;
    }
    // Debounce: only query when the user stops typing for a moment.
    _phoneDebounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) _lookupOutstanding(phone);
    });
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
    final l = context.l10n;
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
            l.checkout,
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: SuuqSpacing.lg),
          Center(
            child: Column(
              children: [
                Text(
                  l.checkoutTotalCaps,
                  style: theme.textTheme.labelSmall?.copyWith(
                    letterSpacing: 1.4,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  context.money(total),
                  style: theme.textTheme.displayMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (cart.discount > Decimal.zero)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      l.checkoutSubtotalDiscount(
                        context.money(cart.subtotal),
                        context.money(cart.discount),
                      ),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                Text(
                  l.checkoutItemCount(_qtyAsNum(cart.itemCount)),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: SuuqSpacing.lg),
          Text(
            l.checkoutPaymentCaps,
            style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
          ),
          const SizedBox(height: SuuqSpacing.xs),
          _PaymentPicker(
            value: _method,
            onChanged: (method) => setState(() {
              _method = method;
              // Coming (back) to cash with nothing typed: restore the
              // exact-total prefill so "Confirm" needs no extra input.
              if (method == PaymentMethod.cash &&
                  _tendered.text.trim().isEmpty &&
                  total > Decimal.zero) {
                _prefillExact(total);
              }
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
                    // The controller listener rebuilds; no setState needed.
                    onFillAmount: (value) =>
                        _tendered.text = _formatDecimal(value),
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
                    : _InfoCard(
                        key: const ValueKey('mobile'),
                        icon: Icons.phone_iphone_rounded,
                        label: l.checkoutMobileInfo,
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
                      SnackBar(
                        content: Text(l.checkoutEnterCashReceived),
                      ),
                    );
                    return;
                  }
                  if (tendered < total) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          l.checkoutShortBy(context.money(total - tendered)),
                        ),
                      ),
                    );
                    return;
                  }
                }

                if (isCredit && _customerName.text.trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(l.checkoutCustomerNameRequired),
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
              label: Text(l.checkoutConfirmTotal(context.money(total))),
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

  /// Whole quantities as int (renders "3"), fractional as double ("2.5") —
  /// for ICU plural placeholders.
  num _qtyAsNum(Decimal value) {
    final n = value.toDouble();
    return n == n.roundToDouble() ? n.toInt() : n;
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
    final l = context.l10n;
    return Row(
      children: [
        _PaymentOption(
          icon: Icons.payments_rounded,
          label: l.paymentCash,
          selected: value == PaymentMethod.cash,
          onTap: () => onChanged(PaymentMethod.cash),
        ),
        const SizedBox(width: SuuqSpacing.xs),
        _PaymentOption(
          icon: Icons.phone_iphone_rounded,
          label: l.paymentMobile,
          selected: value == PaymentMethod.mobileMoney,
          onTap: () => onChanged(PaymentMethod.mobileMoney),
        ),
        const SizedBox(width: SuuqSpacing.xs),
        _PaymentOption(
          icon: Icons.access_time_rounded,
          label: l.paymentCredit,
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
        label: context.l10n.checkoutPaymentSemantic(label),
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
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final showPositiveChange = changeDue != null && changeDue! >= Decimal.zero;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l.checkoutCashCaps,
          style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
        ),
        const SizedBox(height: SuuqSpacing.xs),
        TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: l.checkoutTenderedAmount,
            prefixIcon: const Icon(Icons.payments_rounded, size: 20),
            helperText: l.checkoutTenderedHelper,
          ),
        ),
        const SizedBox(height: SuuqSpacing.sm),
        Wrap(
          spacing: SuuqSpacing.xs,
          runSpacing: SuuqSpacing.xs,
          children: [
            // "Exact" first: the most common case is the customer handing
            // over the exact total.
            ActionChip(
              avatar: const Icon(Icons.check_rounded, size: 16),
              label: Text(l.checkoutExactChip(context.money(total))),
              onPressed: () => onFillAmount(total),
            ),
            for (final amount in _cashSuggestions(total))
              ActionChip(
                label: Text(context.money(amount)),
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
                    null => l.checkoutChangeHint,
                    final value when value < Decimal.zero =>
                      l.checkoutShortByAmount(context.money(value.abs())),
                    final value => l.checkoutChangeDue(context.money(value)),
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

  /// Round-note suggestions above the total. The exact total itself is
  /// covered by the dedicated "Exact" chip rendered first.
  List<Decimal> _cashSuggestions(Decimal total) {
    final ceil = total.toDouble().ceil();
    final next50 = ((ceil + 49) ~/ 50) * 50;
    final next100 = ((ceil + 99) ~/ 100) * 100;
    final values = <String, Decimal>{
      if (next50 > 0) '$next50': Decimal.parse(next50.toString()),
      if (next100 > 0) '$next100': Decimal.parse(next100.toString()),
    }..removeWhere((_, v) => v == total);
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
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hasOutstanding = customerOutstanding > Decimal.zero;
    final cumulativeAfterSale = customerOutstanding + saleTotal;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l.checkoutCustomerCaps,
          style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
        ),
        const SizedBox(height: SuuqSpacing.xs),
        TextField(
          controller: customerName,
          decoration: InputDecoration(
            labelText: l.checkoutCustomerName,
            prefixIcon: const Icon(Icons.person_outline_rounded, size: 20),
          ),
        ),
        const SizedBox(height: SuuqSpacing.sm),
        TextField(
          controller: customerPhone,
          keyboardType: TextInputType.phone,
          decoration: InputDecoration(
            labelText: l.checkoutPhoneOptional,
            prefixIcon: const Icon(Icons.phone_iphone_rounded, size: 20),
          ),
        ),
        const SizedBox(height: SuuqSpacing.sm),
        OutlinedButton.icon(
          icon: const Icon(Icons.event_rounded, size: 18),
          onPressed: onPickDueDate,
          label: Text(
            dueDate == null
                ? l.checkoutDueDateOptional
                : l.checkoutDueDate(context.dateShort(dueDate!)),
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
                      l.checkoutOutstandingTitle,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onErrorContainer,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                _BalanceRow(
                  label: l.checkoutCurrentOutstanding,
                  amount: customerOutstanding,
                  color: scheme.onErrorContainer,
                  theme: theme,
                ),
                _BalanceRow(
                  label: l.checkoutThisSale,
                  amount: saleTotal,
                  color: scheme.onErrorContainer,
                  theme: theme,
                ),
                Divider(
                  color: scheme.onErrorContainer.withValues(alpha: 0.3),
                  height: SuuqSpacing.md,
                ),
                _BalanceRow(
                  label: l.checkoutTotalAfterSale,
                  amount: cumulativeAfterSale,
                  color: scheme.onErrorContainer,
                  theme: theme,
                  bold: true,
                ),
                const SizedBox(height: 4),
                Text(
                  l.checkoutOwnerApprovalNote,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onErrorContainer.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
        ] else ...[
          _InfoCard(
            icon: Icons.verified_user_outlined,
            label: l.checkoutLargeCreditNote,
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
          Text(context.money(amount), style: style),
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
