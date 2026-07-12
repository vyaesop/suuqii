import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';

import 'package:suuqii/l10n/app_localizations.dart';

/// Maps server / transport errors to localized, user-readable messages.
///
/// The API uses problem+json: a machine `code` plus a human (English)
/// `detail`. We translate the codes we know; for unknown codes we fall back
/// to the server's `detail` text, and finally to a generic message. Use this
/// in every snackbar/dialog that surfaces a caught exception — never
/// `Text('$e')`.
String localizedErrorMessage(AppLocalizations l, Object error) {
  if (error is DioException) {
    switch (error.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return l.errNetwork;
      case DioExceptionType.badResponse:
      case DioExceptionType.badCertificate:
      case DioExceptionType.cancel:
      case DioExceptionType.unknown:
        break;
    }
    final data = error.response?.data;
    if (data is Map) {
      final code = data['code'];
      final detail = data['detail'];
      final mapped = _messageForCode(l, code is String ? code : null);
      if (mapped != null) return mapped;
      if (detail is String && detail.isNotEmpty) return detail;
    }
    final status = error.response?.statusCode;
    if (status != null) return l.errHttp(status);
    return l.errNetwork;
  }

  // AuthException and friends already carry a human-readable server message
  // (e.g. remaining PIN attempts); Exception.toString() prefixes noise.
  final text = error.toString().replaceFirst(RegExp('^Exception: '), '');
  return text.isEmpty ? l.errUnknown : text;
}

String? _messageForCode(AppLocalizations l, String? code) {
  switch (code) {
    case 'owner_pin_required':
      return l.ownerPinRequired;
    case 'wrong_pin':
      return l.wrongPin;
    case 'phone_taken':
      return l.errPhoneTaken;
    case 'customer_credit_limit_exceeded':
      return l.errCreditLimitExceeded;
    case 'expense_approval_required':
      return l.errExpenseApprovalRequired;
    case 'invalid_payload':
      return l.errInvalidPayload;
    case 'conflict':
      return l.errConflict;
    case 'expired':
      return l.errExpired;
    case 'bad_role':
      return l.errBadRole;
    case 'database_schema_outdated':
      return l.errServerUpgrading;
    case null:
      return null;
    default:
      return null;
  }
}

extension ErrorL10nX on BuildContext {
  /// Localized message for a caught [error], for snackbars/dialogs.
  String errorMessage(Object error) =>
      localizedErrorMessage(AppLocalizations.of(this), error);
}
