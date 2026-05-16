import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../features/auth/domain/entities/auth_state.dart';
import '../features/auth/presentation/controllers/auth_controller.dart';
import '../features/auth/presentation/screens/login_screen.dart';
import '../features/auth/presentation/screens/register_shop_screen.dart';
import '../features/dashboard/presentation/owner_dashboard_screen.dart';
import '../features/debt/presentation/debts_screen.dart';
import '../features/inventory/presentation/inventory_screen.dart';
import '../features/sales/presentation/pos_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/shifts/presentation/shift_screen.dart';
import 'home_shell.dart';

part 'router.g.dart';

@Riverpod(keepAlive: true)
GoRouter router(RouterRef ref) {
  return GoRouter(
    initialLocation: '/pos',
    redirect: (ctx, state) {
      final auth = ref.read(authControllerProvider).valueOrNull;
      final loc = state.matchedLocation;
      final publicPaths = {'/login', '/register-shop', '/accept-invite'};
      final isAuthed = auth is Authenticated;
      if (!isAuthed && !publicPaths.contains(loc)) return '/login';
      if (isAuthed && publicPaths.contains(loc)) return '/pos';
      final isOwner = isAuthed && auth.role == 'owner';
      if (loc.startsWith('/owner') && !isOwner) return '/pos';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(path: '/register-shop', builder: (_, __) => const RegisterShopScreen()),
      ShellRoute(
        builder: (_, __, child) => HomeShell(child: child),
        routes: [
          GoRoute(path: '/pos', builder: (_, __) => const PosScreen()),
          GoRoute(path: '/inventory', builder: (_, __) => const InventoryScreen()),
          GoRoute(path: '/debts', builder: (_, __) => const DebtsScreen()),
          GoRoute(path: '/shift', builder: (_, __) => const ShiftScreen()),
          GoRoute(path: '/owner', builder: (_, __) => const OwnerDashboardScreen()),
          GoRoute(path: '/me', builder: (_, __) => const SettingsScreen()),
        ],
      ),
    ],
  );
}
