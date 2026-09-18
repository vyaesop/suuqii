import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:suuqii/app/theme/tokens.dart';
import 'package:suuqii/core/connectivity/offline_banner.dart';
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
    // Boutique shops share the regular nav (docs/19 §13.1): only shops with
    // ingredient supplies swap the Debts tab for Supplies.
    final hasSupplies = auth is Authenticated && auth.features.hasSupplies;
    final isBaker = auth is Authenticated && auth.isBaker;
    final loc = GoRouterState.of(context).matchedLocation;
    final scheme = Theme.of(context).colorScheme;

    // Bakers get no POS, no debts and no money surface at all — their tabs are
    // the bake, the ingredients they draw on, and their shift.
    final paths = isBaker
        ? ['/handover', '/inventory', '/supplies', '/shift']
        : [
            '/pos',
            '/inventory',
            // Bakery shops replace the Debts tab with Supplies.
            if (hasSupplies) '/supplies' else '/debts',
            '/shift',
            if (isOwner) '/owner' else '/me',
          ];
    final idx = paths.indexWhere(loc.startsWith).clamp(0, paths.length - 1);

    final destinations = isBaker
        ? [
            _NavItem(icon: Icons.bakery_dining_rounded, label: l.navHandover),
            _NavItem(icon: Icons.inventory_2_rounded, label: l.navInventory),
            _NavItem(icon: Icons.egg_alt_rounded, label: l.navSupplies),
            _NavItem(icon: Icons.timelapse_rounded, label: l.navShift),
          ]
        : [
            _NavItem(icon: Icons.point_of_sale_rounded, label: l.navSell),
            _NavItem(icon: Icons.inventory_2_rounded, label: l.navInventory),
            if (hasSupplies)
              _NavItem(icon: Icons.egg_alt_rounded, label: l.navSupplies)
            else
              _NavItem(
                icon: Icons.account_balance_wallet_rounded,
                label: l.navDebts,
              ),
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
              SuuqSpacing.md,
              SuuqSpacing.xs,
              SuuqSpacing.xs,
              SuuqSpacing.xs,
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
                    tooltip: l.navSettings,
                    onPressed: () => context.push('/me'),
                  ),
              ],
            ),
          ),
        ),
      ),
      body: Column(
        children: [
          const OfflineBanner(),
          Expanded(child: child),
        ],
      ),
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
    if (location.startsWith('/supplies')) return l.navSupplies;
    if (location.startsWith('/handovers-received')) return l.navCounted;
    if (location.startsWith('/handover')) return l.navHandover;
    if (location.startsWith('/shift')) return l.navShift;
    if (location.startsWith('/owner')) return l.navDashboard;
    if (location.startsWith('/me')) return l.navSettings;
    if (location.startsWith('/expenses')) return l.expenses;
    if (location.startsWith('/audit')) return l.auditTitle;
    return l.appTitle;
  }
}

class _NavItem {
  const _NavItem({required this.icon, required this.label});
  final IconData icon;
  final String label;
}
