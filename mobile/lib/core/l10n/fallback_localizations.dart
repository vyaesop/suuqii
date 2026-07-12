import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

/// flutter_localizations ships no Afaan Oromo (`om`) data, so the global
/// delegates reject the locale and MaterialApp would warn / fall back badly.
/// These delegates claim `om` and serve the English framework strings
/// (date-picker labels, tooltips, semantics) instead. All user-facing app
/// strings come from AppLocalizations, which fully supports `om`.
const List<LocalizationsDelegate<dynamic>> omFallbackDelegates = [
  _OmMaterialLocalizationsDelegate(),
  _OmCupertinoLocalizationsDelegate(),
  _OmWidgetsLocalizationsDelegate(),
];

class _OmMaterialLocalizationsDelegate
    extends LocalizationsDelegate<MaterialLocalizations> {
  const _OmMaterialLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => locale.languageCode == 'om';

  @override
  Future<MaterialLocalizations> load(Locale locale) =>
      GlobalMaterialLocalizations.delegate.load(const Locale('en'));

  @override
  bool shouldReload(_OmMaterialLocalizationsDelegate old) => false;
}

class _OmCupertinoLocalizationsDelegate
    extends LocalizationsDelegate<CupertinoLocalizations> {
  const _OmCupertinoLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => locale.languageCode == 'om';

  @override
  Future<CupertinoLocalizations> load(Locale locale) =>
      GlobalCupertinoLocalizations.delegate.load(const Locale('en'));

  @override
  bool shouldReload(_OmCupertinoLocalizationsDelegate old) => false;
}

class _OmWidgetsLocalizationsDelegate
    extends LocalizationsDelegate<WidgetsLocalizations> {
  const _OmWidgetsLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) => locale.languageCode == 'om';

  @override
  Future<WidgetsLocalizations> load(Locale locale) =>
      // Afaan Oromo is written left-to-right, same as English.
      GlobalWidgetsLocalizations.delegate.load(const Locale('en'));

  @override
  bool shouldReload(_OmWidgetsLocalizationsDelegate old) => false;
}
