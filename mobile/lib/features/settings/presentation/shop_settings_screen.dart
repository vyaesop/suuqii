import 'package:decimal/decimal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/http/dio_client.dart';
import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/settings/data/shop_settings_data_source.dart';
import 'package:suuqii/shared/widgets/empty_state.dart';

final _shopSettingsApiProvider = Provider<ShopSettingsDataSource>(
  (ref) => ShopSettingsDataSource(ref.watch(dioProvider)),
);

final _shopSettingsProvider = FutureProvider.autoDispose<ShopSettings>(
  (ref) => ref.watch(_shopSettingsApiProvider).fetch(),
);

/// Owner-only, online-only: edit shop name and the two money thresholds.
/// On save the PATCHed values are pushed into the auth state so the offline
/// checks (credit limit at checkout, expense PIN gate) update immediately.
class ShopSettingsScreen extends ConsumerWidget {
  const ShopSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = context.l10n;
    final async = ref.watch(_shopSettingsProvider);

    return Scaffold(
      appBar: AppBar(title: Text(l.shopSettingsTitle)),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => EmptyState(
          icon: Icons.cloud_off_rounded,
          title: l.shopSettingsLoadFailedTitle,
          message: context.errorMessage(e),
          action: OutlinedButton.icon(
            icon: const Icon(Icons.refresh_rounded),
            // ignore: unused_result
            onPressed: () => ref.refresh(_shopSettingsProvider),
            label: Text(l.commonRetry),
          ),
        ),
        data: (settings) => _ShopSettingsForm(settings: settings),
      ),
    );
  }
}

class _ShopSettingsForm extends ConsumerStatefulWidget {
  const _ShopSettingsForm({required this.settings});
  final ShopSettings settings;

  @override
  ConsumerState<_ShopSettingsForm> createState() => _ShopSettingsFormState();
}

class _ShopSettingsFormState extends ConsumerState<_ShopSettingsForm> {
  late final TextEditingController _name;
  late final TextEditingController _debtThreshold;
  late final TextEditingController _expenseThreshold;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.settings.name);
    _debtThreshold = TextEditingController(text: widget.settings.debtThreshold);
    _expenseThreshold = TextEditingController(
      text: widget.settings.expenseApprovalThreshold,
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _debtThreshold.dispose();
    _expenseThreshold.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    return ListView(
      padding: const EdgeInsets.all(SuuqSpacing.md),
      children: [
        TextField(
          controller: _name,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: l.shopSettingsNameLabel,
            prefixIcon: const Icon(Icons.storefront_outlined),
          ),
        ),
        const SizedBox(height: SuuqSpacing.md),
        TextField(
          controller: _debtThreshold,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: l.shopSettingsDebtThresholdLabel,
            helperText: l.shopSettingsDebtThresholdHelp,
            helperMaxLines: 3,
            prefixText: 'ETB  ',
          ),
        ),
        const SizedBox(height: SuuqSpacing.md),
        TextField(
          controller: _expenseThreshold,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: l.shopSettingsExpenseThresholdLabel,
            helperText: l.shopSettingsExpenseThresholdHelp,
            helperMaxLines: 3,
            prefixText: 'ETB  ',
          ),
        ),
        const SizedBox(height: SuuqSpacing.lg),
        SizedBox(
          height: 56,
          child: FilledButton.icon(
            icon: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.save_outlined),
            onPressed: _busy ? null : _save,
            label: Text(l.commonSave),
          ),
        ),
      ],
    );
  }

  Future<void> _save() async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final name = _name.text.trim();
    if (name.isEmpty) {
      messenger.showSnackBar(
        SnackBar(content: Text(l.shopSettingsNameRequired)),
      );
      return;
    }
    final debt = Decimal.tryParse(_debtThreshold.text.trim());
    final expense = Decimal.tryParse(_expenseThreshold.text.trim());
    if (debt == null ||
        debt < Decimal.zero ||
        expense == null ||
        expense < Decimal.zero) {
      messenger.showSnackBar(
        SnackBar(content: Text(l.debtEnterValidAmount)),
      );
      return;
    }

    setState(() => _busy = true);
    try {
      final updated = await ref.read(_shopSettingsApiProvider).update(
            name: name,
            debtThreshold: debt.toString(),
            expenseApprovalThreshold: expense.toString(),
          );
      // Mirror into auth state + its persistence so offline checks pick the
      // new thresholds up immediately.
      await ref.read(authControllerProvider.notifier).applyShopSettings(
            shopName: updated.name,
            debtThreshold: updated.debtThreshold,
            expenseApprovalThreshold: updated.expenseApprovalThreshold,
          );
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(l.shopSettingsSaved)));
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text(context.errorMessage(e))));
    }
  }
}
