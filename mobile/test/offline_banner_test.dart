import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:suuqii/app/theme/app_theme.dart';
import 'package:suuqii/core/connectivity/connectivity_provider.dart';
import 'package:suuqii/core/connectivity/offline_banner.dart';
import 'package:suuqii/features/sync/presentation/sync_status_badge.dart';
import 'package:suuqii/l10n/app_localizations.dart';

Widget _wrap(Widget child, {required bool online}) {
  return ProviderScope(
    overrides: [
      onlineStatusProvider.overrideWith((ref) => Stream.value(online)),
      pendingSyncCountProvider.overrideWith((ref) => Stream.value(0)),
      deadLetterSyncCountProvider.overrideWith((ref) => Stream.value(0)),
    ],
    child: MaterialApp(
      theme: AppTheme.light(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Column(children: [child])),
    ),
  );
}

void main() {
  group('OfflineBanner', () {
    testWidgets('is hidden while online', (tester) async {
      await tester.pumpWidget(_wrap(const OfflineBanner(), online: true));
      await tester.pumpAndSettle();

      expect(
        find.text("You're offline — sales are saved and will sync."),
        findsNothing,
      );
      expect(find.byIcon(Icons.cloud_off_rounded), findsNothing);
    });

    testWidgets('shows the localized message with a cloud-off icon offline',
        (tester) async {
      await tester.pumpWidget(_wrap(const OfflineBanner(), online: false));
      await tester.pumpAndSettle();

      expect(
        find.text("You're offline — sales are saved and will sync."),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);
    });
  });

  group('SyncStatusBadge offline state', () {
    testWidgets('shows a neutral cloud-off "Offline" chip when offline',
        (tester) async {
      await tester.pumpWidget(_wrap(const SyncStatusBadge(), online: false));
      await tester.pumpAndSettle();

      expect(find.text('Offline'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);
      expect(find.byIcon(Icons.sync_problem_rounded), findsNothing);
    });

    testWidgets('shows "Synced" when online with nothing pending',
        (tester) async {
      await tester.pumpWidget(_wrap(const SyncStatusBadge(), online: true));
      await tester.pumpAndSettle();

      expect(find.text('Synced'), findsOneWidget);
      expect(find.byIcon(Icons.cloud_done_rounded), findsOneWidget);
    });
  });
}
