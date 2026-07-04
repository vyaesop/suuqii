import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:suuqii/app/router.dart';
import 'package:suuqii/app/theme/app_theme.dart';
import 'package:suuqii/core/locale/locale_controller.dart';
import 'package:suuqii/l10n/app_localizations.dart';

class SuuqiiApp extends ConsumerWidget {
  const SuuqiiApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    final locale = ref.watch(localeControllerProvider);
    return MaterialApp.router(
      title: 'Suuqii',
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      locale: locale,
      routerConfig: router,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [Locale('en'), Locale('om')],
    );
  }
}
