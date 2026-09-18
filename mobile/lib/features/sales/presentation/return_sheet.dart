import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/core/utils/formats.dart';
import 'package:suuqii/core/utils/money.dart';
import 'package:suuqii/features/sales/data/sales_repository.dart';
import 'package:suuqii/features/sales/domain/entities/sale_return.dart';
import 'package:suuqii/features/sales/presentation/receipt_share.dart';
import 'package:suuqii/shared/widgets/sheet_handle.dart';

/// What the cashier decided in the return sheet. A refund carries the amount
/// and method; an exchange carries only the lines — the POS settles it.
class ReturnSheetResult {
  const ReturnSheetResult.refund({
    required this.items,
    required this.reason,
    required this.credit,
    required Decimal this.refundAmount,
    required RefundMethod this.refundMethod,
    this.note,
  }) : isExchange = false;

  const ReturnSheetResult.exchange({
    required this.items,
    required this.reason,
    required this.credit,
    this.note,
  })  : isExchange = true,
        refundAmount = null,
        refundMethod = null;

  final List<ReturnLine> items;
  final ReturnReason reason;
  final String? note;

  /// Proportional credit for [items] (docs/19 §13.3), birr.
  final Decimal credit;
  final bool isExchange;
  final Decimal? refundAmount;
  final RefundMethod? refundMethod;
}

/// Opens the return / exchange sheet for [sale] (docs/19 §6.5).
Future<ReturnSheetResult?> showReturnSheet(
  BuildContext context, {
  required SaleReceiptData sale,
  required ReturnCreditCalculator calculator,
  required bool outsideWindow,
  required int returnWindowDays,
}) {
  return showModalBottomSheet<ReturnSheetResult>(
    context: context,
    isScrollControlled: true,
    builder: (_) => ReturnSheet(
      sale: sale,
      calculator: calculator,
      outsideWindow: outsideWindow,
      returnWindowDays: returnWindowDays,
    ),
  );
}

class ReturnSheet extends StatefulWidget {
  const ReturnSheet({
    required this.sale,
    required this.calculator,
    required this.outsideWindow,
    required this.returnWindowDays,
    super.key,
  });

  final SaleReceiptData sale;
  final ReturnCreditCalculator calculator;

  /// Owner warning only: cashiers are PIN-gated for every return anyway,
  /// and the server audits the owner instead of refusing.
  final bool outsideWindow;
  final int returnWindowDays;

  @override
  State<ReturnSheet> createState() => _ReturnSheetState();
}

class _Pick {
  _Pick({required this.qty, required this.condition});
  Decimal qty;
  ReturnCondition condition;
}

class _ReturnSheetState extends State<ReturnSheet> {
  final Map<String, _Pick> _picked = {};
  ReturnReason? _reason;
  RefundMethod _refundMethod = RefundMethod.cash;
  final _note = TextEditingController();
  final _refund = TextEditingController();

  /// Once the cashier types a refund amount, stop overwriting it with the
  /// credit as ticks change — but keep it clamped to the new maximum.
  bool _refundEdited = false;

  @override
  void dispose() {
    _note.dispose();
    _refund.dispose();
    super.dispose();
  }

  List<ReturnLine> get _lines => [
        for (final e in _picked.entries)
          if (e.value.qty > Decimal.zero)
            ReturnLine(
              saleItemId: e.key,
              quantity: e.value.qty,
              condition: e.value.condition,
            ),
      ];

  Decimal get _credit {
    final byId = {for (final i in widget.sale.items) i.id: i};
    return decimalFromSantim(
      widget.calculator.creditTotalSantim([
        for (final l in _lines)
          (
            unitPriceSantim: santimFromDecimal(byId[l.saleItemId]!.unitPrice),
            quantity: l.quantity,
          ),
      ]),
    );
  }

  void _syncRefundToCredit() {
    final credit = _credit;
    if (!_refundEdited) {
      _refund.text = _fmt(credit);
      return;
    }
    final typed = Decimal.tryParse(_refund.text.trim().replaceAll(',', '.'));
    if (typed != null && typed > credit) _refund.text = _fmt(credit);
  }

  void _toggle(SaleReceiptItem item, bool on) {
    setState(() {
      if (on) {
        // A line can have a fractional remainder (0.5 kg, or one unit of two
        // already partly returned); seeding a flat 1 would bounce off the
        // server with `return_exceeds_sold`.
        final remaining = Decimal.parse(item.remainingQuantity.toString());
        _picked[item.id] = _Pick(
          qty: remaining < Decimal.one ? remaining : Decimal.one,
          condition: ReturnCondition.resellable,
        );
      } else {
        _picked.remove(item.id);
      }
      _syncRefundToCredit();
    });
  }

