// Non-web platforms never leave the app for a Stripe redirect, so there is
// nothing to park. The kIsWeb checks in tenant_portal_session_store.dart keep
// these from being called.
void parkSession({
  required String email,
  required String accessCode,
  String? tenantId,
  String? setupIntentId,
  required int expiresAtMs,
}) {}

Map<String, Object?>? takeParkedSession() => null;

void clearParkedSession() {}

void clearStripeRedirectParams() {}
