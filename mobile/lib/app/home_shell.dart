import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/sync/presentation/sync_status_badge.dart';
import 'package:suuqii/l10n/app_localizations.dart';

class HomeShell extends ConsumerWidget {
  const HomeShell({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final isOwner = auth is Authenticated && auth.role == 'owner';
    final isBakery = auth is Authenticated && auth.isBakery;
    final loc = GoRouterState.of(context).matchedLocation;
    final scheme = Theme.of(context).colorScheme;

    // Bakery shops replace the Debts tab with Supplies.
    final paths = [
      '/pos',
      '/inventory',
      if (isBakery) '/supplies' else '/debts',
      '/shift',
      if (isOwner) '/owner' else '/me',
    ];
    final idx = paths.indexWhere(loc.startsWith).clamp(0, paths.length - 1);

    final destinations = [
      _NavItem(icon: Icons.point_of_sale_rounded, label: l.navSell),
      _NavItem(icon: Icons.inventory_2_rounded, label: l.navInventory),
      if (isBakery)
        const _NavItem(icon: Icons.egg_alt_rounded, label: 'Supplies')
      else
        _NavItem(icon: Icons.account_balance_wallet_rounded, label: l.navDebts),
      _NavItem(icon: Icons.timelapse_rounded, label: l.navShift),
      if (isOwner)
        _NavItem(icon: Icons.insights_rounded, label: l.navDashboard)
      else
        _NavItem(icon: Icons.tune_rounded, label: l.navSettings),
    ];

    return Scaffold(
      appBar: PreferredSize(
        preferredSize: const Size.fromHeight(56),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              SuuqSpacing.md, SuuqSpacing.xs, SuuqSpacing.xs, SuuqSpacing.xs,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _titleFor(loc, l),
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                ),
                const SyncStatusBadge(),
                if (isOwner)
                  IconButton(
                    icon: Icon(
                      Icons.menu_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
                    tooltip: 'Settings',
                    onPressed: () => context.push('/me'),
                  ),
              ],
            ),
          ),
        ),
      ),
      body: child,
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: scheme.surface,
          border: Border(
            top: BorderSide(color: scheme.outlineVariant),
          ),
        ),
        child: NavigationBar(
          destinations: destinations
              .map(
                (d) => NavigationDestination(
                  icon: Icon(d.icon, color: scheme.onSurfaceVariant),
                  selectedIcon: Icon(d.icon, color: scheme.onPrimaryContainer),
                  label: d.label,
                ),
              )
              .toList(),
          selectedIndex: idx,
          onDestinationSelected: (i) => context.go(paths[i]),
        ),
      ),
    );
  }

  String _titleFor(String location, AppLocalizations l) {
    if (location.startsWith('/pos')) return l.navSell;
    if (location.startsWith('/inventory')) return l.navInventory;
    if (location.startsWith('/debts')) return l.navDebts;
    if (location.startsWith('/supplies')) return 'Supplies';
    if (location.startsWith('/shift')) return l.navShift;
    if (location.startsWith('/owner')) return l.navDashboard;
    if (location.startsWith('/me')) return l.navSettings;
    if (location.startsWith('/expenses')) return 'Expenses';
    if (location.startsWith('/audit')) return 'Audit';
    return 'Suuqii';
  }
}

class _NavItem {
  const _NavItem({required this.icon, required this.label});
  final IconData icon;
  final String label;
}
