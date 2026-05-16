import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../features/auth/domain/entities/auth_state.dart';
import '../features/auth/presentation/controllers/auth_controller.dart';
import '../features/sync/presentation/sync_status_badge.dart';
import '../l10n/app_localizations.dart';

class HomeShell extends ConsumerWidget {
  const HomeShell({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l = AppLocalizations.of(context);
    final auth = ref.watch(authControllerProvider).valueOrNull;
    final isOwner = auth is Authenticated && auth.role == 'owner';
    final loc = GoRouterState.of(context).matchedLocation;

    final destinations = <NavigationDestination>[
      NavigationDestination(icon: const Icon(Icons.point_of_sale), label: l.navSell),
      NavigationDestination(icon: const Icon(Icons.inventory_2_outlined), label: l.navInventory),
      NavigationDestination(icon: const Icon(Icons.account_balance_wallet_outlined), label: l.navDebts),
      NavigationDestination(icon: const Icon(Icons.access_time), label: l.navShift),
      isOwner
          ? NavigationDestination(icon: const Icon(Icons.insights), label: l.navDashboard)
          : NavigationDestination(icon: const Icon(Icons.settings), label: l.navSettings),
    ];

    final paths = ['/pos', '/inventory', '/debts', '/shift', isOwner ? '/owner' : '/me'];
    final idx = paths.indexWhere(loc.startsWith).clamp(0, paths.length - 1);

    return Scaffold(
      appBar: AppBar(actions: const [SyncStatusBadge()]),
      body: child,
      bottomNavigationBar: NavigationBar(
        destinations: destinations,
        selectedIndex: idx,
        onDestinationSelected: (i) => context.go(paths[i]),
      ),
    );
  }
}
