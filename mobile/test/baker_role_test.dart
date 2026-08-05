import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/app/router.dart';
import 'package:suuqii/features/auth/domain/entities/auth_state.dart';

Authenticated _auth(String role, {String shopType = 'bakery'}) => Authenticated(
      userId: 'u1',
      shopId: 's1',
      role: role,
      userName: 'Test',
      shopName: 'Keol Bakery',
      accessToken: 'token',
      shopType: shopType,
    );

void main() {
  group('baker capabilities', () {
    test('a baker never touches money', () {
      final baker = _auth('baker');
      expect(baker.isBaker, isTrue);
      expect(baker.canSell, isFalse);
      expect(baker.canSeeMoney, isFalse);
      expect(baker.isOwner, isFalse);
    });

    test('a baker declares handovers but cannot count them in', () {
      // Two independent counts is the whole control; one person doing both
      // collapses it. Mirrors ROLE_CAPS[BAKER] on the server.
      final baker = _auth('baker');
      expect(baker.canCreateHandover, isTrue);
      expect(baker.canAcceptHandover, isFalse);
    });

    test('a cashier counts handovers in but does not declare them', () {
      final cashier = _auth('cashier');
      expect(cashier.canAcceptHandover, isTrue);
      expect(cashier.canCreateHandover, isFalse);
      expect(cashier.canSell, isTrue);
    });

    test('an owner can do both sides', () {
      final owner = _auth('owner');
      expect(owner.canCreateHandover, isTrue);
      expect(owner.canAcceptHandover, isTrue);
      expect(owner.canSeeMoney, isTrue);
    });

    test('an unrecognised role gets no money capability', () {
      final stranger = _auth('chef');
      expect(stranger.canSell, isFalse);
      expect(stranger.canSeeMoney, isFalse);
      expect(stranger.canCreateHandover, isFalse);
      expect(stranger.canAcceptHandover, isFalse);
    });

    test('bakers land on the handover screen, everyone else on the POS', () {
      expect(_auth('baker').homeRoute, '/handover');
      expect(_auth('cashier').homeRoute, '/pos');
      expect(_auth('owner').homeRoute, '/pos');
    });
  });

  group('roleRedirect', () {
    const moneyLocations = ['/pos', '/recent-sales', '/debts', '/expenses'];
    const ownerOnlyLocations = [
      '/owner',
      '/reports',
      '/reports/batches',
      '/audit',
      '/employees',
      '/open-shifts',
      '/shop-settings',
    ];
    const bakerAllowed = [
      '/handover',
      '/inventory',
      '/inventory/new',
      '/supplies',
      '/shift',
      '/me',
    ];

    test('a deep link to any money route sends a baker back to /handover', () {
      for (final loc in moneyLocations) {
        expect(
          roleRedirect(loc, isOwner: false, isBaker: true),
          '/handover',
          reason: 'baker deep-linked to $loc must not reach it',
        );
      }
    });

    test('owner-only routes are closed to bakers too', () {
      for (final loc in ownerOnlyLocations) {
        expect(
          roleRedirect(loc, isOwner: false, isBaker: true),
          '/handover',
          reason: '$loc must be closed to bakers',
        );
      }
    });

    test('a baker may reach production, inventory, supplies and their shift',
        () {
      for (final loc in bakerAllowed) {
        expect(
          roleRedirect(loc, isOwner: false, isBaker: true),
          isNull,
          reason: '$loc should be reachable by a baker',
        );
      }
    });

    test('cashiers keep their existing access', () {
      for (final loc in moneyLocations) {
        expect(roleRedirect(loc, isOwner: false, isBaker: false), isNull);
      }
      for (final loc in ownerOnlyLocations) {
        expect(roleRedirect(loc, isOwner: false, isBaker: false), '/pos');
      }
    });

    test('the handover routes are reachable by cashiers and owners', () {
      for (final loc in ['/handover', '/handovers-received']) {
        expect(roleRedirect(loc, isOwner: false, isBaker: false), isNull);
        expect(roleRedirect(loc, isOwner: true, isBaker: false), isNull);
      }
    });
  });
}
