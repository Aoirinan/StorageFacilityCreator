# Files Reviewed But Intentionally Not Changed

Date: 2026-03-14

## App/Core Logic (Protected)

- `lib/main.dart` - app bootstrap, Firebase/App Check, runtime error handling; high production risk.
- `lib/router/app_router.dart` - authenticated route graph and guard-sensitive app shell.
- `lib/router/app_router_new.dart` - active router provider path used by app startup.
- `lib/router/app_route.dart` - route constants used across app.
- `lib/router/public_routes.dart` - public app routes (`/login`, `/pay`, `/rental`, `/public-move-in`, etc.).
- `lib/router/route_helpers.dart` - route scaffolding/navigation wrappers.

Reason: avoids auth, redirect, and route regression risk.

## Integrations and Billing Runtime (Protected)

- `functions/src/index.ts` - central callable/onRequest runtime for Stripe, Twilio, SendGrid, QuickBooks.
- `functions/src/stripe/tenant_billing.ts` - payment setup, payment intents, autopay behaviors.
- `functions/src/accounting/quickbooks.ts` - QuickBooks OAuth and accounting sync logic.
- `lib/services/stripe_service.dart`
- `lib/services/stripe_connect_service.dart`
- `lib/services/sms_service.dart`
- `lib/services/email_cloud_service.dart`
- `lib/services/quickbooks_service.dart`
- `lib/screens/quickbooks_integration_screen.dart`
- `lib/screens/texting_setup_screen.dart`
- `lib/screens/billing_and_payments_screen.dart`

Reason: mission requires preserving production billing/messaging/accounting functionality.

## Deployment/Security Configuration (Protected)

- `firebase.json`
- `firestore.rules`
- `storage.rules`
- `web/index.html`
- `web/stripe_embedded.html`
- `web/stripe_card_capture.html`

Reason: security/runtime-sensitive config and hosted payment shell behavior.

## Marketing Files Reviewed But Left As-Is

- `marketing/src/app/acceptable-use/page.tsx` - content already structured and cross-linked.
- `marketing/src/app/billing/page.tsx` - pricing/billing legal intent preserved.
- `marketing/src/app/esign-disclosure/page.tsx` - detailed structure already present; no high-confidence legal rewrite needed.
- `marketing/src/app/subprocessors/page.tsx` - table structure already clear and accurate.
- `marketing/src/components/CtaButton.tsx` - variant hierarchy already stable.
- `marketing/src/app/robots.ts` - already correct and stable.

Reason: these files were reviewed but did not require additional safe changes in this execution batch.
