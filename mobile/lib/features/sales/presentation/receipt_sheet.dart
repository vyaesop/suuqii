import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/utils/money.dart';
import 'package:suuqii/features/sales/domain/entities/sale.dart';
import 'package:suuqii/shared/widgets/sheet_handle.dart';

/// Post-sale receipt summary. Shows what the customer paid for and how,
/// with copy-to-clipboard and "new sale" actions.
class ReceiptSheet extends StatelessWidget {
  const ReceiptSheet({
    required this.cart,
    required this.paymentMethod,
    required this.saleId,
    required this.soldAt,
    this.amountTendered,
    this.changeDue,
    this.customerName,
    this.customerPhone,
    this.dueDate,
    super.key,
  });

  final Cart cart;
  final PaymentMethod paymentMethod;
  final String saleId;
  final DateTime soldAt;
  final Decimal? amountTendered;
  final Decimal? changeDue;
  final String? customerName;
  final String? customerPhone;
  final DateTime? dueDate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return SuuqSheet(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Center(
            child: Container(
              width: 64,
              height: 64,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.check_rounded,
                size: 36,
                color: scheme.onPrimaryContainer,
              ),
            ),
          ),
          const SizedBox(height: SuuqSpacing.sm),
          Center(
            child: Text(
              'Sale recorded',
              style: theme.textTheme.titleLarge,
            ),
          ),
          const SizedBox(height: 2),
          Center(
            child: Text(
              _formatDateTime(soldAt.toLocal()),
              style: theme.textTheme.bodySmall,
            ),
          ),
          const SizedBox(height: SuuqSpacing.lg),
          Container(
            padding: const EdgeInsets.all(SuuqSpacing.md),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(SuuqRadius.md),
            ),
            child: Column(
              children: [
                if (cart.discount > Decimal.zero) ...[
                  Row(
                    children: [
                      Text('Subtotal', style: theme.textTheme.bodySmall),
                      const Spacer(),
                      Text(
                        formatMoney(cart.subtotal),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text('Discount', style: theme.textTheme.bodySmall),
                      const Spacer(),
                      Text(
                        '- ${formatMoney(cart.discount)}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: scheme.error,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  Divider(color: scheme.outlineVariant, height: SuuqSpacing.sm),
                ],
                Row(
                  children: [
                    Text(
                      'TOTAL',
                      style: theme.textTheme.labelSmall?.copyWith(
                        letterSpacing: 1.2,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      formatMoney(cart.total),
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                if (amountTendered != null) ...[
                  const SizedBox(height: SuuqSpacing.sm),
                  Divider(color: scheme.outlineVariant, height: 1),
                  const SizedBox(height: SuuqSpacing.sm),
                  _MoneyRow(
                    label: 'Tendered',
                    value: formatMoney(amountTendered!),
                  ),
                  if (changeDue != null && changeDue! > Decimal.zero)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _MoneyRow(
                        label: 'Change',
                        value: formatMoney(changeDue!),
                      ),
                    ),
                ],
              ],
            ),
          ),
          const SizedBox(height: SuuqSpacing.sm),
          _MetaRow(
            icon: _paymentIcon(paymentMethod),
            label: _paymentLabel(paymentMethod),
          ),
          if (customerName != null && customerName!.isNotEmpty)
            _MetaRow(
              icon: Icons.person_outline_rounded,
              label: customerName!,
            ),
          if (customerPhone != null && customerPhone!.isNotEmpty)
            _MetaRow(
              icon: Icons.phone_iphone_rounded,
              label: customerPhone!,
            ),
          if (dueDate != null)
            _MetaRow(
              icon: Icons.event_rounded,
              label: 'Due ${_formatDate(dueDate!)}',
            ),
          const SizedBox(height: SuuqSpacing.md),
          Text(
            'ITEMS',
            style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
          ),
          const SizedBox(height: SuuqSpacing.xs),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height * 0.35,
            ),
            child: ListView.separated(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: cart.lines.length,
              separatorBuilder: (_, __) =>
                  Divider(height: 1, color: scheme.outlineVariant),
              itemBuilder: (_, i) {
                final line = cart.lines[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: SuuqSpacing.xs),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              line.product.name,
                              style: theme.textTheme.titleSmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            Text(
                              '${_fmtQty(line.qty.toDouble())} '
                              '${line.product.unit} x '
                              '${formatMoney(line.product.sellingPrice)}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: SuuqSpacing.sm),
                      Text(
                        formatMoney(line.lineTotal),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: SuuqSpacing.lg),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.copy_rounded, size: 18),
                  onPressed: () {
                    final text = _buildShareText();
                    Clipboard.setData(ClipboardData(text: text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Receipt copied')),
                    );
                  },
                  label: const Text('Copy'),
                ),
              ),
              const SizedBox(width: SuuqSpacing.sm),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  icon: const Icon(Icons.add_shopping_cart_rounded, size: 18),
                  onPressed: () => Navigator.of(context).pop(),
                  label: const Text('New sale'),
                ),
              ),
            ],
          ),
          const SizedBox(height: SuuqSpacing.xs),
          Center(
            child: Text(
              '#${saleId.substring(0, 8)}',
              style: theme.textTheme.bodySmall?.copyWith(
                letterSpacing: 1,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _buildShareText() {
    final buf = StringBuffer()
      ..writeln('Receipt #${saleId.substring(0, 8)}')
      ..writeln(_formatDateTime(soldAt.toLocal()))
      ..writeln();
    for (final line in cart.lines) {
      buf.writeln(
        '${line.product.name}  '
        '${_fmtQty(line.qty.toDouble())}${line.product.unit} x '
        '${formatMoney(line.product.sellingPrice)} = ${formatMoney(line.lineTotal)}',
      );
    }
    buf
      ..writeln()
      ..writeln('Total: ${formatMoney(cart.total)}')
      ..writeln('Payment: ${_paymentLabel(paymentMethod)}');
    if (amountTendered != null) {
      buf.writeln('Tendered: ${formatMoney(amountTendered!)}');
    }
    if (changeDue != null && changeDue! > Decimal.zero) {
      buf.writeln('Change: ${formatMoney(changeDue!)}');
    }
    if (customerName != null && customerName!.isNotEmpty) {
      buf.writeln('Customer: $customerName');
    }
    if (customerPhone != null && customerPhone!.isNotEmpty) {
      buf.writeln('Phone: $customerPhone');
    }
    if (dueDate != null) {
      buf.writeln('Due: ${_formatDate(dueDate!)}');
    }
    return buf.toString();
  }

  String _fmtQty(double n) {
    if (n == n.roundToDouble()) return n.toInt().toString();
    return n.toStringAsFixed(2);
  }

  IconData _paymentIcon(PaymentMethod method) => switch (method) {
        PaymentMethod.cash => Icons.payments_rounded,
        PaymentMethod.mobileMoney => Icons.phone_iphone_rounded,
        PaymentMethod.credit => Icons.access_time_rounded,
      };

  String _paymentLabel(PaymentMethod method) => switch (method) {
        PaymentMethod.cash => 'Paid in cash',
        PaymentMethod.mobileMoney => 'Paid via mobile money',
        PaymentMethod.credit => 'On credit',
      };

  String _formatDate(DateTime d) => '${d.year}-${_p(d.month)}-${_p(d.day)}';
  String _formatDateTime(DateTime d) =>
      '${_formatDate(d)}  ${_p(d.hour)}:${_p(d.minute)}';
  String _p(int n) => n < 10 ? '0$n' : '$n';
}

class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: SuuqSpacing.xs),
      child: Row(
        children: [
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: SuuqSpacing.xs),
          Expanded(
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

class _MoneyRow extends StatelessWidget {
  const _MoneyRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        Text(label, style: theme.textTheme.bodySmall),
        const Spacer(),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
