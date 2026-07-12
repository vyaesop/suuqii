import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/app/router.dart';

void main() {
  group('ownerOnlyRedirect', () {
    const ownerOnlyLocations = [
      '/owner',
      '/reports',
      '/reports/batches',
      '/audit',
      '/employees',
      '/open-shifts',
    ];

    const sharedLocations = [
      '/pos',
      '/inventory',
      '/inventory/new',
      '/inventory/bulk-restock',
      '/debts',
      '/supplies',
      '/shift',
      '/expenses',
      '/recent-sales',
      '/me',
    ];

    test('redirects cashiers away from every owner-only route', () {
      for (final loc in ownerOnlyLocations) {
        expect(
          ownerOnlyRedirect(loc, isOwner: false),
          '/pos',
          reason: 'cashier deep-linked to $loc must be sent to /pos',
        );
      }
    });

    test('allows cashiers on shared routes', () {
      for (final loc in sharedLocations) {
        expect(
          ownerOnlyRedirect(loc, isOwner: false),
          isNull,
          reason: '$loc should be reachable by cashiers',
        );
      }
    });

    test('never redirects owners', () {
      for (final loc in [...ownerOnlyLocations, ...sharedLocations]) {
        expect(
          ownerOnlyRedirect(loc, isOwner: true),
          isNull,
          reason: 'owners may visit $loc',
        );
      }
    });
  });
}
