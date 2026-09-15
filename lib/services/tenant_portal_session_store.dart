import 'package:flutter/foundation.dart' show kIsWeb;

import 'package:sfcapp/providers/tenant_portal_provider.dart';
import 'package:sfcapp/services/tenant_portal_session_store_stub.dart'
    if (dart.library.html) 'package:sfcapp/services/tenant_portal_session_store_web.dart' as platform;

/// A portal session that was parked in the browser right before Stripe could
/// navigate away from the app.
///
/// Stripe's Payment Element confirms most cards and Link inline, but a bank
/// that demands 3DS still performs a full-page redirect to `return_url`. That
/// reloads the Flutter app and the tenant's email + access code, which only
/// ever lived in memory, are gone; the tenant then lands on the login screen
/// seconds after typing their card, which reads as "it failed". Parking the
/// lookup in sessionStorage for a few minutes lets the access screen resume
/// the session and finish recording the card.
class ParkedPortalSession {
  final TenantPortalLookup lookup;
  final String? tenantId;
  final String? setupIntentId;

  const ParkedPortalSession({required this.lookup, this.tenantId, this.setupIntentId});
}

class TenantPortalSessionStore {
  /// Long enough to get through a 3DS challenge, short enough that a shared
  /// computer does not keep an access code around.
  static const Duration ttl = Duration(minutes: 15);

  static void park({
    required TenantPortalLookup lookup,
    String? tenantId,
    String? setupIntentId,
  }) {
    if (!kIsWeb) return;
    platform.parkSession(
      email: lookup.email,
      accessCode: lookup.accessCode,
      tenantId: tenantId,
      setupIntentId: setupIntentId,
      expiresAtMs: DateTime.now().add(ttl).millisecondsSinceEpoch,
    );
  }

  /// Returns the parked session if one exists and has not expired, and clears
  /// it either way so it is used at most once.
  static ParkedPortalSession? takeParked() {
    if (!kIsWeb) return null;
    final raw = platform.takeParkedSession();
    if (raw == null) return null;
    final expiresAt = raw['expiresAtMs'];
    if (expiresAt is! int || DateTime.now().millisecondsSinceEpoch > expiresAt) return null;
    final email = raw['email'];
    final accessCode = raw['accessCode'];
    if (email is! String || accessCode is! String || email.isEmpty || accessCode.isEmpty) return null;
    return ParkedPortalSession(
      lookup: TenantPortalLookup(email: email, accessCode: accessCode),
      tenantId: raw['tenantId'] as String?,
      setupIntentId: raw['setupIntentId'] as String?,
    );
  }

  static void clear() {
    if (!kIsWeb) return;
    platform.clearParkedSession();
  }

  /// Query parameters Stripe appends when it sends the tenant back: after a
  /// Payment Element redirect (`redirect_status`), or after Checkout
  /// (`portal_payment`, which our own success/cancel URLs carry). Empty when
  /// the app was not reached that way.
  static Map<String, String> stripeRedirectParams() {
    if (!kIsWeb) return const {};
    final params = Uri.base.queryParameters;
    final hasElementReturn = params.containsKey('redirect_status');
    final hasCheckoutReturn = params.containsKey('portal_payment');
    if (!hasElementReturn && !hasCheckoutReturn) return const {};
    return {
      if (hasElementReturn) 'redirect_status': params['redirect_status'] ?? '',
      if (hasCheckoutReturn) 'portal_payment': params['portal_payment'] ?? '',
      if (params['setup_intent'] != null) 'setup_intent': params['setup_intent']!,
      if (params['payment_intent'] != null) 'payment_intent': params['payment_intent']!,
      if (params['session_id'] != null) 'session_id': params['session_id']!,
    };
  }

  /// Drop Stripe's redirect parameters from the address bar so a refresh does
  /// not replay the resume.
  static void clearStripeRedirectParams() {
    if (!kIsWeb) return;
    platform.clearStripeRedirectParams();
  }
}
