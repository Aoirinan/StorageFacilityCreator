import * as functions from 'firebase-functions/v1';

/**
 * Rebuild the exact URL Twilio signed.
 *
 * Inside a 1st-gen Cloud Function the request path is "/" because the
 * platform strips the function name, so the Twilio SDK's own reconstruction
 * (`protocol://host/`) never matches the configured webhook
 * (`https://host/handleIncomingSMS`) and every inbound text was refused with
 * 403. Put the function name back from the runtime environment. Elsewhere
 * (emulator, a custom domain with a path) the original URL is already right.
 */
export function twilioWebhookUrl(req: functions.https.Request): string {
  const host = req.get?.('host') || req.headers.host || '';
  const original = (req.originalUrl || req.url || '/') as string;
  const forwardedProto = String(req.headers['x-forwarded-proto'] || '').split(',')[0].trim();
  const proto = forwardedProto || (process.env.FUNCTIONS_EMULATOR === 'true' ? 'http' : 'https');
  const fnName = process.env.FUNCTION_TARGET || process.env.K_SERVICE || '';
  const stripped = original.replace(/^\/+/, '');
  const pathIsBare = stripped === '' || stripped.startsWith('?');
  if (fnName && pathIsBare && host.endsWith('cloudfunctions.net')) {
    return `${proto}://${host}/${fnName}${stripped}`;
  }
  return `${proto}://${host}${original}`;
}

/**
 * Validates Twilio `X-Twilio-Signature` for standard form POST webhooks.
 * In the emulator, set TWILIO_SKIP_SIGNATURE_VERIFY=true to skip (local testing only).
 */
export function verifyTwilioWebhookSignature(
  req: functions.https.Request,
  res: functions.Response<unknown>,
  authToken: string,
): boolean {
  if (process.env.FUNCTIONS_EMULATOR === 'true' && process.env.TWILIO_SKIP_SIGNATURE_VERIFY === 'true') {
    functions.logger.warn('Twilio webhook signature verification skipped (emulator only)');
    return true;
  }
  const twilioSdk = require('twilio') as typeof import('twilio') & {
    validateRequest: (
      authToken: string,
      signature: string,
      url: string,
      params: Record<string, unknown>,
    ) => boolean;
  };
  const token = (authToken || '').trim();
  if (!token) {
    functions.logger.error('Twilio webhook: TWILIO_AUTH_TOKEN is empty');
    res.status(500).type('text/plain').send('Webhook misconfigured');
    return false;
  }
  const signature = req.get?.('X-Twilio-Signature') || '';
  const url = twilioWebhookUrl(req);
  try {
    const params = (req.body && typeof req.body === 'object' ? req.body : {}) as Record<string, unknown>;
    const ok = Boolean(signature) && twilioSdk.validateRequest(token, signature, url, params);
    if (!ok) {
      functions.logger.warn('Twilio webhook signature validation failed', {
        url,
        hasSignature: Boolean(signature),
      });
      res.status(403).type('text/plain').send('Forbidden');
      return false;
    }
  } catch (e: unknown) {
    const message = e instanceof Error ? e.message : String(e);
    functions.logger.error('Twilio webhook signature validation error', { message, url });
    res.status(403).type('text/plain').send('Forbidden');
    return false;
  }
  return true;
}
