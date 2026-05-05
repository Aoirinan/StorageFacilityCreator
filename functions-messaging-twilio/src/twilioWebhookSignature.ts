import * as functions from 'firebase-functions/v1';
import type { Request as ExpressRequest } from 'express';

/**
 * Validates Twilio `X-Twilio-Signature` for standard form POST webhooks.
 * In the emulator, set TWILIO_SKIP_SIGNATURE_VERIFY=true to skip (local testing only).
 */
export function verifyTwilioWebhookSignature(
  req: functions.https.Request,
  res: functions.Response<unknown>,
  authToken: string,
): boolean {
  if (
    process.env.FUNCTIONS_EMULATOR === 'true' &&
    process.env.TWILIO_SKIP_SIGNATURE_VERIFY === 'true'
  ) {
    functions.logger.warn('Twilio webhook signature verification skipped (emulator only)');
    return true;
  }
  const twilioSdk = require('twilio') as typeof import('twilio') & {
    validateExpressRequest: (
      req: functions.https.Request,
      authToken: string,
      opts?: Record<string, unknown>,
    ) => boolean;
  };
  const token = (authToken || '').trim();
  if (!token) {
    functions.logger.error('Twilio webhook: TWILIO_AUTH_TOKEN is empty');
    res.status(500).type('text/plain').send('Webhook misconfigured');
    return false;
  }
  try {
    const ok = twilioSdk.validateExpressRequest(req, token, {});
    if (!ok) {
      functions.logger.warn('Twilio webhook signature validation failed', {
        path: (req as ExpressRequest).path,
        hasSignature: Boolean(req.get?.('X-Twilio-Signature')),
      });
      res.status(403).type('text/plain').send('Forbidden');
      return false;
    }
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    functions.logger.error('Twilio webhook signature validation error', { message: msg });
    res.status(403).type('text/plain').send('Forbidden');
    return false;
  }
  return true;
}
