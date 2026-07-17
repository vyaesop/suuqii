/// Ethiopian phone number normalization.
///
/// Users type numbers in many shapes — `+251 91 234 5678`, `2519…`,
/// `0912-345-678`, or a bare `912345678`. The backend and the local DB key
/// accounts by phone, so every form must submit the same canonical local
/// format: `09XXXXXXXX` / `07XXXXXXXX`.
library;

final _junk = RegExp(r'[\s\-()]');
final _international = RegExp(r'^251([79]\d{8})$');
final _bareLocal = RegExp(r'^[79]\d{8}$');
final _canonical = RegExp(r'^0[79]\d{8}$');

/// Normalizes [raw] to the canonical Ethiopian local mobile format
/// (`09XXXXXXXX` or `07XXXXXXXX`).
///
/// Accepts international (`+2519…`, `2519…`, same for 7), canonical local
/// (`09…`/`07…`), and bare 9-digit (`9…`/`7…`) forms, ignoring spaces,
/// dashes, and parentheses. Returns `null` when the input cannot be a valid
/// Ethiopian mobile number.
String? normalizeEthiopianPhone(String raw) {
  var s = raw.replaceAll(_junk, '');
  if (s.startsWith('+')) s = s.substring(1);

  final intl = _international.firstMatch(s);
  if (intl != null) s = '0${intl.group(1)}';

  if (_bareLocal.hasMatch(s)) s = '0$s';

  return _canonical.hasMatch(s) ? s : null;
}
