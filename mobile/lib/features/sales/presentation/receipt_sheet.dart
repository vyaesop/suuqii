import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/features/sales/domain/entities/sale.dart';
import 'package:suuqii/features/sales/presentation/receipt_share.dart';
import 'package:suuqii/shared/widgets/sheet_handle.dart';

/// Post-sale receipt summary. Shows what the customer paid for and how,
/// with share, copy-to-clipboard and "new sale" actions.
class ReceiptSheet extends StatelessWidget {
  const ReceiptSheet({
    required this.cart,
    required this.paymentMethod,
    required this.saleId,
    required this.soldAt,
    this.shopName,
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

  /// Shown at the top of the shared receipt text when available.
  final String? shopName;
  final Decimal? amountTendered;
  final Decimal? changeDue;
  final String? customerName;
  final String? customerPhone;
  final DateTime? dueDate;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
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
              l.receiptSaleRecorded,
              style: theme.textTheme.titleLarge,
            ),
          ),
          const SizedBox(height: 2),
          Center(
            child: Text(
              context.dateTimeShort(soldAt.toLocal()),
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
                      Text(l.receiptSubtotal, style: theme.textTheme.bodySmall),
                      const Spacer(),
                      Text(
                        context.money(cart.subtotal),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(l.cartDiscount, style: theme.textTheme.bodySmall),
                      const Spacer(),
                      Text(
                        l.cartMinusAmount(context.money(cart.discount)),
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
                      l.checkoutTotalCaps,
                      style: theme.textTheme.labelSmall?.copyWith(
                        letterSpacing: 1.2,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      context.money(cart.total),
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
                    label: l.tendered,
                    value: context.money(amountTendered!),
                  ),
                  if (changeDue != null && changeDue! > Decimal.zero)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: _MoneyRow(
                        label: l.change,
                        value: context.money(changeDue!),
                      ),
                    ),
                ],
              ],
            ),
          ),
          const SizedBox(height: SuuqSpacing.sm),
          _MetaRow(
            icon: _paymentIcon(paymentMethod),
            label: _paymentLabel(l, paymentMethod),
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
              label: l.checkoutDueDate(context.dateShort(dueDate!)),
            ),
          const SizedBox(height: SuuqSpacing.md),
          Text(
            l.receiptItemsCaps,
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
                              l.receiptQtyUnitPrice(
                                _fmtQty(line.qty.toDouble()),
                                line.product.unit,
                                context.money(line.product.sellingPrice),
                              ),
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: SuuqSpacing.sm),
                      Text(
                        context.money(line.lineTotal),
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
                    final text = _buildShareText(context);
                    Clipboard.setData(ClipboardData(text: text));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(l.receiptCopied)),
                    );
                  },
                  label: Text(l.receiptCopy),
                ),
              ),
              const SizedBox(width: SuuqSpacing.sm),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.share_rounded, size: 18),
                  onPressed: () => shareReceiptText(_buildShareText(context)),
                  label: Text(l.receiptShare),
                ),
              ),
            ],
          ),
          const SizedBox(height: SuuqSpacing.sm),
          SizedBox(
            height: 52,
            child: FilledButton.icon(
              icon: const Icon(Icons.add_shopping_cart_rounded, size: 18),
              onPressed: () => Navigator.of(context).pop(),
              label: Text(l.receiptNewSale),
            ),
          ),
          const SizedBox(height: SuuqSpacing.xs),
          Center(
            child: Text(
              l.receiptSaleNumber(saleId.substring(0, 8)),
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

  String _buildShareText(BuildContext context) {
    return composeReceiptShareText(
      context,
      saleId: saleId,
      soldAt: soldAt,
      shopName: shopName,
      lines: [
        for (final line in cart.lines)
          ReceiptShareLine(
            name: line.product.name,
            qty: _fmtQty(line.qty.toDouble()),
            unit: line.product.unit,
            unitPrice: line.product.sellingPrice,
            lineTotal: line.lineTotal,
          ),
      ],
      subtotal: cart.subtotal,
      discount: cart.discount,
      total: cart.total,
      paymentLabel: _paymentLabel(context.l10n, paymentMethod),
      amountTendered: amountTendered,
      changeDue: changeDue,
      customerName: customerName,
      customerPhone: customerPhone,
      dueDate: dueDate,
    );
  }

  String _fmtQty(double n) => receiptQtyText(n);

  IconData _paymentIcon(PaymentMethod method) => switch (method) {
        PaymentMethod.cash => Icons.payments_rounded,
        PaymentMethod.mobileMoney => Icons.phone_iphone_rounded,
        PaymentMethod.credit => Icons.access_time_rounded,
      };

  String _paymentLabel(AppLocalizations l, PaymentMethod method) =>
      switch (method) {
        PaymentMethod.cash => l.receiptPaidCash,
        PaymentMethod.mobileMoney => l.receiptPaidMobile,
        PaymentMethod.credit => l.receiptOnCredit,
      };
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
