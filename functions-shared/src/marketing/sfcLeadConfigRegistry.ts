export type SfcLeadConfigProvider = {
  getLeadLine: () => string;
  getSmsAutoReply: () => string;
  getForwardTo: () => string;
};

let sfcLeadConfig: SfcLeadConfigProvider | null = null;

export function registerSfcLeadConfigProvider(provider: SfcLeadConfigProvider): void {
  sfcLeadConfig = provider;
}

export function requireSfcLeadConfigProvider(): SfcLeadConfigProvider {
  if (!sfcLeadConfig) {
    throw new Error(
      'SFC lead config not registered: call registerSfcLeadConfigProvider(...) from your functions entrypoint before using shared SFC lead helpers.',
    );
  }
  return sfcLeadConfig;
}
