import type { Twilio } from 'twilio';
import { TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_DRY_RUN } from './secrets';
import type { A2PTwilioClient } from './a2pTwilioTypes';

let twilioClient: any = null;

export function isTwilioDryRunEnabled(): boolean {
  return (TWILIO_DRY_RUN.value() || 'false').toLowerCase() === 'true';
}

export function getTwilioClient(): any {
  if (!twilioClient) {
    const twilioFactory = require('twilio');
    const accountSid = TWILIO_ACCOUNT_SID.value().trim();
    const authToken = TWILIO_AUTH_TOKEN.value().trim();
    twilioClient = twilioFactory(accountSid, authToken);
  }
  return twilioClient;
}

/**
 * The same client, typed for the A2P registration flow. Assigning the SDK's
 * `Twilio` type to `A2PTwilioClient` here is the compile-time check that every
 * method and parameter name the registration code uses exists on the real SDK.
 */
export function getA2PTwilioClient(): A2PTwilioClient {
  const client: Twilio = getTwilioClient();
  return client;
}
