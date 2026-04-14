import 'dart:convert';
import 'dart:html' as html;

const String _kQuickBooksOAuthHandoffKey = 'sfc.quickbooks.oauth.pending';

Map<String, String>? captureQuickBooksOAuthFromCurrentUrl() {
  final params = Uri.base.queryParameters;
  final code = params['code']?.trim() ?? '';
  final realmId = params['realmId']?.trim() ?? '';
  final state = params['state']?.trim() ?? '';
  if (code.isEmpty || realmId.isEmpty || state.isEmpty) return null;

  final payload = <String, String>{
    'code': code,
    'realmId': realmId,
    'state': state,
    'capturedAt': DateTime.now().toUtc().toIso8601String(),
  };

  html.window.localStorage[_kQuickBooksOAuthHandoffKey] = jsonEncode(payload);
  return payload;
}

Map<String, String>? takePendingQuickBooksOAuthPayload() {
  final raw = html.window.localStorage[_kQuickBooksOAuthHandoffKey];
  if (raw == null || raw.trim().isEmpty) return null;

  try {
    final decoded = jsonDecode(raw) as Map<String, dynamic>;
    final payload = <String, String>{
      'code': (decoded['code'] ?? '').toString(),
      'realmId': (decoded['realmId'] ?? '').toString(),
      'state': (decoded['state'] ?? '').toString(),
    };
    if (payload.values.any((v) => v.trim().isEmpty)) {
      html.window.localStorage.remove(_kQuickBooksOAuthHandoffKey);
      return null;
    }
    html.window.localStorage.remove(_kQuickBooksOAuthHandoffKey);
    return payload;
  } catch (_) {
    html.window.localStorage.remove(_kQuickBooksOAuthHandoffKey);
    return null;
  }
}
