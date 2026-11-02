import 'dart:convert';

/// Helpers for turning server/WebView cookie output into a valid `Cookie`
/// request header ("name1=value1; name2=value2").

/// Parses a `Set-Cookie` response header as returned by package:http.
///
/// package:http joins multiple `Set-Cookie` headers with ", ", and each one
/// carries attributes (Path, Expires, HttpOnly, ...). Only the leading
/// `name=value` pair of each cookie belongs in a `Cookie` request header.
Map<String, String> parseSetCookieHeader(String? header) {
  final result = <String, String>{};
  if (header == null || header.trim().isEmpty) return result;

  // Split on commas that start a new cookie ("..., name=value"), but not on
  // the comma inside an Expires date ("Expires=Wed, 21 Oct 2026 ...").
  final parts = header.split(RegExp(r',(?=\s*[^;,=\s]+=)'));
  for (final part in parts) {
    final pair = part.split(';').first.trim();
    final eq = pair.indexOf('=');
    if (eq <= 0) continue;
    final name = pair.substring(0, eq).trim();
    final value = pair.substring(eq + 1).trim();
    if (name.isEmpty) continue;
    result[name] = value;
  }
  return result;
}

/// Parses a `Cookie` request header / `document.cookie` string.
Map<String, String> parseCookieHeader(String? header) {
  final result = <String, String>{};
  if (header == null || header.trim().isEmpty) return result;
  for (final part in header.split(';')) {
    final pair = part.trim();
    final eq = pair.indexOf('=');
    if (eq <= 0) continue;
    result[pair.substring(0, eq).trim()] = pair.substring(eq + 1).trim();
  }
  return result;
}

/// Serializes cookies into a `Cookie` request header value.
String serializeCookies(Map<String, String> cookies) =>
    cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');

/// Merges [update] into [existing] (newer values win) and returns the header.
String mergeCookieHeaders(String? existing, Map<String, String> update) {
  final merged = parseCookieHeader(existing)..addAll(update);
  return serializeCookies(merged);
}

/// `runJavaScriptReturningResult` returns a JSON-encoded string on Android
/// (e.g. `"a=b; c=d"` including the quotes) but a plain string on iOS/macOS.
/// This returns the plain string in both cases.
String normalizeJsStringResult(Object? result) {
  if (result == null) return '';
  var s = result.toString().trim();
  if (s == 'null') return '';
  if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
    try {
      final decoded = jsonDecode(s);
      if (decoded is String) s = decoded;
    } catch (_) {
      s = s.substring(1, s.length - 1);
    }
  }
  return s.trim();
}
