import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/core/utils/money.dart';

void main() {
  test('formats money with the default currency symbol', () {
    expect(formatMoney(d(1234)), 'ETB 1,234');
  });
}
