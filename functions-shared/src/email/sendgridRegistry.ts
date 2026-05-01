export type SendgridMailConfigProvider = {
  getApiKey: () => string;
  getFromEmail: () => string;
};

let sendgridConfig: SendgridMailConfigProvider | null = null;

export function registerSendgridMailConfigProvider(provider: SendgridMailConfigProvider): void {
  sendgridConfig = provider;
}

export function requireSendgridMailConfigProvider(): SendgridMailConfigProvider {
  if (!sendgridConfig) {
    throw new Error(
      'SendGrid not configured: call registerSendgridMailConfigProvider(...) from your functions entrypoint before using shared SendGrid helpers.',
    );
  }
  return sendgridConfig;
}
