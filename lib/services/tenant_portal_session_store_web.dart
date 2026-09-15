// Web implementation: sessionStorage is per-tab and cleared when the tab
// closes, which is the right lifetime for an access code that only needs to
// survive one Stripe redirect.
import 'dart:convert';
import 'dart:html' as html;

const _key = 'sfc.tenantPortal.parkedSession';

void parkSession({
  required String email,
  required String accessCode,
  String? tenantId,
  String? setupIntentId,
  required int expiresAtMs,
}) {
  try {
    html.window.sessionStorage[_key] = jsonEncode({
      'email': email,
      'accessCode': accessCode,
      'tenantId': tenantId,
      'setupIntentId': setupIntentId,
      'expiresAtMs': expiresAtMs,
    });
  } catch (_) {
    // Storage blocked (private mode, policy). The inline path still works;
    // only the rare 3DS redirect loses its resume.
  }
}

Map<String, Object?>? takeParkedSession() {
  try {
    final raw = html.window.sessionStorage[_key];
    html.window.sessionStorage.remove(_key);
    if (raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    return decoded is Map ? decoded.cast<String, Object?>() : null;
  } catch (_) {
    return null;
  }
}

void clearParkedSession() {
  try {
    html.window.sessionStorage.remove(_key);
  } catch (_) {}
}

void clearStripeRedirectParams() {
  try {
    final uri = Uri.base;
    final q = uri.queryParameters;
    if (!q.containsKey('redirect_status') && !q.containsKey('portal_payment')) return;
    final cleaned = uri.replace(queryParameters: const {}).toString().replaceFirst('?', '');
    html.window.history.replaceState(null, html.document.title, cleaned);
  } catch (_) {}
}
