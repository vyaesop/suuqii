import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/core/utils/phone.dart';

void main() {
  group('normalizeEthiopianPhone', () {
    test('accepts canonical local numbers unchanged', () {
      expect(normalizeEthiopianPhone('0912345678'), '0912345678');
      expect(normalizeEthiopianPhone('0712345678'), '0712345678');
    });

    test('converts international format to local', () {
      expect(normalizeEthiopianPhone('+251912345678'), '0912345678');
      expect(normalizeEthiopianPhone('251912345678'), '0912345678');
      expect(normalizeEthiopianPhone('+251712345678'), '0712345678');
      expect(normalizeEthiopianPhone('251712345678'), '0712345678');
    });

    test('prepends 0 to bare 9-digit numbers', () {
      expect(normalizeEthiopianPhone('912345678'), '0912345678');
      expect(normalizeEthiopianPhone('712345678'), '0712345678');
    });

    test('strips spaces, dashes, and parentheses', () {
      expect(normalizeEthiopianPhone('+251 91 234 5678'), '0912345678');
      expect(normalizeEthiopianPhone('0912-345-678'), '0912345678');
      expect(normalizeEthiopianPhone('(091) 234 5678'), '0912345678');
      expect(normalizeEthiopianPhone(' 0912345678 '), '0912345678');
    });

    test('rejects invalid numbers', () {
      expect(normalizeEthiopianPhone(''), isNull);
      expect(normalizeEthiopianPhone('12345'), isNull);
      // Wrong operator prefix (Ethiopian mobiles start 09/07).
      expect(normalizeEthiopianPhone('0812345678'), isNull);
      expect(normalizeEthiopianPhone('812345678'), isNull);
      // Too short / too long.
      expect(normalizeEthiopianPhone('091234567'), isNull);
      expect(normalizeEthiopianPhone('09123456789'), isNull);
      expect(normalizeEthiopianPhone('+25191234567'), isNull);
      expect(normalizeEthiopianPhone('+2519123456789'), isNull);
      // Not a phone at all.
      expect(normalizeEthiopianPhone('abc'), isNull);
      expect(normalizeEthiopianPhone('091234567a'), isNull);
      // Wrong country code.
      expect(normalizeEthiopianPhone('+254912345678'), isNull);
      // A stray plus in the middle is invalid.
      expect(normalizeEthiopianPhone('09123+45678'), isNull);
    });
  });
}
