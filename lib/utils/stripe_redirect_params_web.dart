import 'dart:html' as html;

/// Reads Stripe redirect params from the current URL (after Link/3DS redirect).
/// Returns empty map if not a redirect return.
Map<String, String> getStripeRedirectParams() {
  final uri = Uri.parse(html.window.location.href);
  final params = uri.queryParameters;
  final redirectStatus = params['redirect_status'];
  final setupIntent = params['setup_intent'] ??
      (params['setup_intent_client_secret']?.contains('_secret_') == true
          ? params['setup_intent_client_secret']!.split('_secret_').first
          : null);
  if (redirectStatus != 'succeeded' || setupIntent == null || !setupIntent.startsWith('seti_')) {
    return const {};
  }
  return {
    'redirect_status': redirectStatus!,
    'setup_intent': setupIntent,
  };
}

/// Removes Stripe redirect params from the main URL query to avoid replay.
void clearStripeRedirectParamsFromUrl() {
  final loc = html.window.location;
  final uri = Uri.parse(loc.href);
  final query = Map<String, String>.from(uri.queryParameters);
  query.remove('redirect_status');
  query.remove('setup_intent');
  query.remove('setup_intent_client_secret');
  final newPath = uri.path +
      (query.isEmpty ? '' : '?${query.entries.map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}').join('&')}') +
      (uri.fragment.isNotEmpty ? '#${uri.fragment}' : '');
  html.window.history.replaceState(null, '', newPath);
}
