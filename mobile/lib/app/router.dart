import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:suuqii/app/home_shell.dart';
import 'package:suuqii/app/sheet_snackbar_observer.dart';
import 'package:suuqii/app/update_required_screen.dart';
import 'package:suuqii/core/http/update_required.dart';
import 'package:suuqii/features/audit/presentation/audit_screen.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/auth/presentation/screens/accept_invite_screen.dart';
import 'package:suuqii/features/auth/presentation/screens/login_screen.dart';
import 'package:suuqii/features/auth/presentation/screens/register_shop_screen.dart';
import 'package:suuqii/features/dashboard/presentation/owner_dashboard_screen.dart';
import 'package:suuqii/features/dashboard/presentation/reports_screen.dart';
import 'package:suuqii/features/dashboard/presentation/size_curve_screen.dart';
import 'package:suuqii/features/debt/presentation/debt_detail_screen.dart';
import 'package:suuqii/features/debt/presentation/debts_screen.dart';
import 'package:suuqii/features/expenses/presentation/expenses_screen.dart';
import 'package:suuqii/features/handovers/presentation/accept_handover_screen.dart';
import 'package:suuqii/features/handovers/presentation/baker_handover_screen.dart';
import 'package:suuqii/features/inventory/presentation/batch_report_screen.dart';
import 'package:suuqii/features/inventory/presentation/bulk_restock_screen.dart';
import 'package:suuqii/features/inventory/presentation/inventory_screen.dart';
import 'package:suuqii/features/inventory/presentation/product_detail_screen.dart';
import 'package:suuqii/features/inventory/presentation/product_edit_screen.dart';
import 'package:suuqii/features/inventory/presentation/style_screen.dart';
import 'package:suuqii/features/inventory/presentation/style_wizard_screen.dart';
import 'package:suuqii/features/sales/presentation/pos_screen.dart';
import 'package:suuqii/features/sales/presentation/recent_sales_screen.dart';
import 'package:suuqii/features/sales/presentation/sale_detail_screen.dart';
import 'package:suuqii/features/settings/presentation/data_screen.dart';
import 'package:suuqii/features/settings/presentation/devices_screen.dart';
import 'package:suuqii/features/settings/presentation/employees_screen.dart';
import 'package:suuqii/features/settings/presentation/settings_screen.dart';
import 'package:suuqii/features/settings/presentation/shop_settings_screen.dart';
import 'package:suuqii/features/shifts/presentation/open_shifts_screen.dart';
import 'package:suuqii/features/shifts/presentation/shift_screen.dart';
import 'package:suuqii/features/supplies/presentation/supplies_screen.dart';

part 'router.g.dart';

/// Route prefixes that only owners may visit (see docs/17-roles.md).
/// Cashiers are redirected to the POS both from navigation and deep links.
/// This is UX only — the server independently enforces every owner-only
/// endpoint.
const ownerOnlyPathPrefixes = [
  '/owner',
  '/reports',
  '/audit',
  '/employees',
  '/open-shifts',
  '/shop-settings',
  // CSV export carries cost prices and margins.
  '/data',
];

/// Prefixes a baker must never reach: anything that takes payment, moves money
/// or shows what things cost. A baker landing on these would be a capability
/// leak, so deep links are redirected too.
const bakerDeniedPathPrefixes = [
  '/pos',
  '/recent-sales',
  '/debts',
  '/expenses',
];

/// Single reusable role guard: returns the location to redirect to, or null
/// when [location] is allowed.
///
/// Bakers are checked before owners-only because their denied set overlaps
/// routes a cashier may visit — `isOwner: false` alone does not describe them.
String? roleRedirect(
  String location, {
  required bool isOwner,
  required bool isBaker,
}) {
  if (isBaker) {
    return bakerDeniedPathPrefixes.any(location.startsWith) ||
            ownerOnlyPathPrefixes.any(location.startsWith)
        ? '/handover'
        : null;
  }
  if (isOwner) return null;
  return ownerOnlyPathPrefixes.any(location.startsWith) ? '/pos' : null;
}