  void _setQty(SaleReceiptItem item, Decimal qty) {
    final max = Decimal.parse(item.remainingQuantity.toString());
    setState(() {
      if (qty <= Decimal.zero) {
        _picked.remove(item.id);
      } else {
        _picked[item.id]!.qty = qty > max ? max : qty;
      }
      _syncRefundToCredit();
    });
  }

  void _returnEverything() {
    setState(() {
      for (final item in widget.sale.items) {
        if (item.isFullyReturned) continue;
        _picked[item.id] = _Pick(
          qty: Decimal.parse(item.remainingQuantity.toString()),
          condition: _picked[item.id]?.condition ?? ReturnCondition.resellable,
        );
      }
      _syncRefundToCredit();
    });
  }

  bool _validateCommon() {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    if (_lines.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(l.returnNoItems)));
      return false;
    }
    if (_reason == null) {
      messenger.showSnackBar(SnackBar(content: Text(l.returnReasonRequired)));
      return false;
    }
    return true;
  }

  void _submitRefund() {
    if (!_validateCommon()) return;
    final credit = _credit;
    final amount = Decimal.tryParse(_refund.text.trim().replaceAll(',', '.'));
    if (amount == null || amount < Decimal.zero || amount > credit) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.l10n.returnRefundInvalid(context.money(credit)),
          ),
        ),
      );
      return;
    }
    Navigator.pop(
      context,
      ReturnSheetResult.refund(
        items: _lines,
        reason: _reason!,
        credit: credit,
        refundAmount: amount,
        refundMethod: _refundMethod,
        note: _noteOrNull,
      ),
    );
  }

  void _submitExchange() {
    if (!_validateCommon()) return;
    Navigator.pop(
      context,
      ReturnSheetResult.exchange(
        items: _lines,
        reason: _reason!,
        credit: _credit,
        note: _noteOrNull,
      ),
    );
  }

  String? get _noteOrNull {
    final t = _note.text.trim();
    return t.isEmpty ? null : t;
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final credit = _credit;
    final hasPick = _lines.isNotEmpty;

    return SuuqSheet(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(l.returnButton, style: theme.textTheme.titleLarge),
              ),
              TextButton(
                onPressed: _returnEverything,
                child: Text(l.returnEverything),
              ),
            ],
          ),
          Text(
            l.receiptSaleNumber(widget.sale.id.substring(0, 8)),
            style: theme.textTheme.bodySmall?.copyWith(
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          if (widget.outsideWindow) ...[
            const SizedBox(height: SuuqSpacing.sm),
            _WarningCard(text: l.returnOutsideWindow(widget.returnWindowDays)),
          ],
          const SizedBox(height: SuuqSpacing.md),
          Text(l.returnSelectItemsHint, style: theme.textTheme.bodySmall),
          const SizedBox(height: SuuqSpacing.xs),
          for (final item in widget.sale.items)
            _ReturnItemTile(
              item: item,
              pick: _picked[item.id],
              onToggle: (on) => _toggle(item, on),
              onQty: (q) => _setQty(item, q),
              onCondition: (c) => setState(() {
                _picked[item.id]!.condition = c;
              }),
            ),
          const SizedBox(height: SuuqSpacing.md),
          Text(
            l.returnReasonCaps,
            style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
          ),
          const SizedBox(height: SuuqSpacing.xs),
          Wrap(
            spacing: SuuqSpacing.xs,
            runSpacing: SuuqSpacing.xs,
            children: [
              for (final r in ReturnReason.values)
                ChoiceChip(
                  label: Text(returnReasonLabel(l, r)),
                  selected: _reason == r,
                  onSelected: (_) => setState(() => _reason = r),
                ),
            ],
          ),
          const SizedBox(height: SuuqSpacing.sm),
          TextField(
            controller: _note,
            decoration: InputDecoration(hintText: l.returnNoteHint),
            maxLines: 2,
            minLines: 1,
          ),
          const SizedBox(height: SuuqSpacing.md),
          Container(
            padding: const EdgeInsets.all(SuuqSpacing.md),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(SuuqRadius.md),
            ),
            child: Row(
              children: [
                Text(l.returnCredit, style: theme.textTheme.bodyMedium),
                const Spacer(),
                Text(
                  context.money(credit),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: SuuqSpacing.md),
          Text(
            l.returnRefundCaps,
            style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.2),
          ),
          const SizedBox(height: SuuqSpacing.xs),
          SegmentedButton<RefundMethod>(
            segments: [
              ButtonSegment(
                value: RefundMethod.cash,
                icon: const Icon(Icons.payments_rounded, size: 18),
                label: Text(l.paymentCash),
              ),
              ButtonSegment(
                value: RefundMethod.mobileMoney,
                icon: const Icon(Icons.phone_iphone_rounded, size: 18),
                label: Text(l.paymentMobile),
              ),
            ],
            selected: {_refundMethod},
            onSelectionChanged: (s) => setState(() => _refundMethod = s.first),
          ),
          const SizedBox(height: SuuqSpacing.sm),
          TextField(
            controller: _refund,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            // Rebuild so the Refund button always names the amount that
            // will actually be handed over.
            onChanged: (_) => setState(() => _refundEdited = true),
            decoration: InputDecoration(
              labelText: l.returnRefundAmountLabel,
              prefixText: 'ETB  ',
              helperText: l.returnRefundAmountHelper(context.money(credit)),
            ),
          ),
          const SizedBox(height: SuuqSpacing.lg),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.swap_horiz_rounded, size: 20),
                    onPressed: hasPick ? _submitExchange : null,
                    label: Text(l.returnExchangeButton),
                  ),
                ),
              ),
              const SizedBox(width: SuuqSpacing.sm),
              Expanded(
                child: SizedBox(
                  height: 56,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.undo_rounded, size: 20),
                    onPressed: hasPick ? _submitRefund : null,
                    label: Text(
                      l.returnRefundButton(
                        context.money(
                          Decimal.tryParse(
                                _refund.text.trim().replaceAll(',', '.'),
                              ) ??
                              credit,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static String _fmt(Decimal v) {
    final n = v.toDouble();
    return n == n.roundToDouble() ? n.toInt().toString() : n.toStringAsFixed(2);
  }
}

/// Localised label for a return reason chip / detail row.
String returnReasonLabel(AppLocalizations l, ReturnReason r) => switch (r) {
      ReturnReason.wrongSize => l.returnReasonWrongSize,
      ReturnReason.defect => l.returnReasonDefect,
      ReturnReason.changedMind => l.returnReasonChangedMind,
      ReturnReason.other => l.returnReasonOther,
    };

String returnConditionLabel(AppLocalizations l, ReturnCondition c) =>
    switch (c) {
      ReturnCondition.resellable => l.returnConditionResellable,
      ReturnCondition.damaged => l.returnConditionDamaged,
    };

class _ReturnItemTile extends StatelessWidget {
  const _ReturnItemTile({
    required this.item,
    required this.pick,
    required this.onToggle,
    required this.onQty,
    required this.onCondition,
  });

  final SaleReceiptItem item;
  final _Pick? pick;
  final ValueChanged<bool> onToggle;
  final ValueChanged<Decimal> onQty;
  final ValueChanged<ReturnCondition> onCondition;

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final done = item.isFullyReturned;
    final remaining = Decimal.parse(item.remainingQuantity.toString());
    final qty = pick?.qty ?? Decimal.zero;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: SuuqSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Checkbox(
                value: pick != null,
                onChanged: done ? null : (v) => onToggle(v ?? false),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        color: done ? scheme.onSurfaceVariant : null,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      done
                          ? l.returnFullyReturned
                          : item.returnedQuantity > 0
                              ? '${l.returnSoldQty(receiptQtyText(item.quantity))}'
                                  ' · ${l.returnAlreadyReturned(receiptQtyText(item.returnedQuantity))}'
                              : '${l.returnSoldQty(receiptQtyText(item.quantity))}'
                                  ' · ${context.money(item.unitPrice)}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              if (pick != null)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      key: ValueKey('return_minus_${item.id}'),
                      icon: const Icon(Icons.remove_rounded, size: 18),
                      onPressed: () => onQty(qty - Decimal.one),
                    ),
                    Text(
                      receiptQtyText(qty.toDouble()),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    IconButton(
                      key: ValueKey('return_plus_${item.id}'),
                      icon: const Icon(Icons.add_rounded, size: 18),
                      onPressed: qty >= remaining
                          ? null
                          : () => onQty(qty + Decimal.one),
                    ),
                  ],
                ),
            ],
          ),
          if (pick != null)
            Padding(
              padding: const EdgeInsets.only(left: 48, bottom: SuuqSpacing.xs),
              child: Wrap(
                spacing: SuuqSpacing.xs,
                children: [
                  for (final c in ReturnCondition.values)
                    ChoiceChip(
                      label: Text(returnConditionLabel(l, c)),
                      selected: pick!.condition == c,
                      onSelected: (_) => onCondition(c),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _WarningCard extends StatelessWidget {
  const _WarningCard({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(SuuqSpacing.md),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(SuuqRadius.md),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: scheme.onErrorContainer),
          const SizedBox(width: SuuqSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
