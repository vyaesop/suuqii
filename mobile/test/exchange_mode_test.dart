import 'package:decimal/decimal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';
import 'package:suuqii/features/auth/presentation/controllers/auth_controller.dart';
import 'package:suuqii/features/inventory/domain/entities/product.dart';
import 'package:suuqii/features/sales/domain/entities/sale_return.dart';
import 'package:suuqii/features/sales/presentation/cart_controller.dart';
import 'package:suuqii/features/sales/presentation/exchange_controller.dart';

/// Auth controller whose session can be changed mid-test, the way logout and
/// switchShop change it in the app.
class _MutableAuthController extends AuthController {
  _MutableAuthController(this.initial);

  final AuthState initial;

  @override
  Future<AuthState> build() async => initial;

  void set(AuthState next) => state = AsyncData(next);
}

const _shopA = Authenticated(
  userId: 'user-1',
  shopId: 'shop-a',
  role: 'owner',
  userName: 'Owner',
  shopName: 'Bole Boutique',
  accessToken: 'token',
  shopType: 'boutique',
);

const _shopB = Authenticated(
  userId: 'user-1',
  shopId: 'shop-b',
  role: 'owner',
  userName: 'Owner',
  shopName: 'Piassa Boutique',
  accessToken: 'token',
  shopType: 'boutique',
);

final _exchange = ExchangeContext(
  originalSaleId: 'sale-in-shop-a',
  items: [
    ReturnLine(
      saleItemId: 'si-1',
      quantity: Decimal.one,
      condition: ReturnCondition.resellable,
    ),
  ],
  reason: ReturnReason.wrongSize,
  credit: Decimal.parse('1200'),
);

final _product = Product(
  id: 'p-1',
  shopId: 'shop-a',
  name: 'Slim jeans · 32 · Blue',
  purchasePrice: Decimal.parse('800'),
  sellingPrice: Decimal.parse('1200'),
  stock: Decimal.fromInt(5),
  lowStockThreshold: Decimal.one,
  unit: 'piece',
);

void main() {
  late _MutableAuthController auth;
  late ProviderContainer container;

  setUp(() async {
    auth = _MutableAuthController(_shopA);
    container = ProviderContainer(
      overrides: [authControllerProvider.overrideWith(() => auth)],
    );
    addTearDown(container.dispose);
    await container.read(authControllerProvider.future);
  });

  test('an exchange does not survive a shop switch', () async {
    container.read(exchangeModeProvider.notifier).current = _exchange;
    expect(container.read(exchangeModeProvider), isNotNull);

    // switchShop wipes the local database, so the sale this exchange settles
    // against no longer exists — checkout would fail with `not_found`.
    auth.set(_shopB);
    expect(container.read(exchangeModeProvider), isNull);
  });

  test('an exchange does not survive a logout', () async {
    container.read(exchangeModeProvider.notifier).current = _exchange;
    auth.set(const Unauthenticated());
    expect(container.read(exchangeModeProvider), isNull);
  });

  test('an unrelated auth change keeps the exchange', () async {
    container.read(exchangeModeProvider.notifier).current = _exchange;
    // Renaming the shop is not a session change.
    auth.set(_shopA.copyWith(shopName: 'Bole Boutique & Co'));
    expect(
      container.read(exchangeModeProvider)?.originalSaleId,
      'sale-in-shop-a',
    );
  });

  test('the cart is emptied by a shop switch', () async {
    container.read(cartControllerProvider.notifier).addProduct(_product);
    expect(container.read(cartControllerProvider).isEmpty, isFalse);

    auth.set(_shopB);
    expect(container.read(cartControllerProvider).isEmpty, isTrue);
  });
}
