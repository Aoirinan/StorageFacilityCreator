import { requireTwilioConfigProvider } from './configRegistry';

let twilioClient: unknown = null;

export function isTwilioDryRunEnabled(): boolean {
  const { getDryRun } = requireTwilioConfigProvider();
  return (getDryRun() || 'false').toLowerCase() === 'true';
}

export function getTwilioClient(): unknown {
  if (!twilioClient) {
    const twilioFactory = require('twilio') as typeof import('twilio');
    const { getAccountSid, getAuthToken } = requireTwilioConfigProvider();
    const accountSid = getAccountSid().trim();
    const authToken = getAuthToken().trim();
    twilioClient = twilioFactory(accountSid, authToken);
  }
  return twilioClient;
}
