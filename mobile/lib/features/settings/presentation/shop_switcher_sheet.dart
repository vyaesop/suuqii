import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/l10n/error_l10n.dart';
import 'package:suuqii/core/l10n/l10n.dart';
import 'package:suuqii/features/auth/domain/entities/shop_option.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/settings/presentation/employees_screen.dart'
    show authApiProvider;
import 'package:suuqii/shared/widgets/sheet_handle.dart';

/// Shops the signed-in account may act in.
final myShopsProvider = FutureProvider.autoDispose<List<ShopOption>>((ref) {
  return ref.watch(authApiProvider).myShops();
});

/// Switch the device between shops the same person owns — the case this exists
/// for is one owner running a bakery and a regular shop.
///
/// Switching re-issues tokens *and wipes the local database*: the on-device
/// store holds one shop's data at a time. That makes it a deliberate action
/// with a confirmation, not a casual toggle.
class ShopSwitcherSheet extends ConsumerStatefulWidget {
  const ShopSwitcherSheet({super.key});

  @override
  ConsumerState<ShopSwitcherSheet> createState() => _ShopSwitcherSheetState();
}

class _ShopSwitcherSheetState extends ConsumerState<ShopSwitcherSheet> {
  bool _busy = false;

  Future<void> _switch(ShopOption shop, {bool force = false}) async {
    final l = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(authControllerProvider.notifier).switchShop(
            shop.id,
            force: force,
          );
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(content: Text(l.shopSwitchedTo(shop.name))),
      );
    } on PendingSyncException catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      // Unsynced sales belong to the shop being left. Switching would wipe
      // them, so this needs an explicit decision rather than a silent loss.
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l.shopSwitchPendingTitle),
          content: Text(l.shopSwitchPendingBody(e.pendingCount)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l.shopSwitchDiscardAndSwitch),
            ),
          ],
        ),
      );
      if ((discard ?? false) && mounted) {
        await _switch(shop, force: true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      messenger.showSnackBar(
        SnackBar(content: Text(localizedErrorMessage(l, e))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shops = ref.watch(myShopsProvider);

    return SuuqSheet(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l.shopSwitcherTitle, style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            l.shopSwitcherSubtitle,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: SuuqSpacing.md),
          shops.when(
            loading: () => const Padding(
              padding: EdgeInsets.all(SuuqSpacing.lg),
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(SuuqSpacing.md),
              child: Text(localizedErrorMessage(l, e)),
            ),
            data: (items) => Column(
              children: [
                for (final shop in items)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      shop.isBakery
                          ? Icons.bakery_dining_rounded
                          : Icons.storefront_rounded,
                      color: shop.isActive ? scheme.primary : null,
                    ),
                    title: Text(shop.name),
                    subtitle: Text(_roleLabel(l, shop.role)),
                    trailing: shop.isActive
                        ? Icon(Icons.check_circle_rounded, color: scheme.primary)
                        : const Icon(Icons.chevron_right_rounded),
                    enabled: !_busy && !shop.isActive,
                    onTap: shop.isActive || _busy ? null : () => _switch(shop),
                  ),
              ],
            ),
          ),
          if (_busy) ...[
            const SizedBox(height: SuuqSpacing.sm),
            const LinearProgressIndicator(),
          ],
        ],
      ),
    );
  }

  String _roleLabel(AppLocalizations l, String role) => switch (role) {
        'owner' => l.employeeRoleOwner,
        'baker' => l.employeeRoleBaker,
        _ => l.employeeRoleCashier,
      };
}
