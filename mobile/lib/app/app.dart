import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suuqii/app/router.dart';
import 'package:suuqii/app/theme/app_theme.dart';
import 'package:suuqii/core/l10n/fallback_localizations.dart';
import 'package:suuqii/core/l10n/locale_controller.dart';
import 'package:suuqii/l10n/app_localizations.dart';

class SuuqiiApp extends ConsumerWidget {
  const SuuqiiApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    // null → follow the device locale; MaterialApp resolves unsupported
    // device locales to English (first entry in supportedLocales).
    final locale = ref.watch(localeControllerProvider);
    return MaterialApp.router(
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      routerConfig: router,
      locale: locale,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        // `om` isn't in flutter_localizations; these serve English framework
        // strings for it. Must come before the Global* delegates.
        ...omFallbackDelegates,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en'), Locale('om')],
    );
  }
}