/// Kept for the existing call sites and tests; [roleRedirect] is the general
/// form.
String? ownerOnlyRedirect(String location, {required bool isOwner}) =>
    roleRedirect(location, isOwner: isOwner, isBaker: false);

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
    )
    ..listen<bool>(
      updateRequiredProvider,
      (_, __) => refreshNotifier.trigger(),
    );

  return GoRouter(
    initialLocation: '/pos',
    refreshListenable: refreshNotifier,
    observers: [SheetSnackBarObserver()],
    redirect: (ctx, state) {
      final loc = state.matchedLocation;

      // The backend demands a newer app (HTTP 426): block everything behind
      // the update screen. The flag never resets in-session, so there is no
      // way to navigate away until a newer build is installed.
      final updateRequired = ref.read(updateRequiredProvider);
      if (updateRequired) {
        return loc == '/update-required' ? null : '/update-required';
      }

      final authAsync = ref.read(authControllerProvider);
      if (authAsync.isLoading) return null;

      final auth = authAsync.valueOrNull;
      final publicPaths = {'/login', '/register-shop', '/accept-invite'};
      final isAuthed = auth is Authenticated;
      // Bakers have no POS, so the post-auth landing route is role-dependent.
      final home = isAuthed ? auth.homeRoute : '/pos';
      if (loc == '/update-required') return home;
      if (!isAuthed && !publicPaths.contains(loc)) return '/login';
      if (isAuthed && publicPaths.contains(loc)) return home;
      return roleRedirect(
        loc,
        isOwner: isAuthed && auth.isOwner,
        isBaker: isAuthed && auth.isBaker,
      );
    },
    routes: [
      GoRoute(
        path: '/update-required',
        builder: (_, __) => const UpdateRequiredScreen(),
      ),
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
        // Sheets opened from tab screens land on this navigator.
        observers: [SheetSnackBarObserver()],
        builder: (_, __, child) => HomeShell(child: child),
        routes: [
          GoRoute(path: '/pos', builder: (_, __) => const PosScreen()),
          GoRoute(
            path: '/recent-sales',
            builder: (_, __) => const RecentSalesScreen(),
            routes: [
              GoRoute(
                path: ':id',
                builder: (_, state) =>
                    SaleDetailScreen(saleId: state.pathParameters['id']!),
              ),
            ],
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
              // Boutique: create a style with its size × colour matrix.
              // Declared before ':id' so the literal segment wins.
              GoRoute(
                path: 'new-style',
                builder: (_, __) => const StyleWizardScreen(),
              ),
              GoRoute(
                path: 'style/:id',
                builder: (_, state) =>
                    StyleScreen(styleId: state.pathParameters['id']!),
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
            routes: [
              // Owner-only via the /reports redirect guard above.
              GoRoute(
                path: 'batches',
                builder: (_, state) => BatchReportScreen(
                  productId: state.uri.queryParameters['product'],
                ),
              ),
              // Boutique size curve for one style, opened from the style
              // screen and from a rebuy row; owner-only via the same guard.
              GoRoute(
                path: 'size-curve',
                builder: (_, state) => SizeCurveScreen(
                  styleId: state.uri.queryParameters['style'] ?? '',
                ),
              ),
            ],
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
          // Baker's home: record the bake and declare what went to the counter.
          GoRoute(
            path: '/handover',
            builder: (_, __) => const BakerHandoverScreen(),
          ),
          // Counter's side: the second, independent count.
          GoRoute(
            path: '/handovers-received',
            builder: (_, __) => const AcceptHandoverScreen(),
          ),
          GoRoute(path: '/audit', builder: (_, __) => const AuditScreen()),
          GoRoute(
            path: '/employees',
            builder: (_, __) => const EmployeesScreen(),
            routes: [
              // Owner-only via the /employees redirect guard above.
              GoRoute(
                path: 'devices',
                builder: (_, __) => const DevicesScreen(),
              ),
            ],
          ),
          GoRoute(
            path: '/shop-settings',
            builder: (_, __) => const ShopSettingsScreen(),
          ),
          // Owner-only via the /data redirect guard.
          GoRoute(path: '/data', builder: (_, __) => const DataScreen()),
          GoRoute(path: '/me', builder: (_, __) => const SettingsScreen()),
        ],
      ),
    ],
  );
}
