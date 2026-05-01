import * as admin from 'firebase-admin';
import * as Sentry from '@sentry/node';

let sentryInitAttempted = false;

/** Idempotent Firebase Admin bootstrap for multi-codebase cold starts. */
export function ensureFirebaseAdminApp(): void {
  if (admin.apps.length === 0) {
    admin.initializeApp();
  }
}

/**
 * Idempotent Sentry bootstrap. Mirrors legacy `functions/src/index.ts` scrubbing rules.
 * Call after `ensureFirebaseAdminApp()` if you use Sentry in that codebase.
 */
export function ensureSentryForFunctions(): void {
  if (sentryInitAttempted) {
    return;
  }
  sentryInitAttempted = true;
  const dsn = process.env.SENTRY_DSN;
  if (!dsn) {
    return;
  }
  Sentry.init({
    dsn,
    environment: process.env.GCLOUD_PROJECT?.includes('dev') ? 'development' : 'production',
    tracesSampleRate: 0.1,
    beforeSend(event) {
      if (event.request) {
        if (
          event.request.url?.includes('/payment') ||
          event.request.url?.includes('/stripe') ||
          event.request.url?.includes('/checkout')
        ) {
          delete event.request.data;
          if ('body' in event.request) {
            delete (event.request as { body?: unknown }).body;
          }
        }
        if (event.request.url) {
          event.request.url = event.request.url.replace(/email=([^&]+)/gi, 'email=[REDACTED]');
        }
      }
      if (event.extra) {
        const sensitiveKeys = ['cardNumber', 'cvv', 'cvc', 'pan', 'paymentMethodId', 'clientSecret'];
        for (const key of sensitiveKeys) {
          if (event.extra?.[key]) {
            event.extra[key] = '[REDACTED]';
          }
        }
      }
      return event;
    },
  });
}
