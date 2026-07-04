import 'package:dio/dio.dart';

import 'package:suuqii/l10n/app_localizations.dart';

/// Maps a thrown error to a short, human-readable message a shopkeeper can act
/// on — never a raw exception or stack trace.
///
/// Transport failures (timeouts, no network) and server faults (5xx) are
/// collapsed into friendly copy; anything else falls back to a generic message.
String messageForError(Object error, AppLocalizations l) {
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return l.errorNoConnection;
      case DioExceptionType.badResponse:
        final code = error.response?.statusCode ?? 0;
        return code >= 500 ? l.errorServer : l.errorGeneric;
      case DioExceptionType.cancel:
      case DioExceptionType.badCertificate:
      case DioExceptionType.unknown:
        return l.errorGeneric;
    }
  }
  return l.errorGeneric;
}
