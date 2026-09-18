import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:suuqii/app/theme/app_theme.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/dashboard/data/boutique_reports_repository.dart';
import 'package:suuqii/features/dashboard/data/dashboard_repository.dart';
import 'package:suuqii/features/dashboard/presentation/reports_screen.dart';
import 'package:suuqii/features/dashboard/presentation/size_curve_screen.dart';
import 'package:suuqii/l10n/app_localizations.dart';

class _TestAuthController extends AuthController {
  _TestAuthController(this.auth);

  final AuthState auth;

  @override
  Future<AuthState> build() async => auth;
}

const _boutiqueOwner = Authenticated(
  userId: 'user-1',
  shopId: 'shop-1',
  role: 'owner',
  userName: 'Owner',
  shopName: 'Bole Boutique',
  accessToken: 'token',
  shopType: 'boutique',
);

const _boutiqueCashier = Authenticated(
  userId: 'user-2',
  shopId: 'shop-1',
  role: 'cashier',
  userName: 'Cashier',
  shopName: 'Bole Boutique',
  accessToken: 'token',
  shopType: 'boutique',
);

const _regularOwner = Authenticated(
  userId: 'user-3',
  shopId: 'shop-2',
  role: 'owner',
  userName: 'Owner',
  shopName: 'Corner Shop',
  accessToken: 'token',
);

final _brokenRun = BrokenRun.fromJson(const {
  'style_id': 'style-1',
  'name': 'Slim jeans',
  'brand': "Levi's",
  'variant_count': 8,
  'in_stock_count': 5,
  'stock_total': '11',
  'missing': [
    {'size': '32', 'color': 'Blue', 'sold_30d': '9'},
  ],
});

final _deadStock = DeadStockReport.fromJson(const {
  'days': 60,
  'items': [
    {
      'product_id': 'p1',
      'name': 'Slim jeans · 40 · Black',
      'stock': '3',
      'age_days': 104,
      'last_sold_at': '2026-06-04',
      'unit_cost': '800.00',
      'value': '1600.00',
    },
    {
      'product_id': 'p2',
      'name': 'Scarf',
      'stock': '1',
      'age_days': 70,
      'last_sold_at': null,
      'unit_cost': '800.00',
      'value': '800.00',
    },
  ],
  // The headline is the whole result's value, not this page's sum.
  'total_value': '2400.00',
  'has_more': false,
});

final _topStyles = [
  TopStyle.fromJson(const {
    'style_id': 'style-1',
    'name': 'Slim jeans',
    'quantity': '30',
    'revenue': '36000.00',
    'profit': '12000.00',
    'variant_count': 8,
  }),
];

final _sizeCurve = SizeCurveReport.fromJson(const {
  'style': {'id': 'style-1', 'name': 'Slim jeans', 'brand': "Levi's"},
  'sizes': [
    {
      'size': '32',
      'received': '12',
      'sold': '9',
      'on_hand': '3',
      'sell_through': '0.75',
      'revenue': '10800.00',
    },
    {
      'size': '34',
      'received': '24',
      'sold': '6',
      'on_hand': '18',
      'sell_through': '0.25',
      'revenue': '7200.00',
    },
  ],
  'colors': [
    {
      'color': 'Blue',
      'received': '36',
      'sold': '15',
      'on_hand': '21',
      'sell_through': '0.416',
      'revenue': '18000.00',
    },
  ],
  'totals': {
    'received': '36',
    'sold': '15',
    'on_hand': '21',
    'revenue': '18000.00',
  },
});

