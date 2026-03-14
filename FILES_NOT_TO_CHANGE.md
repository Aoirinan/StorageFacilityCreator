# Files/Areas Intentionally Not Changed (Audit Guardrails, 2026-03-14)

These files were reviewed during audit and are intentionally out of scope for the marketing/legal refactor unless a minimal, justified compatibility fix is required.

## Flutter app core runtime and routing

- `lib/main.dart` - app bootstrap, Firebase/App Check init, global error handling; high regression risk.
- `lib/router/app_router.dart` - primary authenticated route graph and app shell behavior.
- `lib/router/app_router_new.dart` - modular routing provider used by app startup.
- `lib/router/app_route.dart` - centralized route constants used broadly.
- `lib/router/public_routes.dart` - app public route handling (`/login`, `/tenant-portal`, `/pay`, `/rental`, etc.).
- `lib/router/route_helpers.dart` - shared route shell and navigation wrappers.
- `lib/providers/**` - auth/session/facility state lifecycles.

Reason: changing these can break auth redirects, dashboard access, and production app navigation.

## Cloud Functions integration core

- `functions/src/index.ts` - central callable/onRequest exports for Stripe/Twilio/SendGrid/QuickBooks and many operational flows.
- `functions/src/stripe/tenant_billing.ts` - payment method setup, one-time payment intents, autopay.
- `functions/src/accounting/quickbooks.ts` - QuickBooks OAuth, status, invoice/payment sync, autosync logic.
- `functions/src/migrations/**` - migration scripts not related to marketing changes.

Reason: mission explicitly requires preserving billing/messaging/accounting integrations and env-var behavior.

## App integration services and screens

- `lib/services/stripe_service.dart`, `lib/services/stripe_connect_service.dart`
- `lib/services/sms_service.dart`, `lib/services/messaging_service.dart`
- `lib/services/email_service.dart`, `lib/services/email_cloud_service.dart`
- `lib/services/quickbooks_service.dart`
- `lib/screens/quickbooks_integration_screen.dart`
- `lib/screens/texting_setup_screen.dart`
- `lib/screens/billing_and_payments_screen.dart`
- `lib/screens/tenant_portal_screen.dart`, `lib/screens/public_move_in_screen.dart`, `lib/screens/public_payment_screen.dart`

Reason: production workflows and customer-facing app capability surfaces; not needed for public site refactor.

## Firebase and hosting security configuration

- `firebase.json`
- `firestore.rules`
- `storage.rules`
- `firestore.indexes.json`

Reason: security/runtime-critical platform config with broad blast radius.

## Flutter web shell and payment host files

- `web/index.html`
- `web/stripe_embedded.html`
- `web/stripe_card_capture.html`
- `web/accept-invite.html`

Reason: directly affects web app boot and payment capture behavior.

## Why these are preserved

- They are high-risk production logic surfaces.
- Requested improvements can be delivered inside `marketing/` with additive UI/content/SEO updates.
- Preserving these files minimizes regression risk for auth, billing, integrations, and app routing.
