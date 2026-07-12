import 'package:decimal/decimal.dart';
import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/core/storage/app_database.dart';
import 'package:suuqii/core/utils/money.dart';

void main() {
  group('santimFromDecimal / decimalFromSantim', () {
    test('converts whole birr exactly', () {
      expect(santimFromDecimal(Decimal.parse('25')), 2500);
      expect(santimFromDecimal(Decimal.zero), 0);
      expect(decimalFromSantim(2500), Decimal.parse('25'));
    });

    test('0.1 + 0.2 style values stay exact through the round-trip', () {
      // The classic IEEE-754 trap: 0.1 + 0.2 != 0.3 as doubles.
      final sum = Decimal.parse('0.1') + Decimal.parse('0.2');
      expect(sum, Decimal.parse('0.3'));
      expect(santimFromDecimal(sum), 30);
      expect(decimalFromSantim(30), Decimal.parse('0.3'));

      expect(santimFromDecimal(Decimal.parse('10.10')), 1010);
      expect(decimalFromSantim(1010), Decimal.parse('10.10'));
      expect(santimFromDecimal(Decimal.parse('19.99')), 1999);
      expect(decimalFromSantim(1999), Decimal.parse('19.99'));
    });

    test('rounds half up (away from zero) to the nearest santim', () {
      expect(santimFromDecimal(Decimal.parse('12.345')), 1235);
      expect(santimFromDecimal(Decimal.parse('12.344')), 1234);
      expect(santimFromDecimal(Decimal.parse('12.005')), 1201);
      expect(santimFromDecimal(Decimal.parse('-12.345')), -1235);
    });

    test('round-trip is identity for any 2-decimal amount', () {
      for (final s in ['0.01', '0.29', '1.10', '999999.99', '0.30']) {
        final d = Decimal.parse(s);
        expect(decimalFromSantim(santimFromDecimal(d)), d, reason: s);
      }
    });

    test('negative santim converts back exactly', () {
      expect(decimalFromSantim(-1010), Decimal.parse('-10.10'));
    });
  });

  group('DB-level money exactness (int64 santim storage)', () {
    late AppDatabase db;

    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> insertSale(String id, String total) async {
      await db.into(db.salesTable).insert(
            SalesTableCompanion.insert(
              id: id,
              shopId: 'shop-1',
              userId: 'u1',
              subtotal: santimFromDecimal(Decimal.parse(total)),
              total: santimFromDecimal(Decimal.parse(total)),
              costTotal: santimFromDecimal(Decimal.parse('5.05')),
              paymentMethod: 'cash',
              occurredAt: DateTime.utc(2026, 1, 15),
            ),
          );
      await db.into(db.saleItemsTable).insert(
            SaleItemsTableCompanion.insert(
              id: 'item-$id',
              saleId: id,
              productId: 'p1',
              productNameSnapshot: 'Bread',
              quantity: 1,
              unitPrice: santimFromDecimal(Decimal.parse(total)),
              unitCost: santimFromDecimal(Decimal.parse('5.05')),
            ),
          );
    }

    test('SUM over sales with unit_price 10.10 is exact', () async {
      // As doubles, 10.10 * 3 = 30.299999999999997. As santim it is 3030.
      await insertSale('s1', '10.10');
      await insertSale('s2', '10.10');
      await insertSale('s3', '10.10');

      final row = await db.customSelect(
        'SELECT COALESCE(SUM(total), 0) AS t FROM sales',
      ).getSingle();
      final sum = decimalFromSantim(row.read<int>('t'));
      expect(sum, Decimal.parse('30.30'));

      final itemRow = await db.customSelect(
        'SELECT COALESCE(SUM(unit_price), 0) AS t FROM sale_items',
      ).getSingle();
      expect(decimalFromSantim(itemRow.read<int>('t')), Decimal.parse('30.30'));
    });

    test('outstanding debt math (amount_owed - amount_paid) is exact',
        () async {
      // Debt of 10.10 with three 0.10 payments applied -> 9.80 outstanding.
      await db.into(db.debtsTable).insert(
            DebtsTableCompanion.insert(
              id: 'd1',
              shopId: 'shop-1',
              customerName: 'Abebe',
              customerPhone: const Value('0911000000'),
              amountOwed: santimFromDecimal(Decimal.parse('10.10')),
              amountPaid: Value(
                santimFromDecimal(
                  Decimal.parse('0.10') +
                      Decimal.parse('0.10') +
                      Decimal.parse('0.10'),
                ),
              ),
            ),
          );
      // Second open debt of 0.20 -> total outstanding 10.00 exactly.
      await db.into(db.debtsTable).insert(
            DebtsTableCompanion.insert(
              id: 'd2',
              shopId: 'shop-1',
              customerName: 'Abebe',
              customerPhone: const Value('0911000000'),
              amountOwed: santimFromDecimal(Decimal.parse('0.20')),
            ),
          );

      // Same query shape as the credit-limit gate in SalesRepository and
      // DebtsRepository.outstandingByPhone.
      final rows = await db.customSelect(
        'SELECT COALESCE(SUM(amount_owed - amount_paid), 0) AS outstanding '
        'FROM debts '
        'WHERE shop_id = ? AND customer_phone = ? '
        "AND status IN ('open', 'partial') AND deleted_at IS NULL",
        variables: [
          Variable.withString('shop-1'),
          Variable.withString('0911000000'),
        ],
      ).get();
      final outstanding = decimalFromSantim(rows.first.read<int>('outstanding'));
      expect(outstanding, Decimal.parse('10.00'));
    });

    test('migration expression CAST(ROUND(x * 100) AS INTEGER) rewrites '
        'legacy REAL money values to exact santim', () async {
      // Simulate the v5 state: money stored as REAL doubles in a scratch
      // table, then apply the exact statement used by the 5 -> 6 migration.
      await db.customStatement(
        'CREATE TABLE legacy_money (id TEXT PRIMARY KEY, amount REAL)',
      );
      await db.customStatement(
        'INSERT INTO legacy_money VALUES '
        "('a', 10.1), ('b', 19.99), ('c', 0.29), ('d', 0), ('e', NULL)",
      );
      await db.customStatement(
        'UPDATE legacy_money '
        'SET amount = CAST(ROUND(amount * 100) AS INTEGER) '
        'WHERE amount IS NOT NULL',
      );
      final rows = await db
          .customSelect('SELECT id, amount FROM legacy_money ORDER BY id')
          .get();
      expect(rows[0].read<int>('amount'), 1010);
      expect(rows[1].read<int>('amount'), 1999);
      expect(rows[2].read<int>('amount'), 29);
      expect(rows[3].read<int>('amount'), 0);
      expect(rows[4].readNullable<int>('amount'), isNull);
    });
  });
}