void main() {
  /// The generic report cards would otherwise hit the network; they are not
  /// what these tests are about.
  final quietDashboard = <Override>[
    // The week range is the screen's default, so the bare providers are the
    // very ones it watches.
    salesSeriesProvider().overrideWith((_) async => const <SalesSeriesPoint>[]),
    topProductsProvider().overrideWith((_) async => const <TopProduct>[]),
    paymentMixProvider().overrideWith((_) async => const <PaymentMixSlice>[]),
  ];

  Widget buildReports({
    Authenticated auth = _boutiqueOwner,
    List<Override> overrides = const [],
  }) {
    final router = GoRouter(
      initialLocation: '/reports',
      routes: [
        GoRoute(path: '/reports', builder: (_, __) => const ReportsScreen()),
        GoRoute(
          path: '/reports/size-curve',
          builder: (_, state) => SizeCurveScreen(
            styleId: state.uri.queryParameters['style'] ?? '',
          ),
        ),
      ],
    );
    return ProviderScope(
      overrides: [
        authControllerProvider.overrideWith(() => _TestAuthController(auth)),
        ...quietDashboard,
        ...overrides,
      ],
      child: MaterialApp.router(
        theme: AppTheme.light(),
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    );
  }

  List<Override> boutiqueData({
    List<BrokenRun>? runs,
    DeadStockReport? dead,
    List<TopStyle>? styles,
  }) =>
      [
        brokenRunsProvider.overrideWith((_) async => runs ?? [_brokenRun]),
        deadStockProvider(days: deadStockDefaultDays)
            .overrideWith((_) async => dead ?? _deadStock),
        topStylesProvider().overrideWith((_) async => styles ?? _topStyles),
        sizeCurveProvider('style-1').overrideWith((_) async => _sizeCurve),
      ];

  testWidgets('boutique owner sees the three cards above the other reports',
      (tester) async {
    await tester.pumpWidget(buildReports(overrides: boutiqueData()));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('REBUY LIST'), findsOneWidget);
    expect(find.text('DEAD STOCK'), findsOneWidget);
    expect(find.text('TOP STYLES'), findsOneWidget);

    // Rebuy first (the only actionable card), then dead stock, then top
    // styles; the generic reports are pushed below the fold.
    expect(
      tester.getTopLeft(find.text('REBUY LIST')).dy,
      lessThan(tester.getTopLeft(find.text('DEAD STOCK')).dy),
    );
    expect(
      tester.getTopLeft(find.text('DEAD STOCK')).dy,
      lessThan(tester.getTopLeft(find.text('TOP STYLES')).dy),
    );
    expect(find.text('SALES OVER TIME'), findsNothing);
    await tester.scrollUntilVisible(find.text('SALES OVER TIME'), 200);
    expect(find.text('SALES OVER TIME'), findsOneWidget);
  });

  testWidgets('the rebuy row shows the sizes to buy back', (tester) async {
    await tester.pumpWidget(buildReports(overrides: boutiqueData()));
    await tester.pumpAndSettle();

    expect(find.text('Slim jeans'), findsWidgets);
    expect(find.text("Levi's · 5 of 8 sizes in stock"), findsOneWidget);
    expect(find.text('32 · Blue · 9 sold'), findsOneWidget);
  });

  testWidgets('dead stock leads with the money tied up', (tester) async {
    await tester.pumpWidget(buildReports(overrides: boutiqueData()));
    await tester.pumpAndSettle();

    expect(find.text('ETB 2,400'), findsOneWidget);
    expect(
      find.text('Tied up in stock that has not sold in 60 days'),
      findsOneWidget,
    );
    expect(
      find.text('104 days on the shelf · Last sold Jun 4, 2026'),
      findsOneWidget,
    );
    expect(find.text('70 days on the shelf · Never sold'), findsOneWidget);
    expect(find.text('ETB 1,600'), findsOneWidget);
  });

  testWidgets('top styles ranks by revenue with profit and variant count',
      (tester) async {
    await tester.pumpWidget(buildReports(overrides: boutiqueData()));
    await tester.pumpAndSettle();

    expect(find.text('ETB 36,000'), findsOneWidget);
    expect(
      find.text('30 sold · profit ETB 12,000 · 8 variants'),
      findsOneWidget,
    );
  });

  testWidgets('the section is hidden for a shop without variants',
      (tester) async {
    await tester.pumpWidget(
      buildReports(auth: _regularOwner, overrides: boutiqueData()),
    );
    await tester.pumpAndSettle();

    expect(find.text('REBUY LIST'), findsNothing);
    expect(find.text('DEAD STOCK'), findsNothing);
    expect(find.text('TOP STYLES'), findsNothing);
    expect(find.text('SALES OVER TIME'), findsOneWidget);
  });

  testWidgets('the section is hidden for a cashier', (tester) async {
    await tester.pumpWidget(
      buildReports(auth: _boutiqueCashier, overrides: boutiqueData()),
    );
    await tester.pumpAndSettle();

    expect(find.text('REBUY LIST'), findsNothing);
    expect(find.text('TOP STYLES'), findsNothing);
  });

  testWidgets('empty reports show plain wording, not an error',
      (tester) async {
    await tester.pumpWidget(
      buildReports(
        overrides: boutiqueData(
          runs: const [],
          dead: DeadStockReport.fromJson(const {
            'days': 60,
            'items': <Map<String, dynamic>>[],
            'total_value': '0',
          }),
          styles: const [],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Every style still has all its sizes.'), findsOneWidget);
    expect(
      find.text('Nothing is standing still — everything has sold recently.'),
      findsOneWidget,
    );
    expect(find.text('No styles sold in this range.'), findsOneWidget);
  });

  testWidgets('a failed report offers a retry instead of a red screen',
      (tester) async {
    await tester.pumpWidget(
      buildReports(
        overrides: [
          brokenRunsProvider.overrideWith(
            (_) => Future<List<BrokenRun>>.error(Exception('offline')),
          ),
          deadStockProvider(days: deadStockDefaultDays)
              .overrideWith((_) async => _deadStock),
          topStylesProvider().overrideWith((_) async => _topStyles),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('offline'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    // The other two cards still render their numbers.
    expect(find.text('ETB 2,400'), findsOneWidget);
  });

  testWidgets('tapping a rebuy row opens the size curve for that style',
      (tester) async {
    await tester.pumpWidget(buildReports(overrides: boutiqueData()));
    await tester.pumpAndSettle();

    await tester.tap(find.text("Levi's · 5 of 8 sizes in stock"));
    await tester.pumpAndSettle();

    expect(find.text('Size curve'), findsOneWidget);
    expect(find.text('BY SIZE'), findsOneWidget);
    expect(find.text('BY COLOUR'), findsOneWidget);
  });

  testWidgets('size-curve bars are proportional to received and sold',
      (tester) async {
    await tester.pumpWidget(
      buildReports(
        overrides: [
          ...boutiqueData(),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text("Levi's · 5 of 8 sizes in stock"));
    await tester.pumpAndSettle();

    final factors = tester
        .widgetList<FractionallySizedBox>(find.byType(FractionallySizedBox))
        .map((w) => w.widthFactor)
        .toList();
    // Size 32 (12 of a 24-unit top buy, 9 sold), size 34 (24 received,
    // 6 sold), then the single colour row (full width, 15 of 36 sold).
    expect(factors, [0.5, 0.75, 1.0, 0.25, 1.0, closeTo(15 / 36, 0.001)]);

    expect(find.text('75%'), findsOneWidget);
    expect(find.text('9 of 12'), findsOneWidget);
    // Totals: received / sold / on hand and the revenue line.
    expect(find.text('36'), findsOneWidget);
    expect(find.text('ETB 18,000'), findsOneWidget);
  });

  testWidgets('a style with nothing received shows the empty curve',
      (tester) async {
    await tester.pumpWidget(
      buildReports(
        overrides: [
          ...boutiqueData(),
          sizeCurveProvider('style-1')
              .overrideWith((_) async => SizeCurveReport.fromJson(const {})),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text("Levi's · 5 of 8 sizes in stock"));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Nothing received yet'), findsOneWidget);
  });

  testWidgets('a failed size curve can be retried', (tester) async {
    await tester.pumpWidget(
      buildReports(
        overrides: [
          ...boutiqueData(),
          sizeCurveProvider('style-1').overrideWith(
            (_) => Future<SizeCurveReport>.error(Exception('offline')),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text("Levi's · 5 of 8 sizes in stock"));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Failed to load'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });
}
