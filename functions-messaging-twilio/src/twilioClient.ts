import { TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_DRY_RUN } from './secrets';

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
