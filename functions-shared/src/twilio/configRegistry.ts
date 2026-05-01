export type TwilioConfigProvider = {
  getAccountSid: () => string;
  getAuthToken: () => string;
  getDryRun: () => string;
};

let twilioConfig: TwilioConfigProvider | null = null;

export function registerTwilioConfigProvider(provider: TwilioConfigProvider): void {
  twilioConfig = provider;
}

export function requireTwilioConfigProvider(): TwilioConfigProvider {
  if (!twilioConfig) {
    throw new Error(
      'Twilio not configured: call registerTwilioConfigProvider(...) from your functions entrypoint before using shared Twilio helpers.',
    );
  }
  return twilioConfig;
}
