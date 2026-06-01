import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:suuqii/app/home_shell.dart';
import 'package:suuqii/features/audit/presentation/audit_screen.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/auth/presentation/screens/accept_invite_screen.dart';
import 'package:suuqii/features/auth/presentation/screens/login_screen.dart';
import 'package:suuqii/features/auth/presentation/screens/register_shop_screen.dart';
import 'package:suuqii/features/dashboard/presentation/owner_dashboard_screen.dart';
import 'package:suuqii/features/dashboard/presentation/reports_screen.dart';
import 'package:suuqii/features/debt/presentation/debt_detail_screen.dart';
import 'package:suuqii/features/debt/presentation/debts_screen.dart';
import 'package:suuqii/features/expenses/presentation/expenses_screen.dart';
import 'package:suuqii/features/inventory/presentation/bulk_restock_screen.dart';
import 'package:suuqii/features/inventory/presentation/inventory_screen.dart';
import 'package:suuqii/features/inventory/presentation/product_detail_screen.dart';
import 'package:suuqii/features/inventory/presentation/product_edit_screen.dart';
import 'package:suuqii/features/sales/presentation/pos_screen.dart';
import 'package:suuqii/features/sales/presentation/recent_sales_screen.dart';
import 'package:suuqii/features/settings/presentation/employees_screen.dart';
import 'package:suuqii/features/settings/presentation/settings_screen.dart';
import 'package:suuqii/features/shifts/presentation/open_shifts_screen.dart';
import 'package:suuqii/features/shifts/presentation/shift_screen.dart';
import 'package:suuqii/features/supplies/presentation/supplies_screen.dart';

part 'router.g.dart';

class _RouterRefreshNotifier extends ChangeNotifier {
  void trigger() => notifyListeners();
}

@Riverpod(keepAlive: true)
GoRouter router(RouterRef ref) {
  final refreshNotifier = _RouterRefreshNotifier();
  ref
    ..onDispose(refreshNotifier.dispose)
    ..listen<AsyncValue<AuthState>>(
      authControllerProvider,
      (_, __) => refreshNotifier.trigger(),
    );

  return GoRouter(
    initialLocation: '/pos',
    refreshListenable: refreshNotifier,
    redirect: (ctx, state) {
      final authAsync = ref.read(authControllerProvider);
      if (authAsync.isLoading) return null;

      final auth = authAsync.valueOrNull;
      final loc = state.matchedLocation;
      final publicPaths = {'/login', '/register-shop', '/accept-invite'};
      final isAuthed = auth is Authenticated;
      if (!isAuthed && !publicPaths.contains(loc)) return '/login';
      if (isAuthed && publicPaths.contains(loc)) return '/pos';
      final isOwner = isAuthed && auth.role == 'owner';
      if (loc.startsWith('/owner') && !isOwner) return '/pos';
      if (loc == '/audit' && !isOwner) return '/pos';
      if (loc.startsWith('/employees') && !isOwner) return '/pos';
      if (loc.startsWith('/reports') && !isOwner) return '/pos';
      if (loc.startsWith('/open-shifts') && !isOwner) return '/pos';
      return null;
    },
    routes: [
      GoRoute(path: '/login', builder: (_, __) => const LoginScreen()),
      GoRoute(
        path: '/register-shop',
        builder: (_, __) => const RegisterShopScreen(),
      ),
      GoRoute(
        path: '/accept-invite',
        builder: (_, __) => const AcceptInviteScreen(),
      ),
      ShellRoute(
        builder: (_, __, child) => HomeShell(child: child),
        routes: [
          GoRoute(path: '/pos', builder: (_, __) => const PosScreen()),
          GoRoute(
            path: '/recent-sales',
            builder: (_, __) => const RecentSalesScreen(),
          ),
          GoRoute(
            path: '/inventory',
            builder: (_, __) => const InventoryScreen(),
            routes: [
              GoRoute(
                path: 'new',
                builder: (_, __) => const ProductEditScreen(),
              ),
              GoRoute(
                path: 'bulk-restock',
                builder: (_, __) => const BulkRestockScreen(),
              ),
              GoRoute(
                path: 'edit/:id',
                builder: (_, state) =>
                    ProductEditScreen(productId: state.pathParameters['id']),
              ),
              GoRoute(
                path: ':id',
                builder: (_, state) => ProductDetailScreen(
                  productId: state.pathParameters['id']!,
                ),
              ),
            ],
          ),
          GoRoute(
            path: '/debts',
            builder: (_, __) => const DebtsScreen(),
            routes: [
              GoRoute(
                path: ':id',
                builder: (_, state) =>
                    DebtDetailScreen(debtId: state.pathParameters['id']!),
              ),
            ],
          ),
          GoRoute(path: '/shift', builder: (_, __) => const ShiftScreen()),
          GoRoute(
            path: '/owner',
            builder: (_, __) => const OwnerDashboardScreen(),
          ),
          GoRoute(
            path: '/reports',
            builder: (_, __) => const ReportsScreen(),
          ),
          GoRoute(
            path: '/open-shifts',
            builder: (_, __) => const OpenShiftsScreen(),
          ),
          GoRoute(
            path: '/expenses',
            builder: (_, __) => const ExpensesScreen(),
          ),
          GoRoute(
            path: '/supplies',
            builder: (_, __) => const SuppliesScreen(),
          ),
          GoRoute(path: '/audit', builder: (_, __) => const AuditScreen()),
          GoRoute(
            path: '/employees',
            builder: (_, __) => const EmployeesScreen(),
          ),
          GoRoute(path: '/me', builder: (_, __) => const SettingsScreen()),
        ],
      ),
    ],
  );
}
